import Foundation
import Testing

@testable import HostSetup

/// The `dscl` sequence, asserted as a sequence. This is the one place RunnerVM creates a user
/// account, and the contract (`docs/design/distribution.md`, "Service account") is specific about
/// every attribute, so the test is the command list.
@Suite struct ServiceAccountManagerTests {
  static let spec = ServiceAccountSpec(home: "/Library/Application Support/RunnerVM/home")

  /// A host with the usual system groups/users occupying 200-205, and nothing named `_runnervm`.
  static func freshHost() -> RecordingCommandRunner {
    RecordingCommandRunner(stubs: [
      .failure(["-read", "/Groups/_runnervm"], 187, "eDSRecordNotFound"),
      .failure(["-read", "/Users/_runnervm"], 187, "eDSRecordNotFound"),
      .stdout(["-list", "/Groups"], groupList(upTo: 205)),
      .stdout(["-list", "/Users"], userList(upTo: 205)),
    ])
  }

  static func groupList(upTo last: Int) -> String {
    (200...last).map { "_svc\($0)                \($0)" }.joined(separator: "\n")
  }

  static func userList(upTo last: Int) -> String {
    (200...last).map { "_svc\($0)                 \($0)" }.joined(separator: "\n")
  }

  private func dsclLines(_ runner: RecordingCommandRunner) async -> [String] {
    await runner.lines.filter { $0.contains("dscl") && $0.contains("-create") }
  }

  // MARK: - Fresh host

  @Test func createsGroupThenUserWithEveryContractAttribute() async throws {
    let runner = Self.freshHost()
    let plan = try await ServiceAccountManager(runner: runner).ensure(Self.spec)

    #expect(plan.createdGroup)
    #expect(plan.createdUser)
    #expect(!plan.fixedPrimaryGroup)
    // First free id in 200-400 with 200-205 taken, and uid == gid because that number is free too.
    #expect(plan.gid == 206)
    #expect(plan.uid == 206)

    #expect(await dsclLines(runner) == [
      "/usr/bin/dscl . -create /Groups/_runnervm",
      "/usr/bin/dscl . -create /Groups/_runnervm PrimaryGroupID 206",
      "/usr/bin/dscl . -create /Groups/_runnervm RealName RunnerVM Service",
      "/usr/bin/dscl . -create /Groups/_runnervm Password *",
      "/usr/bin/dscl . -create /Users/_runnervm",
      "/usr/bin/dscl . -create /Users/_runnervm UserShell /usr/bin/false",
      "/usr/bin/dscl . -create /Users/_runnervm RealName RunnerVM Service",
      "/usr/bin/dscl . -create /Users/_runnervm UniqueID 206",
      "/usr/bin/dscl . -create /Users/_runnervm PrimaryGroupID 206",
      "/usr/bin/dscl . -create /Users/_runnervm NFSHomeDirectory "
        + "/Library/Application Support/RunnerVM/home",
      "/usr/bin/dscl . -create /Users/_runnervm Password *",
      "/usr/bin/dscl . -create /Users/_runnervm IsHidden 1",
    ])
  }

  /// `sysadminctl` is what the first Mac mini deployment needed by hand, and the contract replaces
  /// it outright: no interactive password prompt, ever.
  @Test func neverUsesSysadminctl() async throws {
    let runner = Self.freshHost()
    _ = try await ServiceAccountManager(runner: runner).ensure(Self.spec)
    #expect(await !runner.lines.contains { $0.contains("sysadminctl") })
  }

  @Test func createsTheHomeDirectoryOwnedByTheAccountAt0750() async throws {
    let runner = Self.freshHost()
    _ = try await ServiceAccountManager(runner: runner).ensure(Self.spec)
    let tail = await runner.lines.suffix(3)
    #expect(Array(tail) == [
      "/bin/mkdir -p /Library/Application Support/RunnerVM/home",
      "/bin/chmod 0750 /Library/Application Support/RunnerVM/home",
      "/usr/sbin/chown _runnervm:_runnervm /Library/Application Support/RunnerVM/home",
    ])
  }

  /// The uid == gid preference is cosmetic, so it must never block: when that number is taken by
  /// some other account, the next free id wins.
  @Test func fallsBackToTheNextFreeUIDWhenTheGIDNumberIsTaken() async throws {
    let runner = RecordingCommandRunner(stubs: [
      .failure(["-read", "/Groups/_runnervm"], 187),
      .failure(["-read", "/Users/_runnervm"], 187),
      .stdout(["-list", "/Groups"], Self.groupList(upTo: 205)),
      .stdout(["-list", "/Users"], Self.userList(upTo: 206)),
    ])
    let plan = try await ServiceAccountManager(runner: runner).ensure(Self.spec)
    #expect(plan.gid == 206)
    #expect(plan.uid == 207)
  }

  @Test func refusesWhenTheWholeIDRangeIsOccupied() async {
    let runner = RecordingCommandRunner(stubs: [
      .failure(["-read", "/Groups/_runnervm"], 187),
      .stdout(["-list", "/Groups"], Self.groupList(upTo: 400)),
    ])
    await #expect(throws: SetupError.self) {
      try await ServiceAccountManager(runner: runner).ensure(Self.spec)
    }
  }

  // MARK: - Already provisioned

  @Test func verifiesRatherThanRecreatesAnAlreadyCorrectAccount() async throws {
    let runner = RecordingCommandRunner(stubs: [
      .stdout(["-read", "/Groups/_runnervm"], "PrimaryGroupID: 210\n"),
      .stdout(["-read", "/Users/_runnervm", "PrimaryGroupID"], "PrimaryGroupID: 210\n"),
      .stdout(["-read", "/Users/_runnervm", "UniqueID"], "UniqueID: 210\n"),
    ])
    let plan = try await ServiceAccountManager(runner: runner).ensure(Self.spec)

    #expect(!plan.createdGroup)
    #expect(!plan.createdUser)
    #expect(!plan.fixedPrimaryGroup)
    #expect(plan.uid == 210)
    #expect(plan.gid == 210)
    #expect(await dsclLines(runner).isEmpty)
    #expect(plan.summary.contains("already correct"))
  }

  /// The one thing re-running `setup` repairs: an account whose primary group drifted off the
  /// service group (`staff`, say) cannot read the state tree.
  @Test func repointsAPrimaryGroupThatDriftedOffTheServiceGroup() async throws {
    let runner = RecordingCommandRunner(stubs: [
      .stdout(["-read", "/Groups/_runnervm"], "PrimaryGroupID: 210\n"),
      .stdout(["-read", "/Users/_runnervm", "PrimaryGroupID"], "PrimaryGroupID: 20\n"),
      .stdout(["-read", "/Users/_runnervm", "UniqueID"], "UniqueID: 210\n"),
    ])
    let plan = try await ServiceAccountManager(runner: runner).ensure(Self.spec)

    #expect(plan.fixedPrimaryGroup)
    #expect(!plan.createdUser)
    #expect(await dsclLines(runner)
      == ["/usr/bin/dscl . -create /Users/_runnervm PrimaryGroupID 210"])
    #expect(plan.summary.contains("repointed"))
  }

  /// A group that exists with a user that does not: the user is created against the existing gid
  /// rather than a fresh one.
  @Test func createsOnlyTheMissingUserWhenTheGroupIsAlreadyThere() async throws {
    let runner = RecordingCommandRunner(stubs: [
      .stdout(["-read", "/Groups/_runnervm"], "PrimaryGroupID: 210\n"),
      .failure(["-read", "/Users/_runnervm"], 187),
      .stdout(["-list", "/Users"], Self.userList(upTo: 205)),
    ])
    let plan = try await ServiceAccountManager(runner: runner).ensure(Self.spec)

    #expect(!plan.createdGroup)
    #expect(plan.createdUser)
    #expect(plan.gid == 210)
    #expect(plan.uid == 210)
    #expect(await !dsclLines(runner).contains { $0.contains("/Groups/") })
  }

  // MARK: - Parsers

  @Test func parsesADsclReadResponse() {
    let output = "PrimaryGroupID: 206\n"
    #expect(ServiceAccountManager.parseAttribute(output, attribute: "PrimaryGroupID") == "206")
    #expect(ServiceAccountManager.parseAttribute(output, attribute: "UniqueID") == nil)
  }

  @Test func parsesADsclListResponseAndSkipsUnparseableRows() {
    let output = """
    _runnervm                206
    daemon                   1
    corrupt-row
    nobody                   -2
    """
    #expect(ServiceAccountManager.parseIDList(output) == [206, 1, -2])
  }
}
