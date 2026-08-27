import ImageBuild
import Testing

private let path = "Runnerfile"
private let sha = "deadbeef"

@Suite struct RecipePlannerTests {
  // MARK: - ARG resolution

  @Test func cliOverrideBeatsRecipeDefault() throws {
    let text = """
      FROM ubuntu-24-minimal
      ARG NAME=default
      RUN echo $NAME
      """
    let recipe = try RecipeParser.parse(text, path: path, sha256: sha)
    let plan = try RecipePlanner.plan(recipe, args: ["NAME": "override"])
    #expect(plan.resolvedArgs["NAME"] == "override")
    guard case .run(.shell(let script)) = plan.steps[0].action else { Issue.record("expected shell run"); return }
    #expect(script == "echo override")
  }

  @Test func recipeDefaultUsedWhenNoOverrideGiven() throws {
    let text = "FROM ubuntu-24-minimal\nARG NAME=default\nRUN echo hi\n"
    let recipe = try RecipeParser.parse(text, path: path, sha256: sha)
    let plan = try RecipePlanner.plan(recipe, args: [:])
    #expect(plan.resolvedArgs["NAME"] == "default")
  }

  @Test func missingArgumentWithNoDefaultAndNoOverrideThrows() throws {
    let recipe = try RecipeParser.parse(
      "FROM ubuntu-24-minimal\nARG REQUIRED\nRUN echo hi\n", path: path, sha256: sha
    )
    #expect(throws: RecipeError.argumentMissing("REQUIRED")) {
      try RecipePlanner.plan(recipe, args: [:])
    }
  }

  @Test func unknownCLIArgumentIsRejected() throws {
    let recipe = try RecipeParser.parse("FROM ubuntu-24-minimal\nRUN echo hi\n", path: path, sha256: sha)
    #expect(throws: RecipeError.unknownArgument("BOGUS")) {
      try RecipePlanner.plan(recipe, args: ["BOGUS": "x"])
    }
  }

  // MARK: - ENV folding

  @Test func envAccumulatesAndOverridesTheInjectedDefault() throws {
    let text = """
      FROM ubuntu-24-minimal
      ENV FOO=1
      RUN echo a
      ENV FOO=2
      ENV DEBIAN_FRONTEND=readline
      RUN echo b
      """
    let recipe = try RecipeParser.parse(text, path: path, sha256: sha)
    let plan = try RecipePlanner.plan(recipe, args: [:])
    #expect(plan.steps[0].env["FOO"] == "1")
    #expect(plan.steps[0].env["DEBIAN_FRONTEND"] == "noninteractive")
    #expect(plan.steps[1].env["FOO"] == "2")
    #expect(plan.steps[1].env["DEBIAN_FRONTEND"] == "readline")
  }

  // MARK: - WORKDIR

  @Test func workdirChainsRelativelyAndEmitsASyntheticMkdirExcludedFromTotalSteps() throws {
    let text = """
      FROM ubuntu-24-minimal
      WORKDIR /opt
      WORKDIR app
      RUN pwd
      """
    let recipe = try RecipeParser.parse(text, path: path, sha256: sha)
    let plan = try RecipePlanner.plan(recipe, args: [:])
    #expect(plan.steps.count == 3)
    #expect(plan.steps[0].isSynthetic)
    #expect(plan.steps[0].display == "# mkdir -p /opt")
    #expect(plan.steps[1].isSynthetic)
    #expect(plan.steps[1].display == "# mkdir -p /opt/app")
    #expect(!plan.steps[2].isSynthetic)
    #expect(plan.steps[2].workdir == "/opt/app")
    #expect(plan.totalSteps == 1)
  }

  // MARK: - USER

  @Test func userWrapsSubsequentStepsWithRunuser() throws {
    let text = "FROM ubuntu-24-minimal\nUSER runner\nRUN whoami\n"
    let recipe = try RecipeParser.parse(text, path: path, sha256: sha)
    let plan = try RecipePlanner.plan(recipe, args: [:])
    let argv = plan.steps[0].execArgv(contextRoot: BuildScripts.contextRoot)
    #expect(argv == ["/usr/sbin/runuser", "-u", "runner", "--", "/bin/sh", "-c", "whoami"])
  }

  // MARK: - SHELL

  @Test func shellOverrideAppliesOnlyToShellFormSteps() throws {
    let text = """
      FROM ubuntu-24-minimal
      SHELL ["/bin/bash", "-c"]
      RUN echo hi
      RUN ["/bin/echo", "hi"]
      """
    let recipe = try RecipeParser.parse(text, path: path, sha256: sha)
    let plan = try RecipePlanner.plan(recipe, args: [:])
    #expect(plan.steps[0].execArgv(contextRoot: BuildScripts.contextRoot) == ["/bin/bash", "-c", "echo hi"])
    #expect(plan.steps[1].execArgv(contextRoot: BuildScripts.contextRoot) == ["/bin/echo", "hi"])
  }

  @Test func execFormRequiresAnAbsoluteArgv0AtPlanTime() throws {
    let recipe = try RecipeParser.parse(
      "FROM ubuntu-24-minimal\nRUN [\"relative\", \"-x\"]\n", path: path, sha256: sha
    )
    #expect(throws: RecipeError.execArgvNotAbsolute("relative", line: 2)) {
      try RecipePlanner.plan(recipe, args: [:])
    }
  }

  // MARK: - RUN --timeout

  @Test func timeoutMustBeWithinOneToEighteenHundredSeconds() throws {
    let tooLong = try RecipeParser.parse(
      "FROM ubuntu-24-minimal\nRUN --timeout=1801s echo hi\n", path: path, sha256: sha
    )
    #expect(throws: RecipeError.timeoutInvalid("1801", line: 2)) {
      try RecipePlanner.plan(tooLong, args: [:])
    }

    let ok = try RecipeParser.parse(
      "FROM ubuntu-24-minimal\nRUN --timeout=30s echo hi\n", path: path, sha256: sha
    )
    let plan = try RecipePlanner.plan(ok, args: [:])
    #expect(plan.steps[0].timeoutSeconds == 30)
  }

  // MARK: - Labels / image name

  @Test func imageNameComesFromTheImageNameLabel() throws {
    let text = """
      FROM ubuntu-24-minimal
      LABEL dev.runnervm.image.name="my-image"
      RUN echo hi
      """
    let recipe = try RecipeParser.parse(text, path: path, sha256: sha)
    let plan = try RecipePlanner.plan(recipe, args: [:])
    #expect(plan.imageName == "my-image")
    #expect(plan.labels[RecipePlanner.imageNameLabel] == "my-image")
  }
}
