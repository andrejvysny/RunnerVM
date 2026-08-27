/// Interpolation, COPY validation, and display-text helpers for `RecipePlanner`, split out to keep
/// `RecipePlanner.swift` focused on the instruction-folding loop.
extension RecipePlanner {
  /// Every declared ARG is already in `scope` regardless of where in the file it was declared (see
  /// `RecipePlanner.plan`'s upfront `resolveArgs`), so a reference to it never fails here even if
  /// textually the `ARG` line comes later -- a deliberate simplification over strict Dockerfile
  /// "only visible after declaration" scoping, which this recipe format does not need.
  static func interpolate(_ text: String, scope: [String: String], line: Int) throws -> String {
    try RecipeParser.interpolateOrThrow(text, line: line) { name in
      guard let value = scope[name] else { throw RecipeError.undefinedArgument(name, line: line) }
      return value
    }
  }

  /// Exec-form argv is never interpolated (there is no shell to expand it); shell-form text is.
  static func resolveCommand(
    _ command: RecipeCommand, scope: [String: String], line: Int
  ) throws -> RecipeCommand {
    switch command {
    case .shell(let raw): return .shell(try interpolate(raw, scope: scope, line: line))
    case .exec(let argv): return .exec(argv)
    }
  }

  static func rawCommandText(_ command: RecipeCommand) -> String {
    switch command {
    case .shell(let raw): return raw
    case .exec(let argv): return "[" + argv.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
    }
  }

  static func requireAbsoluteExecArgv(_ command: RecipeCommand, line: Int) throws {
    guard case .exec(let argv) = command else { return }
    guard let first = argv.first, first.hasPrefix("/") else {
      throw RecipeError.execArgvNotAbsolute(argv.first ?? "", line: line)
    }
  }

  static func resolveTimeout(_ seconds: Int?, line: Int) throws -> Int? {
    guard let seconds else { return nil }
    guard (1...1800).contains(seconds) else {
      throw RecipeError.timeoutInvalid(String(seconds), line: line)
    }
    return seconds
  }

  static func resolveWorkdir(_ path: String, previous: String?) -> String {
    guard !path.hasPrefix("/") else { return path }
    let base = previous ?? "/"
    return base.hasSuffix("/") ? base + path : base + "/" + path
  }

  // MARK: - COPY

  static func resolveCopy(
    sources: [String], destination: String, chown: String?, workdir: String?,
    scope: [String: String], line: Int
  ) throws -> (sources: [String], destination: String, chown: String?) {
    let resolvedSources = try sources.map { source -> String in
      let value = try interpolate(source, scope: scope, line: line)
      try validateCopySource(value, line: line)
      return value
    }
    let resolvedDestination = resolveDestinationPath(
      try interpolate(destination, scope: scope, line: line), workdir: workdir
    )
    let resolvedChown = try chown.map { try interpolate($0, scope: scope, line: line) }
    return (resolvedSources, resolvedDestination, resolvedChown)
  }

  private static func validateCopySource(_ source: String, line: Int) throws {
    guard !source.hasPrefix("/") else { throw RecipeError.copyPathEscapesContext(source, line: line) }
    guard !source.split(separator: "/").contains("..") else {
      throw RecipeError.copyPathEscapesContext(source, line: line)
    }
    guard !source.contains(where: { "*?[".contains($0) }) else {
      throw RecipeError.copyGlobUnsupported(source, line: line)
    }
  }

  /// A relative destination joins onto the current WORKDIR (or `/` when none is set yet). `.` and
  /// an empty destination mean "the directory itself" -- normalized to a trailing slash so
  /// `BuildScripts.copy`'s directory-vs-file rule reads it correctly.
  private static func resolveDestinationPath(_ destination: String, workdir: String?) -> String {
    if destination.hasPrefix("/") { return destination }
    let base = workdir ?? "/"
    if destination.isEmpty || destination == "." {
      return base.hasSuffix("/") ? base : base + "/"
    }
    return base.hasSuffix("/") ? base + destination : base + "/" + destination
  }

  // MARK: - Display

  /// The instruction as written (raw, pre-interpolation, so it still shows `${VAR}` placeholders),
  /// first line only, truncated to 120 characters -- these are structural values reconstructed
  /// from the parsed instruction (Recipe does not retain the original source line verbatim).
  static func displayText(prefix: String, body: String) -> String {
    let full = "\(prefix) \(body)"
    let firstLine = full.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
      .first.map(String.init) ?? full
    return String(firstLine.prefix(120))
  }
}
