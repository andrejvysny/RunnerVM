import Foundation
import Logging
import RunnerCore
import Testing

@testable import RunnerLogging

/// Thread-safe in-memory sink for capturing handler output without touching stderr
/// or sleeping on real I/O.
private final class LineCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var _lines: [String] = []

  func append(_ line: String) {
    lock.lock()
    defer { lock.unlock() }
    _lines.append(line)
  }

  var lines: [String] {
    lock.lock()
    defer { lock.unlock() }
    return _lines
  }
}

private func makeEvent(
  level: Logger.Level = .info,
  message: String = "message",
  metadata: Logger.Metadata? = nil
) -> LogEvent {
  LogEvent(level: level, message: "\(message)", metadata: metadata, source: nil, file: #fileID, function: #function, line: #line)
}

@Suite struct JSONLogHandlerTests {
  @Test func outputsValidJSONWithExpectedKeys() throws {
    let collector = LineCollector()
    let handler = JSONLogHandler(label: "scheduler", logLevel: .trace, sink: collector.append)
    handler.log(event: makeEvent(message: "starting instance", metadata: ["instance_id": "abc123"]))

    let lines = collector.lines
    #expect(lines.count == 1)
    let json = try #require(
      try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
    #expect(json["level"] as? String == "info")
    #expect(json["component"] as? String == "scheduler")
    #expect(json["message"] as? String == "starting instance")
    #expect(json["instance_id"] as? String == "abc123")
    #expect(json["timestamp"] is String)
    #expect(json["source"] == nil)
  }

  @Test func keysAreSortedInOutput() {
    let collector = LineCollector()
    let handler = JSONLogHandler(label: "runner", logLevel: .trace, sink: collector.append)
    handler.log(event: makeEvent(level: .debug, message: "hello"))

    let line = collector.lines[0]
    let indices = ["\"component\"", "\"level\"", "\"message\"", "\"timestamp\""]
      .map { line.range(of: $0)!.lowerBound }
    #expect(indices == indices.sorted())
  }

  @Test func nestedMetadataIsFlattenedAsNestedJSON() throws {
    let collector = LineCollector()
    let handler = JSONLogHandler(label: "guest", logLevel: .trace, sink: collector.append)
    handler.log(
      event: makeEvent(metadata: ["request": .dictionary(["method": "GET", "path": "/health"])]))

    let json = try #require(
      try JSONSerialization.jsonObject(with: Data(collector.lines[0].utf8)) as? [String: Any])
    let request = try #require(json["request"] as? [String: Any])
    #expect(request["method"] as? String == "GET")
    #expect(request["path"] as? String == "/health")
  }

  @Test func filtersMessagesBelowConfiguredLevel() {
    let collector = LineCollector()
    let logger = Logger(label: "level-test") { label in
      JSONLogHandler(label: label, logLevel: .warning, sink: collector.append)
    }
    logger.info("should be filtered")
    logger.warning("should appear")

    #expect(collector.lines.count == 1)
    #expect(collector.lines[0].contains("should appear"))
  }

  @Test func timestampParsesAsRFC3339WithFractionalSecondsUTC() throws {
    let collector = LineCollector()
    let handler = JSONLogHandler(label: "daemon", logLevel: .trace, sink: collector.append)
    handler.log(event: makeEvent(message: "tick"))

    let json = try #require(
      try JSONSerialization.jsonObject(with: Data(collector.lines[0].utf8)) as? [String: Any])
    let timestamp = try #require(json["timestamp"] as? String)
    #expect(timestamp.hasSuffix("Z"))

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    #expect(formatter.date(from: timestamp) != nil)
  }

  @Test func redactsMessageContentBeforeWriting() throws {
    let collector = LineCollector()
    let handler = JSONLogHandler(label: "github", logLevel: .trace, sink: collector.append)
    handler.log(event: makeEvent(message: "token: ghp_abcdefghijklmnopqrstuvwxyz012345"))

    let json = try #require(
      try JSONSerialization.jsonObject(with: Data(collector.lines[0].utf8)) as? [String: Any])
    let message = try #require(json["message"] as? String)
    #expect(!message.contains("ghp_"))
  }

  @Test func redactsSensitiveMetadataKeyRegardlessOfContent() throws {
    let collector = LineCollector()
    let handler = JSONLogHandler(label: "runner", logLevel: .trace, sink: collector.append)
    handler.log(event: makeEvent(metadata: ["jitConfig": "totally-benign-looking-string"]))

    let json = try #require(
      try JSONSerialization.jsonObject(with: Data(collector.lines[0].utf8)) as? [String: Any])
    #expect(json["jitConfig"] as? String == "[REDACTED:metadata-key]")
  }
}

@Suite struct RedactorTests {
  @Test func redactsGitHubPersonalAccessToken() {
    let out = Redactor.standard.redact("token: ghp_abcdefghijklmnopqrstuvwxyz012345")
    #expect(!out.contains("ghp_"))
    #expect(out.contains("[REDACTED:github-token]"))
  }

  @Test func redactsGitHubInstallationToken() {
    let out = Redactor.standard.redact("using ghs_abcdefghijklmnopqrstuvwxyz012345 to auth")
    #expect(!out.contains("ghs_"))
    #expect(out.contains("[REDACTED:github-token]"))
  }

  @Test func redactsPEMPrivateKeyBlockEntirely() {
    let pem = """
      -----BEGIN RSA PRIVATE KEY-----
      MIIEowIBAAKCAQEA1234567890abcdefghijklmnopqrstuvwxyz
      more-key-bytes-here-that-are-reasonably-long-too
      -----END RSA PRIVATE KEY-----
      """
    let out = Redactor.standard.redact("cert: \(pem) trailer")
    #expect(!out.contains("MIIEowIBAAKCAQEA"))
    #expect(out.contains("[REDACTED:pem-private-key]"))
    #expect(out.contains("trailer"))
  }

  @Test func redactsOpenSSHPrivateKeyBlock() {
    let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjE\n-----END OPENSSH PRIVATE KEY-----"
    let out = Redactor.standard.redact(pem)
    #expect(!out.contains("b3BlbnNzaC1rZXktdjE"))
    #expect(out.contains("[REDACTED:pem-private-key]"))
  }

  @Test func redactsStandaloneBearerToken() {
    let out = Redactor.standard.redact("calling with Bearer sk_live_1234567890abcdef")
    #expect(!out.contains("sk_live"))
    #expect(out.contains("[REDACTED:bearer-token]"))
  }

  @Test func redactsAuthorizationHeaderValue() {
    let out = Redactor.standard.redact("Authorization: Bearer abc.def.ghi")
    #expect(!out.contains("abc.def.ghi"))
    #expect(out.contains("[REDACTED:authorization-header]"))
  }

  @Test func redactsLongBase64Blob() {
    let blob = String(repeating: "A", count: 300)
    let out = Redactor.standard.redact("jit config: \(blob) end")
    #expect(!out.contains(blob))
    #expect(out.contains("[REDACTED:base64-blob]"))
    #expect(out.contains("end"))
  }

  @Test func doesNotRedactSSHPublicKeys() {
    let rsaKey = "ssh-rsa " + String(repeating: "B", count: 300) + " user@host"
    let ed25519Key = "ssh-ed25519 " + String(repeating: "C", count: 300) + " user@host"
    #expect(Redactor.standard.redact(rsaKey) == rsaKey)
    #expect(Redactor.standard.redact(ed25519Key) == ed25519Key)
  }

  @Test func redactsSensitiveMetadataKeyRegardlessOfContent() {
    let metadata: Logger.Metadata = ["jitConfig": "not-secret-looking-value"]
    let redacted = Redactor.standard.redact(metadata: metadata)
    #expect(redacted["jitConfig"] == .string("[REDACTED:metadata-key]"))
  }

  @Test func redactsSensitiveKeyInNestedMetadata() {
    let metadata: Logger.Metadata = ["config": .dictionary(["password": "hunter2"])]
    let redacted = Redactor.standard.redact(metadata: metadata)
    guard case .dictionary(let config)? = redacted["config"] else {
      Issue.record("expected nested dictionary")
      return
    }
    #expect(config["password"] == .string("[REDACTED:metadata-key]"))
  }

  @Test func redactsSecretContentInsideNestedMetadataValue() {
    let metadata: Logger.Metadata = [
      "request": .dictionary(["headers": .dictionary(["authorization": "Bearer topsecret123456"])])
    ]
    let redacted = Redactor.standard.redact(metadata: metadata)
    guard case .dictionary(let request)? = redacted["request"],
      case .dictionary(let headers)? = request["headers"],
      case .string(let authValue)? = headers["authorization"]
    else {
      Issue.record("expected nested dictionary shape to be preserved")
      return
    }
    #expect(!authValue.contains("topsecret123456"))
  }

  @Test func redactsWithinArrayMetadataValues() {
    // Key deliberately avoids the sensitive-key substrings (e.g. "token") so this
    // exercises array-element content redaction rather than whole-value key redaction.
    let metadata: Logger.Metadata = ["auth_lines": .array(["Bearer abc123def456", "plain-value"])]
    let redacted = Redactor.standard.redact(metadata: metadata)
    guard case .array(let values)? = redacted["auth_lines"] else {
      Issue.record("expected array")
      return
    }
    #expect(values == [.string("[REDACTED:bearer-token]"), .string("plain-value")])
  }
}

@Suite struct LogComponentTests {
  @Test func rawValuesMatchSpecRequiredComponents() {
    #expect(LogComponent.workerSupervisor.rawValue == "worker-supervisor")
    #expect(LogComponent.allCases.count == 13)
  }

  @Test func loggerComponentInitUsesRawValueAsLabel() {
    #expect(Logger(component: .scheduler).label == "scheduler")
  }
}

@Suite struct LogContextTests {
  @Test func buildsStandardObservabilityMetadataKeys() {
    let metadata = Logger.Metadata.context(
      profile: RunnerProfileID(rawValue: "p1"),
      instance: InstanceID(rawValue: "i1"),
      session: RunnerSessionID(rawValue: "s1"),
      githubJobRequestID: "42",
      operation: OperationID(rawValue: "op1"),
      workerPID: 4242,
      imageDigest: ImageDigest(rawValue: "sha256:deadbeef")
    )
    #expect(metadata["profile_id"] == .string("p1"))
    #expect(metadata["instance_id"] == .string("i1"))
    #expect(metadata["runner_session_id"] == .string("s1"))
    #expect(metadata["github_job_request_id"] == .string("42"))
    #expect(metadata["operation_id"] == .string("op1"))
    #expect(metadata["image_digest"] == .string("sha256:deadbeef"))
    guard case .stringConvertible(let pid)? = metadata["worker_pid"] else {
      Issue.record("expected worker_pid to be stringConvertible")
      return
    }
    #expect(pid.description == "4242")
  }

  @Test func omitsKeysForNilFields() {
    let metadata = Logger.Metadata.context(instance: InstanceID(rawValue: "i1"))
    #expect(metadata.count == 1)
    #expect(metadata["instance_id"] == .string("i1"))
  }
}
