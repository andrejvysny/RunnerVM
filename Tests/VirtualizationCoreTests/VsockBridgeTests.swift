import Foundation
import Testing
@testable import VirtualizationCore

private struct Transcript: Sendable {
  var connected = false
  var guestSawRequest: String?
  var clientSawReply: String?
  var guestSawEOF = false
}

private enum FakeGuestError: Error { case unavailable }

@Suite struct VsockBridgeTests {
  private func socketPair() -> (guest: CInt, peer: CInt) {
    var fds: [CInt] = [-1, -1]
    _ = fds.withUnsafeMutableBufferPointer { socketpair(AF_UNIX, SOCK_STREAM, 0, $0.baseAddress!) }
    return (fds[0], fds[1])
  }

  @Test @MainActor func relaysBothDirectionsAndClosesBothHalvesTogether() async throws {
    let directory = try Scratch.makeDirectory("bridge")
    defer { Scratch.remove(directory) }
    let socketPath = directory.appendingPathComponent("agent.sock")
    let pair = socketPair()
    let waiter = CountWaiter()

    let bridge = VsockBridge(socketPath: socketPath) { pair.guest }
    bridge.onConnectionCountChanged { waiter.record($0) }
    try bridge.start()
    defer { bridge.stop() }

    let path = socketPath.path
    let transcript = await onBackgroundThread { () -> Transcript in
      var result = Transcript()
      let client = UnixSocket.connect(to: path)
      guard client >= 0 else { return result }
      result.connected = true
      _ = UnixSocket.send(client, "ping")
      result.guestSawRequest = UnixSocket.receive(pair.peer, count: 4)
      _ = UnixSocket.send(pair.peer, "pong")
      result.clientSawReply = UnixSocket.receive(client, count: 4)
      // Closing the client must propagate a half-close to the guest side.
      close(client)
      result.guestSawEOF = UnixSocket.isAtEOF(pair.peer)
      close(pair.peer)
      return result
    }

    #expect(transcript.connected)
    #expect(transcript.guestSawRequest == "ping")
    #expect(transcript.clientSawReply == "pong")
    #expect(transcript.guestSawEOF)
    // Reaching zero proves the guest-side descriptor was closed too, not just the client's.
    await waiter.wait(for: 0)
    #expect(bridge.activeConnections == 0)
  }

  @Test @MainActor func closesClientImmediatelyWhenGuestIsUnreachable() async throws {
    let directory = try Scratch.makeDirectory("bridge-noguest")
    defer { Scratch.remove(directory) }
    let socketPath = directory.appendingPathComponent("agent.sock")
    let waiter = CountWaiter()

    let bridge = VsockBridge(socketPath: socketPath) { throw FakeGuestError.unavailable }
    bridge.onConnectionCountChanged { waiter.record($0) }
    try bridge.start()
    defer { bridge.stop() }

    let path = socketPath.path
    let sawEOF = await onBackgroundThread { () -> Bool in
      let client = UnixSocket.connect(to: path)
      guard client >= 0 else { return false }
      defer { close(client) }
      return UnixSocket.isAtEOF(client)
    }
    #expect(sawEOF)
    await waiter.wait(for: 0)
  }

  @Test @MainActor func publishesSocketAtMode0600() async throws {
    let directory = try Scratch.makeDirectory("bridge-mode")
    defer { Scratch.remove(directory) }
    let socketPath = directory.appendingPathComponent("agent.sock")
    let bridge = VsockBridge(socketPath: socketPath) { -1 }
    try bridge.start()
    defer { bridge.stop() }

    let attributes = try FileManager.default.attributesOfItem(atPath: socketPath.path)
    #expect(attributes[.posixPermissions] as? NSNumber == 0o600)
    #expect(!FileManager.default.fileExists(atPath: socketPath.path + ".tmp"))
    #expect(bridge.activeConnections == 0)
  }

  @Test @MainActor func refusesToStartTwice() async throws {
    let directory = try Scratch.makeDirectory("bridge-twice")
    defer { Scratch.remove(directory) }
    let bridge = VsockBridge(socketPath: directory.appendingPathComponent("agent.sock")) { -1 }
    try bridge.start()
    defer { bridge.stop() }
    #expect(throws: VsockBridgeError.alreadyStarted) { try bridge.start() }
  }
}
