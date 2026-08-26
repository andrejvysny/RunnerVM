// Derived from openai/tart@16d186c Sources/tart/OCI/Registry.swift:206-304 — FSL-1.1-ALv2.
// See PROVENANCE.md.
import Foundation
import Logging
import RunnerCore
import RunnerLogging

/// A tag resolved to the immutable manifest a VM will actually boot (spec §21).
public struct ResolvedManifest: Sendable, Equatable {
  /// `<registry>/<repository>@sha256:…`, what goes on the instance record.
  public let reference: OCIReference
  public let digest: ImageDigest
  public let manifest: OCIManifest
  /// The exact bytes the registry served; the digest is computed over these, not over a re-encode.
  public let raw: Data
}

/// OCI Distribution v2 client for one registry host.
///
/// A `Sendable` class rather than an actor on purpose: the only mutable state is the auth token,
/// which lives in `RegistryAuthenticator`. An actor here would serialise every blob handler on one
/// executor and destroy the concurrency the layerizer depends on.
public final class RegistryClient: Sendable {
  public struct Options: Sendable {
    public var timeout: Duration
    public var retryPolicy: RetryPolicy
    /// Allows `http://` — only honoured for loopback hosts.
    public var insecure: Bool
    /// GHCR rejects upload chunks of 4 MB and above.
    public var uploadChunkBytes: Int
    public var userAgent: String

    public init(
      timeout: Duration = .seconds(60),
      retryPolicy: RetryPolicy = RetryPolicy(
        maxAttempts: 4, baseDelay: .milliseconds(250), maxDelay: .seconds(10)
      ),
      insecure: Bool = false,
      uploadChunkBytes: Int = 3 * 1024 * 1024,
      userAgent: String = OCIRegistryModule.defaultUserAgent
    ) {
      self.timeout = timeout
      self.retryPolicy = retryPolicy
      self.insecure = insecure
      self.uploadChunkBytes = uploadChunkBytes
      self.userAgent = userAgent
    }
  }

  public let registry: String
  let options: Options
  let logger: Logger
  let baseURL: URL
  private let session: URLSession
  private let auth: RegistryAuthenticator
  private let sleeper: @Sendable (Duration) async throws -> Void

  public init(
    registry: String,
    session: URLSession = RegistryClient.makeSession(),
    credentials: any RegistryCredentialProvider = AnonymousRegistryCredentials(),
    options: Options = Options(),
    logger: Logger = Logger(component: .image),
    now: @escaping @Sendable () -> Date = { Date() },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.registry = registry
    self.session = session
    self.options = options
    self.logger = logger
    sleeper = sleep
    let scheme = options.insecure && OCIReference.isLoopback(registry) ? "http" : "https"
    baseURL = URL(string: "\(scheme)://\(registry)/v2/")!
    auth = RegistryAuthenticator(
      registry: registry, credentials: credentials, session: session,
      userAgent: options.userAgent, now: now, logger: logger
    )
  }

  /// Cookies off: Harbor rejects requests that carry a session cookie without a CSRF token.
  public static func makeSession(
    configuration: URLSessionConfiguration = .ephemeral
  ) -> URLSession {
    configuration.httpShouldSetCookies = false
    return URLSession(configuration: configuration)
  }

  // MARK: - Endpoints

  public func ping() async throws {
    _ = try await requestData(
      RegistryRequest(method: "GET", url: baseURL, operation: "ping \(registry)"), expecting: [200]
    )
  }

  public func tags(repository: String) async throws -> [String] {
    struct TagList: Decodable { var tags: [String]? }
    let (data, _) = try await requestData(
      RegistryRequest(
        method: "GET", url: endpoint(repository, "tags/list"),
        headers: ["Accept": "application/json"], operation: "list tags of \(repository)"
      ),
      expecting: [200]
    )
    guard let list = try? JSONDecoder().decode(TagList.self, from: data) else {
      throw RegistryError.invalidResponse(operation: "list tags", reason: "unparsable tag list")
    }
    return list.tags ?? []
  }

  /// Tag (or digest) → immutable manifest, following an index when the registry serves one.
  public func resolve(_ reference: OCIReference) async throws -> ResolvedManifest {
    guard reference.registry == registry else {
      throw RegistryError.invalidResponse(
        operation: "resolve \(reference)", reason: "client is bound to \(registry)"
      )
    }
    let repository = reference.repositoryPath
    var fetched = try await fetchManifest(repository: repository, reference: reference.manifestReference)
    if fetched.mediaType == RunnerVMMediaType.ociIndex {
      let selected = try OCIIndex.decode(fetched.data).select()
      fetched = try await fetchManifest(repository: repository, reference: selected.digest)
    }
    guard fetched.mediaType == RunnerVMMediaType.ociManifest else {
      throw RegistryError.unsupportedManifest(reason: "media type \(fetched.mediaType)")
    }
    return try ResolvedManifest(
      reference: reference.canonical(withDigest: fetched.digest), digest: fetched.digest,
      manifest: OCIManifest.decode(fetched.data), raw: fetched.data
    )
  }

  public func manifest(repository: String, digest: ImageDigest) async throws -> OCIManifest {
    let fetched = try await fetchManifest(repository: repository, reference: digest.rawValue)
    return try OCIManifest.decode(fetched.data)
  }

  /// Publishes a manifest and returns the digest the registry will serve it under.
  @discardableResult
  public func putManifest(
    _ manifest: OCIManifest, repository: String, reference: String
  ) async throws -> ImageDigest {
    let body = try manifest.encoded()
    let expected = ImageDigest(rawValue: OCIJSON.digest(body))
    let (_, head) = try await requestData(
      RegistryRequest(
        method: "PUT", url: endpoint(repository, "manifests/\(reference)"),
        headers: ["Content-Type": manifest.mediaType], body: body,
        operation: "push manifest \(repository):\(reference)"
      ),
      expecting: [200, 201, 202], retry: false
    )
    if let served = head.header("docker-content-digest"), served != expected.rawValue {
      throw RegistryError.digestMismatch(expected: expected.rawValue, actual: served)
    }
    return expected
  }

  public func blobExists(_ digest: String, repository: String) async throws -> Bool {
    let request = RegistryRequest(
      method: "HEAD", url: endpoint(repository, "blobs/\(digest)"),
      operation: "check blob \(digest) in \(repository)"
    )
    do {
      _ = try await requestData(request, expecting: [200])
      return true
    } catch let error as RegistryError {
      if case .notFound = error { return false }
      throw error
    }
  }

  /// Streams a blob, transparently resuming with `Range` after a dropped connection (spec §119).
  ///
  /// When `rangeStart` is 0 the compressed bytes are hashed as they arrive and checked against
  /// `digest`, so corruption is caught before it reaches the disk image.
  public func pullBlob(
    _ digest: String, repository: String, rangeStart: Int64 = 0, expectedSize: Int64? = nil,
    handler: (Data) async throws -> Void
  ) async throws {
    var verifier = rangeStart == 0 ? ContentDigest.Streaming() : nil
    var offset = rangeStart
    var attempt = 1
    while true {
      var delivered: Int64 = 0
      do {
        try await streamBlob(digest, repository: repository, rangeStart: offset) { chunk in
          try await handler(chunk)
          verifier?.update(chunk)
          delivered += Int64(chunk.count)
        }
        // Digest first: it is the stronger statement, and a wrong blob is usually the wrong size too.
        if let actual = verifier?.finalize(), actual != digest {
          throw RegistryError.digestMismatch(expected: digest, actual: actual)
        }
        if let expectedSize, offset + delivered != expectedSize {
          throw RegistryError.invalidResponse(
            operation: "pull blob \(digest)",
            reason: "received \(offset + delivered) of \(expectedSize) bytes"
          )
        }
        return
      } catch let error as RegistryError where error.retryable && attempt < options.retryPolicy.maxAttempts {
        offset += delivered
        logger.debug(
          "resuming blob pull",
          metadata: ["digest": .string(digest), "offset": .string(String(offset))]
        )
        try await sleeper(options.retryPolicy.delay(forAttempt: attempt))
        attempt += 1
      }
    }
  }

  // MARK: - Manifest plumbing

  private struct FetchedManifest {
    let digest: ImageDigest
    let data: Data
    let mediaType: String
  }

  private func fetchManifest(repository: String, reference: String) async throws -> FetchedManifest {
    let accept = [RunnerVMMediaType.ociManifest, RunnerVMMediaType.ociIndex].joined(separator: ", ")
    let (data, head) = try await requestData(
      RegistryRequest(
        method: "GET", url: endpoint(repository, "manifests/\(reference)"),
        headers: ["Accept": accept], operation: "pull manifest \(repository):\(reference)"
      ),
      expecting: [200]
    )
    let digest = OCIJSON.digest(data)
    if reference.hasPrefix("sha256:"), reference != digest {
      throw RegistryError.digestMismatch(expected: reference, actual: digest)
    }
    struct MediaTypeProbe: Decodable { var mediaType: String? }
    let declared = (try? JSONDecoder().decode(MediaTypeProbe.self, from: data))?.mediaType
    let contentType = head.header("content-type")?.split(separator: ";").first.map(String.init)
    guard let mediaType = declared ?? contentType?.trimmingCharacters(in: .whitespaces) else {
      throw RegistryError.unsupportedManifest(reason: "response declares no media type")
    }
    return FetchedManifest(digest: ImageDigest(rawValue: digest), data: data, mediaType: mediaType)
  }

  private func streamBlob(
    _ digest: String, repository: String, rangeStart: Int64, handler: (Data) async throws -> Void
  ) async throws {
    let operation = "pull blob \(digest)"
    var request = RegistryRequest(
      method: "GET", url: endpoint(repository, "blobs/\(digest)"), operation: operation
    )
    // Asking for `bytes=0-` invites a 200 from some registries, so only range a real resume.
    if rangeStart > 0 { request.headers["Range"] = "bytes=\(rangeStart)-" }
    let (body, head) = try await perform(request)
    let expected = rangeStart > 0 ? 206 : 200
    guard head.status == expected else {
      let detail = await body.errorDetail()
      throw RegistryError.fromStatus(
        head.status, operation: operation, registry: registry, detail: detail
      )
    }
    try await mapTransportErrors(operation) { try await body.forEach(handler) }
  }

  // MARK: - Request plumbing

  func endpoint(_ repository: String, _ suffix: String) -> URL {
    URL(string: "\(repository)/\(suffix)", relativeTo: baseURL)!.absoluteURL
  }

  /// Runs a request and buffers its (small) body. GET/HEAD retry on transient and transport
  /// failures; anything that mutates registry state does not.
  @discardableResult
  func requestData(
    _ request: RegistryRequest, expecting: Set<Int>, retry: Bool = true
  ) async throws -> (Data, HTTPResponseHead) {
    let idempotent = request.method == "GET" || request.method == "HEAD"
    guard retry, idempotent else { return try await requestDataOnce(request, expecting: expecting) }
    return try await options.retryPolicy.run(
      sleep: sleeper,
      shouldRetry: { ($0 as? RegistryError)?.retryable ?? false }
    ) {
      try await self.requestDataOnce(request, expecting: expecting)
    }
  }

  private func requestDataOnce(
    _ request: RegistryRequest, expecting: Set<Int>
  ) async throws -> (Data, HTTPResponseHead) {
    let (body, head) = try await perform(request)
    guard expecting.contains(head.status) else {
      let detail = await body.errorDetail()
      throw RegistryError.fromStatus(
        head.status, operation: request.operation, registry: registry, detail: detail
      )
    }
    // Always drained, HEAD included, so the underlying task is never left half-consumed.
    let data = try await mapTransportErrors(request.operation) { try await body.collect() }
    return (data, head)
  }

  /// Sends the request, answering one 401 challenge and retrying with the new credentials.
  func perform(_ request: RegistryRequest) async throws -> (HTTPBody, HTTPResponseHead) {
    let (header, generation) = await auth.current()
    let (body, head) = try await send(request, authorization: header)
    guard head.status == 401 else { return (body, head) }
    let challenge = head.header("www-authenticate")
    _ = await body.errorDetail()
    let refreshed = try await auth.refresh(
      challenge: challenge, generation: generation, operation: request.operation
    )
    return try await send(request, authorization: refreshed)
  }

  /// A connection that drops mid-body surfaces as `URLError`; classifying it as transport is what
  /// makes it retryable. Errors thrown by the caller's handler are left untouched.
  private func mapTransportErrors<T: Sendable>(
    _ operation: String, _ work: () async throws -> T
  ) async throws -> T {
    do {
      return try await work()
    } catch let error as URLError {
      throw RegistryError.transport(
        operation: operation, reason: error.localizedDescription, cause: error
      )
    }
  }

  private func send(
    _ request: RegistryRequest, authorization: String?
  ) async throws -> (HTTPBody, HTTPResponseHead) {
    let urlRequest = request.urlRequest(
      userAgent: options.userAgent, authorization: authorization, timeout: options.timeout
    )
    do {
      return try await HTTPStreaming.send(urlRequest, on: session)
    } catch let error as RegistryError {
      throw error
    } catch {
      throw RegistryError.transport(
        operation: request.operation, reason: error.localizedDescription,
        cause: error
      )
    }
  }
}
