/// GitHubControl — the only module that talks to GitHub (spec §11, §12, §50, §52).
///
/// Layers, outermost first:
///
///   GitHubActionsControlPlane   what the scheduler sees: JIT config, runner removal, health
///         │
///   GitHubRunnersAPI            typed endpoints; the only place REST paths exist
///         │
///   GitHubHTTPClient            timeouts, retry, rate limits, error classification
///         │
///   GitHubCredentialProvider    PAT (env/file/Keychain) or GitHub App installation token
///
/// Nothing above this module may see a URL path, an HTTP status or an `Authorization` header:
/// scheduler code branches on `GitHubErrorClass`, never on response text (spec §52).
///
/// Scale-set (Actions service) long polling is M6 and lives behind `ScaleSetControlPlane`.
public enum GitHubControlModule {
  public static let name = "GitHubControl"
  /// Sent as `X-GitHub-Api-Version` on every request.
  public static let apiVersion = "2022-11-28"
}
