import ImageBuild
import Testing

@Suite struct BuildProbeReportTests {
  @Test func parsesAFullReport() throws {
    let text = """
      RVM-PROBE-V1
      kernelVersion=6.8.0-1234-aws
      architecture=aarch64
      runnerVersion=2.331.0
      guestAgentVersion=0.4.2
      dockerVersion=27.3.1
      sshEnabled=true
      RVM-PACKAGES-BEGIN
      bash=5.2.21-2ubuntu4
      curl=8.5.0-2ubuntu10.6
      RVM-PACKAGES-END
      """
    let report = try BuildProbeReport.parse(text)
    #expect(report.kernelVersion == "6.8.0-1234-aws")
    #expect(report.architecture == "aarch64")
    #expect(report.runnerVersion == "2.331.0")
    #expect(report.guestAgentVersion == "0.4.2")
    #expect(report.dockerVersion == "27.3.1")
    #expect(report.sshEnabled)
    #expect(report.packages == ["bash=5.2.21-2ubuntu4", "curl=8.5.0-2ubuntu10.6"])
  }

  @Test func missingOptionalFieldsBecomeNil() throws {
    let text = """
      RVM-PROBE-V1
      kernelVersion=6.8.0
      architecture=aarch64
      sshEnabled=false
      RVM-PACKAGES-BEGIN
      RVM-PACKAGES-END
      """
    let report = try BuildProbeReport.parse(text)
    #expect(report.runnerVersion == nil)
    #expect(report.guestAgentVersion == nil)
    #expect(report.dockerVersion == nil)
    #expect(!report.sshEnabled)
  }

  @Test func emptyValuesBecomeNilNotEmptyStrings() throws {
    let text = "RVM-PROBE-V1\nrunnerVersion=\nRVM-PACKAGES-BEGIN\nRVM-PACKAGES-END\n"
    let report = try BuildProbeReport.parse(text)
    #expect(report.runnerVersion == nil)
  }

  @Test func emptyPackagesBlockIsValid() throws {
    let text = "RVM-PROBE-V1\nRVM-PACKAGES-BEGIN\nRVM-PACKAGES-END\n"
    let report = try BuildProbeReport.parse(text)
    #expect(report.packages.isEmpty)
  }

  @Test func missingHeaderIsMalformed() {
    #expect(throws: RecipeError.self) {
      try BuildProbeReport.parse("kernelVersion=6.8.0\nRVM-PACKAGES-BEGIN\nRVM-PACKAGES-END\n")
    }
  }

  @Test func unterminatedPackagesBlockIsMalformed() {
    #expect(throws: RecipeError.self) {
      try BuildProbeReport.parse("RVM-PROBE-V1\nRVM-PACKAGES-BEGIN\nbash=5\n")
    }
  }
}
