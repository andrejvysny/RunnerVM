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
}
