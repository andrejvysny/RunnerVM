import ConfigLoader
import Foundation
import RunnerCore
import Testing

/// The `logging:` section: defaults when absent, every field readable when present, and a typo
/// rejected rather than silently ignored.
struct LoggingConfigTests {
  private static func load(_ yaml: String) throws -> RunnerConfiguration {
    try ConfigLoader.load(yaml: yaml)
  }

  private static let scopeOnly = """
    version: 1
    github:
      scopes:
        - {name: engineering, type: organization, owner: acme}
    """

  @Test func absentSectionResolvesToTheRunnerCoreDefaults() throws {
    let config = try Self.load(Fixtures.minimalYAML)
    #expect(config.logging == LoggingConfig())
    #expect(config.logging.file.enabled)
    #expect(config.logging.file.maxSizeBytes == ByteSize.mebibytes(32).bytes)
    #expect(config.logging.file.maxFiles == 10)
    #expect(config.logging.retention.instanceLogs == .days(7))
    #expect(config.logging.collectRunnerDiagnostics)
    #expect(config.logging.diagnosticsTimeout == .seconds(60))
  }

  @Test func everyFieldIsReadFromTheDocument() throws {
    let config = try Self.load("""
      \(Self.scopeOnly)
      logging:
        file:
          enabled: false
          maxSize: 8MiB
          maxFiles: 3
        retention:
          instanceLogs: 36h
        collectRunnerDiagnostics: false
        diagnosticsTimeout: 90s
      """)
    #expect(config.logging.file.enabled == false)
    #expect(config.logging.file.maxSizeBytes == ByteSize.mebibytes(8).bytes)
    #expect(config.logging.file.maxFiles == 3)
    #expect(config.logging.retention.instanceLogs == .hours(36))
    #expect(config.logging.collectRunnerDiagnostics == false)
    #expect(config.logging.diagnosticsTimeout == .seconds(90))
  }

  @Test func aPartialSectionKeepsTheDefaultsForEverythingElse() throws {
    let config = try Self.load("""
      \(Self.scopeOnly)
      logging:
        retention:
          instanceLogs: 14d
      """)
    #expect(config.logging.retention.instanceLogs == .days(14))
    #expect(config.logging.file == LoggingConfig.FileConfig())
    #expect(config.logging.collectRunnerDiagnostics)
  }

  @Test func anUnknownKeyIsRejectedRatherThanIgnored() throws {
    #expect(throws: (any Error).self) {
      _ = try Self.load("""
        \(Self.scopeOnly)
        logging:
          file:
            maxsize: 8MiB
        """)
    }
  }

  /// A document persisted by a build that predates this section must still load (spec §63/§91).
  @Test func aDocumentWithoutTheSectionStillDecodesThroughCodable() throws {
    // Encode a current document, then delete the key an older build would never have written.
    let encoded = try JSONEncoder().encode(RunnerConfiguration())
    var object = try #require(
      try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "logging")
    let older = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(RunnerConfiguration.self, from: older)
    #expect(decoded.logging == LoggingConfig())
  }

  @Test func theSectionRoundTripsThroughCodable() throws {
    let original = RunnerConfiguration(
      logging: LoggingConfig(
        file: LoggingConfig.FileConfig(
          enabled: false, maxSizeBytes: ByteSize.mebibytes(4).bytes, maxFiles: 2),
        retention: LoggingConfig.RetentionConfig(instanceLogs: .hours(1)),
        collectRunnerDiagnostics: false,
        diagnosticsTimeout: .seconds(5)))
    let data = try JSONEncoder().encode(original)
    #expect(try JSONDecoder().decode(RunnerConfiguration.self, from: data).logging
      == original.logging)
  }
}
