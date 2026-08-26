import RunnerCore
import Testing

/// `logging:` range checks. Codes are stable API — `runnerctl config validate` prints them and
/// `docs/logging.md` documents them.
struct LoggingValidationTests {
  private static func issues(_ logging: LoggingConfig) -> [ConfigurationIssue] {
    RunnerConfiguration(logging: logging).validate(host: Fixtures.hostFacts)
  }

  @Test func theDefaultsValidateClean() {
    #expect(!Self.issues(LoggingConfig()).contains { $0.code.hasPrefix("LOGGING_") })
  }

  @Test func aFileTooSmallToHoldOneBurstIsRejected() {
    let found = Self.issues(LoggingConfig(
      file: LoggingConfig.FileConfig(maxSizeBytes: 1024)))
    #expect(found.contains(code: "LOGGING_FILE_MAX_SIZE_TOO_SMALL"))
    #expect(found.first(code: "LOGGING_FILE_MAX_SIZE_TOO_SMALL")?.severity == .error)
  }

  @Test func maxFilesMustBeBetweenOneAndOneHundred() {
    #expect(Self.issues(LoggingConfig(file: LoggingConfig.FileConfig(maxFiles: 0)))
      .contains(code: "LOGGING_FILE_MAX_FILES_INVALID"))
    #expect(Self.issues(LoggingConfig(file: LoggingConfig.FileConfig(maxFiles: 101)))
      .contains(code: "LOGGING_FILE_MAX_FILES_INVALID"))
    #expect(!Self.issues(LoggingConfig(file: LoggingConfig.FileConfig(maxFiles: 100)))
      .contains(code: "LOGGING_FILE_MAX_FILES_INVALID"))
  }

  /// The file bounds only matter when a file is written at all.
  @Test func fileBoundsAreNotCheckedWhenFileLoggingIsOff() {
    let found = Self.issues(LoggingConfig(
      file: LoggingConfig.FileConfig(enabled: false, maxSizeBytes: 1, maxFiles: 0)))
    #expect(!found.contains(code: "LOGGING_FILE_MAX_SIZE_TOO_SMALL"))
    #expect(!found.contains(code: "LOGGING_FILE_MAX_FILES_INVALID"))
  }

  @Test func negativeRetentionIsAnErrorAndZeroIsAWarning() {
    #expect(Self.issues(LoggingConfig(
      retention: LoggingConfig.RetentionConfig(instanceLogs: .seconds(-1))))
      .contains(code: "LOGGING_RETENTION_NEGATIVE"))
    let zero = Self.issues(LoggingConfig(
      retention: LoggingConfig.RetentionConfig(instanceLogs: .zero)))
    #expect(zero.first(code: "LOGGING_RETENTION_DISABLED")?.severity == .warning)
    #expect(!zero.hasErrors)
  }

  @Test func aNonPositiveDiagnosticsTimeoutIsRejectedOnlyWhileCollectionIsOn() {
    #expect(Self.issues(LoggingConfig(diagnosticsTimeout: .zero))
      .contains(code: "LOGGING_DIAGNOSTICS_TIMEOUT_INVALID"))
    #expect(!Self.issues(LoggingConfig(
      collectRunnerDiagnostics: false, diagnosticsTimeout: .zero))
      .contains(code: "LOGGING_DIAGNOSTICS_TIMEOUT_INVALID"))
  }
}
