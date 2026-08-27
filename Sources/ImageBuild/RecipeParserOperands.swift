import Foundation
import RunnerCore

/// Per-instruction operand grammar, split out of `RecipeParser.swift` to keep that file focused on
/// line joining and dispatch.
extension RecipeParser {
  // MARK: - FROM

  static func parseFrom(
    _ operand: String, line: Int, preFromArgDefaults: [String: String], declaredBeforeFrom: Set<String>
  ) throws -> RecipeFrom {
    guard !operand.isEmpty else { throw RecipeError.operandsMissing(instruction: "FROM", line: line) }
    let interpolated = try interpolateOrThrow(operand, line: line) { name in
      if let value = preFromArgDefaults[name] { return value }
      if declaredBeforeFrom.contains(name) { throw RecipeError.argumentMissing(name) }
      throw RecipeError.undefinedArgument(name, line: line)
    }

    var sha256: String?
    var diskBytes: UInt64?
    var operandTokens: [String] = []
    for token in RecipeText.tokenize(interpolated) {
      if let value = flagValue(token, prefix: "--sha256=") {
        guard isValidSHA256Hex(value) else { throw RecipeError.cloudImageDigestInvalid(value, line: line) }
        sha256 = value
      } else if let value = flagValue(token, prefix: "--disk=") {
        guard let size = try? ByteSize(parsing: value) else {
          throw RecipeError.fromReferenceInvalid(operand, line: line)
        }
        diskBytes = size.bytes
      } else {
        operandTokens.append(token)
      }
    }
    guard !operandTokens.isEmpty else { throw RecipeError.operandsMissing(instruction: "FROM", line: line) }
    if operandTokens.count >= 2, operandTokens[1].uppercased() == "AS" {
      throw RecipeError.fromStageAliasUnsupported(line: line)
    }
    guard operandTokens.count == 1 else { throw RecipeError.fromReferenceInvalid(operand, line: line) }

    let source = try resolveFromSource(operandTokens[0], sha256: sha256, line: line)
    return RecipeFrom(source: source, diskBytes: diskBytes, raw: operand, line: line)
  }

  private static func resolveFromSource(
    _ reference: String, sha256: String?, line: Int
  ) throws -> RecipeFrom.Source {
    if reference.hasPrefix("cloud-image:") {
      let location = String(reference.dropFirst("cloud-image:".count))
      guard location.hasPrefix("https://") || location.hasPrefix("/") else {
        throw RecipeError.fromReferenceInvalid(reference, line: line)
      }
      guard let digest = sha256 else { throw RecipeError.cloudImageDigestMissing(line: line) }
      return .cloudImage(location: location, sha256: digest)
    }
    if (try? ImageReference(parsing: reference)) != nil {
      return .registry(reference)
    }
    return .localImage(reference)
  }

  private static func isValidSHA256Hex(_ text: String) -> Bool {
    text.count == 64 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
  }

  private static func flagValue(_ token: String, prefix: String) -> String? {
    guard token.hasPrefix(prefix) else { return nil }
    return String(token.dropFirst(prefix.count))
  }

  /// `RecipeText.interpolate` reports a scan-level failure via `InterpolationError`; every other
  /// error a `resolve` closure throws (always a `RecipeError` in this parser) passes straight through.
  static func interpolateOrThrow(
    _ text: String, line: Int, resolve: (String) throws -> String
  ) throws -> String {
    do {
      return try RecipeText.interpolate(text, resolve: resolve)
    } catch is RecipeText.InterpolationError {
      throw RecipeError.argumentInvalid(text, line: line)
    }
  }

  // MARK: - ARG

  static func parseArg(_ operand: String, line: Int) throws -> (name: String, defaultValue: String?) {
    guard !operand.isEmpty else { throw RecipeError.operandsMissing(instruction: "ARG", line: line) }
    let name: String
    let defaultValue: String?
    if let eq = operand.firstIndex(of: "=") {
      name = String(operand[..<eq])
      defaultValue = String(operand[operand.index(after: eq)...])
    } else {
      name = operand
      defaultValue = nil
    }
    guard isValidArgName(name) else { throw RecipeError.argumentInvalid(operand, line: line) }
    return (name, defaultValue)
  }

  private static func isValidArgName(_ name: String) -> Bool {
    guard let first = name.first, first.isLetter || first == "_" else { return false }
    return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
  }

  // MARK: - ENV / LABEL

  /// Handles both Dockerfile forms: `KEY=value KEY2="value 2"` (one or more pairs) and the legacy
  /// `KEY value with spaces` (exactly one pair, value is everything after the key).
  static func parseKeyValueList(
    _ operand: String, instruction: String, line: Int
  ) throws -> [RecipeKeyValue] {
    guard !operand.isEmpty else { throw RecipeError.operandsMissing(instruction: instruction, line: line) }
    let words = RecipeText.tokenize(operand)
    guard !words.isEmpty else { throw RecipeError.operandsMissing(instruction: instruction, line: line) }

    if words.allSatisfy({ $0.contains("=") }) {
      return try words.map { word in
        guard let eq = word.firstIndex(of: "="), eq != word.startIndex else {
          throw RecipeError.labelInvalid(word, line: line)
        }
        return RecipeKeyValue(key: String(word[..<eq]), value: String(word[word.index(after: eq)...]))
      }
    }
    guard words.count >= 2 else { throw RecipeError.operandsMissing(instruction: instruction, line: line) }
    return [RecipeKeyValue(key: words[0], value: words.dropFirst().joined(separator: " "))]
  }

  // MARK: - RUN

  static func parseRun(_ operand: String, line: Int) throws -> (RecipeCommand, timeoutSeconds: Int?) {
    guard !operand.isEmpty else { throw RecipeError.operandsMissing(instruction: "RUN", line: line) }
    if operand.contains("<<") { throw RecipeError.heredocUnsupported(line: line) }

    var remainder = operand
    var timeoutSeconds: Int?
    if let value = leadingFlagValue(&remainder, prefix: "--timeout=") {
      do {
        timeoutSeconds = Int(try DurationValue(parsing: value).seconds)
      } catch {
        throw RecipeError.timeoutInvalid(value, line: line)
      }
    }
    remainder = remainder.trimmingCharacters(in: .whitespaces)
    guard !remainder.isEmpty else { throw RecipeError.operandsMissing(instruction: "RUN", line: line) }

    if remainder.hasPrefix("[") {
      return (.exec(try parseExecForm(remainder, line: line)), timeoutSeconds)
    }
    return (.shell(remainder), timeoutSeconds)
  }

  /// Extracts a `prefix=value` token only when it leads the (whitespace-trimmed) text, removing it
  /// and the whitespace after it. RUN's only recognized leading flag today is `--timeout=`.
  private static func leadingFlagValue(_ text: inout String, prefix: String) -> String? {
    let trimmed = text.drop(while: { $0 == " " || $0 == "\t" })
    guard trimmed.hasPrefix(prefix) else { return nil }
    let afterPrefix = trimmed.dropFirst(prefix.count)
    let value = afterPrefix.prefix(while: { $0 != " " && $0 != "\t" })
    text = String(afterPrefix.dropFirst(value.count))
    return String(value)
  }

  static func parseExecForm(_ text: String, line: Int) throws -> [String] {
    let argv: [String]
    do {
      argv = try JSONDecoder().decode([String].self, from: Data(text.utf8))
    } catch {
      throw RecipeError.jsonFormInvalid(reason: "\(error)", line: line)
    }
    guard !argv.isEmpty else {
      throw RecipeError.jsonFormInvalid(reason: "argv must not be empty", line: line)
    }
    return argv
  }

  // MARK: - COPY

  static func parseCopy(
    _ operand: String, line: Int
  ) throws -> (sources: [String], destination: String, chown: String?) {
    guard !operand.isEmpty else { throw RecipeError.operandsMissing(instruction: "COPY", line: line) }
    if operand.contains("<<") { throw RecipeError.heredocUnsupported(line: line) }

    let tokens = RecipeText.tokenize(operand)
    guard !tokens.contains(where: { $0.hasPrefix("--from=") }) else {
      throw RecipeError.copyFromUnsupported(line: line)
    }

    var chown: String?
    var rest: [String] = []
    for token in tokens {
      if let value = flagValue(token, prefix: "--chown=") {
        chown = value
      } else if !token.hasPrefix("--") {
        rest.append(token)
      }
    }
    guard rest.count >= 2 else { throw RecipeError.operandsMissing(instruction: "COPY", line: line) }
    let destination = rest.removeLast()
    return (rest, destination, chown)
  }

  // MARK: - USER / WORKDIR / SHELL

  static func parseUser(_ operand: String, line: Int) throws -> String {
    try requireSingleToken(operand, instruction: "USER", line: line)
  }

  static func parseWorkdir(_ operand: String, line: Int) throws -> String {
    try requireSingleToken(operand, instruction: "WORKDIR", line: line)
  }

  private static func requireSingleToken(_ operand: String, instruction: String, line: Int) throws -> String {
    let trimmed = operand.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { throw RecipeError.operandsMissing(instruction: instruction, line: line) }
    return trimmed
  }

  static func parseShell(_ operand: String, line: Int) throws -> [String] {
    let trimmed = operand.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("[") else {
      throw RecipeError.jsonFormInvalid(
        reason: "SHELL requires JSON array form, e.g. [\"/bin/bash\", \"-c\"]", line: line
      )
    }
    return try parseExecForm(trimmed, line: line)
  }
}
