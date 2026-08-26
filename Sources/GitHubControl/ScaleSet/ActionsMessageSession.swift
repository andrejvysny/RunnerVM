// Ported from github.com/actions/scaleset@v0.4.0 (MIT) session_client.go — see PROVENANCE.md.

import Foundation
import Logging
import RunnerCore
import RunnerLogging

/// One open message session against a runner scale set (spec §50, plan C1 "Demand inbox rule").
///
/// The session owns two things the rest of RunnerVM must never see: the message-queue URL and its
/// access token. The token expires long before the session does, so every queue call answers a 401
/// by refreshing the session — same session id, same cursor — and trying exactly once more, which
/// is what keeps a long-lived poll loop from losing its place.
public actor ActionsMessageSession: ScaleSetSession {
  /// Advertises how many runners the scale set could still start, so the service stops assigning
  /// jobs this host cannot take.
  public static let maxCapacityHeader = "X-ScaleSetMaxCapacity"

  /// The queue's 401. Deliberately not a `GitHubControlError`: it is control flow, and the retry
  /// policy must not treat it as a failed attempt.
  private struct QueueTokenExpired: Error {}

  private let connection: ActionsServiceConnection
  private let scaleSetID: Int64
  private let owner: String
  private let options: ActionsServiceOptions
  private let logger: Logger

  private let sessionID: String
  private var queueURL: URL
  private var queueToken: String
  private var statistics: ScaleSetStatistics?
  private var closed = false

  init(
    connection: ActionsServiceConnection, scaleSetID: Int64, owner: String,
    session: ActionsWire.Session, options: ActionsServiceOptions, logger: Logger
  ) throws {
    guard let sessionID = session.sessionId, !sessionID.isEmpty else {
      throw GitHubControlError.invalidResponse(
        reason: "scale set \(scaleSetID): the Actions service returned a session without an id"
      )
    }
    guard let rawURL = session.messageQueueUrl, let queueURL = URL(string: rawURL) else {
      throw GitHubControlError.invalidResponse(
        reason: "session \(sessionID): the Actions service returned no message queue URL"
      )
    }
    guard let token = session.messageQueueAccessToken, !token.isEmpty else {
      throw GitHubControlError.invalidResponse(
        reason: "session \(sessionID): the Actions service returned no message queue token"
      )
    }
    self.connection = connection
    self.scaleSetID = scaleSetID
    self.owner = session.ownerName ?? owner
    self.options = options
    self.logger = logger
    self.sessionID = sessionID
    self.queueURL = queueURL
    queueToken = token
    statistics = session.statistics?.domain
  }

  public var info: ScaleSetSessionInfo {
    ScaleSetSessionInfo(
      sessionId: sessionID, ownerName: owner, scaleSetId: scaleSetID, statistics: statistics
    )
  }

  // MARK: - Queue

  /// Long-polls the queue. `nil` means the service held the request and had nothing (HTTP 202) —
  /// the caller polls again immediately.
  public func getMessage(lastMessageID: Int64, maxCapacity: Int) async throws -> ScaleSetMessage? {
    try await withSessionRefresh {
      try await self.poll(lastMessageID: lastMessageID, maxCapacity: maxCapacity)
    }
  }

  /// Acknowledges a message. Unacknowledged messages are redelivered, so this is the only thing
  /// that advances the queue; a 404 means someone already acknowledged it and is success.
  public func deleteMessage(id: Int64) async throws {
    try await withSessionRefresh { try await self.delete(messageID: id) }
  }

  /// Claims job requests for this scale set. The returned ids are the subset actually won — the
  /// service hands the rest to someone else.
  public func acquireJobs(requestIDs: [Int64]) async throws -> [Int64] {
    guard !requestIDs.isEmpty else { return [] }
    return try await withSessionRefresh { try await self.acquire(requestIDs: requestIDs) }
  }

  public func close() async throws {
    guard !closed else { return }
    closed = true
    do {
      try await connection.sendExpectingNoContent(
        method: "DELETE", path: ActionsEndpoint.session(scaleSetID, sessionID), idempotent: true,
        label: "DELETE \(ActionsEndpoint.sessions(scaleSetID))"
      )
    } catch let error as GitHubControlError where error.errorClass == .notFound {
      logger.debug("message session already closed", metadata: ["session_id": .string(sessionID)])
    }
  }

  // MARK: - One attempt each

  private func poll(lastMessageID: Int64, maxCapacity: Int) async throws -> ScaleSetMessage? {
    let label = "GET message queue (scale set \(scaleSetID))"
    var request = URLRequest(
      url: try queueURL(lastMessageID: lastMessageID),
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: ActionsURL.seconds(options.effectivePollTimeout)
    )
    request.httpMethod = "GET"
    request.setValue(
      "application/json; api-version=\(options.apiVersion)", forHTTPHeaderField: "Accept"
    )
    authorize(&request)
    request.setValue(String(max(0, maxCapacity)), forHTTPHeaderField: Self.maxCapacityHeader)

    let poll = request
    let attempt: @Sendable () async throws -> (Data, HTTPURLResponse) = { [connection] in
      try await connection.execute(poll, label: label)
    }
    let (data, response) = try await connection.retry.run(idempotent: true, attempt)
    switch response.statusCode {
    case 202:
      return nil
    case 200:
      let message = try ScaleSetMessageDecoder.decode(data, context: label)
      if let latest = message.statistics { statistics = latest }
      return message
    case 401:
      throw QueueTokenExpired()
    default:
      throw ActionsErrorMapper.error(
        status: response.statusCode, headers: response.allHeaderFields, body: data, label: label
      )
    }
  }

  private func delete(messageID: Int64) async throws {
    let label = "DELETE message \(messageID) (scale set \(scaleSetID))"
    var request = URLRequest(
      url: queueURL.appendingPathComponent(String(messageID)),
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: ActionsURL.seconds(options.requestTimeout)
    )
    request.httpMethod = "DELETE"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    authorize(&request)

    let acknowledge = request
    let attempt: @Sendable () async throws -> (Data, HTTPURLResponse) = { [connection] in
      try await connection.execute(acknowledge, label: label)
    }
    let (data, response) = try await connection.retry.run(idempotent: true, attempt)
    switch response.statusCode {
    case 204, 200, 404:
      return
    case 401:
      throw QueueTokenExpired()
    default:
      throw ActionsErrorMapper.error(
        status: response.statusCode, headers: response.allHeaderFields, body: data, label: label
      )
    }
  }

  /// Goes to the Actions service, not the queue, but is authorised with the *queue* token — the
  /// admin token is not accepted here.
  private func acquire(requestIDs: [Int64]) async throws -> [Int64] {
    let path = ActionsEndpoint.acquireJobs(scaleSetID)
    let label = "POST \(path)"
    var request = try await connection.makeRequest(
      method: "POST", path: path, body: try ActionsURL.encode(requestIDs, label: label)
    )
    authorize(&request)

    let (data, response) = try await connection.execute(request, label: label)
    switch response.statusCode {
    case 200:
      return try ActionsURL.decode(ActionsWire.AcquireJobsResponse.self, from: data, label: label)
        .value ?? []
    case 401:
      throw QueueTokenExpired()
    default:
      throw ActionsErrorMapper.error(
        status: response.statusCode, headers: response.allHeaderFields, body: data, label: label
      )
    }
  }

  // MARK: - Session refresh

  /// Runs `body`, and on the queue's 401 refreshes the session token and runs it exactly once
  /// more. A second 401 is a dead session: the caller must open a new one.
  private func withSessionRefresh<T: Sendable>(_ body: () async throws -> T) async throws -> T {
    do {
      return try await body()
    } catch is QueueTokenExpired {
      logger.debug("message queue token expired", metadata: ["session_id": .string(sessionID)])
    }
    try await refresh()
    do {
      return try await body()
    } catch is QueueTokenExpired {
      throw GitHubControlError.scaleSetSessionExpired(scaleSetName: "scale set \(scaleSetID)")
    }
  }

  private func refresh() async throws {
    let label = "PATCH \(ActionsEndpoint.sessions(scaleSetID))"
    let refreshed = try await connection.send(
      method: "PATCH", path: ActionsEndpoint.session(scaleSetID, sessionID), idempotent: true,
      as: ActionsWire.Session.self, label: label
    )
    guard let token = refreshed.messageQueueAccessToken, !token.isEmpty else {
      throw GitHubControlError.scaleSetSessionExpired(scaleSetName: "scale set \(scaleSetID)")
    }
    queueToken = token
    if let rawURL = refreshed.messageQueueUrl, let url = URL(string: rawURL) { queueURL = url }
    if let latest = refreshed.statistics?.domain { statistics = latest }
  }

  private func authorize(_ request: inout URLRequest) {
    request.setValue("Bearer \(queueToken)", forHTTPHeaderField: "Authorization")
    request.setValue(connection.userAgent, forHTTPHeaderField: "User-Agent")
  }

  /// The cursor. Omitted when zero, exactly as the Go client does, so the service replays from the
  /// oldest unacknowledged message.
  private func queueURL(lastMessageID: Int64) throws -> URL {
    guard lastMessageID > 0 else { return queueURL }
    guard var components = URLComponents(url: queueURL, resolvingAgainstBaseURL: false) else {
      throw GitHubControlError.invalidResponse(reason: "session \(sessionID): unusable queue URL")
    }
    var items = (components.queryItems ?? []).filter { $0.name != "lastMessageId" }
    items.append(URLQueryItem(name: "lastMessageId", value: String(lastMessageID)))
    components.queryItems = items
    guard let url = components.url else {
      throw GitHubControlError.invalidResponse(reason: "session \(sessionID): unusable queue URL")
    }
    return url
  }
}
