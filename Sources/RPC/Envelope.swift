import Foundation

public enum RPCProtocol: String, Sendable, Hashable, CaseIterable, Codable {
  case daemon
  case worker
  case guest

  /// Wire version implemented by this module.
  public static let currentVersion = 1

  /// Maximum single frame size accepted on this channel.
  public var frameCap: Int {
    switch self {
    case .daemon: return 16 * 1024 * 1024
    case .worker, .guest: return 4 * 1024 * 1024
    }
  }
}

public enum EnvelopeKind: String, Sendable, Hashable, CaseIterable, Codable {
  case request
  case response
  case event
  case chunk
  case cancel
}

public struct Envelope: Sendable, Hashable {
  public var protocolName: RPCProtocol
  public var version: Int
  public var kind: EnvelopeKind
  public var requestId: String
  public var method: String?
  public var streamSeq: Int64?
  public var end: Bool?
  public var payload: JSONValue?
  public var error: RPCErrorPayload?

  public init(
    protocolName: RPCProtocol,
    version: Int = RPCProtocol.currentVersion,
    kind: EnvelopeKind,
    requestId: String,
    method: String? = nil,
    streamSeq: Int64? = nil,
    end: Bool? = nil,
    payload: JSONValue? = nil,
    error: RPCErrorPayload? = nil
  ) {
    self.protocolName = protocolName
    self.version = version
    self.kind = kind
    self.requestId = requestId
    self.method = method
    self.streamSeq = streamSeq
    self.end = end
    self.payload = payload
    self.error = error
  }
}

// MARK: - Factories

extension Envelope {
  public static func request(
    _ proto: RPCProtocol, requestId: String, method: String, payload: JSONValue? = nil
  ) -> Envelope {
    Envelope(protocolName: proto, kind: .request, requestId: requestId, method: method, payload: payload)
  }

  public static func event(
    _ proto: RPCProtocol, requestId: String, method: String, payload: JSONValue? = nil
  ) -> Envelope {
    Envelope(protocolName: proto, kind: .event, requestId: requestId, method: method, payload: payload)
  }

  public static func response(
    _ proto: RPCProtocol, requestId: String, method: String? = nil, payload: JSONValue
  ) -> Envelope {
    Envelope(protocolName: proto, kind: .response, requestId: requestId, method: method, payload: payload)
  }

  public static func failure(
    _ proto: RPCProtocol, requestId: String, method: String? = nil, error: RPCErrorPayload
  ) -> Envelope {
    Envelope(protocolName: proto, kind: .response, requestId: requestId, method: method, error: error)
  }

  public static func chunk(
    _ proto: RPCProtocol, requestId: String, method: String? = nil, streamSeq: Int64, end: Bool,
    payload: JSONValue? = nil, error: RPCErrorPayload? = nil
  ) -> Envelope {
    Envelope(
      protocolName: proto, kind: .chunk, requestId: requestId, method: method,
      streamSeq: streamSeq, end: end, payload: payload, error: error)
  }

  public static func cancel(_ proto: RPCProtocol, requestId: String) -> Envelope {
    Envelope(protocolName: proto, kind: .cancel, requestId: requestId)
  }
}

// MARK: - Encoding

extension Envelope {
  static let allowedKeys: Set<String> = [
    "protocol", "version", "kind", "requestId", "method", "streamSeq", "end", "payload", "error",
  ]

  /// Deterministic: keys sorted, absent members omitted.
  public func encode() -> [UInt8] {
    var members: [String: JSONValue] = [
      "protocol": .string(protocolName.rawValue),
      "version": .int(Int64(version)),
      "kind": .string(kind.rawValue),
      "requestId": .string(requestId),
    ]
    if let method { members["method"] = .string(method) }
    if let streamSeq { members["streamSeq"] = .int(streamSeq) }
    if let end { members["end"] = .bool(end) }
    if let payload { members["payload"] = payload }
    if let error {
      members["error"] = .object([
        "code": .string(error.code),
        "message": .string(error.message),
        "retryable": .bool(error.retryable),
      ])
    }
    return JSONValue.object(members).encoded()
  }
}

// MARK: - Decoding

extension Envelope {
  public static func decode(
    from bytes: [UInt8], expecting proto: RPCProtocol
  ) throws(EnvelopeError) -> Envelope {
    var outcome: Result<Envelope, EnvelopeError>?
    bytes.withUnsafeBytes { buffer in
      do {
        outcome = .success(try Envelope.decode(from: buffer, expecting: proto))
      } catch let error as EnvelopeError {
        outcome = .failure(error)
      } catch {
        outcome = .failure(EnvelopeError(.malformed, "\(error)"))
      }
    }
    switch outcome! {
    case .success(let envelope): return envelope
    case .failure(let error): throw error
    }
  }

  public static func decode(
    from bytes: UnsafeRawBufferPointer, expecting proto: RPCProtocol
  ) throws(EnvelopeError) -> Envelope {
    let root: JSONValue
    do {
      root = try StrictJSON.parse(bytes)
    } catch {
      throw EnvelopeError(.malformed, "invalid JSON: \(error)")
    }
    guard case .object(let members) = root else {
      throw EnvelopeError(.malformed, "envelope must be a JSON object")
    }
    let salvagedId = members["requestId"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    return try validate(members, salvagedId: salvagedId, expecting: proto)
  }

  private static func validate(
    _ members: [String: JSONValue], salvagedId: String?, expecting proto: RPCProtocol
  ) throws(EnvelopeError) -> Envelope {
    for key in members.keys where !allowedKeys.contains(key) {
      throw EnvelopeError(.malformed, "unknown key '\(key)'", requestId: salvagedId)
    }
    guard let version = members["version"]?.intValue else {
      throw EnvelopeError(.malformed, "missing or non-integer 'version'", requestId: salvagedId)
    }
    guard version == Int64(RPCProtocol.currentVersion) else {
      throw EnvelopeError(.protocolVersion, "unsupported version \(version)", requestId: salvagedId)
    }
    guard let rawProtocol = members["protocol"]?.stringValue,
      let protocolName = RPCProtocol(rawValue: rawProtocol)
    else {
      throw EnvelopeError(.malformed, "missing or unknown 'protocol'", requestId: salvagedId)
    }
    guard protocolName == proto else {
      throw EnvelopeError(
        .protocolMismatch, "expected '\(proto.rawValue)', got '\(rawProtocol)'",
        requestId: salvagedId)
    }
    guard let rawKind = members["kind"]?.stringValue, let kind = EnvelopeKind(rawValue: rawKind) else {
      throw EnvelopeError(.malformed, "missing or unknown 'kind'", requestId: salvagedId)
    }
    guard let requestId = salvagedId else {
      throw EnvelopeError(.malformed, "missing or empty 'requestId'")
    }
    var envelope = Envelope(
      protocolName: protocolName, version: Int(version), kind: kind, requestId: requestId)
    try applyOptionalMembers(members, to: &envelope)
    try checkShape(envelope, members: members)
    return envelope
  }

  private static func applyOptionalMembers(
    _ members: [String: JSONValue], to envelope: inout Envelope
  ) throws(EnvelopeError) {
    let requestId = envelope.requestId
    if let raw = members["method"] {
      guard let method = raw.stringValue, !method.isEmpty else {
        throw EnvelopeError(.malformed, "'method' must be a non-empty string", requestId: requestId)
      }
      envelope.method = method
    }
    if let raw = members["streamSeq"] {
      guard let seq = raw.intValue, seq >= 0 else {
        throw EnvelopeError(.malformed, "'streamSeq' must be a non-negative integer", requestId: requestId)
      }
      envelope.streamSeq = seq
    }
    if let raw = members["end"] {
      guard let end = raw.boolValue else {
        throw EnvelopeError(.malformed, "'end' must be a boolean", requestId: requestId)
      }
      envelope.end = end
    }
    envelope.payload = members["payload"]
    if let raw = members["error"] {
      envelope.error = try decodeError(raw, requestId: requestId)
    }
  }

  private static func decodeError(
    _ raw: JSONValue, requestId: String
  ) throws(EnvelopeError) -> RPCErrorPayload {
    guard case .object(let fields) = raw else {
      throw EnvelopeError(.malformed, "'error' must be an object", requestId: requestId)
    }
    for key in fields.keys where !["code", "message", "retryable"].contains(key) {
      throw EnvelopeError(.malformed, "unknown 'error' key '\(key)'", requestId: requestId)
    }
    guard let code = fields["code"]?.stringValue, !code.isEmpty,
      let message = fields["message"]?.stringValue
    else {
      throw EnvelopeError(.malformed, "'error' needs 'code' and 'message'", requestId: requestId)
    }
    if let retryable = fields["retryable"], retryable.boolValue == nil {
      throw EnvelopeError(.malformed, "'error.retryable' must be a boolean", requestId: requestId)
    }
    return RPCErrorPayload(
      code: code, message: message, retryable: fields["retryable"]?.boolValue ?? false)
  }

  private static func checkShape(
    _ envelope: Envelope, members: [String: JSONValue]
  ) throws(EnvelopeError) {
    let requestId = envelope.requestId
    func reject(_ why: String) -> EnvelopeError {
      EnvelopeError(.malformed, why, requestId: requestId)
    }
    let hasStreamMembers = members["streamSeq"] != nil || members["end"] != nil
    switch envelope.kind {
    case .request, .event:
      guard envelope.method != nil else { throw reject("'\(envelope.kind.rawValue)' needs 'method'") }
      guard !hasStreamMembers else { throw reject("'\(envelope.kind.rawValue)' has stream members") }
      guard envelope.error == nil else { throw reject("'\(envelope.kind.rawValue)' has 'error'") }
    case .response:
      guard !hasStreamMembers else { throw reject("'response' has stream members") }
      guard (members["payload"] == nil) != (members["error"] == nil) else {
        throw reject("'response' needs exactly one of 'payload' or 'error'")
      }
    case .chunk:
      guard envelope.streamSeq != nil else { throw reject("'chunk' needs 'streamSeq'") }
      guard envelope.end != nil else { throw reject("'chunk' needs 'end'") }
    case .cancel:
      guard members["method"] == nil, !hasStreamMembers, members["payload"] == nil,
        members["error"] == nil
      else { throw reject("'cancel' carries only 'requestId'") }
    }
  }
}
