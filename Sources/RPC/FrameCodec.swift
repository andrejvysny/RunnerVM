import NIOCore

/// Length-prefix validation shared by the decoder and the encoder.
enum FrameLength {
  static func validate(_ length: Int, cap: Int) throws {
    guard length > 0, length <= cap else { throw RPCFrameError.invalidLength(length, cap: cap) }
  }
}

/// `uint32` big-endian length prefix followed by exactly that many envelope bytes.
public struct FrameDecoder: ByteToMessageDecoder {
  public typealias InboundOut = ByteBuffer

  public let maxFrameLength: Int

  public init(maxFrameLength: Int) {
    self.maxFrameLength = maxFrameLength
  }

  public mutating func decode(
    context: ChannelHandlerContext, buffer: inout ByteBuffer
  ) throws -> DecodingState {
    guard
      let rawLength = buffer.getInteger(
        at: buffer.readerIndex, endianness: .big, as: UInt32.self)
    else { return .needMoreData }
    let length = Int(rawLength)
    try FrameLength.validate(length, cap: maxFrameLength)
    guard buffer.readableBytes >= 4 + length else { return .needMoreData }
    buffer.moveReaderIndex(forwardBy: 4)
    let frame = buffer.readSlice(length: length)!
    context.fireChannelRead(wrapInboundOut(frame))
    return .continue
  }

  public mutating func decodeLast(
    context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool
  ) throws -> DecodingState {
    try decode(context: context, buffer: &buffer)
  }
}

public struct FrameEncoder: MessageToByteEncoder {
  public typealias OutboundIn = ByteBuffer

  public let maxFrameLength: Int

  public init(maxFrameLength: Int) {
    self.maxFrameLength = maxFrameLength
  }

  public func encode(data: ByteBuffer, out: inout ByteBuffer) throws {
    let length = data.readableBytes
    try FrameLength.validate(length, cap: maxFrameLength)
    out.writeInteger(UInt32(length), endianness: .big)
    out.writeImmutableBuffer(data)
  }
}
