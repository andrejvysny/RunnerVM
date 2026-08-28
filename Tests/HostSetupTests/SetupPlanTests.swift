import ConfigLoader
import Foundation
import RunnerCore
import Testing

@testable import HostSetup

/// The generated documents. Both are rendered as commented text rather than encoded from
/// `RunnerConfiguration`, so the load-and-validate round trip is what keeps them honest.
@Suite struct SetupPlanTests {
  static let hostFacts = HostFacts(
    logicalCPUCount: 10,
    physicalMemoryBytes: ByteSize.gibibytes(24).bytes,
    minimumAllowedCPUCount: 1,
    maximumAllowedCPUCount: 64,
    minimumAllowedMemoryBytes: ByteSize.mebibytes(4).bytes,
    maximumAllowedMemoryBytes: ByteSize.gibibytes(24).bytes)

  private func plan(
    _ answers: SetupAnswers = .stub(), facts: SetupHostFacts = .stub()
  ) -> SetupPlan {
    SetupPlanner.plan(answers: answers, facts: facts)
  }

  /// Loads a document and asserts it carries no validation errors.
  @discardableResult
  private func loadAndValidate(_ yaml: String) throws -> RunnerConfiguration {
    let config = try ConfigLoader.load(yaml: yaml)
    let issues = config.validate(host: Self.hostFacts)
    #expect(!issues.hasErrors, "\(issues.errors)")
    return config
  }

  // MARK: - Round trips

  @Test func theBootstrapDocumentLoadsAndValidatesWithNoProfiles() throws {
    let config = try loadAndValidate(plan().configWithoutProfiles)
    #expect(config.profiles.isEmpty)
    #expect(config.github.scopes.count == 1)
    #expect(config.images.prefetch)
    #expect(config.images.updates.enabled)
    #expect(config.imageUpdates.denyTooOldRunner)
  }

  @Test func theFinalDocumentLoadsAndValidatesWithTheLinuxProfile() throws {
    let config = try loadAndValidate(plan().configFinal)
    let profile = try #require(config.profile(named: "rvm-ab12cd-ubuntu-24"))
    #expect(profile.guestOS == .linux)
    #expect(profile.scope == "repo")
    #expect(profile.image == SetupDefaults.linuxImage)
    #expect(profile.lifecycle == .ephemeral)
    #expect(profile.resources == SetupDefaults.linuxResources)
    #expect(profile.limits.maxInstances == 2)
  }

  /// The macOS half of a plan is the `images.managed` entry only: the profile itself is a
  /// commented block until a provisioning run exists to produce the image.
  @Test func theMacOSDocumentsCarryTheManagedSourceButNotTheProfile() throws {
    let answers = SetupAnswers.stub(macOSEnabled: true)
    for document in [plan(answers).configWithoutProfiles, plan(answers).configFinal] {
      let config = try loadAndValidate(document)
      let managed = try #require(config.images.managed.first)
      #expect(managed.name == "macos-tahoe-base")
      #expect(managed.kind == .macosTart)
      #expect(managed.source == SetupDefaults.macOSSource)
      #expect(managed.resources?.cpuCount == 4)
      #expect(config.profiles.allSatisfy { $0.guestOS != .macos })
    }
  }

  @Test func theCommentedMacOSProfileTellsTheOperatorExactlyWhatToDoNext() {
    let final = plan(.stub(macOSEnabled: true)).configFinal
    #expect(final.contains("# macOS profile — activate after the managed image"))
    #expect(final.contains("runnerctl image update run --managed macos-tahoe-base"))
    #expect(final.contains("set to the image's exact virtual size after first provision"))
    // Commented out, so it is not a profile as far as the loader is concerned.
    #expect(!final.contains("\n  - name: rvm-ab12cd-macos-tahoe"))
  }

  @Test func aPlanWithNoManagedSourcesEmitsNoManagedBlock() {
    #expect(!plan().configFinal.contains("managed:"))
  }

  @Test func anOrganizationScopeCarriesItsRunnerGroupInsteadOfARepository() throws {
    var answers = SetupAnswers.stub(scope: .organization(owner: "acme-org"))
    answers.runnerGroup = "runners"
    let config = try loadAndValidate(plan(answers).configFinal)
    let scope = try #require(config.scope(named: "org"))
    #expect(scope.kind == .organization)
    #expect(scope.owner == "acme-org")
    #expect(scope.runnerGroup == "runners")
    #expect(scope.repository == nil)
  }

  /// Selecting neither environment is legal — an operator may want the daemon installed and the
  /// profiles added by hand — and must still produce a loadable document.
  @Test func aPlanWithNoEnvironmentsStillProducesLoadableDocuments() throws {
    let answers = SetupAnswers.stub(linuxEnabled: false)
    let config = try loadAndValidate(plan(answers).configFinal)
    #expect(config.profiles.isEmpty)
    #expect(plan(answers).labels.isEmpty)
  }

  // MARK: - Plan shape

  @Test func theHeadlessCredentialSourceIsAFileNotTheLoginKeychain() throws {
    let config = try loadAndValidate(plan().configWithoutProfiles)
    #expect(config.github.auth.provider == .pat)
    #expect(config.github.auth.source == .file)
  }

  @Test func theGeneratedReserveIsTheSetupDefaultNotTheModelDefault() throws {
    let config = try loadAndValidate(plan().configWithoutProfiles)
    #expect(config.host.reserve == SetupDefaults.reserve)
    #expect(config.host.maxVMs == .auto)
    // Deliberately smaller than the 50 GiB model default: a single-profile install does not need it.
    #expect(config.host.reserve.diskBytes < HostConfig.Reserve().diskBytes)
  }

  @Test func labelsAreSelfHostedPlusEachActiveProfileName() {
    let plan = plan(.stub(macOSEnabled: true))
    #expect(plan.labels == ["self-hosted", "rvm-ab12cd-ubuntu-24"])
    // The deferred macOS profile contributes nothing: nothing answers to its label yet.
    #expect(!plan.labels.contains("rvm-ab12cd-macos-tahoe"))
    #expect(plan.activeProfiles.map(\.name) == ["rvm-ab12cd-ubuntu-24"])
    #expect(plan.profiles.count == 2)
  }

  @Test func thePlanResolvesEveryPathTheInstallerNeeds() {
    let plan = plan()
    #expect(plan.stateDir == "/Library/Application Support/RunnerVM")
    #expect(plan.runtimeDir == "/var/run/runnervm")
    #expect(plan.configPath == "/Library/Application Support/RunnerVM/config.yaml")
    #expect(plan.socketPath == "/var/run/runnervm/runnerd.sock")
    #expect(plan.account.home == "/Library/Application Support/RunnerVM/home")
    #expect(plan.account.user == "_runnervm")
    #expect(plan.linuxImage == SetupDefaults.linuxImage)
  }

  /// The socket path the plan implies has to fit `sockaddr_un.sun_path`, or nothing on this host
  /// can talk to the daemon at all.
  @Test func theRuntimeDirectoryFitsTheSocketPathBudget() throws {
    let plan = plan()
    let paths = RunnerPaths(
      rootDir: URL(fileURLWithPath: plan.stateDir, isDirectory: true),
      runtimeDir: URL(fileURLWithPath: plan.runtimeDir, isDirectory: true))
    try paths.validateSocketPathLengths()
  }

  /// The default prefix is derived from the host id, which is what keeps two hosts in one GitHub
  /// scope from claiming the same scale-set session.
  @Test func profileNamesDefaultToTheHostDerivedPrefix() {
    #expect(SetupDefaults.profilePrefix(hostID6: "ab12cd") == "rvm-ab12cd")
    #expect(SetupDefaults.linuxProfileName(prefix: "rvm-ab12cd") == "rvm-ab12cd-ubuntu-24")
    #expect(SetupDefaults.macOSProfileName(prefix: "rvm-ab12cd") == "rvm-ab12cd-macos-tahoe")
    // A host whose IOPlatformUUID could not be read still gets a usable, valid name.
    #expect(RunnerConfiguration.isValidProfileName(
      SetupDefaults.linuxProfileName(prefix: SetupDefaults.profilePrefix(hostID6: ""))))
  }

  // MARK: - Sizing

  @Test func theRecommendationIsTheMinimumOfTheThreeDimensions() {
    let advice = SetupSizing.advice(facts: .stub())
    #expect(advice.recommended == min(advice.cpuAllows, min(advice.memoryAllows, advice.diskAllows)))
    #expect(advice.recommended >= 1)
    #expect(!advice.fitsNone)
  }

  /// 200 GiB free, a 20 GiB floor and a 16 GiB disk per runner: disk is not the constraint here,
  /// the 8 remaining vCPU at 2 each are.
  @Test func aCPUBoundHostReportsCPUAsTheLimitingFactor() {
    let advice = SetupSizing.advice(facts: .stub())
    #expect(advice.cpuAllows == 4)
    #expect(advice.limitingFactor == .cpu)
  }

  @Test func aDiskBoundHostReportsDiskAsTheLimitingFactor() {
    let advice = SetupSizing.advice(
      facts: .stub(freeDiskBytes: ByteSize.gibibytes(52).bytes))
    #expect(advice.diskAllows == 2)
    #expect(advice.recommended == 2)
    #expect(advice.limitingFactor == .disk)
  }

  @Test func aHostWithNoHeadroomAtAllStillOffersOneRunnerAndSaysSo() {
    let advice = SetupSizing.advice(
      facts: .stub(cpuCount: 2, freeDiskBytes: ByteSize.gibibytes(21).bytes))
    #expect(advice.fitsNone)
    #expect(advice.recommended == 1)
  }
}
