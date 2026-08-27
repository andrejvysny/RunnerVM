import RunnerCore

/// Every failure a Runnerfile can produce, from lexing through planning.
///
/// Most cases carry the source `line` (1-based, the first physical line of the offending logical
/// instruction) rather than the recipe `path`: `RecipeError` is a plain value with no stored parser
/// context, so only the two whole-file cases (`empty`, `missingFrom`) can name the path. A caller
/// that wants a Dockerfile-style "path:line: message" composes it from `Recipe.path` (or the `path`
/// it passed to `RecipeParser.parse`) plus this error's `description`.
public enum RecipeError: Error, Sendable, Equatable {
  case empty(path: String)
  case unknownInstruction(String, line: Int)
  case unsupportedInstruction(String, line: Int, reason: String)
  case heredocUnsupported(line: Int)
  case missingFrom(path: String)
  case duplicateFrom(line: Int)
  case instructionBeforeFrom(String, line: Int)
  case fromStageAliasUnsupported(line: Int)
  case cloudImageDigestMissing(line: Int)
  case cloudImageDigestInvalid(String, line: Int)
  case fromReferenceInvalid(String, line: Int)
  case argumentInvalid(String, line: Int)
  case argumentMissing(String)
  case unknownArgument(String)
  case undefinedArgument(String, line: Int)
  case operandsMissing(instruction: String, line: Int)
  case jsonFormInvalid(reason: String, line: Int)
  case shellNotAbsolute(String, line: Int)
  case execArgvNotAbsolute(String, line: Int)
  case copyGlobUnsupported(String, line: Int)
  case copyPathEscapesContext(String, line: Int)
  case copyFromUnsupported(line: Int)
  case labelInvalid(String, line: Int)
  case timeoutInvalid(String, line: Int)
  case probeMalformed(reason: String)
}

extension RecipeError: RunnerError {
  public var code: String {
    switch self {
    case .empty: "RECIPE_EMPTY"
    case .unknownInstruction: "RECIPE_UNKNOWN_INSTRUCTION"
    case .unsupportedInstruction: "RECIPE_UNSUPPORTED_INSTRUCTION"
    case .heredocUnsupported: "RECIPE_HEREDOC_UNSUPPORTED"
    case .missingFrom: "RECIPE_MISSING_FROM"
    case .duplicateFrom: "RECIPE_DUPLICATE_FROM"
    case .instructionBeforeFrom: "RECIPE_INSTRUCTION_BEFORE_FROM"
    case .fromStageAliasUnsupported: "RECIPE_FROM_STAGE_ALIAS_UNSUPPORTED"
    case .cloudImageDigestMissing: "RECIPE_CLOUD_IMAGE_DIGEST_MISSING"
    case .cloudImageDigestInvalid: "RECIPE_CLOUD_IMAGE_DIGEST_INVALID"
    case .fromReferenceInvalid: "RECIPE_FROM_REFERENCE_INVALID"
    case .argumentInvalid: "RECIPE_ARGUMENT_INVALID"
    case .argumentMissing: "RECIPE_ARGUMENT_MISSING"
    case .unknownArgument: "RECIPE_UNKNOWN_ARGUMENT"
    case .undefinedArgument: "RECIPE_UNDEFINED_ARGUMENT"
    case .operandsMissing: "RECIPE_OPERANDS_MISSING"
    case .jsonFormInvalid: "RECIPE_JSON_FORM_INVALID"
    case .shellNotAbsolute: "RECIPE_SHELL_NOT_ABSOLUTE"
    case .execArgvNotAbsolute: "RECIPE_EXEC_ARGV_NOT_ABSOLUTE"
    case .copyGlobUnsupported: "RECIPE_COPY_GLOB_UNSUPPORTED"
    case .copyPathEscapesContext: "RECIPE_COPY_PATH_ESCAPES_CONTEXT"
    case .copyFromUnsupported: "RECIPE_COPY_FROM_UNSUPPORTED"
    case .labelInvalid: "RECIPE_LABEL_INVALID"
    case .timeoutInvalid: "RECIPE_TIMEOUT_INVALID"
    case .probeMalformed: "RECIPE_PROBE_MALFORMED"
    }
  }

  public var message: String {
    switch self {
    case .empty(let path): "\(path) is empty"
    case .unknownInstruction(let name, let line): "\(line): unknown instruction '\(name)'"
    case .unsupportedInstruction(let name, let line, let reason):
      "\(line): \(name) is not supported: \(reason)"
    case .heredocUnsupported(let line): "\(line): heredocs (<<EOF) are not supported"
    case .missingFrom(let path): "\(path) has no FROM instruction"
    case .duplicateFrom(let line): "\(line): duplicate FROM instruction"
    case .instructionBeforeFrom(let name, let line): "\(line): \(name) must come after FROM"
    case .fromStageAliasUnsupported(let line):
      "\(line): FROM ... AS <name> build stages are not supported"
    case .cloudImageDigestMissing(let line):
      "\(line): cloud-image FROM requires --sha256=<64 hex>"
    case .cloudImageDigestInvalid(let value, let line):
      "\(line): invalid --sha256 value '\(value)', expected 64 lowercase hex characters"
    case .fromReferenceInvalid(let value, let line): "\(line): invalid FROM reference '\(value)'"
    case .argumentInvalid(let text, let line): "\(line): invalid ARG '\(text)'"
    case .argumentMissing(let name):
      "ARG \(name) has no default value and no build argument was provided for it"
    case .unknownArgument(let name):
      "unknown build argument '\(name)' (no matching ARG declared in the recipe)"
    case .undefinedArgument(let name, let line): "\(line): undefined argument '\(name)'"
    case .operandsMissing(let instruction, let line): "\(line): \(instruction) requires an operand"
    case .jsonFormInvalid(let reason, let line): "\(line): invalid JSON array form: \(reason)"
    case .shellNotAbsolute(let value, let line):
      "\(line): SHELL argv[0] '\(value)' must be an absolute path"
    case .execArgvNotAbsolute(let value, let line):
      "\(line): RUN exec-form argv[0] '\(value)' must be an absolute path"
    case .copyGlobUnsupported(let value, let line):
      "\(line): COPY source '\(value)' uses unsupported glob characters (* ? [)"
    case .copyPathEscapesContext(let value, let line):
      "\(line): COPY source '\(value)' escapes the build context"
    case .copyFromUnsupported(let line): "\(line): COPY --from= (multi-stage copy) is not supported"
    case .labelInvalid(let text, let line): "\(line): invalid LABEL '\(text)'"
    case .timeoutInvalid(let value, let line): "\(line): invalid RUN --timeout value '\(value)'"
    case .probeMalformed(let reason): "malformed build probe report: \(reason)"
    }
  }

  /// Every failure here is a defect in the recipe or its inputs -- rerunning without a change
  /// would fail identically, so nothing is retryable.
  public var retryable: Bool { false }
}
