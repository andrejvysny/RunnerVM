import Foundation
import RunnerCore
import Testing

@Suite struct DoctorFleetingPluginTests {
  @Test func skippedWithoutGitLabProfile() {
    #expect(
      DoctorFleetingPlugin.check(hasGitLabProfile: false, path: "/bin", isExecutable: { _ in true })
        == nil)
  }

  @Test func okWhenOnPath() {
    let check = DoctorFleetingPlugin.check(
      hasGitLabProfile: true, path: "/a:/b",
      isExecutable: { $0 == "/b/fleeting-plugin-runnervm" })
    #expect(check?.status == .ok)
    #expect(check?.id == "gitlab_fleeting_plugin")
    #expect(check?.detail.contains("/b/fleeting-plugin-runnervm") == true)
  }

  @Test func okInExtraDirectoryWhenPathIsMinimal() {
    let check = DoctorFleetingPlugin.check(
      hasGitLabProfile: true, path: "/usr/bin",
      isExecutable: { $0 == "/usr/local/bin/fleeting-plugin-runnervm" })
    #expect(check?.status == .ok)
  }

  @Test func warnsWithFixWhenMissing() {
    let check = DoctorFleetingPlugin.check(
      hasGitLabProfile: true, path: nil, isExecutable: { _ in false })
    #expect(check?.status == .warn)
    #expect(check?.detail.contains("make -C GuestAgent build-plugin") == true)
  }

  @Test func candidatesSkipEmptyAndDuplicateDirectories() {
    let list = DoctorFleetingPlugin.candidates(path: "/usr/local/bin::/x:/x")
    #expect(list == [
      "/usr/local/bin/fleeting-plugin-runnervm", "/x/fleeting-plugin-runnervm",
      "/opt/homebrew/bin/fleeting-plugin-runnervm",
    ])
  }
}
