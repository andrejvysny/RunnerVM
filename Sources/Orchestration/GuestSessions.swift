import Foundation
import GuestControl
import RPC
import RunnerCore

/// One ``GuestAgentClient`` per instance, created on demand and closed when the instance is torn
/// down.
///
/// Each client owns a single connection to vmworker's agent bridge, and the RPC layer multiplexes
/// requests on it — so a long `agent.exec` stream and a `agent.getMetrics` poll share one vsock
/// dial into the guest instead of opening one per call.
actor GuestSessions {
  private let paths: RunnerPaths
  private let limits: ConnectionLimits
  private var clients: [InstanceID: GuestAgentClient] = [:]

  init(paths: RunnerPaths, limits: ConnectionLimits = ConnectionLimits()) {
    self.paths = paths
    self.limits = limits
  }

  func client(for id: InstanceID) -> GuestAgentClient {
    if let client = clients[id] { return client }
    let client = GuestAgentClient(socketPath: paths.agentSocket(id), limits: limits)
    clients[id] = client
    return client
  }

  /// A closed client never redials, so the entry has to go with it: the next caller gets a fresh
  /// client for what may be a fresh guest.
  func drop(_ id: InstanceID) async {
    guard let client = clients.removeValue(forKey: id) else { return }
    await client.close()
  }

  func dropAll() async {
    for id in Array(clients.keys) { await drop(id) }
  }
}
