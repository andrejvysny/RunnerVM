import Foundation
import Testing

@testable import RPC

@Suite(.serialized) struct EndToEndTests {
  @Test func unaryCallRoundTrips() async throws {
    let path = try makeSocketPath()
    let server = RPCServer(protocol: .worker, socketPath: path)
    await server.register(method: "worker.echo", class: .readOnly) { envelope, context in
      #expect(context.methodClass == .readOnly)
      #expect(context.peerUID == getuid())
      return envelope.payload ?? .emptyObject
    }
    try await server.start()
    let client = try await RPCClient.connect(protocol: .worker, socketPath: path)

    let result = try await client.call(
      method: "worker.echo", payload: .object(["ttlMs": .int(9_007_199_254_740_993)]))
    #expect(result["ttlMs"] == .int(9_007_199_254_740_993))

    await client.close()
    await server.stop()
    removeSocketDirectory(path)
  }

  @Test func handlerAndCatalogueErrorsReachTheCaller() async throws {
    let path = try makeSocketPath()
    let server = RPCServer(protocol: .daemon, socketPath: path)
    await server.register(method: "vm.stop", class: .idempotentMutation) { _, _ in
      throw RPCCallError.remote(
        RPCErrorPayload(code: "VM_NOT_RUNNING", message: "not running", retryable: false))
    }
    await server.register(method: "vm.ping", class: .readOnly) { _, _ in .emptyObject }
    try await server.start()
    let client = try await RPCClient.connect(protocol: .daemon, socketPath: path)

    await #expect(throws: RPCCallError.remote(
      RPCErrorPayload(code: "VM_NOT_RUNNING", message: "not running", retryable: false))
    ) {
      try await client.call(method: "vm.stop")
    }
    do {
      _ = try await client.call(method: "vm.nope")
      Issue.record("unknown methods must fail")
    } catch let error as RPCCallError {
      #expect(error.payload?.knownCode == .unknownMethod)
    }
    // The connection survives both failures.
    #expect(try await client.call(method: "vm.ping") == .emptyObject)

    await client.close()
    await server.stop()
    removeSocketDirectory(path)
  }

  @Test func streamDeliversChunksInOrder() async throws {
    let path = try makeSocketPath()
    let server = RPCServer(protocol: .guest, socketPath: path)
    await server.registerStream(method: "agent.exec", class: .singleShot) { _, _, sink in
      for index in 0..<100 { try await sink.send(.object(["i": .int(Int64(index))])) }
    }
    try await server.start()
    let client = try await RPCClient.connect(protocol: .guest, socketPath: path)

    var received: [Int64] = []
    for try await chunk in client.stream(method: "agent.exec") {
      received.append(chunk["i"]?.intValue ?? -1)
    }
    #expect(received == (0..<100).map(Int64.init))

    await client.close()
    await server.stop()
    removeSocketDirectory(path)
  }

  @Test func streamByteBudgetTerminatesTheStream() async throws {
    let path = try makeSocketPath()
    let server = RPCServer(
      protocol: .guest, socketPath: path,
      limits: ConnectionLimits(maxStreamBytesPerRequest: 512))
    await server.registerStream(method: "agent.exec", class: .singleShot) { _, _, sink in
      for index in 0..<1000 { try await sink.send(.object(["i": .int(Int64(index))])) }
    }
    try await server.start()
    let client = try await RPCClient.connect(protocol: .guest, socketPath: path)

    var received = 0
    do {
      for try await _ in client.stream(method: "agent.exec") { received += 1 }
      Issue.record("the byte budget must terminate the stream")
    } catch let error as RPCCallError {
      #expect(error.payload?.knownCode == .busy)
    }
    #expect(received > 0)
    #expect(received < 1000)

    await client.close()
    await server.stop()
    removeSocketDirectory(path)
  }

  @Test func cancellingAStreamCancelsTheHandler() async throws {
    let path = try makeSocketPath()
    let server = RPCServer(protocol: .guest, socketPath: path)
    let firstChunk = Signal()
    let handlerCancelled = Signal()
    let gate = CancellationGate()
    await server.registerStream(method: "agent.tail", class: .singleShot) { _, _, sink in
      try await sink.send(.object(["line": .int(0)]))
      do {
        try await gate.wait()
      } catch {
        await handlerCancelled.fire()
        throw error
      }
    }
    try await server.start()
    let client = try await RPCClient.connect(protocol: .guest, socketPath: path)

    let consumer = Task {
      for try await _ in client.stream(method: "agent.tail") { await firstChunk.fire() }
    }
    await firstChunk.wait()
    consumer.cancel()
    await handlerCancelled.wait()
    _ = try? await consumer.value

    await client.close()
    await server.stop()
    removeSocketDirectory(path)
  }

  @Test func inFlightLimitAnswersBusy() async throws {
    let path = try makeSocketPath()
    let server = RPCServer(
      protocol: .daemon, socketPath: path, limits: ConnectionLimits(maxInFlight: 2))
    let entered = Latch()
    let release = Signal()
    await server.register(method: "hold", class: .readOnly) { _, _ in
      await entered.signal()
      await release.wait()
      return .emptyObject
    }
    try await server.start()
    let client = try await RPCClient.connect(protocol: .daemon, socketPath: path)

    let first = Task { try await client.call(method: "hold") }
    let second = Task { try await client.call(method: "hold") }
    await entered.wait(for: 2)
    do {
      _ = try await client.call(method: "hold")
      Issue.record("third call must be rejected")
    } catch let error as RPCCallError {
      #expect(error.payload?.knownCode == .busy)
      #expect(error.payload?.retryable == true)
    }
    await release.fire()
    _ = try await first.value
    _ = try await second.value

    await client.close()
    await server.stop()
    removeSocketDirectory(path)
  }

  @Test func deadlineFailsTheCall() async throws {
    let path = try makeSocketPath()
    let server = RPCServer(protocol: .daemon, socketPath: path)
    let release = Signal()
    await server.register(method: "hold", class: .readOnly) { _, _ in
      await release.wait()
      return .emptyObject
    }
    try await server.start()
    let client = try await RPCClient.connect(protocol: .daemon, socketPath: path)

    await #expect(throws: RPCCallError.deadlineExceeded) {
      try await client.call(method: "hold", deadline: .milliseconds(100))
    }
    await release.fire()

    await client.close()
    await server.stop()
    removeSocketDirectory(path)
  }

  @Test func serverEventsReachTheClient() async throws {
    let path = try makeSocketPath()
    let server = RPCServer(protocol: .worker, socketPath: path)
    await server.register(method: "ping", class: .readOnly) { _, _ in .emptyObject }
    try await server.start()
    let client = try await RPCClient.connect(protocol: .worker, socketPath: path)

    // A completed call proves the server has registered this connection before broadcasting.
    _ = try await client.call(method: "ping")
    await server.broadcast(
      event: "vm.stateChanged", payload: .object(["vmState": .string("running")]))
    var iterator = client.events.makeAsyncIterator()
    let event = await iterator.next()
    #expect(event?.kind == .event)
    #expect(event?.method == "vm.stateChanged")
    #expect(event?.payload?["vmState"] == .string("running"))

    await client.close()
    await server.stop()
    removeSocketDirectory(path)
  }

  @Test func stoppingTheServerFailsOutstandingCalls() async throws {
    let path = try makeSocketPath()
    let server = RPCServer(protocol: .daemon, socketPath: path)
    let entered = Signal()
    let release = Signal()
    await server.register(method: "hold", class: .readOnly) { _, _ in
      await entered.fire()
      await release.wait()
      return .emptyObject
    }
    try await server.start()
    let client = try await RPCClient.connect(protocol: .daemon, socketPath: path)

    let outstanding = Task { try await client.call(method: "hold") }
    await entered.wait()
    await server.stop()
    await #expect(throws: RPCCallError.disconnected) { try await outstanding.value }
    await release.fire()

    await client.close()
    removeSocketDirectory(path)
  }
}
