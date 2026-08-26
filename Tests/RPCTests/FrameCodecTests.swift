import Foundation
import NIOCore
import Testing

@testable import RPC

@Suite struct FrameCodecTests {
  @Test func frameCapsMatchTheSpec() {
    #expect(RPCProtocol.daemon.frameCap == 16 * 1024 * 1024)
    #expect(RPCProtocol.worker.frameCap == 4 * 1024 * 1024)
    #expect(RPCProtocol.guest.frameCap == 4 * 1024 * 1024)
  }

  @Test func lengthPrefixBoundsAreEnforced() throws {
    let cap = RPCProtocol.guest.frameCap
    try FrameLength.validate(1, cap: cap)
    try FrameLength.validate(cap, cap: cap)
    #expect(throws: RPCFrameError.invalidLength(0, cap: cap)) {
      try FrameLength.validate(0, cap: cap)
    }
    #expect(throws: RPCFrameError.invalidLength(cap + 1, cap: cap)) {
      try FrameLength.validate(cap + 1, cap: cap)
    }
  }

  @Test func encoderWritesBigEndianLength() throws {
    let json = #"{"protocol":"guest","version":1,"kind":"request","requestId":"6f1c1a2e-2c2c-4d0f-9d8a-0f2d1b3c4d5e","method":"agent.hello"}"#
    #expect(json.utf8.count == 0x7B, "fixture frame-of-request-minimal expects 123 bytes")
    var payload = ByteBuffer()
    payload.writeString(json)
    var out = ByteBuffer()
    try FrameEncoder(maxFrameLength: RPCProtocol.guest.frameCap).encode(data: payload, out: &out)
    let prefix = out.getBytes(at: 0, length: 4)!
    #expect(prefix == [0x00, 0x00, 0x00, 0x7B])
    #expect(out.readableBytes == 4 + json.utf8.count)
  }

  @Test func encoderRefusesFramesOutsideTheCap() {
    var oversized = ByteBuffer()
    oversized.writeBytes([UInt8](repeating: 0x20, count: 33))
    var out = ByteBuffer()
    #expect(throws: RPCFrameError.self) {
      try FrameEncoder(maxFrameLength: 32).encode(data: oversized, out: &out)
    }
    #expect(throws: RPCFrameError.self) {
      try FrameEncoder(maxFrameLength: 32).encode(data: ByteBuffer(), out: &out)
    }
  }
}
