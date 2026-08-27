import ImageBuild
import Testing

private let path = "Runnerfile"
private let sha = "deadbeef"

/// `${NAME}`/`$NAME`/`\$` interpolation. FROM resolves at parse time (it can only see ARG
/// defaults declared before it); ENV/LABEL/COPY resolve at plan time, once CLI args are known --
/// see `RecipePlanner`'s doc comment for why. ENV values are asserted through the `env` a
/// following RUN step carries, since `RecipePlan` has no other window into resolved ENV state.
@Suite struct RecipeInterpolationTests {
  @Test func bracedBarewordAndEscapedDollarInterpolateInENV() throws {
    let text = """
      FROM ubuntu-24-minimal
      ARG NAME=world
      ENV GREETING=hello-${NAME}-$NAME-\\$NAME
      RUN echo hi
      """
    let recipe = try RecipeParser.parse(text, path: path, sha256: sha)
    let plan = try RecipePlanner.plan(recipe, args: [:])
    #expect(plan.steps[0].env["GREETING"] == "hello-world-world-$NAME")
  }

  @Test func adjacentInterpolationsResolveIndependently() throws {
    let text = """
      FROM ubuntu-24-minimal
      ARG A=foo
      ARG B=bar
      ENV COMBINED=${A}${B}-$A$B
      RUN echo hi
      """
    let recipe = try RecipeParser.parse(text, path: path, sha256: sha)
    let plan = try RecipePlanner.plan(recipe, args: [:])
    #expect(plan.steps[0].env["COMBINED"] == "foobar-foobar")
  }

  @Test func undefinedArgumentInFromFailsAtParseTime() {
    #expect(throws: RecipeError.undefinedArgument("MISSING", line: 1)) {
      try RecipeParser.parse("FROM ubuntu-$MISSING\n", path: path, sha256: sha)
    }
  }

  @Test func fromInterpolatesAPreFromArgDefault() throws {
    let text = "ARG SUFFIX=minimal\nFROM ubuntu-24-$SUFFIX\n"
    let recipe = try RecipeParser.parse(text, path: path, sha256: sha)
    #expect(recipe.from.source == .localImage("ubuntu-24-minimal"))
  }

  @Test func undefinedArgumentInLabelFailsAtPlanTime() throws {
    let text = """
      FROM ubuntu-24-minimal
      LABEL note=$MISSING
      """
    let recipe = try RecipeParser.parse(text, path: path, sha256: sha)
    #expect(throws: RecipeError.undefinedArgument("MISSING", line: 2)) {
      try RecipePlanner.plan(recipe, args: [:])
    }
  }

  @Test func undefinedArgumentInCopyDestinationFailsAtPlanTime() throws {
    let text = """
      FROM ubuntu-24-minimal
      COPY a.txt /opt/$MISSING/a.txt
      """
    let recipe = try RecipeParser.parse(text, path: path, sha256: sha)
    #expect(throws: RecipeError.undefinedArgument("MISSING", line: 2)) {
      try RecipePlanner.plan(recipe, args: [:])
    }
  }

  @Test func copyDestinationInterpolatesADeclaredArgument() throws {
    let text = """
      FROM ubuntu-24-minimal
      ARG APP_DIR=app
      COPY a.txt /opt/${APP_DIR}/a.txt
      """
    let recipe = try RecipeParser.parse(text, path: path, sha256: sha)
    let plan = try RecipePlanner.plan(recipe, args: [:])
    guard case .copy(_, let destination, _) = plan.steps[0].action else {
      Issue.record("expected .copy"); return
    }
    #expect(destination == "/opt/app/a.txt")
  }
}
