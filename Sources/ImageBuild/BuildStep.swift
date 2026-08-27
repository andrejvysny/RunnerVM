/// What a `BuildStep` actually does: run a command, or materialize files from the build context.
public enum StepAction: Sendable, Hashable {
  case run(RecipeCommand)
  case copy(sources: [String], destination: String, chown: String?)
}

/// One planned unit of work, fully resolved (no `${VAR}` left in it) and ready to hand to
/// `agent.exec`. `RecipePlanner` produces these in execution order.
public struct BuildStep: Sendable, Hashable {
  /// Position in `RecipePlan.steps` (synthetic steps included, so this is not a "step N of M" count
  /// -- see `RecipePlan.totalSteps` for that).
  public var index: Int
  public var line: Int
  /// The instruction as written, first line only, truncated to 120 characters.
  public var display: String
  public var action: StepAction
  public var env: [String: String]
  public var workdir: String?
  public var user: String?
  public var shell: [String]
  public var timeoutSeconds: Int?
  /// `true` for the `mkdir -p` a `WORKDIR` instruction emits; not real recipe content, so callers
  /// that show build progress should skip it and it is excluded from `RecipePlan.totalSteps`.
  public var isSynthetic: Bool

  public init(
    index: Int, line: Int, display: String, action: StepAction, env: [String: String],
    workdir: String?, user: String?, shell: [String], timeoutSeconds: Int?, isSynthetic: Bool
  ) {
    self.index = index
    self.line = line
    self.display = display
    self.action = action
    self.env = env
    self.workdir = workdir
    self.user = user
    self.shell = shell
    self.timeoutSeconds = timeoutSeconds
    self.isSynthetic = isSynthetic
  }

  /// argv for `agent.exec`. `RecipePlanner` has already validated absoluteness (`shellNotAbsolute`,
  /// `execArgvNotAbsolute`) before building this step, so this never fails.
  public func execArgv(contextRoot: String) -> [String] {
    let base: [String]
    switch action {
    case .run(.shell(let script)):
      base = shell + [script]
    case .run(.exec(let argv)):
      base = argv
    case .copy(let sources, let destination, let chown):
      let script = BuildScripts.copy(
        sources: sources, destination: destination, chown: chown, workdir: workdir,
        contextRoot: contextRoot
      )
      base = ["/bin/sh", "-c", script]
    }
    guard let user else { return base }
    return ["/usr/sbin/runuser", "-u", user, "--"] + base
  }
}
