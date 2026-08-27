/// The resolved `FROM` line: which base disk a recipe builds on top of.
public struct RecipeFrom: Sendable, Hashable {
  public enum Source: Sendable, Hashable {
    /// An image already imported into the local image store (or a `sha256:<hex>` digest of one).
    case localImage(String)
    /// A base cloud disk, fetched and hash-verified before the builder VM ever boots.
    case cloudImage(location: String, sha256: String)
    /// An OCI registry reference (`ImageReference`-shaped: has a registry host and a path).
    case registry(String)
  }

  public var source: Source
  /// `--disk=<ByteSize>` on a `cloud-image:` FROM, if given.
  public var diskBytes: UInt64?
  /// The FROM operand exactly as written (pre-interpolation), for diagnostics.
  public var raw: String
  public var line: Int

  public init(source: Source, diskBytes: UInt64?, raw: String, line: Int) {
    self.source = source
    self.diskBytes = diskBytes
    self.raw = raw
    self.line = line
  }
}

/// One `key=value` pair from `ENV` or `LABEL`. Values are stored as authored -- interpolation
/// happens later, once the planner knows the final ARG/ENV symbol table.
public struct RecipeKeyValue: Sendable, Hashable {
  public var key: String
  public var value: String

  public init(key: String, value: String) {
    self.key = key
    self.value = value
  }
}

/// A `RUN` command in either Dockerfile form. Exec-form argv is never shell-interpolated (there is
/// no shell to do it); shell-form text is interpolated at plan time.
public enum RecipeCommand: Sendable, Hashable {
  case shell(String)
  case exec([String])
}

/// One instruction from a parsed Runnerfile, in source order. Values that support `${VAR}`
/// interpolation are stored raw here; `RecipePlanner` resolves them against ARGs/ENV in sequence.
public enum RecipeInstruction: Sendable, Hashable {
  case from(RecipeFrom)
  case arg(name: String, defaultValue: String?, line: Int)
  case env([RecipeKeyValue], line: Int)
  case run(RecipeCommand, timeoutSeconds: Int?, line: Int)
  case copy(sources: [String], destination: String, chown: String?, line: Int)
  case user(String, line: Int)
  case workdir(String, line: Int)
  case shell([String], line: Int)
  case label([RecipeKeyValue], line: Int)
}

/// A parsed Runnerfile: syntactically valid, but not yet planned against build arguments.
public struct Recipe: Sendable, Hashable {
  public var from: RecipeFrom
  /// Every instruction in source order, `from` included as the first element.
  public var instructions: [RecipeInstruction]
  /// Every `ARG` name declared anywhere in the file, in first-declaration order.
  public var declaredArgs: [String]
  public var path: String
  public var sha256: String

  public init(
    from: RecipeFrom, instructions: [RecipeInstruction], declaredArgs: [String], path: String,
    sha256: String
  ) {
    self.from = from
    self.instructions = instructions
    self.declaredArgs = declaredArgs
    self.path = path
    self.sha256 = sha256
  }
}
