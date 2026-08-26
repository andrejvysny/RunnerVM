import RunnerCore

/// Failures that abort a YAML load before a `RunnerConfiguration` exists. Field-level problems
/// found once a configuration decodes cleanly are `ConfigurationIssue`s from RunnerCore's
/// `validate(host:)`; this type covers everything that happens earlier, in the YAML -> DTO stage.
public enum ConfigLoadError: RunnerError {
  /// The document itself is not valid YAML (bad indentation, unterminated string, etc).
  case yamlSyntax(line: Int, column: Int, message: String)
  /// A key that does not appear anywhere in the configuration schema. Typos should fail loudly
  /// rather than being silently ignored the way lenient `Decodable` key matching would.
  case unknownKey(path: String)
  /// A key that the schema recognizes but a required value is missing at.
  case missingKey(path: String)
  /// A key's value does not parse into its target type (bad byte size, bad duration, bad enum).
  case invalidValue(path: String, reason: String)
  case unsupportedVersion(Int)
  /// Aggregate of every `severity == .error` issue from `RunnerConfiguration.validate(host:)`.
  case validationFailed([ConfigurationIssue])

  public var code: String {
    switch self {
    case .yamlSyntax: "CONFIG_YAML_SYNTAX"
    case .unknownKey: "CONFIG_UNKNOWN_KEY"
    case .missingKey: "CONFIG_MISSING_KEY"
    case .invalidValue: "CONFIG_INVALID_VALUE"
    case .unsupportedVersion: "CONFIG_UNSUPPORTED_VERSION"
    case .validationFailed: "CONFIG_VALIDATION_FAILED"
    }
  }

  public var message: String {
    switch self {
    case let .yamlSyntax(line, column, message): "YAML syntax error at \(line):\(column): \(message)"
    case let .unknownKey(path): "unknown configuration key '\(path)'"
    case let .missingKey(path): "missing required key '\(path)'"
    case let .invalidValue(path, reason): "\(path): \(reason)"
    case let .unsupportedVersion(version):
      "configuration version \(version) is not supported (expected \(RunnerConfiguration.currentVersion))"
    case let .validationFailed(issues):
      "configuration rejected: " + issues.map { "\($0.path): \($0.code)" }.joined(separator: ", ")
    }
  }

  /// Configuration is operator input: nothing here improves by trying again.
  public var retryable: Bool {
    false
  }
}
