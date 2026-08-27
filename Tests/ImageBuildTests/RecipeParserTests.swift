import ImageBuild
import Testing

private let path = "Runnerfile"
private let sha = "deadbeef" // arbitrary provenance hash; the parser never validates it

@Suite struct RecipeParserTests {
  @Test func parsesEveryAcceptedInstruction() throws {
    let text = """
      FROM ubuntu-24-minimal
      ARG FOO=bar
      ENV NAME=value
      RUN echo hello
      COPY src.txt /opt/src.txt
      USER runner
      WORKDIR /opt/app
      SHELL ["/bin/bash", "-c"]
      LABEL team=platform
      """
    let recipe = try RecipeParser.parse(text, path: path, sha256: sha)
    #expect(recipe.from.source == .localImage("ubuntu-24-minimal"))
    #expect(recipe.declaredArgs == ["FOO"])
    #expect(recipe.instructions.count == 9)

    guard case .arg(let name, let def, _) = recipe.instructions[1] else {
      Issue.record("expected .arg"); return
    }
    #expect(name == "FOO")
    #expect(def == "bar")

    guard case .env(let kvs, _) = recipe.instructions[2] else { Issue.record("expected .env"); return }
    #expect(kvs == [RecipeKeyValue(key: "NAME", value: "value")])

    guard case .run(let cmd, let timeout, _) = recipe.instructions[3] else {
      Issue.record("expected .run"); return
    }
    #expect(cmd == .shell("echo hello"))
    #expect(timeout == nil)

    guard case .copy(let sources, let dest, let chown, _) = recipe.instructions[4] else {
      Issue.record("expected .copy"); return
    }
    #expect(sources == ["src.txt"])
    #expect(dest == "/opt/src.txt")
    #expect(chown == nil)

    guard case .user(let user, _) = recipe.instructions[5] else { Issue.record("expected .user"); return }
    #expect(user == "runner")

    guard case .workdir(let workdir, _) = recipe.instructions[6] else {
      Issue.record("expected .workdir"); return
    }
    #expect(workdir == "/opt/app")

    guard case .shell(let argv, _) = recipe.instructions[7] else { Issue.record("expected .shell"); return }
    #expect(argv == ["/bin/bash", "-c"])

    guard case .label(let labels, _) = recipe.instructions[8] else { Issue.record("expected .label"); return }
    #expect(labels == [RecipeKeyValue(key: "team", value: "platform")])
  }

  @Test func joinsBackslashContinuationsIncludingInsideRun() throws {
    let text = "FROM ubuntu-24-minimal\nRUN echo a && \\\n    echo b\n"
    let recipe = try RecipeParser.parse(text, path: path, sha256: sha)
    guard case .run(let cmd, _, let line) = recipe.instructions[1] else { Issue.record("expected .run"); return }
    #expect(cmd == .shell("echo a && echo b"))
    #expect(line == 2)
  }

  @Test func commentAtLineStartIsIgnoredButMidLineHashIsLiteral() throws {
    let text = """
      # a leading comment, plus an ignored directive
      # syntax=docker/dockerfile:1
      FROM ubuntu-24-minimal
      LABEL note="value # not a comment"
      """
    let recipe = try RecipeParser.parse(text, path: path, sha256: sha)
    #expect(recipe.instructions.count == 2)
    guard case .label(let kvs, _) = recipe.instructions[1] else { Issue.record("expected .label"); return }
    #expect(kvs.first?.value == "value # not a comment")
  }

  @Test func tolerantOfCRLFLineEndings() throws {
    let text = "FROM ubuntu-24-minimal\r\nRUN echo hi\r\n"
    let recipe = try RecipeParser.parse(text, path: path, sha256: sha)
    #expect(recipe.instructions.count == 2)
  }

  @Test func keywordsAreCaseInsensitive() throws {
    let text = "from ubuntu-24-minimal\nRuN echo hi\n"
    let recipe = try RecipeParser.parse(text, path: path, sha256: sha)
    #expect(recipe.instructions.count == 2)
    guard case .run = recipe.instructions[1] else { Issue.record("expected .run"); return }
  }

  @Test func execFormDecodesJSONEscapes() throws {
    let text = #"""
      FROM ubuntu-24-minimal
      RUN ["/bin/sh", "-c", "echo \"quoted\" and back\\slash"]
      """#
    let recipe = try RecipeParser.parse(text, path: path, sha256: sha)
    guard case .run(let cmd, _, _) = recipe.instructions[1] else { Issue.record("expected .run"); return }
    #expect(cmd == .exec(["/bin/sh", "-c", "echo \"quoted\" and back\\slash"]))
  }

  @Test func copyAcceptsChown() throws {
    let text = """
      FROM ubuntu-24-minimal
      COPY --chown=runner:runner app.tar /opt/app.tar
      """
    let recipe = try RecipeParser.parse(text, path: path, sha256: sha)
    guard case .copy(let sources, let dest, let chown, _) = recipe.instructions[1] else {
      Issue.record("expected .copy"); return
    }
    #expect(sources == ["app.tar"])
    #expect(dest == "/opt/app.tar")
    #expect(chown == "runner:runner")
  }

  @Test func cloudImageAcceptsShaFlagBeforeOrAfterOperand() throws {
    let hex = String(repeating: "a", count: 64)
    let before = "FROM cloud-image:https://example.com/img.img --sha256=\(hex)\n"
    let after = "FROM --sha256=\(hex) cloud-image:https://example.com/img.img\n"
    for text in [before, after] {
      let recipe = try RecipeParser.parse(text, path: path, sha256: sha)
      #expect(recipe.from.source == .cloudImage(location: "https://example.com/img.img", sha256: hex))
    }
  }

  @Test func cloudImageWithoutShaFailsToParse() {
    #expect(throws: RecipeError.cloudImageDigestMissing(line: 1)) {
      try RecipeParser.parse("FROM cloud-image:https://example.com/img.img\n", path: path, sha256: sha)
    }
  }

  @Test(arguments: [
    "CMD", "ENTRYPOINT", "EXPOSE", "VOLUME", "ONBUILD", "HEALTHCHECK", "STOPSIGNAL", "ADD", "MAINTAINER",
  ])
  func rejectsUnsupportedInstructionsWithAWorkaroundReason(keyword: String) {
    let text = "FROM ubuntu-24-minimal\n\(keyword) something\n"
    do {
      _ = try RecipeParser.parse(text, path: path, sha256: sha)
      Issue.record("expected an error for \(keyword)")
    } catch let error as RecipeError {
      guard case .unsupportedInstruction(let name, let line, let reason) = error else {
        Issue.record("expected .unsupportedInstruction, got \(error)")
        return
      }
      #expect(name == keyword)
      #expect(line == 2)
      #expect(!reason.isEmpty)
      #expect(error.code == "RECIPE_UNSUPPORTED_INSTRUCTION")
    } catch {
      Issue.record("wrong error type: \(error)")
    }
  }

  @Test func fromWithStageAliasIsUnsupported() {
    #expect(throws: RecipeError.fromStageAliasUnsupported(line: 1)) {
      try RecipeParser.parse("FROM ubuntu-24-minimal AS builder\n", path: path, sha256: sha)
    }
  }

  @Test func copyFromFlagIsUnsupported() {
    #expect(throws: RecipeError.copyFromUnsupported(line: 2)) {
      try RecipeParser.parse(
        "FROM ubuntu-24-minimal\nCOPY --from=builder a b\n", path: path, sha256: sha
      )
    }
  }

  @Test func missingFromIsRejected() {
    #expect(throws: RecipeError.missingFrom(path: path)) {
      try RecipeParser.parse("ARG FOO=bar\n", path: path, sha256: sha)
    }
  }

  @Test func duplicateFromIsRejected() {
    #expect(throws: RecipeError.duplicateFrom(line: 2)) {
      try RecipeParser.parse("FROM ubuntu-24-minimal\nFROM ubuntu-24\n", path: path, sha256: sha)
    }
  }

  @Test func instructionBeforeFromIsRejected() {
    #expect(throws: RecipeError.instructionBeforeFrom("ENV", line: 1)) {
      try RecipeParser.parse("ENV FOO=bar\nFROM ubuntu-24-minimal\n", path: path, sha256: sha)
    }
  }

  /// SHELL's absoluteness rule is a planner (semantic) check, not a parser (syntax) one -- parsing
  /// a non-absolute argv[0] succeeds, and only `RecipePlanner.plan` rejects it.
  @Test func nonAbsoluteShellParsesButFailsToPlan() throws {
    let text = """
      FROM ubuntu-24-minimal
      SHELL ["bash", "-c"]
      """
    let recipe = try RecipeParser.parse(text, path: path, sha256: sha)
    guard case .shell(let argv, _) = recipe.instructions[1] else { Issue.record("expected .shell"); return }
    #expect(argv == ["bash", "-c"])
    #expect(throws: RecipeError.shellNotAbsolute("bash", line: 2)) {
      try RecipePlanner.plan(recipe, args: [:])
    }
  }

  @Test func heredocIsRejected() {
    #expect(throws: RecipeError.heredocUnsupported(line: 2)) {
      try RecipeParser.parse(
        "FROM ubuntu-24-minimal\nRUN <<EOF\necho hi\nEOF\n", path: path, sha256: sha
      )
    }
  }

  @Test func unknownInstructionIsRejected() {
    #expect(throws: RecipeError.unknownInstruction("FOOBAR", line: 2)) {
      try RecipeParser.parse("FROM ubuntu-24-minimal\nFOOBAR baz\n", path: path, sha256: sha)
    }
  }

  @Test func emptyTextIsRejected() {
    #expect(throws: RecipeError.empty(path: path)) {
      try RecipeParser.parse("", path: path, sha256: sha)
    }
  }
}
