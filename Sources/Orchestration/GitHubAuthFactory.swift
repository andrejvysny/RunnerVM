import Foundation
import GitHubControl
import RunnerCore

/// Where the daemon reads — and, for `auth login`, writes — the GitHub PAT for one
/// `GitHubAuthConfig.Source` (spec §12).
///
/// The store is the *only* place that knows the concrete location, so `auth.status`,
/// `auth.login` and `auth.logout` all report the same string and can never disagree about which
/// keychain item or file the daemon is actually using.
public enum GitHubTokenStore: Sendable {
  case environment(variable: String)
  case file(url: URL)
  case keychain(service: String, account: String, keychain: any KeychainItemStore)

  public static let fileName = "github-token"
  public static let keychainAccount = "default"

  public var location: String {
    switch self {
    case let .environment(variable): "environment \(variable)"
    case let .file(url): "file \(url.path(percentEncoded: false))"
    case let .keychain(service, account, _): "keychain \(service)/\(account)"
    }
  }

  public var provider: any GitHubCredentialProvider {
    switch self {
    case let .environment(variable):
      EnvironmentPATProvider(variable: variable)
    case let .file(url):
      FilePATProvider(url: url)
    case let .keychain(service, account, keychain):
      KeychainPATProvider(service: service, account: account, keychain: keychain)
    }
  }

  /// `auth login`. The environment is not a store the daemon can write to, and pretending
  /// otherwise would silently drop the operator's token.
  public func write(token: String) throws {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw GitHubControlError.permanentConfiguration(reason: "refusing to store an empty token")
    }
    switch self {
    case let .environment(variable):
      throw GitHubControlError.permanentConfiguration(
        reason: "github.auth.source is 'env'; export \(variable) instead of using auth login")
    case let .file(url):
      try Self.writeFile(trimmed, to: url)
    case let .keychain(service, account, keychain):
      try KeychainPATProvider(service: service, account: account, keychain: keychain)
        .store(token: trimmed)
    }
  }

  /// `auth logout`. Idempotent; `false` means there was nothing stored.
  @discardableResult
  public func clear() throws -> Bool {
    switch self {
    case let .environment(variable):
      throw GitHubControlError.permanentConfiguration(
        reason: "github.auth.source is 'env'; unset \(variable) instead of using auth logout")
    case let .file(url):
      let path = url.path(percentEncoded: false)
      guard FileManager.default.fileExists(atPath: path) else { return false }
      try FileManager.default.removeItem(at: url)
      return true
    case let .keychain(service, account, keychain):
      let existed = (try? keychain.password(service: service, account: account)) ?? nil
      try KeychainPATProvider(service: service, account: account, keychain: keychain).remove()
      return existed != nil
    }
  }

  /// Owner-only from the moment the file exists: `FilePATProvider` refuses to read anything
  /// looser, and a token with `admin:org` in a world-readable file is a host-wide compromise.
  private static func writeFile(_ token: String, to url: URL) throws {
    let manager = FileManager.default
    let path = url.path(percentEncoded: false)
    do {
      try manager.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      guard manager.createFile(
        atPath: path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
      else {
        throw GitHubControlError.permanentConfiguration(reason: "cannot write token file \(path)")
      }
      // `createFile` keeps the mode of a file that already existed, so it is reasserted here.
      try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    } catch let error as GitHubControlError {
      throw error
    } catch {
      throw GitHubControlError.permanentConfiguration(
        reason: "cannot write token file \(path): \(error.localizedDescription)")
    }
  }
}

/// `{clientId|appId, installationId, privateKeyPath}` at `<stateDir>/github-app.json` (spec §12).
struct GitHubAppFile: Decodable, Sendable {
  var appID: String
  var installationID: Int64
  var privateKeyPath: String

  private enum CodingKeys: String, CodingKey {
    case appId, clientId, installationId, privateKeyPath
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // GitHub now shows a `clientId` (`Iv23…`) where it used to show a numeric app id; both are
    // accepted as the JWT `iss`.
    let id = try container.decodeIfPresent(String.self, forKey: .clientId)
      ?? container.decodeIfPresent(String.self, forKey: .appId)
      ?? container.decodeIfPresent(Int64.self, forKey: .appId).map(String.init)
    guard let id, !id.isEmpty else {
      throw GitHubControlError.permanentConfiguration(
        reason: "github-app.json has neither clientId nor appId")
    }
    appID = id
    installationID = try container.decode(Int64.self, forKey: .installationId)
    privateKeyPath = try container.decode(String.self, forKey: .privateKeyPath)
  }
}

/// Builds the daemon's credential provider from `github.auth` (spec §12).
///
/// Exactly one source is consulted: the one the configuration names. A silent fallback chain
/// would let a stale keychain item shadow the token an operator just exported, and `auth status`
/// could then report a credential the next request does not use.
public enum GitHubAuthFactory {
  public struct Resolved: Sendable {
    public let provider: any GitHubCredentialProvider
    /// `nil` for `provider: app` — the App flow has no token for `auth login` to write.
    public let store: GitHubTokenStore?
    public let location: String
  }

  public static func resolve(
    auth: GitHubAuthConfig,
    paths: RunnerPaths,
    keychain: any KeychainItemStore = SecurityKeychainStore(),
    session: URLSession = .shared,
    baseURL: URL = GitHubHTTPClient.defaultBaseURL
  ) throws -> Resolved {
    switch auth.provider {
    case .pat:
      let store = tokenStore(source: auth.source, paths: paths, keychain: keychain)
      return Resolved(provider: store.provider, store: store, location: store.location)
    case .app:
      // TODO(M6): `runnerctl auth app --app-id … --installation-id … --key <path>` should write
      // this file; today an operator places it by hand.
      let url = paths.stateDir.appending(path: "github-app.json")
      let provider = try appProvider(at: url, session: session, baseURL: baseURL)
      return Resolved(
        provider: provider, store: nil,
        location: "GitHub App \(url.path(percentEncoded: false))")
    }
  }

  public static func tokenStore(
    source: GitHubAuthConfig.Source, paths: RunnerPaths, keychain: any KeychainItemStore
  ) -> GitHubTokenStore {
    switch source {
    case .env:
      .environment(variable: EnvironmentPATProvider.defaultVariable)
    case .file:
      .file(url: paths.stateDir.appending(path: GitHubTokenStore.fileName))
    case .keychain:
      .keychain(
        service: KeychainPATProvider.defaultService,
        account: GitHubTokenStore.keychainAccount, keychain: keychain)
    }
  }

  private static func appProvider(
    at url: URL, session: URLSession, baseURL: URL
  ) throws -> any GitHubCredentialProvider {
    let path = url.path(percentEncoded: false)
    let data = try SecureFile.read(
      path: path, label: "GitHub App descriptor", policy: .ownerAndGroupRead)
    let file: GitHubAppFile
    do {
      file = try JSONDecoder().decode(GitHubAppFile.self, from: data)
    } catch let error as GitHubControlError {
      throw error
    } catch {
      throw GitHubControlError.permanentConfiguration(
        reason: "\(path) is not a valid GitHub App descriptor: \(error)")
    }
    let keyPath = resolvedPrivateKeyPath(file.privateKeyPath, relativeTo: url)
    let pem = try SecureFile.readString(
      path: keyPath, label: "GitHub App private key", policy: .ownerOnly)
    return try GitHubAppCredentialProvider(
      appID: file.appID, installationID: file.installationID, privateKeyPEM: pem,
      baseURL: baseURL, session: session)
  }

  /// A relative `privateKeyPath` in `github-app.json` is resolved against the *descriptor's*
  /// directory, not the process's working directory — `runnerd` is a daemon with no meaningful
  /// cwd, so a relative path must be anchored to something stable.
  private static func resolvedPrivateKeyPath(
    _ privateKeyPath: String, relativeTo descriptorURL: URL
  ) -> String {
    guard !privateKeyPath.hasPrefix("/") else { return privateKeyPath }
    return descriptorURL.deletingLastPathComponent()
      .appending(path: privateKeyPath).path(percentEncoded: false)
  }
}
