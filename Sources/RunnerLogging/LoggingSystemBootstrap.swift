import Logging

/// Convenience bootstrap so executables wire up `JSONLogHandler` with one call.
public enum LoggingSystemBootstrap {
  public static func bootstrapJSON(
    minimumLevel: Logger.Level = .info,
    redactor: Redactor = .standard,
    sink: @escaping @Sendable (String) -> Void = JSONLogHandler.defaultSink
  ) {
    LoggingSystem.bootstrap { label in
      JSONLogHandler(label: label, logLevel: minimumLevel, redactor: redactor, sink: sink)
    }
  }

  /// Fans one already-redacted line out to several destinations. Used by `runnerd` to keep stderr
  /// (which launchd captures) while also writing the rotating file.
  public static func tee(
    _ sinks: [@Sendable (String) -> Void]
  ) -> @Sendable (String) -> Void {
    { line in
      for sink in sinks { sink(line) }
    }
  }
}
