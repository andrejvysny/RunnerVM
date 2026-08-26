import Foundation

/// One registry exchange, before authentication is attached. Values are immutable enough that the
/// retry loop can simply re-send the same struct.
struct RegistryRequest {
  var method: String
  var url: URL
  var headers: [String: String] = [:]
  var query: [URLQueryItem] = []
  var body: Data?
  /// Human phrase used verbatim in error messages ("pull manifest acme/x:stable").
  var operation: String

  func urlRequest(userAgent: String, authorization: String?, timeout: Duration) -> URLRequest {
    var request = URLRequest(url: resolvedURL)
    request.httpMethod = method
    let parts = timeout.components
    request.timeoutInterval = TimeInterval(parts.seconds) + Double(parts.attoseconds) / 1e18
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    for (name, value) in headers {
      request.setValue(value, forHTTPHeaderField: name)
    }
    if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
    if let body {
      request.httpBody = body
      request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
    } else if method == "POST" || method == "PUT" || method == "PATCH" {
      // Registries reject an upload POST without an explicit zero length.
      request.setValue("0", forHTTPHeaderField: "Content-Length")
    }
    return request
  }

  private var resolvedURL: URL {
    guard !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
      return url
    }
    components.queryItems = (components.queryItems ?? []) + query
    return components.url ?? url
  }
}
