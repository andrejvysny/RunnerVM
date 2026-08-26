import Foundation

/// Case-insensitive view of a GitHub response's headers, plus the few RunnerVM acts on.
public struct GitHubHeaders: Sendable, Hashable {
  private let storage: [String: String]

  public init(_ fields: [String: String]) {
    storage = Dictionary(
      fields.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last }
    )
  }

  init(_ fields: [AnyHashable: Any]) {
    self.init(
      Dictionary(
        fields.compactMap { key, value -> (String, String)? in
          guard let key = key as? String else { return nil }
          return (key, String(describing: value))
        },
        uniquingKeysWith: { _, last in last }
      )
    )
  }

  public subscript(name: String) -> String? {
    storage[name.lowercased()]
  }

  /// Echoed back in every error so a support ticket can quote it.
  public var requestID: String? {
    self["x-github-request-id"]
  }

  /// `Retry-After` in seconds. GitHub also allows an HTTP-date, which is not accepted here on
  /// purpose: a bad clock would turn a 2 second wait into hours.
  public var retryAfter: Duration? {
    guard let raw = self["retry-after"], let seconds = Double(raw.trimmingCharacters(in: .whitespaces)),
          seconds > 0
    else { return nil }
    return .seconds(seconds)
  }

  public var rateLimit: RateLimitSnapshot? {
    let remaining = self["x-ratelimit-remaining"].flatMap(Int.init)
    let limit = self["x-ratelimit-limit"].flatMap(Int.init)
    let reset = self["x-ratelimit-reset"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    guard remaining != nil || limit != nil || reset != nil else { return nil }
    return RateLimitSnapshot(
      limit: limit, remaining: remaining, reset: reset, resource: self["x-ratelimit-resource"]
    )
  }

  /// URL of the next page, from the `Link` header (RFC 8288 subset GitHub emits).
  public var nextPageLink: URL? {
    link(rel: "next")
  }

  public func link(rel: String) -> URL? {
    guard let header = self["link"] else { return nil }
    for part in header.split(separator: ",") {
      let pieces = part.split(separator: ";")
      guard let target = pieces.first?.trimmingCharacters(in: .whitespaces),
            target.hasPrefix("<"), target.hasSuffix(">")
      else { continue }
      let matches = pieces.dropFirst().contains { piece in
        let normalized = piece.replacingOccurrences(of: "\"", with: "")
          .trimmingCharacters(in: .whitespaces)
        return normalized == "rel=\(rel)"
      }
      if matches { return URL(string: String(target.dropFirst().dropLast())) }
    }
    return nil
  }
}

/// Primary rate-limit accounting (spec §52). Secondary limits arrive as `Retry-After` instead.
public struct RateLimitSnapshot: Sendable, Hashable {
  public let limit: Int?
  public let remaining: Int?
  public let reset: Date?
  public let resource: String?

  public var isExhausted: Bool {
    (remaining ?? 1) <= 0
  }

  /// How long until the window resets, clamped at zero so a skewed clock cannot produce a
  /// negative sleep.
  public func waitInterval(now: Date) -> Duration? {
    guard let reset else { return nil }
    let seconds = reset.timeIntervalSince(now)
    return seconds > 0 ? .seconds(seconds) : .zero
  }
}

/// A decoded 2xx response plus the metadata callers act on.
public struct GitHubResponse<Value: Sendable>: Sendable {
  public let value: Value
  public let status: Int
  public let headers: GitHubHeaders

  public init(value: Value, status: Int, headers: GitHubHeaders) {
    self.value = value
    self.status = status
    self.headers = headers
  }

  public var rateLimit: RateLimitSnapshot? {
    headers.rateLimit
  }

  public var requestID: String? {
    headers.requestID
  }

  public var nextPage: URL? {
    headers.nextPageLink
  }
}

/// Body of a `204 No Content` (or any response whose payload RunnerVM ignores).
public struct NoContent: Decodable, Sendable, Hashable {
  public init() {}
  public init(from decoder: any Decoder) throws {}
}
