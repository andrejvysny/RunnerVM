import Foundation

/// `agent.exec` payload. `timeoutMs` and `maxOutputBytes` are mandatory on the host side: an
/// unbounded exec on an untrusted guest is a denial-of-service surface (spec §38).
public struct ExecRequest: Codable, Sendable, Equatable {
  public var argv: [String]
  public var cwd: String?
  public var env: [String: String]?
  public var timeoutMs: Int64
  public var maxOutputBytes: Int64

  public static let defaultTimeoutMs: Int64 = 30_000
  public static let defaultMaxOutputBytes: Int64 = 1 << 20

  public init(
    argv: [String], cwd: String? = nil, env: [String: String]? = nil,
    timeoutMs: Int64 = ExecRequest.defaultTimeoutMs,
    maxOutputBytes: Int64 = ExecRequest.defaultMaxOutputBytes
  ) {
    self.argv = argv
    self.cwd = cwd
    self.env = env
    self.timeoutMs = timeoutMs
    self.maxOutputBytes = maxOutputBytes
  }
}

public enum ExecStream: String, Codable, Sendable, CaseIterable, Hashable {
  case stdout
  case stderr
}

/// One `agent.exec` output chunk. `data` is base64 on the wire.
public struct ExecChunk: Codable, Sendable, Equatable {
  public var stream: ExecStream
  public var data: Data

  public init(stream: ExecStream, data: Data) {
    self.stream = stream
    self.data = data
  }
}

/// The last payload-bearing `agent.exec` chunk. The agent appends an empty `end: true` chunk after
/// it (or an error-bearing one), so the host reads chunks until `end` and takes the exit code from
/// the final payload.
public struct ExecResult: Codable, Sendable, Equatable {
  public var exitCode: Int64

  public init(exitCode: Int64) { self.exitCode = exitCode }
}

/// What ``GuestAgentClient/exec(_:)`` yields. `exited` arrives exactly once and last.
public enum ExecEvent: Sendable, Equatable {
  case stdout(Data)
  case stderr(Data)
  case exited(Int32)

  public init(chunk: ExecChunk) {
    switch chunk.stream {
    case .stdout: self = .stdout(chunk.data)
    case .stderr: self = .stderr(chunk.data)
    }
  }
}
