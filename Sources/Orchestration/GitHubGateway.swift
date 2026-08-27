import DaemonAPI
import Foundation
import GitHubControl
import Logging
import RunnerCore
import RunnerLogging

/// The daemon's single door to GitHub (spec §12, §50).
///
/// Owns one `GitHubHTTPClient` for the whole process, rebuilt only when `github.auth` changes, and
/// caches the last credential probe so `system.status` never has to reach api.github.com.
public actor GitHubGateway {
  public struct Options: Sendable {
    public var paths: RunnerPaths
    public var baseURL: URL
    public var session: URLSession
    public var keychain: any KeychainItemStore
    public var http: GitHubHTTPClient.Options
    /// Builds the scale-set control plane over the same credential and connection pool. `nil`
    /// uses `ActionsScaleSetClient`; tests inject a fake so no component test reaches the preview
    /// Actions service.
    public var scaleSetPlane: (@Sendable (GitHubHTTPClient) -> any ScaleSetControlPlane)?
    /// Receives one outcome per HTTP attempt; the daemon wires `MetricsGitHubRequestObserver`.
    public var requestObserver: (any GitHubRequestObserver)?

    public init(
      paths: RunnerPaths,
      baseURL: URL = GitHubHTTPClient.defaultBaseURL,
      session: URLSession = .shared,
      keychain: any KeychainItemStore = SecurityKeychainStore(),
      http: GitHubHTTPClient.Options = GitHubHTTPClient.Options(),
      scaleSetPlane: (@Sendable (GitHubHTTPClient) -> any ScaleSetControlPlane)? = nil,
      requestObserver: (any GitHubRequestObserver)? = nil
    ) {
      self.paths = paths
      self.baseURL = baseURL
      self.session = session
      self.keychain = keychain
      self.http = http
      self.scaleSetPlane = scaleSetPlane
      self.requestObserver = requestObserver
    }
  }

  private let options: Options
  private let logger: Logger
  private var configuration: RunnerConfiguration?
  private var resolved: GitHubAuthFactory.Resolved?
  private var plane: RESTControlPlane?
  private var scaleSets: (any ScaleSetControlPlane)?
  private var cached: AuthStatus

  public init(options: Options, logger: Logger = Logger(component: .github)) {
    self.options = options
    self.logger = logger
    cached = Self.unconfigured(
      auth: GitHubAuthConfig(), location: "-",
      hint: "apply a configuration with `runnerctl config apply`")
  }

  // MARK: - Configuration

  /// Called on every `config.apply` and at bootstrap. Rebuilding the client here — rather than
  /// per request — keeps a single connection pool and a single App-token cache.
  public func updateConfiguration(_ config: RunnerConfiguration?) {
    configuration = config
    plane = nil
    scaleSets = nil
    resolved = nil
    guard let config else {
      cached = Self.unconfigured(
        auth: GitHubAuthConfig(), location: "-",
        hint: "apply a configuration with `runnerctl config apply`")
      return
    }
    do {
      let resolution = try GitHubAuthFactory.resolve(
        auth: config.github.auth, paths: options.paths, keychain: options.keychain,
        session: options.session, baseURL: options.baseURL)
      resolved = resolution
      let client = GitHubHTTPClient(
        baseURL: options.baseURL, credentials: resolution.provider, session: options.session,
        options: options.http, logger: logger, observer: options.requestObserver)
      plane = RESTControlPlane(client: client)
      scaleSets = makeScaleSetPlane(client)
      cached = Self.unknown(auth: config.github.auth, location: resolution.location)
    } catch {
      cached = Self.problem(
        auth: config.github.auth, location: "-", state: "invalid", error: error,
        hint: "fix github.auth in the configuration")
      logger.error(
        "GitHub credentials are unusable",
        metadata: ["error": .string(Self.describe(error))])
    }
  }

  public func controlPlane() -> (any GitHubActionsControlPlane)? { plane }

  /// Spec §50. `nil` until a configuration with a usable credential has been applied — the
  /// scale-set protocol is still public preview, so nothing in the daemon may assume it exists.
  public func scaleSetControlPlane() -> (any ScaleSetControlPlane)? { scaleSets }

  /// One client per credential, sharing the REST connection pool and the App-token cache.
  private func makeScaleSetPlane(_ client: GitHubHTTPClient) -> any ScaleSetControlPlane {
    if let factory = options.scaleSetPlane { return factory(client) }
    return ActionsScaleSetClient(
      http: client, apiBaseURL: options.baseURL, session: options.session, logger: logger)
  }

  public func runnersAPI() -> GitHubRunnersAPI? { plane?.api }

  public func allowPublicRepositories() -> Bool {
    configuration?.security.allowPublicRepositories ?? false
  }

  // MARK: - auth.*

  /// Last probe result. Never touches the network — but while nothing has been probed yet it
  /// does read the local credential source, so `auth status` and `system.status` can say
  /// "unconfigured" instead of the useless "unknown" before the first maintenance tick.
  public func snapshot() async -> AuthStatus {
    guard cached.state == "unknown", let auth = configuration?.github.auth,
          auth.provider == .pat, let resolved
    else { return cached }
    do {
      _ = try await resolved.provider.credential()
    } catch let error as GitHubControlError where error.errorClass == .notFound {
      cached = Self.unconfigured(
        auth: auth, location: resolved.location, hint: Self.loginHint(auth))
    } catch {
      cached = Self.problem(
        auth: auth, location: resolved.location, state: "invalid", error: error,
        hint: Self.loginHint(auth))
    }
    return cached
  }

  /// One live credential check (spec §148). Also the maintenance loop's refresh of `snapshot()`.
  @discardableResult
  public func probe() async -> AuthStatus {
    guard let config = configuration, let resolved else { return cached }
    let auth = config.github.auth
    let credential: GitHubCredential
    do {
      credential = try await resolved.provider.credential()
    } catch let error as GitHubControlError where error.errorClass == .notFound {
      cached = Self.unconfigured(
        auth: auth, location: resolved.location, hint: Self.loginHint(auth))
      return cached
    } catch {
      cached = Self.problem(
        auth: auth, location: resolved.location, state: "invalid", error: error,
        hint: Self.loginHint(auth))
      return cached
    }
    cached = await verify(credential, auth: auth, location: resolved.location)
    return cached
  }

  /// A PAT has a login to report; a GitHub App installation token has no user, and minting it
  /// already proved the key, the app id and the installation are all good.
  private func verify(
    _ credential: GitHubCredential, auth: GitHubAuthConfig, location: String
  ) async -> AuthStatus {
    guard credential.kind == .pat, let api = plane?.api else {
      return AuthStatus(
        state: "healthy", provider: auth.provider.rawValue, source: auth.source.rawValue,
        location: location, checkedAt: RFC3339.string(from: Date()))
    }
    do {
      let login = try await api.whoAmI()
      return AuthStatus(
        state: "healthy", provider: auth.provider.rawValue, source: auth.source.rawValue,
        location: location, login: login, checkedAt: RFC3339.string(from: Date()))
    } catch {
      let authentication = (error as? GitHubControlError)?.errorClass == .authentication
      return Self.problem(
        auth: auth, location: location, state: authentication ? "invalid" : "degraded",
        error: error, hint: authentication ? Self.loginHint(auth) : nil)
    }
  }

  public func login(token: String) async throws -> AuthLoginResponse {
    let store = try requireStore()
    try store.write(token: token)
    logger.notice("github credential stored", metadata: ["location": .string(store.location)])
    return AuthLoginResponse(location: store.location, status: await probe())
  }

  public func logout() async throws -> AuthLogoutResponse {
    let store = try requireStore()
    let removed = try store.clear()
    logger.notice(
      "github credential removed",
      metadata: ["location": .string(store.location), "removed": .stringConvertible(removed)])
    _ = await probe()
    return AuthLogoutResponse(location: store.location, removed: removed)
  }

  private func requireStore() throws -> GitHubTokenStore {
    guard let resolved else {
      throw OrchestrationError.githubNotConfigured(
        reason: "no configuration has been applied yet")
    }
    guard let store = resolved.store else {
      throw OrchestrationError.githubNotConfigured(
        reason: "github.auth.provider is 'app'; there is no token to store")
    }
    return store
  }

  // MARK: - Status construction

  private static func loginHint(_ auth: GitHubAuthConfig) -> String {
    switch auth.source {
    case .env: "export \(EnvironmentPATProvider.defaultVariable)=<token>"
    case .file, .keychain: "run `runnerctl auth login --token-stdin`"
    }
  }

  private static func unconfigured(
    auth: GitHubAuthConfig, location: String, hint: String
  ) -> AuthStatus {
    AuthStatus(
      state: "unconfigured", provider: auth.provider.rawValue, source: auth.source.rawValue,
      location: location, hint: hint)
  }

  private static func unknown(auth: GitHubAuthConfig, location: String) -> AuthStatus {
    AuthStatus(
      state: "unknown", provider: auth.provider.rawValue, source: auth.source.rawValue,
      location: location, hint: "run `runnerctl github test` to probe the credential")
  }

  private static func problem(
    auth: GitHubAuthConfig, location: String, state: String, error: any Error, hint: String?
  ) -> AuthStatus {
    AuthStatus(
      state: state, provider: auth.provider.rawValue, source: auth.source.rawValue,
      location: location, problem: describe(error), hint: hint,
      checkedAt: RFC3339.string(from: Date()))
  }

  private static func describe(_ error: any Error) -> String {
    guard let error = error as? any RunnerError else { return String(describing: error) }
    return "\(error.code): \(error.message)"
  }
}
