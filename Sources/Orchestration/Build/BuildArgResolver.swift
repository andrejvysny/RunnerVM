import Foundation
import GitHubControl
import ImageBuild
import RunnerCore

/// How the runner version and its tarball digest were established, for `provenance.actionsRunner`.
public struct ResolvedBuildArgs: Sendable, Hashable {
  public var args: [String: String]
  /// `github-release-asset` or `operator`; `nil` when the recipe declares no runner arguments.
  public var digestSource: String?
  public var runnerVersion: String?
  public var runnerSHA256: String?
}

/// What `BuildArgResolver` needs from GitHub. A protocol rather than `GitHubRunnersAPI` directly
/// because the resolver must work with *no* credential at all (anonymous `releases/latest` is a
/// public endpoint) and because tests must never reach api.github.com.
public protocol RunnerReleaseLookup: Sendable {
  /// Newest published `actions/runner` version, without the leading `v`.
  func latestVersion() async throws -> String?
  /// `sha256:<hex>` GitHub publishes for one release asset, or `nil` when it publishes none.
  func assetDigest(version: String, asset: String) async throws -> String?
}

/// Resolves build arguments before a recipe is planned, so the string `latest` never reaches the
/// guest and `RUNNER_SHA256` is either GitHub's own asset digest or an operator's explicit pin.
///
/// Fails closed: a recipe that declares `ARG RUNNER_SHA256` and gets no digest from anywhere is
/// `BUILD_RUNNER_DIGEST_UNAVAILABLE`, not a build that downloads an unverified tarball as root.
public struct BuildArgResolver: Sendable {
  public static let versionArg = "RUNNER_VERSION"
  public static let digestArg = "RUNNER_SHA256"
  public static let sudoArg = "RUNNER_SUDO"

  private let lookup: (any RunnerReleaseLookup)?

  public init(lookup: (any RunnerReleaseLookup)?) {
    self.lookup = lookup
  }

  public func resolve(
    recipe: Recipe, requested: [String: String]
  ) async throws -> ResolvedBuildArgs {
    // Fail closed before anything is persisted: the resolved map lands in `args_json`, in the
    // image provenance and in the pushed OCI config, none of which is redacted.
    if let key = BuildArgumentPolicy.firstSecretLookingArgument(in: requested) {
      throw ImageBuildError.argumentLooksLikeSecret(key: key)
    }
    var args = requested
    let declared = Set(recipe.declaredArgs)
    guard declared.contains(Self.versionArg) || declared.contains(Self.digestArg) else {
      return ResolvedBuildArgs(args: args, digestSource: nil)
    }
    let version = try await resolveVersion(declared: declared, args: &args, recipe: recipe)
    guard declared.contains(Self.digestArg) else {
      return ResolvedBuildArgs(
        args: args, digestSource: nil, runnerVersion: version, runnerSHA256: nil)
    }
    let pinned = Self.nonEmpty(args[Self.digestArg])
    let published = try? await lookup?.assetDigest(
      version: version ?? "", asset: Self.assetName(version: version ?? ""))
    let digest = try Self.reconcile(pinned: pinned, published: published, version: version)
    args[Self.digestArg] = digest.value
    return ResolvedBuildArgs(
      args: args, digestSource: digest.source, runnerVersion: version, runnerSHA256: digest.value)
  }

  /// `latest`, an empty value, or no value at all all mean "ask GitHub"; anything else is an
  /// operator pin and is left alone.
  private func resolveVersion(
    declared: Set<String>, args: inout [String: String], recipe: Recipe
  ) async throws -> String? {
    guard declared.contains(Self.versionArg) else { return nil }
    let requested = Self.nonEmpty(args[Self.versionArg]) ?? Self.declaredDefault(
      Self.versionArg, in: recipe)
    if let requested, requested != "latest" {
      args[Self.versionArg] = requested
      return requested
    }
    guard let resolved = try await lookup?.latestVersion(), !resolved.isEmpty else {
      throw ImageBuildError.runnerVersionUnresolved
    }
    args[Self.versionArg] = resolved
    return resolved
  }

  private static func reconcile(
    pinned: String?, published: String?, version: String?
  ) throws -> (value: String, source: String) {
    let normalizedPin = pinned.map(strip)
    let normalizedPublished = published.map(strip)
    if let normalizedPin {
      if let normalizedPublished, normalizedPublished != normalizedPin {
        throw ImageBuildError.runnerDigestMismatch
      }
      return (normalizedPin, "operator")
    }
    guard let normalizedPublished else {
      throw ImageBuildError.runnerDigestUnavailable(version: version ?? "unknown")
    }
    return (normalizedPublished, "github-release-asset")
  }

  static func assetName(version: String) -> String {
    "actions-runner-linux-arm64-\(version).tar.gz"
  }

  private static func strip(_ digest: String) -> String {
    digest.hasPrefix("sha256:") ? String(digest.dropFirst("sha256:".count)) : digest
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  private static func declaredDefault(_ name: String, in recipe: Recipe) -> String? {
    for case let .arg(argName, defaultValue, _) in recipe.instructions where argName == name {
      return nonEmpty(defaultValue)
    }
    return nil
  }
}

/// Production `RunnerReleaseLookup`: the daemon's cached view of the newest release first, then a
/// direct (possibly anonymous) call for the asset digest, which nothing else caches.
public struct GitHubRunnerReleaseLookup: RunnerReleaseLookup {
  private let versions: RunnerVersionMonitor?
  private let gateway: GitHubGateway?
  private let session: URLSession
  private let baseURL: URL

  public init(
    versions: RunnerVersionMonitor?, gateway: GitHubGateway?, session: URLSession = .shared,
    baseURL: URL = URL(string: "https://api.github.com")!
  ) {
    self.versions = versions
    self.gateway = gateway
    self.session = session
    self.baseURL = baseURL
  }

  public func latestVersion() async throws -> String? {
    if let cached = await versions?.latest()?.version { return cached }
    // A gateway without a working credential answers nil (or throws); that is not "no release",
    // so fall through to the anonymous endpoint rather than giving up.
    if let api = await gateway?.runnersAPI(), let version = try? await api.latestRunnerVersion() {
      return version
    }
    return try await anonymous(path: "/repos/actions/runner/releases/latest")?.version
  }

  /// GitHub publishes `assets[].digest` as `sha256:<hex>` on recent releases only; an older one
  /// simply has none, which the resolver turns into `BUILD_RUNNER_DIGEST_UNAVAILABLE`.
  public func assetDigest(version: String, asset: String) async throws -> String? {
    guard !version.isEmpty else { return nil }
    let release = try await anonymous(path: "/repos/actions/runner/releases/tags/v\(version)")
    return release?.assets?.first { $0.name == asset }?.digest
  }

  private struct Release: Decodable {
    struct Asset: Decodable {
      var name: String
      var digest: String?
    }

    var tagName: String?
    var assets: [Asset]?

    var version: String? {
      guard let tagName else { return nil }
      return tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }

    private enum CodingKeys: String, CodingKey {
      case tagName = "tag_name"
      case assets
    }
  }

  private func anonymous(path: String) async throws -> Release? {
    var request = URLRequest(url: baseURL.appending(path: path))
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("runnervm", forHTTPHeaderField: "User-Agent")
    guard let (data, response) = try? await session.data(for: request),
          (response as? HTTPURLResponse)?.statusCode == 200
    else { return nil }
    return try? JSONDecoder().decode(Release.self, from: data)
  }
}
