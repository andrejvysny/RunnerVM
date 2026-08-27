import Foundation

/// Parses Runnerfile text (Dockerfile line syntax) into a `Recipe`. Pure text in, structured
/// instructions out -- no filesystem or network access, and no ARG/ENV interpolation beyond what
/// `FROM` needs to resolve its own source at parse time (see `parseFrom`). Everything else keeps
/// its raw `${VAR}` text for `RecipePlanner` to resolve once build arguments are known.
public enum RecipeParser {
  public static let defaultFileName = "Runnerfile"

  public static func parse(_ text: String, path: String, sha256: String) throws -> Recipe {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw RecipeError.empty(path: path)
    }

    var state = ParseState()
    for logical in logicalLines(of: text) {
      let (keyword, operand) = splitKeyword(logical.text)
      let upper = keyword.uppercased()
      let line = logical.line

      if let reason = rejectedInstructions[upper] {
        throw RecipeError.unsupportedInstruction(upper, line: line, reason: reason)
      }
      guard acceptedInstructions.contains(upper) else {
        throw RecipeError.unknownInstruction(keyword, line: line)
      }
      if upper != "FROM", upper != "ARG", state.from == nil {
        throw RecipeError.instructionBeforeFrom(upper, line: line)
      }
      try state.apply(upper, operand: operand, line: line)
    }

    guard let resolvedFrom = state.from else { throw RecipeError.missingFrom(path: path) }
    return Recipe(
      from: resolvedFrom, instructions: state.instructions, declaredArgs: state.declaredArgsOrder,
      path: path, sha256: sha256
    )
  }

  /// Accumulates parse results across the instruction loop: the running FROM (for the "one FROM,
  /// ARG-only before it" rule), declared ARG names/defaults, and the finished instruction list.
  private struct ParseState {
    var instructions: [RecipeInstruction] = []
    var declaredArgsOrder: [String] = []
    var declaredArgsSeen = Set<String>()
    var preFromArgDefaults: [String: String] = [:]
    var declaredBeforeFrom = Set<String>()
    var from: RecipeFrom?

    mutating func apply(_ upper: String, operand: String, line: Int) throws {
      switch upper {
      case "FROM":
        guard from == nil else { throw RecipeError.duplicateFrom(line: line) }
        let parsed = try RecipeParser.parseFrom(
          operand, line: line, preFromArgDefaults: preFromArgDefaults,
          declaredBeforeFrom: declaredBeforeFrom
        )
        from = parsed
        instructions.append(.from(parsed))
      case "ARG":
        let (name, defaultValue) = try RecipeParser.parseArg(operand, line: line)
        if declaredArgsSeen.insert(name).inserted { declaredArgsOrder.append(name) }
        if from == nil {
          declaredBeforeFrom.insert(name)
          if let defaultValue { preFromArgDefaults[name] = defaultValue }
        }
        instructions.append(.arg(name: name, defaultValue: defaultValue, line: line))
      case "ENV":
        let kvs = try RecipeParser.parseKeyValueList(operand, instruction: "ENV", line: line)
        instructions.append(.env(kvs, line: line))
      case "RUN":
        let (command, timeoutSeconds) = try RecipeParser.parseRun(operand, line: line)
        instructions.append(.run(command, timeoutSeconds: timeoutSeconds, line: line))
      case "COPY":
        let (sources, destination, chown) = try RecipeParser.parseCopy(operand, line: line)
        instructions.append(.copy(sources: sources, destination: destination, chown: chown, line: line))
      case "USER":
        instructions.append(.user(try RecipeParser.parseUser(operand, line: line), line: line))
      case "WORKDIR":
        instructions.append(.workdir(try RecipeParser.parseWorkdir(operand, line: line), line: line))
      case "SHELL":
        instructions.append(.shell(try RecipeParser.parseShell(operand, line: line), line: line))
      case "LABEL":
        let kvs = try RecipeParser.parseKeyValueList(operand, instruction: "LABEL", line: line)
        instructions.append(.label(kvs, line: line))
      default:
        throw RecipeError.unknownInstruction(upper, line: line)
      }
    }
  }

  static let acceptedInstructions: Set<String> = [
    "FROM", "ARG", "ENV", "RUN", "COPY", "USER", "WORKDIR", "SHELL", "LABEL",
  ]

  /// Hard-rejected instructions with a one-line workaround, shown as part of `unsupportedInstruction`.
  static let rejectedInstructions: [String: String] = [
    "CMD": "a RunnerVM image has no container entrypoint -- the guest agent starts actions/runner; "
      + "use RUN to install software",
    "ENTRYPOINT": "a RunnerVM image has no container entrypoint -- the guest agent starts "
      + "actions/runner; use RUN to install software",
    "EXPOSE": "RunnerVM images are VM disks, not containers -- guest networking belongs to the OS, "
      + "not a published port; drop EXPOSE",
    "VOLUME": "RunnerVM has no container volume layer -- use RUN to create directories on the VM disk",
    "ONBUILD": "RunnerVM recipes are not layered like container images -- inline the instruction "
      + "directly instead of ONBUILD",
    "HEALTHCHECK": "RunnerVM instances are health-checked by the guest agent, not a container "
      + "healthcheck -- drop HEALTHCHECK",
    "STOPSIGNAL": "RunnerVM has no container init to signal -- drop STOPSIGNAL",
    "ADD": "ADD's remote-fetch/auto-extract behavior has no guest-side equivalent -- use COPY plus "
      + "RUN to fetch/extract explicitly",
    "MAINTAINER": "MAINTAINER is obsolete -- use LABEL instead",
  ]

  // MARK: - Line joining

  struct LogicalLine {
    var line: Int
    var text: String
  }

  /// Normalizes CRLF, drops blank and `#`-comment lines (which also disposes of `# escape=`/
  /// `# syntax=` directives -- they are comments like any other), and joins `\`-continued lines.
  static func logicalLines(of text: String) -> [LogicalLine] {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    let rawLines = normalized.components(separatedBy: "\n")
    var result: [LogicalLine] = []
    var i = 0
    while i < rawLines.count {
      let leading = rawLines[i].drop(while: { $0 == " " || $0 == "\t" })
      guard !leading.isEmpty, leading.first != "#" else {
        i += 1
        continue
      }
      let startLine = i + 1
      var accumulated = String(leading)
      while endsWithOddBackslashCount(accumulated) {
        accumulated.removeLast()
        i += 1
        guard i < rawLines.count else { break }
        accumulated += rawLines[i].drop(while: { $0 == " " || $0 == "\t" })
      }
      result.append(LogicalLine(line: startLine, text: accumulated))
      i += 1
    }
    return result
  }

  /// A trailing run of N backslashes continues the line only when N is odd: `\\` is a literal
  /// (JSON-escaped) backslash, not a continuation marker -- see the module doc for why this
  /// matters for exec-form `RUN`/`SHELL` arrays.
  private static func endsWithOddBackslashCount(_ text: String) -> Bool {
    var count = 0
    for ch in text.reversed() {
      if ch == "\\" { count += 1 } else { break }
    }
    return count % 2 == 1
  }

  static func splitKeyword(_ text: String) -> (keyword: String, operand: String) {
    guard let idx = text.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
      return (text, "")
    }
    let keyword = String(text[..<idx])
    let operand = String(text[idx...]).trimmingCharacters(in: .whitespaces)
    return (keyword, operand)
  }
}
