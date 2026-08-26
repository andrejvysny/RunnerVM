import Foundation
import Testing

@testable import RPC

@Suite(.serialized) struct TransportSecurityTests {
  @Test func socketIsPublishedWithOwnerOnlyPermissions() async throws {
    let path = try makeSocketPath()
    let server = RPCServer(protocol: .worker, socketPath: path)
    try await server.start()

    let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o600)
    #expect(!FileManager.default.fileExists(atPath: path.path + ".tmp"))

    await server.stop()
    removeSocketDirectory(path)
  }

  @Test func peerUIDIsAcceptedWhenAllowed() async throws {
    let path = try makeSocketPath()
    let server = RPCServer(protocol: .worker, socketPath: path, allowedUIDs: [getuid()])
    await server.register(method: "ping", class: .readOnly) { _, context in
      .object(["uid": .int(Int64(context.peerUID))])
    }
    try await server.start()
    let client = try await RPCClient.connect(protocol: .worker, socketPath: path)

    let result = try await client.call(method: "ping")
    #expect(result["uid"] == .int(Int64(getuid())))

    await client.close()
    await server.stop()
    removeSocketDirectory(path)
  }

  @Test func peerUIDIsRejectedWhenNotAllowed() async throws {
    let path = try makeSocketPath()
    let server = RPCServer(
      protocol: .worker, socketPath: path, allowedUIDs: [getuid() &+ 4242])
    await server.register(method: "ping", class: .readOnly) { _, _ in .emptyObject }
    try await server.start()

    var succeeded = false
    if let client = try? await RPCClient.connect(protocol: .worker, socketPath: path) {
      succeeded = (try? await client.call(method: "ping")) != nil
      await client.close()
    }
    #expect(!succeeded, "a disallowed uid must never reach a handler")

    await server.stop()
    removeSocketDirectory(path)
  }

  @Test func oversizedFrameClosesTheConnection() async throws {
    let path = try makeSocketPath()
    let server = RPCServer(protocol: .guest, socketPath: path)
    try await server.start()

    let descriptor = try RawSocket.connect(to: path)
    RawSocket.write(descriptor, [0x00, 0x40, 0x00, 0x01])  // 4 MiB + 1, one over the guest cap
    #expect(RawSocket.readsEOF(descriptor))
    close(descriptor)

    await server.stop()
    removeSocketDirectory(path)
  }

  @Test func zeroLengthFrameClosesTheConnection() async throws {
    let path = try makeSocketPath()
    let server = RPCServer(protocol: .guest, socketPath: path)
    try await server.start()

    let descriptor = try RawSocket.connect(to: path)
    RawSocket.write(descriptor, [0x00, 0x00, 0x00, 0x00])
    #expect(RawSocket.readsEOF(descriptor))
    close(descriptor)

    await server.stop()
    removeSocketDirectory(path)
  }

  @Test func malformedEnvelopeWithRequestIdKeepsTheConnection() async throws {
    let path = try makeSocketPath()
    let server = RPCServer(protocol: .guest, socketPath: path)
    await server.register(method: "agent.hello", class: .readOnly) { _, _ in .emptyObject }
    try await server.start()
    let client = try await RPCClient.connect(protocol: .guest, socketPath: path)

    // `stream` on a unary method still gets a well-formed error, and the socket stays usable.
    do {
      _ = try await client.call(method: "agent.missing")
      Issue.record("expected UNKNOWN_METHOD")
    } catch let error as RPCCallError {
      #expect(error.payload?.knownCode == .unknownMethod)
    }
    #expect(try await client.call(method: "agent.hello") == .emptyObject)

    await client.close()
    await server.stop()
    removeSocketDirectory(path)
  }
}
