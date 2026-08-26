import Foundation

extension FakeRegistry {
  func blob(_ request: FakeRequest, digest: String, state: inout State) -> Reply {
    guard let data = state.blobs[digest] else {
      return Self.failure(404, "BLOB_UNKNOWN", digest)
    }
    if request.method == "HEAD" {
      return Reply(
        status: 200,
        headers: ["Content-Length": String(data.count), "Docker-Content-Digest": digest]
      )
    }
    if case let .status(status)? = Self.peekFault(digest, &state) {
      Self.dropFault(digest, &state)
      return Self.failure(status, "SERVER_ERROR", "scripted failure")
    }
    var start = 0
    var status = 200
    if let range = request.header("Range"), let parsed = Self.rangeStart(range) {
      start = parsed
      status = 206
    }
    guard start <= data.count else {
      return Self.failure(416, "RANGE_INVALID", "\(start) past \(data.count)")
    }
    let body = Data(data[data.index(data.startIndex, offsetBy: start)...])
    var headers = [
      "Content-Type": "application/octet-stream",
      "Docker-Content-Digest": digest,
      "Content-Length": String(body.count),
    ]
    if status == 206 {
      headers["Content-Range"] = "bytes \(start)-\(max(start, data.count - 1))/\(data.count)"
    }
    var reply = Reply(status: status, headers: headers, body: body)
    if case let .disconnect(afterBytes)? = Self.peekFault(digest, &state) {
      Self.dropFault(digest, &state)
      reply.truncateAfter = min(afterBytes, body.count)
      reply.failure = URLError(.networkConnectionLost)
    }
    return reply
  }

  func upload(
    _ request: FakeRequest, repository: String, session: String, state: inout State
  ) -> Reply {
    switch request.method {
    case "POST":
      let id = UUID().uuidString
      state.uploads[id] = Data()
      return Reply(
        status: 202,
        headers: [
          "Location": "/v2/\(repository)/blobs/uploads/\(id)",
          "Docker-Upload-UUID": id,
          "Range": "0-0",
        ]
      )
    case "PATCH":
      return patch(request, repository: repository, session: session, state: &state)
    case "PUT":
      return finish(request, session: session, state: &state)
    default:
      return Self.failure(405, "UNSUPPORTED", request.method)
    }
  }

  private func patch(
    _ request: FakeRequest, repository: String, session: String, state: inout State
  ) -> Reply {
    guard var uploaded = state.uploads[session] else {
      return Self.failure(404, "BLOB_UPLOAD_UNKNOWN", session)
    }
    if let oversize = rejectOversizedChunk(request.body.count) { return oversize }
    if let range = request.header("Content-Range") {
      guard let start = Self.rangeStart(range), start == uploaded.count else {
        return Self.failure(
          416, "BLOB_UPLOAD_INVALID", "expected Content-Range starting at \(uploaded.count), got \(range)"
        )
      }
    }
    uploaded.append(request.body)
    state.uploads[session] = uploaded
    return Reply(
      status: 202,
      headers: [
        "Location": "/v2/\(repository)/blobs/uploads/\(session)",
        "Range": "0-\(max(0, uploaded.count - 1))",
      ]
    )
  }

  private func finish(_ request: FakeRequest, session: String, state: inout State) -> Reply {
    guard var uploaded = state.uploads[session] else {
      return Self.failure(404, "BLOB_UPLOAD_UNKNOWN", session)
    }
    if !request.body.isEmpty {
      if let oversize = rejectOversizedChunk(request.body.count) { return oversize }
      uploaded.append(request.body)
    }
    guard let digest = request.query["digest"] else {
      return Self.failure(400, "DIGEST_INVALID", "missing digest parameter")
    }
    let actual = ContentDigest.hash(uploaded)
    guard actual == digest else {
      return Self.failure(400, "DIGEST_INVALID", "expected \(digest), computed \(actual)")
    }
    state.blobs[digest] = uploaded
    state.uploads[session] = nil
    return Reply(status: 201, headers: ["Docker-Content-Digest": digest, "Location": "/v2/blobs/\(digest)"])
  }

  private func rejectOversizedChunk(_ bytes: Int) -> Reply? {
    guard bytes >= maxUploadChunkBytes else { return nil }
    return Self.failure(
      413, "BLOB_UPLOAD_INVALID", "chunk of \(bytes) bytes exceeds the \(maxUploadChunkBytes)-byte limit"
    )
  }

  /// A fault aimed at this digest wins over the untargeted queue.
  private static func peekFault(_ digest: String, _ state: inout State) -> BlobFault? {
    state.targetedBlobFaults[digest]?.first ?? state.blobFaults.first
  }

  private static func dropFault(_ digest: String, _ state: inout State) {
    if state.targetedBlobFaults[digest]?.isEmpty == false {
      state.targetedBlobFaults[digest]?.removeFirst()
      return
    }
    if !state.blobFaults.isEmpty { state.blobFaults.removeFirst() }
  }

  /// `bytes=<start>-…` (request Range) and `<start>-<end>` (upload Content-Range).
  static func rangeStart(_ raw: String) -> Int? {
    let value = raw.hasPrefix("bytes=") ? String(raw.dropFirst("bytes=".count)) : raw
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard let dash = trimmed.firstIndex(of: "-") else { return Int(trimmed) }
    return Int(trimmed[trimmed.startIndex ..< dash])
  }
}
