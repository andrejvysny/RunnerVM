import Foundation
import RunnerCore
import Synchronization

/// In-process OCI Distribution v2 registry.
///
/// Test support shipped in the product module for the same reason `FakeGitHubServer` is: other test
/// targets need it and SwiftPM test targets cannot import each other. Nothing in the daemon may
/// construct one.
///
/// A `URLProtocol` rather than a socket server: no ports, no listen backlog, no flakiness, and the
/// real `URLSession` path — headers, ranges, chunked bodies — is still exercised.
public final class FakeRegistry: Sendable {
  public enum AuthMode: Sendable {
    case anonymous
    /// Docker token flow. `credential` nil means the token endpoint serves anyone.
    case bearer(credential: RegistryCredential?)
    case basic(credential: RegistryCredential)
  }

  public struct Recorded: Sendable, Hashable {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let headers: [String: String]
    public let bodyBytes: Int

    public func header(_ name: String) -> String? {
      headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
  }

  struct StoredManifest {
    var data: Data
    var mediaType: String
  }

  enum BlobFault {
    /// One HTTP error, then the fault is spent.
    case status(Int)
    /// Deliver this many bytes, then drop the connection.
    case disconnect(afterBytes: Int)
  }

  struct State {
    var blobs: [String: Data] = [:]
    var manifests: [String: StoredManifest] = [:]
    var tags: [String: Set<String>] = [:]
    var uploads: [String: Data] = [:]
    var tokens: Set<String> = []
    var recorded: [Recorded] = []
    var blobFaults: [BlobFault] = []
    var targetedBlobFaults: [String: [BlobFault]] = [:]
  }

  /// Unique per instance, so concurrent tests never see each other's content and `canInit(with:)`
  /// can ignore every URL that is not ours.
  public let host: String
  let auth: AuthMode
  /// Returned as `expires_in`. A value at or below `RegistryAuthenticator`'s refresh margin makes
  /// the client treat every token as already stale, which is how token refresh is tested.
  let tokenLifetime: Int
  /// GHCR rejects upload chunks of 4 MB and above.
  public let maxUploadChunkBytes: Int
  let state = Mutex(State())

  public init(
    auth: AuthMode = .anonymous, tokenLifetime: Int = 300,
    maxUploadChunkBytes: Int = 4 * 1024 * 1024
  ) {
    host = "fake-\(UUID().uuidString.lowercased()).registry.invalid"
    self.auth = auth
    self.tokenLifetime = tokenLifetime
    self.maxUploadChunkBytes = maxUploadChunkBytes
    FakeRegistryDirectory.shared.register(self)
  }

  /// Frees the directory slot. Optional — hosts are unique — but keeps long runs tidy.
  public func shutdown() {
    FakeRegistryDirectory.shared.unregister(host)
  }

  // MARK: - Wiring

  public func makeSessionConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FakeRegistryURLProtocol.self]
    return configuration
  }

  public func makeSession() -> URLSession {
    RegistryClient.makeSession(configuration: makeSessionConfiguration())
  }

  /// A client bound to this fake. `sleep` is a no-op so retry paths never spend wall-clock time.
  public func makeClient(
    credentials: any RegistryCredentialProvider = AnonymousRegistryCredentials(),
    options: RegistryClient.Options = RegistryClient.Options(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) -> RegistryClient {
    RegistryClient(
      registry: host, session: makeSession(), credentials: credentials, options: options,
      now: now, sleep: { _ in }
    )
  }

  public func reference(_ repository: String, tag: String = "latest") throws -> OCIReference {
    try OCIReference(parsing: "\(host)/\(repository):\(tag)")
  }

  // MARK: - Content

  @discardableResult
  public func putBlob(_ data: Data) -> String {
    let digest = ContentDigest.hash(data)
    state.withLock { $0.blobs[digest] = data }
    return digest
  }

  public func blob(_ digest: String) -> Data? {
    state.withLock { $0.blobs[digest] }
  }

  public var blobCount: Int {
    state.withLock { $0.blobs.count }
  }

  /// Serves `data` under someone else's digest — a registry that hands back the wrong object.
  public func overwriteBlob(_ digest: String, with data: Data) {
    state.withLock { $0.blobs[digest] = data }
  }

  /// Replaces a blob's bytes while keeping its digest key, so a pull sees a digest mismatch.
  public func corruptBlob(_ digest: String) {
    state.withLock { state in
      guard var data = state.blobs[digest], !data.isEmpty else { return }
      data[data.startIndex] = data[data.startIndex] &+ 1
      state.blobs[digest] = data
    }
  }

  @discardableResult
  public func putManifest(
    _ data: Data, repository: String, reference: String,
    mediaType: String = RunnerVMMediaType.ociManifest
  ) -> String {
    let digest = ContentDigest.hash(data)
    state.withLock { state in
      let stored = StoredManifest(data: data, mediaType: mediaType)
      state.manifests[Self.key(repository, reference)] = stored
      state.manifests[Self.key(repository, digest)] = stored
      if !reference.hasPrefix("sha256:") { state.tags[repository, default: []].insert(reference) }
    }
    return digest
  }

  public func manifestData(repository: String, reference: String) -> Data? {
    state.withLock { $0.manifests[Self.key(repository, reference)]?.data }
  }

  // MARK: - Scripting

  /// Invalidates every issued token; the next authenticated request gets a 401 challenge.
  public func expireTokens() {
    state.withLock { $0.tokens.removeAll() }
  }

  public func failNextBlobGet(status: Int = 500) {
    state.withLock { $0.blobFaults.append(.status(status)) }
  }

  public func disconnectNextBlobGet(afterBytes: Int) {
    state.withLock { $0.blobFaults.append(.disconnect(afterBytes: afterBytes)) }
  }

  /// Faults aimed at one blob, so a scripted failure lands on a known disk chunk no matter what
  /// order the layerizer's task group happens to run in.
  public func failBlobGet(digest: String, status: Int = 500, times: Int = 1) {
    state.withLock { state in
      state.targetedBlobFaults[digest, default: []]
        .append(contentsOf: Array(repeating: .status(status), count: times))
    }
  }

  public func disconnectBlobGet(digest: String, afterBytes: Int) {
    state.withLock { $0.targetedBlobFaults[digest, default: []].append(.disconnect(afterBytes: afterBytes)) }
  }

  public func clearBlobFaults() {
    state.withLock { state in
      state.blobFaults.removeAll()
      state.targetedBlobFaults.removeAll()
    }
  }

  public var recorded: [Recorded] {
    state.withLock { $0.recorded }
  }

  public func requests(_ method: String, containing fragment: String) -> [Recorded] {
    recorded.filter { $0.method == method && $0.path.contains(fragment) }
  }

  public func resetRecording() {
    state.withLock { $0.recorded.removeAll() }
  }

  static func key(_ repository: String, _ reference: String) -> String {
    "\(repository)|\(reference)"
  }
}
