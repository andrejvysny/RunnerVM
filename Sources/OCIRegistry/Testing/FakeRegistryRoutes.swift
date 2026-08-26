import Foundation

struct FakeRequest {
  let method: String
  let path: String
  let query: [String: String]
  let headers: [String: String]
  let body: Data

  func header(_ name: String) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }
}

extension FakeRegistry {
  struct Reply {
    var status: Int
    var headers: [String: String] = [:]
    var body: Data = .init()
    /// Deliver this many bytes and then drop the connection.
    var truncateAfter: Int?
    var failure: URLError?
  }

  func respond(to request: FakeRequest) -> Reply {
    state.withLock { state in
      state.recorded.append(
        Recorded(
          method: request.method, path: request.path, query: request.query,
          headers: request.headers, bodyBytes: request.body.count
        )
      )
      return route(request, &state)
    }
  }

  private func route(_ request: FakeRequest, _ state: inout State) -> Reply {
    if request.path == "/token" { return issueToken(request, &state) }
    guard request.path.hasPrefix("/v2/") else {
      return Self.failure(404, "UNSUPPORTED", "not a registry path")
    }
    let rest = String(request.path.dropFirst("/v2/".count))
    if let challenge = authorize(request, repository: Self.repository(of: rest), state: &state) {
      return challenge
    }
    if rest.isEmpty { return Reply(
      status: 200,
      headers: ["Content-Type": "application/json"],
      body: Data("{}".utf8)
    ) }
    if rest.hasSuffix("/tags/list") {
      return tagList(String(rest.dropLast("/tags/list".count)), &state)
    }
    if let split = Self.split(rest, on: "/blobs/uploads/") {
      return upload(request, repository: split.repository, session: split.suffix, state: &state)
    }
    if let split = Self.split(rest, on: "/blobs/") {
      return blob(request, digest: split.suffix, state: &state)
    }
    if let split = Self.split(rest, on: "/manifests/") {
      return manifest(request, repository: split.repository, reference: split.suffix, state: &state)
    }
    return Self.failure(404, "UNSUPPORTED", "no route for \(request.path)")
  }

  // MARK: - Auth

  private func authorize(_ request: FakeRequest, repository: String, state: inout State) -> Reply? {
    switch auth {
    case .anonymous:
      return nil
    case let .basic(credential):
      guard request.header("Authorization") == credential.basicAuthorizationValue else {
        return Self.failure(
          401, "UNAUTHORIZED", "basic auth required",
          headers: ["WWW-Authenticate": "Basic realm=\"runnervm-fake\""]
        )
      }
      return nil
    case .bearer:
      let presented = request.header("Authorization")?.split(separator: " ", maxSplits: 1)
      guard let presented, presented.count == 2, presented[0] == "Bearer",
            state.tokens.contains(String(presented[1]))
      else {
        return Self.failure(
          401, "UNAUTHORIZED", "token required",
          headers: ["WWW-Authenticate": bearerChallenge(repository: repository)]
        )
      }
      return nil
    }
  }

  private func bearerChallenge(repository: String) -> String {
    let scope = repository.isEmpty ? "registry:catalog:*" : "repository:\(repository):pull,push"
    return "Bearer realm=\"https://\(host)/token\",service=\"\(host)\",scope=\"\(scope)\""
  }

  private func issueToken(_ request: FakeRequest, _ state: inout State) -> Reply {
    if case let .bearer(credential) = auth, let credential,
       request.header("Authorization") != credential.basicAuthorizationValue
    {
      return Self.failure(401, "UNAUTHORIZED", "token endpoint requires basic credentials")
    }
    let token = UUID().uuidString
    state.tokens.insert(token)
    let payload: [String: Any] = [
      "token": token,
      "expires_in": tokenLifetime,
      "issued_at": ISO8601DateFormatter().string(from: Date()),
    ]
    let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    return Reply(status: 200, headers: ["Content-Type": "application/json"], body: body)
  }

  // MARK: - Manifests and tags

  private func manifest(
    _ request: FakeRequest, repository: String, reference: String, state: inout State
  ) -> Reply {
    if request.method == "PUT" {
      let digest = ContentDigest.hash(request.body)
      let mediaType = request.header("Content-Type") ?? RunnerVMMediaType.ociManifest
      let stored = StoredManifest(data: request.body, mediaType: mediaType)
      state.manifests[Self.key(repository, reference)] = stored
      state.manifests[Self.key(repository, digest)] = stored
      if !reference.hasPrefix("sha256:") { state.tags[repository, default: []].insert(reference) }
      return Reply(
        status: 201,
        headers: [
          "Docker-Content-Digest": digest,
          "Location": "/v2/\(repository)/manifests/\(digest)",
        ]
      )
    }
    guard let stored = state.manifests[Self.key(repository, reference)] else {
      return Self.failure(404, "MANIFEST_UNKNOWN", "\(repository):\(reference)")
    }
    let headers = [
      "Content-Type": stored.mediaType,
      "Docker-Content-Digest": ContentDigest.hash(stored.data),
      "Content-Length": String(stored.data.count),
    ]
    return Reply(
      status: 200, headers: headers, body: request.method == "HEAD" ? Data() : stored.data
    )
  }

  private func tagList(_ repository: String, _ state: inout State) -> Reply {
    let tags = (state.tags[repository] ?? []).sorted()
    let payload: [String: Any] = ["name": repository, "tags": tags]
    let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    return Reply(status: 200, headers: ["Content-Type": "application/json"], body: body)
  }

  // MARK: - Helpers

  static func failure(
    _ status: Int, _ code: String, _ message: String, headers: [String: String] = [:]
  ) -> Reply {
    let payload = ["errors": [["code": code, "message": message]]]
    var replyHeaders = headers
    replyHeaders["Content-Type"] = "application/json"
    return Reply(
      status: status, headers: replyHeaders,
      body: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    )
  }

  /// `<name>/<verb>/<suffix>` where `<name>` itself contains slashes.
  static func split(_ rest: String, on separator: String) -> (repository: String, suffix: String)? {
    guard let range = rest.range(of: separator, options: .backwards) else { return nil }
    return (String(rest[rest.startIndex ..< range.lowerBound]), String(rest[range.upperBound...]))
  }

  /// Best-effort repository name for the auth challenge scope.
  static func repository(of rest: String) -> String {
    for separator in ["/blobs/uploads/", "/blobs/", "/manifests/", "/tags/list"] {
      if let split = split(rest, on: separator) { return split.repository }
    }
    return ""
  }
}
