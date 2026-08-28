import Foundation
import RunnerCore
import Testing

@testable import HostSetup

/// The wizard as transcripts: a list of answers in, a `SetupAnswers` out, nothing touched.
///
/// The answer order is the question order — deployment, scope, runner group (organizations only),
/// token, environments, macOS source, then per-environment concurrency and profile name, then the
/// summary confirmation.
@Suite struct SetupWizardTests {
  private func run(
    _ answers: [String], facts: SetupHostFacts = .stub()
  ) -> (answers: SetupAnswers?, io: ScriptedSetupIO) {
    let io = ScriptedSetupIO(answers: answers)
    return (SetupWizard(io: io).run(facts: facts), io)
  }

  // MARK: - Transcripts

  @Test func organizationScopeWithMacOSEnabled() throws {
    let (result, _) = run([
      "1",             // deployment: LaunchDaemon
      "2",             // scope: organization
      "acme-org",      // organization login
      "runners",       // runner group
      "ghp_secret",    // token
      "y",             // linux
      "y",             // macos
      "",              // macOS source: the default
      "3",             // linux concurrency
      "",              // linux profile name: the default
      "2",             // macos concurrency
      "",              // macos profile name: the default
      "y",             // continue
    ])
    let answers = try #require(result)

    #expect(answers.mode == .daemon)
    #expect(answers.scope == .organization(owner: "acme-org"))
    #expect(answers.runnerGroup == "runners")
    #expect(answers.token == "ghp_secret")
    #expect(answers.linuxEnabled)
    #expect(answers.macOSEnabled)
    #expect(answers.macOSSource == SetupDefaults.macOSSource)
    #expect(answers.linuxConcurrency == 3)
    #expect(answers.macOSConcurrency == 2)
    #expect(answers.linuxProfileName == "rvm-ab12cd-ubuntu-24")
    #expect(answers.macOSProfileName == "rvm-ab12cd-macos-tahoe")
    // Outside the profile namespace on purpose: a managed name equal to a profile name is a
    // validation error.
    #expect(answers.managedImageName == "macos-tahoe-base")
  }

  @Test func repositoryScopeWithEveryDefaultTaken() throws {
    let (result, io) = run([
      "", "", "acme", "widgets", "ghp_secret", "", "", "", "", "",
    ])
    let answers = try #require(result)

    #expect(answers.mode == .daemon)
    #expect(answers.scope == .repository(owner: "acme", repository: "widgets"))
    #expect(answers.linuxEnabled)
    #expect(!answers.macOSEnabled)
    // A base Mac mini fits 4 of the 2 vCPU / 4 GiB / 16 GiB default shape.
    #expect(answers.linuxConcurrency == SetupSizing.advice(facts: .stub()).recommended)
    // A repository scope is never asked about runner groups.
    #expect(!io.prompts.contains { $0.contains("Runner group") })
    #expect(answers.runnerGroup == SetupDefaults.runnerGroup)
  }

  @Test func theAgentModeIsSelectable() throws {
    let (result, _) = run(["2", "", "acme", "widgets", "t", "", "", "", "", ""])
    #expect(try #require(result).mode == .agent)
  }

  @Test func overridingTheProfileNameAndTheMacOSSource() throws {
    let (result, _) = run([
      "", "", "acme", "widgets", "t",
      "y", "y",
      "ghc.io/acme/macos-base:pinned",
      "1", "linux-runners",
      "1", "mac-runners",
      "y",
    ])
    let answers = try #require(result)
    #expect(answers.linuxProfileName == "linux-runners")
    #expect(answers.macOSProfileName == "mac-runners")
    #expect(answers.macOSSource == "ghc.io/acme/macos-base:pinned")
  }

  // MARK: - Refusal and re-prompting

  @Test func decliningTheSummaryReturnsNothing() {
    let (result, io) = run(["", "", "acme", "widgets", "t", "", "", "", "", "n"])
    #expect(result == nil)
    #expect(io.output.contains("Nothing was changed."))
  }

  @Test func aProfileNameThatIsNotAValidLabelIsReAsked() throws {
    let (result, io) = run([
      "", "", "acme", "widgets", "t", "", "",
      "1", "Not A Label", "fine-name",
      "y",
    ])
    #expect(try #require(result).linuxProfileName == "fine-name")
    #expect(io.output.contains("must match [a-z0-9][a-z0-9._-]*"))
  }

  @Test func aConcurrencyOverTheMacOSCapIsReAsked() throws {
    let (result, io) = run([
      "", "", "acme", "widgets", "t", "y", "y", "",
      "1", "",
      "9", "2", "",
      "y",
    ])
    #expect(try #require(result).macOSConcurrency == 2)
    #expect(io.output.contains("at most 2 on this host"))
  }

  /// A wizard driven by a pipe must not spin forever on a question it will never get an answer to.
  @Test func givingUpOnAQuestionAbandonsTheRunRatherThanLooping() {
    let (result, io) = run(["", ""])  // scope owner is required and never supplied
    #expect(result == nil)
    #expect(io.output.contains("after \(SetupWizard.maxAttempts) attempts"))
  }

  // MARK: - What the operator is told

  @Test func anEmptyTokenIsAcceptedWithAnExplicitWarning() throws {
    let (result, io) = run(["", "", "acme", "widgets", "", "", "", "", "", ""])
    #expect(try #require(result).token.isEmpty)
    #expect(io.output.contains("runnerctl auth login --token-stdin"))
  }

  @Test func fileVaultBeingOnIsSurfacedBeforeAnyQuestion() {
    let (_, io) = run(
      ["", "", "acme", "widgets", "t", "", "", "", "", ""],
      facts: .stub(fileVault: .on))
    #expect(io.output.contains("pre-boot authentication"))
  }

  @Test func anExistingInstallIsCalledOutAsAReconfiguration() {
    let (_, io) = run(
      ["", "", "acme", "widgets", "t", "", "", "", "", ""],
      facts: .stub(existingInstall: ExistingInstall(stateDirectory: true, daemonPlist: true)))
    #expect(io.output.contains("an existing install was found"))
    #expect(io.output.contains("reconfigure it in place"))
  }

  /// The recommendation is shown per dimension, not just as one number, so an operator who wants
  /// more knows what to add.
  @Test func theConcurrencyRecommendationNamesEachDimension() {
    let (_, io) = run(["", "", "acme", "widgets", "t", "", "", "", "", ""])
    #expect(io.output.contains("CPU allows"))
    #expect(io.output.contains("memory allows"))
    #expect(io.output.contains("disk allows"))
  }

  @Test func aHostTooSmallForOneRunnerIsToldSo() {
    let tiny = SetupHostFacts.stub(
      cpuCount: 2, memoryBytes: ByteSize.gibibytes(8).bytes,
      freeDiskBytes: ByteSize.gibibytes(4).bytes)
    let (_, io) = run(["", "", "acme", "widgets", "t", "", "", "", "", ""], facts: tiny)
    #expect(io.output.contains("does not fit even one runner"))
  }

  @Test func theSummaryShowsEveryDecisionBeforeTheConfirmation() {
    let (_, io) = run([
      "", "", "acme", "widgets", "ghp_secret", "y", "y", "", "2", "", "1", "", "y",
    ])
    #expect(io.output.contains("repository acme/widgets"))
    #expect(io.output.contains("rvm-ab12cd-ubuntu-24 x2"))
    #expect(io.output.contains("rvm-ab12cd-macos-tahoe x1"))
    #expect(io.output.contains("supplied"))
  }

  // MARK: - Scope parsing

  @Test(arguments: [
    ("repo:acme/widgets", SetupScope.repository(owner: "acme", repository: "widgets")),
    ("repository:acme/widgets", SetupScope.repository(owner: "acme", repository: "widgets")),
    ("org:acme", SetupScope.organization(owner: "acme")),
    ("organization:acme", SetupScope.organization(owner: "acme")),
  ])
  func parsesTheAcceptedScopeSpellings(_ fixture: (String, SetupScope)) {
    #expect(SetupScope.parse(fixture.0) == fixture.1)
  }

  @Test(arguments: [
    "acme/widgets", "repo:acme", "repo:acme/widgets/extra", "org:acme/widgets", "repo:", "", "org",
  ])
  func rejectsEveryOtherScopeSpelling(_ text: String) {
    #expect(SetupScope.parse(text) == nil)
  }
}

/// `TTYSetupIO`'s output shape. Only the write side is exercised: the read side needs a real
/// terminal, and `readLine` against a test runner's stdin is not a thing that can be asserted.
@Suite struct TTYSetupIOTests {
  private func collected(_ body: (TTYSetupIO) -> Void) -> String {
    let sink = Sink()
    body(TTYSetupIO(write: { sink.append($0) }))
    return sink.text
  }

  /// `@unchecked Sendable` with a lock, like `ScriptedSetupIO`: the closure is `@Sendable` but
  /// every test drives it from one task.
  private final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    func append(_ text: String) { lock.withLock { buffer += text } }
    var text: String { lock.withLock { buffer } }
  }

  @Test func sayTerminatesItsLineButAPromptDoesNot() {
    // A prompt and the answer typed after it belong on one line.
    #expect(collected { $0.say("hello") } == "hello\n")
  }

  @Test func headingUnderlinesTheTextToItsOwnWidth() {
    #expect(collected { $0.heading("Summary") } == "\nSummary\n-------\n")
  }
}
