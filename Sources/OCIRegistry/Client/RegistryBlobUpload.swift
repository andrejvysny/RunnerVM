// Derived from openai/tart@16d186c Sources/tart/OCI/Registry.swift:206-264 (chunked push,
// `uploadLocationFromResponse`) — FSL-1.1-ALv2. See PROVENANCE.md.
import Foundation
import RunnerCore

extension RegistryClient {
  /// Uploads a blob the caller can produce in slices.
  ///
  /// `provider` is called with `(offset, length)` and must return exactly that many bytes, so a
  /// 512 MiB layer is streamed off disk instead of being held in memory.
  public func pushBlob(
    digest: String, size: Int, repository: String,
    provider: (_ offset: Int, _ length: Int) throws -> Data
  ) async throws {
    var location = try await beginUpload(repository: repository, digest: digest)
    if size <= options.uploadChunkBytes {
      try await finishUpload(location: location, digest: digest, body: provider(0, size))
      return
    }
    var offset = 0
    while offset < size {
      let length = min(options.uploadChunkBytes, size - offset)
      let chunk = try provider(offset, length)
      guard chunk.count == length else {
        throw RegistryError.invalidResponse(
          operation: "push blob \(digest)", reason: "provider returned \(chunk.count) of \(length) bytes"
        )
      }
      location = try await patchChunk(
        location: location, chunk: chunk, offset: offset, digest: digest, repository: repository
      )
      offset += length
    }
    try await finishUpload(location: location, digest: digest, body: Data())
  }

  /// Uploads a blob already in memory. Only used for small layers (config, NVRAM).
  public func pushBlob(_ data: Data, digest: String? = nil, repository: String) async throws -> String {
    let resolved = digest ?? ContentDigest.hash(data)
    try await pushBlob(digest: resolved, size: data.count, repository: repository) { offset, length in
      let start = data.index(data.startIndex, offsetBy: offset)
      return Data(data[start ..< data.index(start, offsetBy: length)])
    }
    return resolved
  }

  // MARK: - Upload session

  private func beginUpload(repository: String, digest: String) async throws -> URL {
    let (_, head) = try await requestData(
      RegistryRequest(
        method: "POST", url: endpoint(repository, "blobs/uploads/"),
        operation: "start upload of \(digest) to \(repository)"
      ),
      expecting: [201, 202], retry: false
    )
    return try uploadLocation(from: head, operation: "start upload of \(digest)")
  }

  private func patchChunk(
    location: URL, chunk: Data, offset: Int, digest: String, repository: String
  ) async throws -> URL {
    let operation = "upload chunk at \(offset) of \(digest)"
    let (_, head) = try await requestData(
      RegistryRequest(
        method: "PATCH", url: location,
        headers: [
          "Content-Type": "application/octet-stream",
          "Content-Range": "\(offset)-\(offset + chunk.count - 1)",
        ],
        body: chunk, operation: operation
      ),
      // ECR answers 201 where the spec says 202.
      expecting: [201, 202], retry: false
    )
    return try uploadLocation(from: head, operation: operation)
  }

  /// The closing PUT carries `?digest=` and, for a monolithic upload, the whole blob. No
  /// `Content-Range`: registries disagree about whether it is allowed here.
  private func finishUpload(location: URL, digest: String, body: Data) async throws {
    _ = try await requestData(
      RegistryRequest(
        method: "PUT", url: location,
        headers: ["Content-Type": "application/octet-stream"],
        query: [URLQueryItem(name: "digest", value: digest)],
        body: body.isEmpty ? nil : body, operation: "finish upload of \(digest)"
      ),
      expecting: [201, 202], retry: false
    )
  }

  /// The `Location` of an upload session may be relative, and each response can move it.
  private func uploadLocation(from head: HTTPResponseHead, operation: String) throws -> URL {
    guard let raw = head.header("location") else {
      throw RegistryError.invalidResponse(operation: operation, reason: "no Location header")
    }
    guard let resolved = URL(string: raw, relativeTo: baseURL) else {
      throw RegistryError.invalidResponse(operation: operation, reason: "malformed Location '\(raw)'")
    }
    return resolved.absoluteURL
  }
}

public extension RegistryClient {
  /// Buffers a small blob. Only for config-sized payloads; disk chunks stream through `pullBlob`.
  func blob(_ digest: String, repository: String, maximumBytes: Int = 8 * 1024 * 1024) async throws -> Data {
    var buffer = Data()
    try await pullBlob(digest, repository: repository) { data in
      guard buffer.count + data.count <= maximumBytes else {
        throw RegistryError.invalidResponse(
          operation: "pull blob \(digest)", reason: "larger than the \(maximumBytes)-byte limit"
        )
      }
      buffer.append(data)
    }
    return buffer
  }
}
