import ImageBuild
import Testing

@Suite struct BuildScriptsTests {
  @Test func everyScriptStartsWithSetDashEUAndNeverPinsLatest() {
    let scripts = [
      BuildScripts.mountContext, BuildScripts.probe, BuildScripts.seal,
      BuildScripts.copy(
        sources: ["a"], destination: "/opt/a", chown: nil, workdir: nil,
        contextRoot: BuildScripts.contextRoot
      ),
    ]
    for script in scripts {
      #expect(script.hasPrefix("set -eu"))
      #expect(!script.contains("latest"))
    }
  }

  @Test func copyToADirectoryDestinationCreatesItAndCopiesEachSource() {
    let script = BuildScripts.copy(
      sources: ["a.txt", "b.txt"], destination: "/opt/app/", chown: nil, workdir: nil,
      contextRoot: BuildScripts.contextRoot
    )
    #expect(script.contains("mkdir -p '/opt/app/'"))
    #expect(script.contains("cp -a '\(BuildScripts.contextRoot)/a.txt' '/opt/app/'"))
    #expect(script.contains("cp -a '\(BuildScripts.contextRoot)/b.txt' '/opt/app/'"))
  }

  @Test func copyToAFileDestinationCreatesOnlyTheParentDirectory() {
    let script = BuildScripts.copy(
      sources: ["a.txt"], destination: "/opt/app/renamed.txt", chown: nil, workdir: nil,
      contextRoot: BuildScripts.contextRoot
    )
    #expect(script.contains("mkdir -p '/opt/app'"))
    #expect(!script.contains("mkdir -p '/opt/app/renamed.txt'"))
    #expect(script.contains("cp -a '\(BuildScripts.contextRoot)/a.txt' '/opt/app/renamed.txt'"))
  }

  @Test func multipleSourcesForceADirectoryDestinationEvenWithoutATrailingSlash() {
    let script = BuildScripts.copy(
      sources: ["a.txt", "b.txt"], destination: "/opt/app", chown: nil, workdir: nil,
      contextRoot: BuildScripts.contextRoot
    )
    #expect(script.contains("mkdir -p '/opt/app'"))
  }

  @Test func chownAppliesRecursivelyToTheDestination() {
    let script = BuildScripts.copy(
      sources: ["a.txt"], destination: "/opt/a.txt", chown: "runner:runner", workdir: nil,
      contextRoot: BuildScripts.contextRoot
    )
    #expect(script.contains("chown -R 'runner:runner' '/opt/a.txt'"))
  }

  @Test func relativeDestinationResolvesAgainstWorkdir() {
    let script = BuildScripts.copy(
      sources: ["a.txt"], destination: "a.txt", chown: nil, workdir: "/opt/app",
      contextRoot: BuildScripts.contextRoot
    )
    #expect(script.contains("cp -a '\(BuildScripts.contextRoot)/a.txt' '/opt/app/a.txt'"))
  }
}
