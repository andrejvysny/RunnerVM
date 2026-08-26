import Foundation
import RunnerCore

/// One GitHub REST call, independent of transport. Bodies are pre-encoded so the value can cross
/// the client actor's boundary without an `any Encodable` existential.
public struct GitHubRequest: Sendable, Hashable {
  public enum Method: String, Sendable, Hashable {
    case get = "GET"
    case post = "POST"
    case patch = "PATCH"
    case put = "PUT"
    case delete = "DELETE"

    /// HTTP's own default. `POST` may still be marked idempotent explicitly — GitHub's
    /// `generate-jitconfig` is not, because a retry would leave an orphan runner registration.
    var isIdempotentByDefault: Bool {
      self != .post && self != .patch
    }
  }

  public var method: Method
  /// Absolute path with a leading slash, e.g. `/orgs/acme/actions/runners`.
  public var path: String
  public var query: [URLQueryItem]
  public var body: Data?
  /// Retries are only ever attempted when this is `true` (spec §52).
  public var idempotent: Bool
  public var accept: String

  /// Set only when following a `Link: rel="next"` header, whose URL already carries the query.
  var absoluteURL: URL?

  public static let defaultAccept = "application/vnd.github+json"

  public init(
    method: Method, path: String, query: [URLQueryItem] = [], body: Data? = nil,
    idempotent: Bool? = nil, accept: String = GitHubRequest.defaultAccept
  ) {
    self.method = method
    self.path = path
    self.query = query
    self.body = body
    self.idempotent = idempotent ?? method.isIdempotentByDefault
    self.accept = accept
  }

  public static func get(_ path: String, query: [URLQueryItem] = []) -> GitHubRequest {
    GitHubRequest(method: .get, path: path, query: query)
  }

  public static func delete(_ path: String) -> GitHubRequest {
    GitHubRequest(method: .delete, path: path)
  }

  public static func post(_ path: String, idempotent: Bool = false) -> GitHubRequest {
    GitHubRequest(method: .post, path: path, idempotent: idempotent)
  }

  /// - Throws: `GitHubControlError.permanentConfiguration` when the body cannot be encoded, which
  ///   is always a programming error rather than something a retry could fix.
  public static func post(
    _ path: String, json body: some Encodable, idempotent: Bool = false
  ) throws -> GitHubRequest {
    try GitHubRequest(
      method: .post, path: path, body: encode(body), idempotent: idempotent
    )
  }

  static func following(_ url: URL) -> GitHubRequest {
    var request = GitHubRequest(method: .get, path: url.path)
    request.absoluteURL = url
    return request
  }

  static func encode(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    // Deterministic bytes so a recorded request body can be compared verbatim in tests.
    encoder.outputFormatting = [.sortedKeys]
    do {
      return try encoder.encode(value)
    } catch {
      throw GitHubControlError.permanentConfiguration(
        reason: "could not encode request body of type \(type(of: value)): \(error)"
      )
    }
  }

  func url(relativeTo baseURL: URL) throws -> URL {
    if let absoluteURL { return absoluteURL }
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      throw GitHubControlError.permanentConfiguration(reason: "invalid GitHub base URL \(baseURL)")
    }
    components.percentEncodedPath = (components.percentEncodedPath as NSString)
      .appendingPathComponent(path)
    if !query.isEmpty { components.queryItems = query }
    guard let url = components.url else {
      throw GitHubControlError.permanentConfiguration(
        reason: "could not build a URL for \(method.rawValue) \(path)"
      )
    }
    return url
  }

  /// Safe to log: method plus path, never the query (which can carry names) or the body.
  var logDescription: String {
    "\(method.rawValue) \(absoluteURL?.path ?? path)"
  }
}
