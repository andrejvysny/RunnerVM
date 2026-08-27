/// Turns a parsed `Recipe` plus build arguments into a concrete `RecipePlan`: every `${VAR}`
/// resolved, every ARG/ENV/WORKDIR/USER/SHELL state fold applied in source order, one `BuildStep`
/// per `RUN`/`COPY` (plus a synthetic `mkdir -p` per `WORKDIR`).
public enum RecipePlanner {
  public static let imageNameLabel = "dev.runnervm.image.name"
  public static let defaultShell = ["/bin/sh", "-c"]
  public static let injectedEnv = ["DEBIAN_FRONTEND": "noninteractive"]

  public static func plan(_ recipe: Recipe, args: [String: String]) throws -> RecipePlan {
    let resolvedArgs = try resolveArgs(recipe: recipe, overrides: args)

    // `scope` is the interpolation symbol table (ARGs ∪ accumulated ENV); `env` is only the
    // ENV-derived part that gets attached to each step's process environment.
    var scope = resolvedArgs
    for (key, value) in injectedEnv { scope[key] = value }
    var env = injectedEnv

    var state = FoldState()
    var steps: [BuildStep] = []
    var totalSteps = 0

    for instruction in recipe.instructions {
      switch instruction {
      case .from, .arg:
        continue // FROM lives on Recipe.from; ARGs are already folded into `resolvedArgs`/`scope`.
      case .env(let kvs, let line):
        try applyEnv(kvs, scope: &scope, env: &env, line: line)
      case .run(let command, let timeoutSeconds, let line):
        steps.append(try makeRunStep(
          command, timeoutSeconds: timeoutSeconds, line: line, index: steps.count, scope: scope,
          state: state, env: env
        ))
        totalSteps += 1
      case .copy(let sources, let destination, let chown, let line):
        steps.append(try makeCopyStep(
          sources: sources, destination: destination, chown: chown, line: line, index: steps.count,
          scope: scope, state: state, env: env
        ))
        totalSteps += 1
      case .user(let raw, let line):
        state.user = try interpolate(raw, scope: scope, line: line)
      case .workdir(let raw, let line):
        let resolved = resolveWorkdir(try interpolate(raw, scope: scope, line: line), previous: state.workdir)
        state.workdir = resolved
        steps.append(BuildStep(
          index: steps.count, line: line, display: displayText(prefix: "#", body: "mkdir -p \(resolved)"),
          action: .run(.exec(["/bin/mkdir", "-p", resolved])), env: env, workdir: resolved,
          user: state.user, shell: state.shell, timeoutSeconds: nil, isSynthetic: true
        ))
      case .shell(let argv, let line):
        guard let first = argv.first, first.hasPrefix("/") else {
          throw RecipeError.shellNotAbsolute(argv.first ?? "", line: line)
        }
        state.shell = argv
      case .label(let kvs, let line):
        for kv in kvs { state.labels[kv.key] = try interpolate(kv.value, scope: scope, line: line) }
      }
    }

    return RecipePlan(
      from: recipe.from, steps: steps, resolvedArgs: resolvedArgs, labels: state.labels,
      imageName: state.labels[imageNameLabel], totalSteps: totalSteps
    )
  }

  /// Running per-instruction state that folds forward across the whole recipe (Dockerfile
  /// semantics: WORKDIR/USER/SHELL/labels persist until the next instruction that changes them).
  private struct FoldState {
    var workdir: String?
    var user: String?
    var shell = RecipePlanner.defaultShell
    var labels: [String: String] = [:]
  }

  private static func applyEnv(
    _ kvs: [RecipeKeyValue], scope: inout [String: String], env: inout [String: String], line: Int
  ) throws {
    for kv in kvs {
      let value = try interpolate(kv.value, scope: scope, line: line)
      scope[kv.key] = value
      env[kv.key] = value
    }
  }

  private static func makeRunStep(
    _ command: RecipeCommand, timeoutSeconds: Int?, line: Int, index: Int, scope: [String: String],
    state: FoldState, env: [String: String]
  ) throws -> BuildStep {
    let resolvedTimeout = try resolveTimeout(timeoutSeconds, line: line)
    let resolvedCommand = try resolveCommand(command, scope: scope, line: line)
    try requireAbsoluteExecArgv(resolvedCommand, line: line)
    return BuildStep(
      index: index, line: line, display: displayText(prefix: "RUN", body: rawCommandText(command)),
      action: .run(resolvedCommand), env: env, workdir: state.workdir, user: state.user,
      shell: state.shell, timeoutSeconds: resolvedTimeout, isSynthetic: false
    )
  }

  private static func makeCopyStep(
    sources: [String], destination: String, chown: String?, line: Int, index: Int,
    scope: [String: String], state: FoldState, env: [String: String]
  ) throws -> BuildStep {
    let resolved = try resolveCopy(
      sources: sources, destination: destination, chown: chown, workdir: state.workdir, scope: scope,
      line: line
    )
    let displayBody = (chown.map { "--chown=\($0) " } ?? "") + sources.joined(separator: " ")
      + " " + destination
    return BuildStep(
      index: index, line: line, display: displayText(prefix: "COPY", body: displayBody),
      action: .copy(sources: resolved.sources, destination: resolved.destination, chown: resolved.chown),
      env: env, workdir: state.workdir, user: state.user, shell: state.shell, timeoutSeconds: nil,
      isSynthetic: false
    )
  }

  private static func resolveArgs(recipe: Recipe, overrides: [String: String]) throws -> [String: String] {
    let declared = Set(recipe.declaredArgs)
    for key in overrides.keys.sorted() where !declared.contains(key) {
      throw RecipeError.unknownArgument(key)
    }
    var defaults: [String: String] = [:]
    for case .arg(let name, let defaultValue, _) in recipe.instructions {
      if let defaultValue { defaults[name] = defaultValue }
    }
    var resolved: [String: String] = [:]
    for name in recipe.declaredArgs {
      if let override = overrides[name] {
        resolved[name] = override
      } else if let value = defaults[name] {
        resolved[name] = value
      } else {
        throw RecipeError.argumentMissing(name)
      }
    }
    return resolved
  }
}
