import Foundation
import Synchronization

/// Maps a request's host back to the fake that owns it.
final class FakeRegistryDirectory: Sendable {
  static let shared = FakeRegistryDirectory()

  private let registries = Mutex<[String: FakeRegistry]>([:])

  func register(_ registry: FakeRegistry) {
    registries.withLock { $0[registry.host] = registry }
  }

  func unregister(_ host: String) {
    registries.withLock { $0[host] = nil }
  }

  func registry(for url: URL?) -> FakeRegistry? {
    guard let host = url?.host() else { return nil }
    return registries.withLock { $0[host] }
  }
}

public final class FakeRegistryURLProtocol: URLProtocol {
  override public class func canInit(with request: URLRequest) -> Bool {
    FakeRegistryDirectory.shared.registry(for: request.url) != nil
  }

  override public class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override public func startLoading() {
    guard let url = request.url, let registry = FakeRegistryDirectory.shared.registry(for: url) else {
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
      return
    }
    let reply = registry.respond(to: Self.decode(request, url: url))
    guard
      let response = HTTPURLResponse(
        url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    let delivered = reply.truncateAfter.map { reply.body.prefix($0) } ?? reply.body[...]
    if !delivered.isEmpty { client?.urlProtocol(self, didLoad: Data(delivered)) }
    guard let failure = reply.failure else {
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    // `URLSession` needs a run-loop turn to hand the partial body to the delegate; failing any
    // sooner discards it, and a resume test could then never observe a real high-water mark.
    // `URLProtocol` is not `Sendable`, but after `startLoading` returns this instance is only ever
    // touched by the single completion call below.
    nonisolated(unsafe) let owner = self
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) { [client] in
      client?.urlProtocol(owner, didFailWithError: failure)
    }
  }

  override public func stopLoading() {}

  private static func decode(_ request: URLRequest, url: URL) -> FakeRequest {
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let query = Dictionary(
      (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
      uniquingKeysWith: { _, last in last }
    )
    return FakeRequest(
      method: request.httpMethod ?? "GET",
      path: url.path(percentEncoded: false),
      query: query,
      headers: request.allHTTPHeaderFields ?? [:],
      body: body(of: request) ?? Data()
    )
  }

  /// `URLSession` turns `httpBody` into a stream before a protocol sees the request, so both forms
  /// have to be handled or every upload looks empty.
  private static func body(of request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while stream.hasBytesAvailable {
      let read = stream.read(&buffer, maxLength: buffer.count)
      if read <= 0 { break }
      data.append(contentsOf: buffer[0 ..< read])
    }
    return data
  }
}
