import Foundation

/// Structured classification required by spec §52. Scheduler logic branches on this, never on
/// HTTP error text.
public enum GitHubErrorClass: String, Codable, Sendable, CaseIterable, Hashable {
  case authentication
  case authorization
  case rateLimited
  case notFound
  case conflict
  case transientServer
  case transport
  case invalidResponse
  case permanentConfiguration

  /// Only classes that can plausibly succeed with the same request later.
  public var retryable: Bool {
    switch self {
    case .rateLimited, .transientServer, .transport: true
    case .authentication, .authorization, .notFound, .conflict, .invalidResponse,
         .permanentConfiguration:
      false
    }
  }
}

public enum GitHubControlError: RunnerError {
  case authenticationFailed(reason: String)
  case authorizationFailed(reason: String)
  case rateLimited(retryAfter: Duration?)
  case notFound(resource: String)
  case conflict(reason: String)
  case transientServerError(status: Int)
  case transport(cause: (any Error & Sendable)?)
  case invalidResponse(reason: String)
  case permanentConfiguration(reason: String)
  case jitGenerationFailed(reason: String)
  /// The profile's `timeouts.jitGeneration` expired before GitHub answered `generate-jitconfig`.
  case jitGenerationTimeout(seconds: Double)
  case runnerRemovalFailed(runnerID: Int64, reason: String)
  case scaleSetSessionExpired(scaleSetName: String)
  case publicRepositoryNotAllowed(scope: String)

  public var errorClass: GitHubErrorClass {
    switch self {
    case .authenticationFailed: .authentication
    case .authorizationFailed, .publicRepositoryNotAllowed: .authorization
    case .rateLimited: .rateLimited
    case .notFound: .notFound
    case .conflict: .conflict
    // An expired scale-set session is recoverable by opening a new session, so it is transient.
    case .transientServerError, .scaleSetSessionExpired: .transientServer
    // Cosmetic here -- no orchestration consumer branches on the class of a session failure --
    // but a deadline that expired is a slow or unreachable GitHub, which is what `.transport`
    // means everywhere else in this enum.
    case .transport, .jitGenerationTimeout: .transport
    case .invalidResponse: .invalidResponse
    case .permanentConfiguration, .jitGenerationFailed, .runnerRemovalFailed: .permanentConfiguration
    }
  }

  public var code: String {
    switch self {
    case .authenticationFailed: "GITHUB_AUTHENTICATION_FAILED"
    case .authorizationFailed: "GITHUB_AUTHORIZATION_FAILED"
    case .rateLimited: "GITHUB_RATE_LIMITED"
    case .notFound: "GITHUB_NOT_FOUND"
    case .conflict: "GITHUB_CONFLICT"
    case .transientServerError: "GITHUB_TRANSIENT_SERVER_ERROR"
    case .transport: "GITHUB_TRANSPORT_ERROR"
    case .invalidResponse: "GITHUB_INVALID_RESPONSE"
    case .permanentConfiguration: "GITHUB_PERMANENT_CONFIGURATION"
    case .jitGenerationFailed: "GITHUB_JIT_GENERATION_FAILED"
    case .jitGenerationTimeout: "GITHUB_JIT_GENERATION_TIMEOUT"
    case .runnerRemovalFailed: "GITHUB_RUNNER_REMOVAL_FAILED"
    case .scaleSetSessionExpired: "GITHUB_SCALE_SET_SESSION_EXPIRED"
    case .publicRepositoryNotAllowed: "GITHUB_PUBLIC_REPOSITORY_NOT_ALLOWED"
    }
  }

  public var message: String {
    switch self {
    case .authenticationFailed(let reason): "GitHub authentication failed: \(reason)"
    case .authorizationFailed(let reason): "GitHub authorization failed: \(reason)"
    case .rateLimited(let after):
      after.map { "rate limited, retry after \(DurationValue($0))" } ?? "rate limited"
    case .notFound(let resource): "not found: \(resource)"
    case .conflict(let reason): "conflict: \(reason)"
    case .transientServerError(let status): "GitHub returned \(status)"
    case .transport: "transport failure talking to GitHub"
    case .invalidResponse(let reason): "unexpected GitHub response: \(reason)"
    case .permanentConfiguration(let reason): "GitHub configuration is wrong: \(reason)"
    case .jitGenerationFailed(let reason): "JIT runner config generation failed: \(reason)"
    case .jitGenerationTimeout(let seconds):
      "JIT runner config generation did not finish within \(seconds)s"
    case .runnerRemovalFailed(let id, let reason): "could not remove runner \(id): \(reason)"
    case .scaleSetSessionExpired(let name): "scale set session expired for \(name)"
    case .publicRepositoryNotAllowed(let scope):
      "scope \(scope) is a public repository and security.allowPublicRepositories is false"
    }
  }

  public var retryable: Bool { errorClass.retryable }

  /// `Retry-After`, when GitHub supplied one. Feeds `RetryPolicy.delay(forAttempt:retryAfter:)`.
  public var retryAfter: Duration? {
    if case .rateLimited(let after) = self { return after }
    return nil
  }

  public var underlying: (any Error)? {
    if case .transport(let cause) = self { return cause }
    return nil
  }
}
