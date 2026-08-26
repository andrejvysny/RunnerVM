// Ported from github.com/actions/scaleset@v0.4.0 (MIT) errors.go — see PROVENANCE.md.

import Foundation
import RunnerCore

/// Turns an Actions-service HTTP failure into the classification the scheduler branches on
/// (spec §52). The Actions service does not use GitHub REST's `{"message": …}` envelope; it
/// returns a .NET exception `{"typeName": …, "message": …}`, so it needs its own mapper.
enum ActionsErrorMapper {
  /// Correlation ids the Actions service returns. Both are safe to log.
  static let activityIDHeader = "ActivityId"
  static let requestIDHeader = "X-GitHub-Request-Id"

  static func error(
    status: Int, headers: [AnyHashable: Any], body: Data, label: String
  ) -> GitHubControlError {
    let reason = describe(status: status, headers: headers, body: body, label: label)
    switch status {
    case 401:
      return .authenticationFailed(reason: reason)
    case 403:
      return .authorizationFailed(reason: reason)
    case 404:
      return .notFound(resource: reason)
    case 409:
      return .conflict(reason: reason)
    case 429:
      return .rateLimited(retryAfter: retryAfter(headers))
    case 400, 405, 410, 415, 422, 451:
      return .permanentConfiguration(reason: reason)
    case 500 ... 599:
      return .transientServerError(status: status)
    default:
      return .invalidResponse(reason: reason)
    }
  }

  /// A `URLSession` failure. Cancellation must survive as `CancellationError`, or the retry loop
  /// keeps trying after the task is gone.
  static func transportError(_ error: any Error) -> any Error {
    if error is CancellationError { return error }
    guard let urlError = error as? URLError else { return GitHubControlError.transport(cause: error) }
    if urlError.code == .cancelled { return CancellationError() }
    return GitHubControlError.transport(cause: urlError)
  }

  /// `typeName` carries the service-side exception; both fields are service text, never credentials.
  private static func describe(
    status: Int, headers: [AnyHashable: Any], body: Data, label: String
  ) -> String {
    var parts = ["\(label): HTTP \(status)"]
    if let exception = try? JSONDecoder().decode(ActionsWire.ExceptionBody.self, from: body) {
      let detail = [exception.typeName, exception.message].compactMap(\.self)
        .filter { !$0.isEmpty }.joined(separator: ": ")
      if !detail.isEmpty { parts.append(detail) }
    } else if let text = String(data: body.prefix(256), encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      parts.append(text)
    }
    if let activity = header(activityIDHeader, in: headers) { parts.append("activity_id=\(activity)") }
    if let request = header(requestIDHeader, in: headers) { parts.append("github_request_id=\(request)") }
    return parts.joined(separator: " — ")
  }

  private static func retryAfter(_ headers: [AnyHashable: Any]) -> Duration? {
    guard let raw = header("Retry-After", in: headers), let seconds = Double(raw) else { return nil }
    return .seconds(max(0, seconds))
  }

  static func header(_ name: String, in headers: [AnyHashable: Any]) -> String? {
    for (key, value) in headers {
      guard let key = key as? String, key.caseInsensitiveCompare(name) == .orderedSame else { continue }
      return value as? String
    }
    return nil
  }
}
