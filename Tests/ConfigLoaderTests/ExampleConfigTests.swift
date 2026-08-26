import ConfigLoader
import RunnerCore
import Testing

struct ExampleConfigTests {
  @Test func exampleLoadsWithoutThrowing() throws {
    let config = try ConfigLoader.load(yaml: ExampleConfig.example)
    #expect(config.version == 1)
    #expect(config.profiles.count == 1)
    #expect(config.github.scopes.count == 1)
  }

  @Test func exampleValidatesWithZeroErrors() throws {
    let config = try ConfigLoader.load(yaml: ExampleConfig.example)
    let issues = config.validate(host: Fixtures.hostFacts)
    #expect(!issues.hasErrors, "\(issues)")
  }

  @Test func exampleValidatesWithZeroIssuesAtAll() throws {
    // Stronger than "no errors": the shipped example shouldn't even nudge an operator with a
    // warning (e.g. memory overcommit, public repositories) on a fresh install.
    let config = try ConfigLoader.load(yaml: ExampleConfig.example)
    #expect(config.validate(host: Fixtures.hostFacts).isEmpty)
  }

  @Test func loadAndValidateReturnsNoWarningsForTheExample() throws {
    let (config, warnings) = try ConfigLoader.loadAndValidate(
      yaml: ExampleConfig.example, host: Fixtures.hostFacts
    )
    #expect(config.profiles.map(\.name) == ["ubuntu-24"])
    #expect(warnings.isEmpty)
  }
}
