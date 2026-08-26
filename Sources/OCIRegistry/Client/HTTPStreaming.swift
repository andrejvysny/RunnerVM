// Derived from openai/tart@16d186c Sources/tart/Fetcher.swift — FSL-1.1-ALv2. See PROVENANCE.md.
import Foundation
import Synchronization

struct HTTPResponseHead {
  let status: Int
  /// Lower-cased header names; HTTP headers are case-insensitive and registries disagree on case.
  let headers: [String: String]
  let expectedLength: Int64

  func header(_ name: String) -> String? {
    headers[name.lowercased()]
  }
}

/// A response body being streamed off the network, with backpressure.
struct HTTPBody {
  private let stream: AsyncThrowingStream<Data, any Error>
  private let collector: HTTPStreamCollector

  init(stream: AsyncThrowingStream<Data, any Error>, collector: HTTPStreamCollector) {
    self.stream = stream
    self.collector = collector
  }

  /// Consumes the body. Reporting each chunk back to the collector is what lets it un-suspend the
  /// URL task, so a slow writer throttles the network instead of growing an unbounded buffer.
  func forEach(_ body: (Data) async throws -> Void) async throws {
    do {
      for try await chunk in stream {
        try Task.checkCancellation()
        try await body(chunk)
        collector.consumed(chunk.count)
      }
    } catch let error as CancellationError {
      collector.cancel()
      throw error
    }
  }

  /// Buffers the whole body. Only used for manifests, tokens and error payloads.
  func collect(limit: Int = 8 * 1024 * 1024) async throws -> Data {
    var result = Data()
    try await forEach { chunk in
      guard result.count < limit else { return }
      result.append(chunk)
    }
    return result
  }

  /// Reads at most `limit` bytes for an error message and drops the rest.
  func errorDetail(limit: Int = 512) async -> String {
    let data = await (try? collect(limit: limit)) ?? Data()
    let text = String(decoding: data.prefix(limit), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.replacingOccurrences(of: "\n", with: " ")
  }

  func cancel() {
    collector.cancel()
  }
}

enum HTTPStreaming {
  /// Issues `request` and returns as soon as the response head is known, so a multi-gigabyte blob
  /// never has to be buffered before its status code can be checked.
  static func send(
    _ request: URLRequest,
    on session: URLSession
  ) async throws -> (HTTPBody, HTTPResponseHead) {
    let collector = HTTPStreamCollector()
    let task = session.dataTask(with: request)
    task.delegate = collector
    let stream = AsyncThrowingStream<Data, any Error> { continuation in
      collector.attach(continuation: continuation, task: task)
    }
    let head = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        collector.start(responseContinuation: continuation)
      }
    } onCancel: {
      collector.cancel()
    }
    return (HTTPBody(stream: stream, collector: collector), head)
  }
}

/// `URLSessionDataTask` → `AsyncThrowingStream<Data>`.
///
/// Buffers small deliveries into ~4 MiB pieces (one delivery per TCP read is far too granular for
/// the LZ4 decompressor) and suspends the task when the consumer falls behind.
final class HTTPStreamCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private static let flushBytes = 4 * 1024 * 1024
  private static let highWatermark = 32 * 1024 * 1024
  private static let lowWatermark = 8 * 1024 * 1024

  private struct State {
    var buffer = Data()
    var inFlight = 0
    var suspended = false
    var finished = false
    var task: URLSessionDataTask?
    var response: CheckedContinuation<HTTPResponseHead, any Error>?
    var stream: AsyncThrowingStream<Data, any Error>.Continuation?
    /// `URLSessionTask.delegate` is a weak reference, so the collector has to keep itself alive
    /// until the exchange finishes.
    var keepAlive: HTTPStreamCollector?
  }

  private let state = Mutex(State())

  func attach(continuation: AsyncThrowingStream<Data, any Error>.Continuation, task: URLSessionDataTask) {
    state.withLock {
      $0.stream = continuation
      $0.task = task
    }
  }

  func start(responseContinuation: CheckedContinuation<HTTPResponseHead, any Error>) {
    let task: URLSessionDataTask? = state.withLock {
      $0.response = responseContinuation
      $0.keepAlive = self
      return $0.task
    }
    task?.resume()
  }

  func cancel() {
    let task = state.withLock { $0.task }
    task?.cancel()
  }

  func consumed(_ bytes: Int) {
    let resume: URLSessionDataTask? = state.withLock { state in
      state.inFlight = max(0, state.inFlight - bytes)
      guard state.suspended, state.inFlight <= Self.lowWatermark else { return nil }
      state.suspended = false
      return state.task
    }
    resume?.resume()
  }

  // MARK: - URLSessionDataDelegate

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      return
    }
    let headers = Dictionary(
      http.allHeaderFields.compactMap { key, value -> (String, String)? in
        guard let name = key as? String else { return nil }
        return (name.lowercased(), String(describing: value))
      },
      uniquingKeysWith: { _, last in last }
    )
    let head = HTTPResponseHead(
      status: http.statusCode, headers: headers, expectedLength: http.expectedContentLength
    )
    takeResponseContinuation()?.resume(returning: head)
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let action: (Data?, URLSessionDataTask?) = state.withLock { state in
      state.buffer.append(data)
      guard state.buffer.count >= Self.flushBytes else { return (nil, nil) }
      let flushed = state.buffer
      state.buffer.removeAll(keepingCapacity: true)
      state.inFlight += flushed.count
      guard !state.suspended, state.inFlight > Self.highWatermark else { return (flushed, nil) }
      state.suspended = true
      return (flushed, state.task)
    }
    if let flushed = action.0 { state.withLock { $0.stream }?.yield(flushed) }
    action.1?.suspend()
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
    let finish: (Data?, AsyncThrowingStream<Data, any Error>.Continuation?) = state.withLock { state in
      guard !state.finished else { return (nil, nil) }
      state.finished = true
      let remainder = state.buffer.isEmpty ? nil : state.buffer
      state.buffer.removeAll()
      let stream = state.stream
      state.stream = nil
      state.keepAlive = nil
      return (remainder, stream)
    }
    // Bytes already received are valid even when the connection then drops: yielding them lets a
    // resumed pull restart from the real high-water mark instead of from zero.
    if let remainder = finish.0 { finish.1?.yield(remainder) }
    if let error {
      takeResponseContinuation()?.resume(throwing: error)
      finish.1?.finish(throwing: error)
      return
    }
    finish.1?.finish()
    // A 204/HEAD exchange can complete without ever delivering a response object.
    takeResponseContinuation()?.resume(
      throwing: RegistryError.transport(
        operation: "request", reason: "connection closed before a response was received", cause: nil
      )
    )
  }

  private func takeResponseContinuation() -> CheckedContinuation<HTTPResponseHead, any Error>? {
    state.withLock { state in
      defer { state.response = nil }
      return state.response
    }
  }
}
