import Foundation
import RunnerCore

/// `release-manifest.json`, the machine-readable pointer every release carries
/// (`docs/design/distribution.md`, "Release artifacts and manifest"). `scripts/bootstrap.sh` reads
/// the same document with `jq`; this is the Swift half, used by `runnerctl upgrade`.
///
/// Decoding is lenient in exactly the way the rest of the wire types are: the four fields an
/// installer cannot proceed without are required, and everything else falls back to what a release
/// built before that key existed meant.
public struct ReleaseManifest: Codable, Sendable, Hashable {
  /// `0.2.0` — no leading `v`. The git tag is `v` + this.
  public var version: String
  public var architecture: String
  public var minimumMacOS: String
  /// The pkg asset's file name, e.g. `RunnerVM-macos-arm64.pkg`. Validated on decode: it is
  /// appended to a URL and handed to `installer`, so it may not be an arbitrary string.
  public var package: String
  /// 64 lowercase hex characters.
  public var sha256: String
  /// A Developer ID Installer signature was present when the release was built.
  public var signed: Bool
  /// The Apple Team ID that signed the release, `""` on an unsigned build.
  ///
  /// A claim, never a reference. It travels in the same document as the package it describes, so
  /// anyone who can publish a manifest can publish this field; the install-side gate compares the
  /// signature's own team against `RunnerVMSigning.expectedTeamID` and ignores this value.
  public var teamId: String
  /// The release was stapled with a notary ticket when it was built. Same status as `teamId`: it
  /// is what `--check` reports, not what `upgrade` decides on.
  public var notarized: Bool
  public var license: String

  public init(
    version: String,
    architecture: String = "arm64",
    minimumMacOS: String = "15.0",
    package: String,
    sha256: String,
    signed: Bool = false,
    teamId: String = "",
    notarized: Bool = false,
    license: String = "Apache-2.0"
  ) {
    self.version = version
    self.architecture = architecture
    self.minimumMacOS = minimumMacOS
    self.package = package
    self.sha256 = sha256
    self.signed = signed
    self.teamId = teamId
    self.notarized = notarized
    self.license = license
  }

  private enum CodingKeys: String, CodingKey {
    case version, architecture, minimumMacOS, package, sha256, signed, teamId, notarized, license
  }

  /// Deliberately more lenient than `bootstrap.sh`, which hard-fails on a missing `architecture`,
  /// `minimumMacOS` or `signed`. The asymmetry is not an oversight and should not be "fixed" on
  /// either side: bash only ever reads a manifest it has just downloaded from a current release,
  /// while this decoder also reads manifests cached on disk by *older* releases -- including the
  /// one a rollback reads to find the previous package's file name, which predates keys that did
  /// not exist when it was written. Only the fields an installer cannot proceed without
  /// (`version`, `package`, `sha256`) are required here; the rest fall back to what a release
  /// built before that key existed meant.
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let package = try c.decode(String.self, forKey: .package)
    try ReleaseManifest.validate(packageName: package)
    let version = try c.decode(String.self, forKey: .version)
    try ReleaseManifest.validate(version: version)
    self.init(
      version: version,
      architecture: try c.decodeIfPresent(String.self, forKey: .architecture) ?? "arm64",
      minimumMacOS: try c.decodeIfPresent(String.self, forKey: .minimumMacOS) ?? "15.0",
      package: package,
      sha256: try c.decode(String.self, forKey: .sha256),
      // A release published before the key existed was unsigned; that is the safe default,
      // because it makes `upgrade` warn rather than silently skip the warning.
      signed: try c.decodeIfPresent(Bool.self, forKey: .signed) ?? false,
      teamId: try c.decodeIfPresent(String.self, forKey: .teamId) ?? "",
      notarized: try c.decodeIfPresent(Bool.self, forKey: .notarized) ?? false,
      license: try c.decodeIfPresent(String.self, forKey: .license) ?? "Apache-2.0")
  }

  /// `^[A-Za-z0-9._-]+\.pkg$`, plus no leading `-`: the same rule `bootstrap.sh`'s
  /// `verify_pkg_name` enforces, because the two installers must refuse the same documents.
  ///
  /// The name is appended to a release URL, written into the cache directory and passed to
  /// `installer` as an argument, so `../`, a shell metacharacter or a leading dash in it is not a
  /// cosmetic problem. Refused at decode, which is before the download: a name this host will not
  /// install is not something to discover after `curl` has already written it somewhere.
  public static func validate(packageName name: String) throws {
    guard !name.isEmpty else {
      throw UpgradeError.manifestInvalid(detail: "'package' is empty")
    }
    guard !name.hasPrefix("-") else {
      throw UpgradeError.manifestInvalid(
        detail: "'package' '\(name)' must not start with '-'")
    }
    guard name.hasSuffix(".pkg"), name.count > ".pkg".count else {
      throw UpgradeError.manifestInvalid(detail: "'package' '\(name)' does not end in .pkg")
    }
    guard name.allSatisfy({ character in
      character.isASCII
        && (character.isLetter || character.isNumber || character == "." || character == "_"
          || character == "-")
    }) else {
      throw UpgradeError.manifestInvalid(
        detail: "'package' '\(name)' contains characters outside [A-Za-z0-9._-]")
    }
  }

  /// `version` names the cache directory (`upgrades/<version>/`) and rides on the `curl -o` and
  /// `spctl` command lines, so it is held to the same "plain token" rule as the package name:
  /// `MAJOR.MINOR.PATCH` with an optional dot/dash/alphanumeric prerelease suffix.
  ///
  /// The digit tests are `isASCII && isNumber`, not `isNumber` alone: `Character.isNumber` is true
  /// for every Unicode decimal digit, so `١.٢.٣` would pass here and fail `bootstrap.sh`'s
  /// `*[!0-9]*` glob -- and a rule the two installers apply differently is not a rule.
  public static func validate(version: String) throws {
    let parts = version.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    let core = parts[0].split(separator: ".", omittingEmptySubsequences: false)
    guard core.count == 3, core.allSatisfy({ field in
      !field.isEmpty && field.allSatisfy { $0.isASCII && $0.isNumber }
    }) else {
      throw UpgradeError.manifestInvalid(detail: "'version' '\(version)' is not MAJOR.MINOR.PATCH")
    }
    if parts.count == 2 {
      let suffix = parts[1]
      guard !suffix.isEmpty, suffix.allSatisfy({ character in
        character.isASCII
          && (character.isLetter || character.isNumber || character == "." || character == "-")
      }) else {
        throw UpgradeError.manifestInvalid(
          detail: "'version' '\(version)' has a prerelease suffix outside [0-9A-Za-z.-]")
      }
    }
  }

  /// What the manifest *claims* about its own package, for `--check` and the ladder. Never a
  /// verification: `Upgrader.signatureStep` reads the package's actual signature on this host.
  public var signingClaim: String {
    guard signed else { return "unsigned" }
    let team = teamId.isEmpty ? "team not stated" : teamId
    return "\(notarized ? "signed+notarized" : "signed, not notarized") (\(team))"
  }

  /// The one-line summary `--check` and the pre-drain confirmation both print.
  public var summary: String {
    "\(version) (\(package), \(architecture), macOS \(minimumMacOS)+, \(signingClaim))"
  }

  public static func decode(_ json: String) throws -> ReleaseManifest {
    guard let data = json.data(using: .utf8) else {
      throw UpgradeError.manifestInvalid(detail: "not UTF-8")
    }
    do {
      return try JSONDecoder().decode(ReleaseManifest.self, from: data)
    } catch let error as UpgradeError {
      // The package-name rule raises its own message; wrapping it in a decoding error would bury
      // the one sentence that says what is wrong with the release.
      throw error
    } catch {
      throw UpgradeError.manifestInvalid(detail: "\(error)")
    }
  }

  /// Refuses before anything is downloaded, exactly where `bootstrap.sh`'s
  /// `verify_manifest_platform` refuses: a manifest for another architecture or a newer macOS is
  /// not something to discover after `installer -pkg` has already run.
  public func validatePlatform(
    architecture hostArchitecture: String = ReleaseManifest.hostArchitecture,
    macOSMajor: Int = ReleaseManifest.hostMacOSMajor
  ) throws {
    guard architecture == hostArchitecture else {
      throw UpgradeError.platformUnsupported(
        detail: "release \(version) is \(architecture); this host is \(hostArchitecture)")
    }
    guard let required = Int(minimumMacOS.split(separator: ".").first ?? "") else {
      throw UpgradeError.manifestInvalid(detail: "unparsable minimumMacOS '\(minimumMacOS)'")
    }
    guard macOSMajor >= required else {
      throw UpgradeError.platformUnsupported(
        detail: "release \(version) requires macOS \(minimumMacOS)+; this host is \(macOSMajor)")
    }
  }

  // MARK: - Host facts

  /// `arm64` on every machine RunnerVM supports; read rather than assumed, so a manifest/host
  /// mismatch is reported with the truth.
  public static var hostArchitecture: String {
    var size = 0
    sysctlbyname("hw.machine", nil, &size, nil, 0)
    guard size > 0 else { return "unknown" }
    var buffer = [UInt8](repeating: 0, count: size)
    sysctlbyname("hw.machine", &buffer, &size, nil, 0)
    let terminator = buffer.firstIndex(of: 0) ?? buffer.count
    return String(decoding: buffer[..<terminator], as: UTF8.self)
  }

  public static var hostMacOSMajor: Int {
    ProcessInfo.processInfo.operatingSystemVersion.majorVersion
  }
}

// MARK: - Where a release is fetched from

/// Resolves the three URLs an upgrade needs. `latest` uses GitHub's `/releases/latest/download/`
/// redirect — the same URL shape the `curl | sudo bash` one-liner uses — so "upgrade to whatever is
/// current" never has to list tags first.
public struct ReleaseSource: Sendable, Hashable {
  public static let defaultRepository = "andrejvysny/RunnerVM"
  public static let manifestName = "release-manifest.json"

  /// Always ends with `/`.
  public let baseURL: String

  public init(baseURL: String) {
    self.baseURL = baseURL.hasSuffix("/") ? baseURL : baseURL + "/"
  }

  public static func latest(repository: String = defaultRepository) -> ReleaseSource {
    ReleaseSource(baseURL: "https://github.com/\(repository)/releases/latest/download")
  }

  /// `version` may be given with or without the `v`; the tag always carries it.
  public static func tagged(
    _ version: String, repository: String = defaultRepository
  ) -> ReleaseSource {
    let tag = version.hasPrefix("v") ? version : "v\(version)"
    return ReleaseSource(baseURL: "https://github.com/\(repository)/releases/download/\(tag)")
  }

  /// `RUNNERVM_PKG_URL` when set (the same operator seam `bootstrap.sh` exposes, for a mirror or
  /// a local `file://` directory), else `--version` when given, else `latest`.
  ///
  /// The override wins because it is the more specific instruction -- an operator who points this
  /// host at a mirror means that mirror, tag or no tag -- and because `bootstrap.sh` has always
  /// resolved it that way. Two installers that disagree about where a release comes from is the
  /// kind of difference that only shows up on the host that has both set.
  public static func resolve(
    version: String?, overrideURL: String? = nil, repository: String = defaultRepository
  ) -> ReleaseSource {
    if let overrideURL, !overrideURL.isEmpty { return ReleaseSource(baseURL: overrideURL) }
    if let version, !version.isEmpty { return .tagged(version, repository: repository) }
    return .latest(repository: repository)
  }

  public var manifestURL: String { baseURL + Self.manifestName }

  public func assetURL(_ name: String) -> String { baseURL + name }
}

// MARK: - Errors

/// Failures the upgrader raises itself. Command failures still surface as
/// `SetupError.commandFailed`: the two share `CommandRunner`, and an `installer` exit code should
/// read the same wherever it came from.
public enum UpgradeError: RunnerError {
  case manifestUnreachable(url: String, detail: String)
  case manifestInvalid(detail: String)
  case platformUnsupported(detail: String)
  case checksumMismatch(detail: String)
  /// Signed by a Developer ID this build is not pinned to. Deliberately has no override.
  case signatureRejected(found: String, expected: String)
  case declined(step: String)
  case notRoot

  public var code: String {
    switch self {
    case .manifestUnreachable: "UPGRADE_MANIFEST_UNREACHABLE"
    case .manifestInvalid: "UPGRADE_MANIFEST_INVALID"
    case .platformUnsupported: "UPGRADE_PLATFORM_UNSUPPORTED"
    case .checksumMismatch: "UPGRADE_CHECKSUM_MISMATCH"
    case .signatureRejected: "UPGRADE_SIGNATURE_REJECTED"
    case .declined: "UPGRADE_DECLINED"
    case .notRoot: "UPGRADE_NOT_ROOT"
    }
  }

  public var message: String {
    switch self {
    case let .manifestUnreachable(url, detail):
      "cannot reach \(url): \(detail)"
    case let .manifestInvalid(detail):
      "release-manifest.json is not usable: \(detail)"
    case let .platformUnsupported(detail):
      "\(detail); nothing was installed"
    case let .checksumMismatch(detail):
      "\(detail); nothing was installed"
    case let .signatureRejected(found, expected):
      "the package is signed by Apple Team \(found), not \(expected), the publisher this build "
        + "of RunnerVM is pinned to; nothing was installed"
    case let .declined(step):
      "aborted at \(step); nothing was changed"
    case .notRoot:
      "upgrade installs a pkg and reloads the launchd job, so it needs root: "
        + "re-run as `sudo runnerctl upgrade`"
    }
  }

  public var retryable: Bool {
    switch self {
    case .manifestUnreachable: true
    default: false
    }
  }
}
