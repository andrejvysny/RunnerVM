import Foundation
import RunnerCore

/// Routing and state transitions for `FakeActionsService`. Every request is served under one lock,
/// so a test can assert on state the moment a call returns.
extension FakeActionsService {
  func respond(to request: Recorded, host: String) -> Response {
    state.withLock { state in
      state.recorded.append(request)
      if let scripted = consumeFailure(&state, request) { return scripted }
      if host == restHost { return rest(&state, request) }
      if request.path.hasPrefix("/queue/") { return queue(&state, request) }
      guard request.path.hasPrefix(Self.tenantPath) else {
        return .failure(404, "NotFoundException", "no tenant at \(request.path)")
      }
      return api(&state, request, path: String(request.path.dropFirst(Self.tenantPath.count)))
    }
  }

  private func consumeFailure(_ state: inout State, _ request: Recorded) -> Response? {
    guard
      let index = state.failures.firstIndex(where: {
        request.path.contains($0.pathFragment) && ($0.method == nil || $0.method == request.method)
          && $0.remaining > 0
      })
    else { return nil }
    state.failures[index].remaining -= 1
    let failure = state.failures[index]
    if failure.remaining == 0 { state.failures.remove(at: index) }
    return .failure(failure.status, "ScriptedException", failure.message)
  }

  // MARK: - api.github.com leg

  private func rest(_ state: inout State, _ request: Recorded) -> Response {
    if request.method == "POST", request.path.hasSuffix("/runners/registration-token") {
      state.registrationTokens += 1
      return .json("{\"token\":\"registration-token-\(state.registrationTokens)\"}", status: 201)
    }
    guard request.method == "POST", request.path == "/actions/runner-registration" else {
      return .failure(404, "NotFoundException", "no REST route for \(request.path)")
    }
    guard let auth = request.header("Authorization"), auth.hasPrefix("RemoteAuth ") else {
      return .failure(401, "UnauthorizedException", "runner-registration needs a RemoteAuth header")
    }
    let token = Self.mintAdminToken(lifetime: state.adminTokenLifetime)
    state.adminTokens.insert(token)
    return .json("{\"url\":\"\(actionsBaseURL.absoluteString)/\",\"token\":\"\(token)\"}")
  }

  // MARK: - Actions service tenant

  private func api(_ state: inout State, _ request: Recorded, path: String) -> Response {
    let parts = path.split(separator: "/").map(String.init)
    let bearer = Self.bearer(request)
    let isSessionToken = state.sessions.values.contains { $0.queueToken == bearer }
    // `acquirejobs` is the one tenant endpoint authorised with the message-queue token.
    guard state.adminTokens.contains(bearer) || isSessionToken else {
      return .failure(401, "UnauthorizedException", "unknown or missing bearer token")
    }
    switch parts {
    case ["_apis", "runtime", "runnergroups"]:
      return runnerGroups(&state, request)
    case ["_apis", "runtime", "runnerscalesets"]:
      return request.method == "POST" ? createScaleSet(&state, request) : listScaleSets(&state, request)
    case ["_apis", "distributedtask", "pools", "0", "agents"]:
      return listRunners(&state, request)
    default:
      break
    }
    if parts.count == 6, parts[1] == "distributedtask", let id = Int64(parts[5]) {
      return runner(&state, request, id: id)
    }
    guard parts.count >= 4, parts[1] == "runtime", parts[2] == "runnerscalesets",
          let scaleSetID = Int64(parts[3])
    else {
      return .failure(404, "NotFoundException", "no tenant route for \(path)")
    }
    switch parts.count {
    case 4:
      return scaleSet(&state, request, id: scaleSetID)
    case 5 where parts[4] == "sessions":
      return createSession(&state, request, scaleSetID: scaleSetID)
    case 5 where parts[4] == "acquirejobs":
      return acquireJobs(&state, request)
    case 5 where parts[4] == "generatejitconfig":
      return generateJITConfig(&state, request, scaleSetID: scaleSetID)
    case 6 where parts[4] == "sessions":
      return session(&state, request, scaleSetID: scaleSetID, sessionID: parts[5])
    default:
      return .failure(404, "NotFoundException", "no tenant route for \(path)")
    }
  }

  private func runnerGroups(_ state: inout State, _ request: Recorded) -> Response {
    let wanted = request.query["groupName"]
    let groups = state.runnerGroups
      .filter { wanted == nil || $0.value == wanted }
      .map { ["id": $0.key, "name": $0.value, "size": 0, "isDefaultGroup": $0.key == 1] as [String: Any] }
    return Self.list(groups)
  }

  private func listScaleSets(_ state: inout State, _ request: Recorded) -> Response {
    let group = request.query["runnerGroupId"].flatMap(Int64.init)
    let name = request.query["name"]
    let found = state.scaleSets.values
      .filter { (group == nil || $0.runnerGroupID == group) && (name == nil || $0.name == name) }
      .sorted { $0.id < $1.id }
    return Self.list(found.map { dictionary(for: $0, state: state) })
  }

  private func createScaleSet(_ state: inout State, _ request: Recorded) -> Response {
    let body = Self.object(request)
    let name = body["name"] as? String ?? ""
    let group = Self.int64(body["runnerGroupId"]) ?? 1
    guard !state.scaleSets.values.contains(where: { $0.name == name && $0.runnerGroupID == group })
    else {
      return .failure(409, "ScaleSetExistsException", "scale set \(name) already exists")
    }
    let id = state.nextScaleSetID
    state.nextScaleSetID += 1
    let record = ScaleSetRecord(
      id: id, name: name, runnerGroupID: group, labels: Self.labels(body),
      disableUpdate: Self.disableUpdate(body)
    )
    state.scaleSets[id] = record
    return .json(Self.encode(dictionary(for: record, state: state)))
  }

  private func scaleSet(_ state: inout State, _ request: Recorded, id: Int64) -> Response {
    guard var record = state.scaleSets[id] else {
      return .failure(404, "ScaleSetNotFoundException", "no scale set \(id)")
    }
    switch request.method {
    case "GET":
      return .json(Self.encode(dictionary(for: record, state: state)))
    case "PATCH":
      let body = Self.object(request)
      if let name = body["name"] as? String { record.name = name }
      if let group = Self.int64(body["runnerGroupId"]) { record.runnerGroupID = group }
      if body["labels"] != nil { record.labels = Self.labels(body) }
      if body["RunnerSetting"] != nil { record.disableUpdate = Self.disableUpdate(body) }
      state.scaleSets[id] = record
      return .json(Self.encode(dictionary(for: record, state: state)))
    case "DELETE":
      state.scaleSets[id] = nil
      state.sessions = state.sessions.filter { $0.value.scaleSetID != id }
      return .empty(204)
    default:
      return .failure(405, "MethodNotAllowedException", request.method)
    }
  }

  // MARK: - Sessions

  private func createSession(
    _ state: inout State, _ request: Recorded, scaleSetID: Int64
  ) -> Response {
    guard let scaleSet = state.scaleSets[scaleSetID] else {
      return .failure(404, "ScaleSetNotFoundException", "no scale set \(scaleSetID)")
    }
    let id = UUID().uuidString.lowercased()
    state.queueTokenRotations += 1
    let record = SessionRecord(
      id: id, scaleSetID: scaleSetID,
      owner: Self.object(request)["ownerName"] as? String ?? "",
      queueToken: "queue-token-\(state.queueTokenRotations)"
    )
    state.sessions[id] = record
    return .json(Self.encode(dictionary(for: record, scaleSet: scaleSet, state: state)))
  }

  private func session(
    _ state: inout State, _ request: Recorded, scaleSetID: Int64, sessionID: String
  ) -> Response {
    guard var record = state.sessions[sessionID], record.scaleSetID == scaleSetID else {
      return .failure(404, "SessionNotFoundException", "no session \(sessionID)")
    }
    switch request.method {
    case "PATCH":
      state.queueTokenRotations += 1
      record.queueToken = "queue-token-\(state.queueTokenRotations)"
      state.sessions[sessionID] = record
      let scaleSet = state.scaleSets[scaleSetID]
      return .json(Self.encode(dictionary(for: record, scaleSet: scaleSet, state: state)))
    case "DELETE":
      state.sessions[sessionID] = nil
      return .empty(204)
    default:
      return .failure(405, "MethodNotAllowedException", request.method)
    }
  }

  // MARK: - Message queue

  private func queue(_ state: inout State, _ request: Recorded) -> Response {
    let parts = request.path.split(separator: "/").map(String.init)
    guard parts.count >= 3, let record = state.sessions[parts[1]] else {
      return .failure(404, "SessionNotFoundException", "no queue for \(request.path)")
    }
    if state.expireQueueTokenCount > 0 {
      state.expireQueueTokenCount -= 1
      return .failure(401, "TokenExpiredException", "message queue token expired")
    }
    guard Self.bearer(request) == record.queueToken else {
      return .failure(401, "TokenExpiredException", "message queue token expired")
    }
    if parts.count == 4, let messageID = Int64(parts[3]) {
      guard let index = state.messages.firstIndex(where: { $0.id == messageID }) else {
        return .empty(404)
      }
      state.messages[index].acknowledged = true
      return .empty(204)
    }
    let cursor = request.query["lastMessageId"].flatMap(Int64.init) ?? 0
    guard let message = state.messages.first(where: { !$0.acknowledged && $0.id > cursor }) else {
      return .empty(202)
    }
    var payload: [String: Any] = [
      "messageId": message.id, "messageType": message.type, "body": message.body,
    ]
    if let statistics = message.statistics { payload["statistics"] = Self.dictionary(statistics) }
    return .json(Self.encode(payload))
  }

  private func acquireJobs(_ state: inout State, _ request: Recorded) -> Response {
    let requested = (Self.array(request) ?? []).compactMap(Self.int64)
    let won = state.acquirable.map { allowed in requested.filter(allowed.contains) } ?? requested
    return .json(Self.encode(["count": won.count, "value": won]))
  }

  // MARK: - Runners

  private func generateJITConfig(
    _ state: inout State, _ request: Recorded, scaleSetID: Int64
  ) -> Response {
    guard state.scaleSets[scaleSetID] != nil else {
      return .failure(404, "ScaleSetNotFoundException", "no scale set \(scaleSetID)")
    }
    let body = Self.object(request)
    let name = body["name"] as? String ?? "runner"
    let id = state.nextRunnerID
    state.nextRunnerID += 1
    state.runners[id] = RunnerRecord(id: id, name: name, scaleSetID: scaleSetID)
    let encoded = Data("{\"runner\":\"\(name)\",\"work\":\(Self.encode(body["workFolder"] ?? "_work"))}".utf8)
      .base64EncodedString()
    return .json(
      Self.encode([
        "runner": ["id": id, "name": name, "runnerScaleSetId": scaleSetID],
        "encodedJITConfig": encoded,
      ])
    )
  }

  private func listRunners(_ state: inout State, _ request: Recorded) -> Response {
    let name = request.query["agentName"]
    let found = state.runners.values
      .filter { name == nil || $0.name == name }
      .sorted { $0.id < $1.id }
      .map { ["id": $0.id, "name": $0.name, "runnerScaleSetId": $0.scaleSetID] as [String: Any] }
    return Self.list(found)
  }

  private func runner(_ state: inout State, _ request: Recorded, id: Int64) -> Response {
    guard let record = state.runners[id] else {
      return .failure(404, "AgentNotFoundException", "no runner \(id)")
    }
    switch request.method {
    case "GET":
      return .json(
        Self.encode(["id": record.id, "name": record.name, "runnerScaleSetId": record.scaleSetID])
      )
    case "DELETE":
      state.runners[id] = nil
      return .empty(204)
    default:
      return .failure(405, "MethodNotAllowedException", request.method)
    }
  }
}

// MARK: - Encoding helpers

extension FakeActionsService {
  private func dictionary(for record: ScaleSetRecord, state: State) -> [String: Any] {
    [
      "id": record.id, "name": record.name, "runnerGroupId": record.runnerGroupID,
      "runnerGroupName": state.runnerGroups[record.runnerGroupID] ?? "default",
      "labels": record.labels.map { ["type": "System", "name": $0] },
      "RunnerSetting": ["disableUpdate": record.disableUpdate],
      "runnerJitConfigUrl":
        "\(actionsBaseURL.absoluteString)/_apis/runtime/runnerscalesets/\(record.id)/generatejitconfig",
      "statistics": Self.dictionary(state.statistics),
    ]
  }

  private func dictionary(
    for record: SessionRecord, scaleSet: ScaleSetRecord?, state: State
  ) -> [String: Any] {
    var payload: [String: Any] = [
      "sessionId": record.id, "ownerName": record.owner,
      "messageQueueUrl": "\(actionsBaseURL.scheme ?? "https")://\(actionsHost)/queue/\(record.id)/messages",
      "messageQueueAccessToken": record.queueToken,
      "statistics": Self.dictionary(state.statistics),
    ]
    if let scaleSet { payload["runnerScaleSet"] = dictionary(for: scaleSet, state: state) }
    return payload
  }

  static func dictionary(_ statistics: ScaleSetStatistics) -> [String: Any] {
    [
      "totalAvailableJobs": statistics.totalAvailableJobs,
      "totalAcquiredJobs": statistics.totalAcquiredJobs,
      "totalAssignedJobs": statistics.totalAssignedJobs,
      "totalRunningJobs": statistics.totalRunningJobs,
      "totalRegisteredRunners": statistics.totalRegisteredRunners,
      "totalBusyRunners": statistics.totalBusyRunners,
      "totalIdleRunners": statistics.totalIdleRunners,
    ]
  }

  static func list(_ values: [[String: Any]]) -> Response {
    .json(encode(["count": values.count, "value": values]))
  }

  static func encode(_ object: Any) -> String {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]
      ),
      let text = String(data: data, encoding: .utf8)
    else { return "{}" }
    return text
  }

  static func bearer(_ request: Recorded) -> String {
    guard let value = request.header("Authorization"), value.hasPrefix("Bearer ") else { return "" }
    return String(value.dropFirst("Bearer ".count))
  }

  static func object(_ request: Recorded) -> [String: Any] {
    guard let body = request.body,
          let parsed = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    else { return [:] }
    return parsed
  }

  static func array(_ request: Recorded) -> [Any]? {
    guard let body = request.body else { return nil }
    return try? JSONSerialization.jsonObject(with: body) as? [Any]
  }

  static func int64(_ value: Any?) -> Int64? {
    (value as? NSNumber)?.int64Value
  }

  static func labels(_ body: [String: Any]) -> [String] {
    ((body["labels"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
  }

  static func disableUpdate(_ body: [String: Any]) -> Bool {
    ((body["RunnerSetting"] as? [String: Any])?["disableUpdate"] as? NSNumber)?.boolValue ?? false
  }

  /// An unsigned JWT: the client only ever reads the `exp` claim, and a fake must never look like
  /// a credential that could work anywhere else.
  static func mintAdminToken(lifetime: TimeInterval) -> String {
    let expiry = Int(Date().timeIntervalSince1970 + lifetime)
    let header = base64URL("{\"alg\":\"none\",\"typ\":\"JWT\"}")
    let payload = base64URL("{\"exp\":\(expiry),\"iss\":\"fake-actions\"}")
    return "\(header).\(payload).not-a-signature"
  }

  private static func base64URL(_ text: String) -> String {
    Data(text.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
