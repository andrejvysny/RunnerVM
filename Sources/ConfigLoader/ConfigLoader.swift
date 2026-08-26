import Foundation
import RunnerCore
import Yams

/// YAML text -> validated `RunnerConfiguration` (spec §63, §91). This is the only module in
/// RunnerVM that parses YAML; every other module consumes `RunnerConfiguration` directly.
public enum ConfigLoader {
  /// Parses and maps `yaml` without checking it against host capacity. Use `loadAndValidate` when
  /// a `HostFacts` is available.
  public static func load(yaml: String) throws(ConfigLoadError) -> RunnerConfiguration {
    let node = try composeNode(yaml)
    if let unknownPath = ConfigSchema.firstUnknownKey(in: node) {
      throw .unknownKey(path: unknownPath)
    }
    let dto = try decodeDTO(node)
    guard dto.version == RunnerConfiguration.currentVersion else {
      throw .unsupportedVersion(dto.version)
    }
    return try ConfigMapper.map(dto)
  }

  public static func load(fileAt url: URL) throws -> RunnerConfiguration {
    let text = try String(contentsOf: url, encoding: .utf8)
    return try load(yaml: text)
  }

  /// Parses, maps, and validates against `facts`. Throws `ConfigLoadError.validationFailed` when
  /// any finding is `severity == .error`; otherwise returns the (possibly empty) warning list.
  public static func loadAndValidate(
    yaml: String, host facts: HostFacts
  ) throws -> (RunnerConfiguration, [ConfigurationIssue]) {
    let config = try load(yaml: yaml)
    let issues = config.validate(host: facts)
    guard !issues.hasErrors else { throw ConfigLoadError.validationFailed(issues.errors) }
    return (config, issues)
  }

  // MARK: - Stage 1: YAML syntax

  private static func composeNode(_ yaml: String) throws(ConfigLoadError) -> Node {
    let node: Node?
    do {
      node = try Yams.compose(yaml: yaml)
    } catch {
      throw yamlSyntaxError(error)
    }
    guard let node else {
      throw .missingKey(path: "version") // empty document: nothing to decode
    }
    return node
  }

  private static func yamlSyntaxError(_ error: any Error) -> ConfigLoadError {
    guard let yamlError = error as? YamlError else {
      return .yamlSyntax(line: 0, column: 0, message: "\(error)")
    }
    switch yamlError {
    case let .scanner(_, problem, mark, _), let .parser(_, problem, mark, _),
         let .composer(_, problem, mark, _):
      return .yamlSyntax(line: mark.line, column: mark.column, message: problem)
    default:
      return .yamlSyntax(line: 0, column: 0, message: "\(yamlError)")
    }
  }

  // MARK: - Stage 2: DTO decode

  private static func decodeDTO(_ node: Node) throws(ConfigLoadError) -> ConfigDTO {
    do {
      return try YAMLDecoder().decode(ConfigDTO.self, from: node)
    } catch let error as DecodingError {
      throw decodeError(error)
    } catch {
      throw .invalidValue(path: "<root>", reason: "\(error)")
    }
  }

  private static func decodeError(_ error: DecodingError) -> ConfigLoadError {
    switch error {
    case let .keyNotFound(key, context):
      return .missingKey(path: renderPath(context.codingPath + [key]))
    case let .typeMismatch(_, context), let .valueNotFound(_, context), let .dataCorrupted(context):
      return .invalidValue(path: renderPath(context.codingPath), reason: context.debugDescription)
    @unknown default:
      return .invalidValue(path: "<root>", reason: "\(error)")
    }
  }

  /// Renders a `CodingPath` as `profiles[1].resources.memory`: array indices in brackets, field
  /// names dot-joined, matching `ConfigurationIssue.path`'s existing convention.
  private static func renderPath(_ codingPath: [any CodingKey]) -> String {
    var out = ""
    for key in codingPath {
      if let intValue = key.intValue {
        out += "[\(intValue)]"
      } else {
        out += out.isEmpty ? key.stringValue : ".\(key.stringValue)"
      }
    }
    return out.isEmpty ? "<root>" : out
  }
}
