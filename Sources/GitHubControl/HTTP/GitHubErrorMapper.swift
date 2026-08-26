import Foundation
import RunnerCore

/// GitHub's error envelope. `errors[]` carries the field-level detail for a 422.
struct GitHubErrorBody: Decodable {
  struct Detail: Decodable {
    let resource: String?
    let field: String?
    let code: String?
    let message: String?
  }

  let message: String?
  let documentationURL: String?
  let errors: [Detail]?

  private enum CodingKeys: String, CodingKey {
    case message, errors
    case documentationURL = "documentation_url"
  }

  /// One line, safe to log: GitHub never echoes credentials in these fields.
  var summary: String {
    let details = (errors ?? []).compactMap { detail -> String? in
      let parts = [detail.resource, detail.field, detail.code, detail.message].compactMap(\.self)
      return parts.isEmpty ? nil : parts.joined(separator: ".")
    }
    let head = message ?? "no message"
    return details.isEmpty ? head : "\(head) (\(details.joined(separator: "; ")))"
  }
}

/// Turns an HTTP status into the classification the scheduler branches on (spec §52).
/// Nothing above this function is allowed to look at a status code.
enum GitHubErrorMapper {
  static func error(
    status: Int, headers: GitHubHeaders, body: Data, request: GitHubRequest, now: Date
  ) -> GitHubControlError {
    let reason = describe(status: status, headers: headers, body: body, request: request)
    switch status {
    case 401:
      return .authenticationFailed(reason: reason)
    case 403:
      if let wait = rateLimitWait(headers: headers, now: now) { return .rateLimited(retryAfter: wait) }
      return .authorizationFailed(reason: reason)
    case 429:
      return .rateLimited(retryAfter: rateLimitWait(headers: headers, now: now) ?? .zero)
    case 404:
      return .notFound(resource: "\(request.logDescription) — \(reason)")
    case 409:
      return .conflict(reason: reason)
    case 422, 400, 405, 410, 415, 451:
      return .permanentConfiguration(reason: reason)
    case 500 ... 599:
      return .transientServerError(status: status)
    default:
      return .invalidResponse(reason: reason)
    }
  }

  /// A 403 is a rate limit only when GitHub says so: either an explicit `Retry-After` (secondary
  /// limit) or an exhausted primary budget. Everything else is a permissions problem.
  private static func rateLimitWait(headers: GitHubHeaders, now: Date) -> Duration? {
    if let retryAfter = headers.retryAfter { return retryAfter }
    guard let rateLimit = headers.rateLimit, rateLimit.isExhausted else { return nil }
    return rateLimit.waitInterval(now: now) ?? .zero
  }

  private static func describe(
    status: Int, headers: GitHubHeaders, body: Data, request: GitHubRequest
  ) -> String {
    let decoded = try? JSONDecoder().decode(GitHubErrorBody.self, from: body)
    let summary = decoded?.summary ?? "HTTP \(status)"
    let requestID = headers.requestID.map { " [request \($0)]" } ?? ""
    return "\(request.logDescription): \(summary)\(requestID)"
  }
}
