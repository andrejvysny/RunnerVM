import DaemonAPI
import Foundation
import GuestControl
import RunnerCore

/// Boots one pinned maintenance instance and proves the guest actually works, the way
/// `qualify-macos-image.sh` proves a macOS image but reusable from Swift: `runnerctl system
/// smoke-test` and `doctor --deep`'s `smoke_test` both drive this same type.
///
/// Each step records exactly one `SmokeTestCheck`. `instance.boot` and `guest.exec` gate what
/// comes after them -- nothing past a boot that never reached `idle`, or an exec that never
/// exited zero, is meaningful -- but teardown and the leak checks always run at the end,
/// regardless of what failed above them: a smoke test that fails must not leave a VM behind any
/// more than one that passes.
public struct SmokeTest: Sendable {
  private let client: any SmokeTestDaemon
  private let paths: RunnerPaths
  private let now: @Sendable () -> Date
  private let sleep: @Sendable (Duration) async throws -> Void
  private let sshPort: UInt16

  public init(
    client: any SmokeTestDaemon, paths: RunnerPaths,
    now: @escaping @Sendable () -> Date = { Date() },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.init(client: client, paths: paths, now: now, sleep: sleep, sshPort: 22)
  }

  /// Test-only entry point: lets `HostSetupTests` point the ssh-closed check at a local listener
  /// instead of the real port 22, which a sandboxed test runner cannot always bind.
  init(
    client: any SmokeTestDaemon, paths: RunnerPaths, now: @escaping @Sendable () -> Date,
    sleep: @escaping @Sendable (Duration) async throws -> Void, sshPort: UInt16
  ) {
    self.client = client
    self.paths = paths
    self.now = now
    self.sleep = sleep
    self.sshPort = sshPort
  }

  public func run(_ options: SmokeTestOptions) async -> SmokeTestReport {
    var checks: [SmokeTestCheck] = []

    guard let id = await create(options, checks: &checks) else {
      return SmokeTestReport(profile: options.profile, instanceId: nil, checks: checks, passed: false)
    }

    if await pollUntilIdle(id: id, timeout: options.bootTimeout, checks: &checks) {
      if await execCheck(id: id, macOS: options.macOS, checks: &checks), options.macOS {
        await selfTestCheck(id: id, checks: &checks)
        await sshClosedCheck(id: id, checks: &checks)
      }
    }

    await teardownAndLeakChecks(id: id, checks: &checks)

    return SmokeTestReport(
      profile: options.profile, instanceId: id, checks: checks, passed: checks.allSatisfy(\.ok))
  }

  // MARK: - Create

  private func create(_ options: SmokeTestOptions, checks: inout [SmokeTestCheck]) async -> String? {
    do {
      let instance = try await client.instanceCreate(
        profile: options.profile, purpose: InstancePurpose.maintenance.rawValue,
        ttlMs: options.ttlMs, imageOverride: options.imageOverride)
      checks.append(SmokeTestCheck(name: "instance.create", ok: true, detail: instance.id))
      return instance.id
    } catch {
      checks.append(SmokeTestCheck(name: "instance.create", ok: false, detail: "\(error)"))
      return nil
    }
  }

  // MARK: - Boot

  /// Polls the same call `vm show` uses, at a 1s interval, until `idle` (pass), a terminal state
  /// (fail, with the state and any failure detail), or `timeout` elapses (fail).
  private func pollUntilIdle(
    id: String, timeout: Duration, checks: inout [SmokeTestCheck]
  ) async -> Bool {
    let started = now()
    let deadline = started.addingTimeInterval(Self.doubleSeconds(timeout))
    while true {
      let instance: InstanceInfoDTO
      do {
        instance = try await client.instanceGet(id: id)
      } catch {
        checks.append(SmokeTestCheck(name: "instance.boot", ok: false, detail: "instance.get: \(error)"))
        return false
      }
      switch instance.state {
      case "idle":
        let elapsed = Int(now().timeIntervalSince(started))
        checks.append(SmokeTestCheck(name: "instance.boot", ok: true, detail: "idle after \(elapsed)s"))
        return true
      case "failed", "interrupted", "deleted":
        let reason = [instance.failureCode, instance.failureMessage].compactMap { $0 }
          .joined(separator: ": ")
        checks.append(SmokeTestCheck(
          name: "instance.boot", ok: false,
          detail: "reached \(instance.state)" + (reason.isEmpty ? "" : ": \(reason)")))
        return false
      default:
        break
      }
      guard now() < deadline else {
        checks.append(SmokeTestCheck(
          name: "instance.boot", ok: false,
          detail: "still \(instance.state) after \(Int(Self.doubleSeconds(timeout)))s"))
        return false
      }
      do {
        try await sleep(.seconds(1))
      } catch {
        checks.append(SmokeTestCheck(name: "instance.boot", ok: false, detail: "cancelled"))
        return false
      }
    }
  }

  // MARK: - Guest exec

  private func execCheck(id: String, macOS: Bool, checks: inout [SmokeTestCheck]) async -> Bool {
    let argv = macOS ? ["sw_vers", "-productVersion"] : ["uname", "-a"]
    do {
      let stream = try await client.instanceExec(InstanceExecRequest(id: id, argv: argv))
      var output = Data()
      var exitCode: Int32?
      for try await event in stream {
        switch event {
        case .chunk(let chunk): output.append(chunk.data)
        case .exited(let code): exitCode = code
        }
      }
      let text = String(decoding: output, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard exitCode == 0 else {
        checks.append(SmokeTestCheck(
          name: "guest.exec", ok: false, detail: "exit \(exitCode.map(String.init) ?? "?"): \(text)"))
        return false
      }
      checks.append(SmokeTestCheck(name: "guest.exec", ok: true, detail: text))
      return true
    } catch {
      checks.append(SmokeTestCheck(name: "guest.exec", ok: false, detail: "\(error)"))
      return false
    }
  }

  // MARK: - macOS-only guest checks

  private func selfTestCheck(id: String, checks: inout [SmokeTestCheck]) async {
    do {
      let result = try await client.instanceSelfTest(id: id)
      guard !result.passed else {
        checks.append(SmokeTestCheck(
          name: "guest.selfTest", ok: true, detail: "\(result.checks.count) check(s) passed"))
        return
      }
      let failed = result.checks.first { !$0.ok }
      checks.append(SmokeTestCheck(
        name: "guest.selfTest", ok: false,
        detail: failed.map { "\($0.name): \($0.detail)" } ?? "self-test failed"))
    } catch {
      checks.append(SmokeTestCheck(name: "guest.selfTest", ok: false, detail: "\(error)"))
    }
  }

  /// A refused or timed-out connection to port 22 is the pass here -- the seal-time lockdown
  /// disables sshd, and a fresh boot has to prove it held. No IP reported is not a failure of the
  /// guest's own lockdown, so it is skipped (recorded as passing) rather than failed.
  private func sshClosedCheck(id: String, checks: inout [SmokeTestCheck]) async {
    do {
      let info = try await client.instanceSSHInfo(id: id)
      guard let address = info.ipAddresses.first else {
        checks.append(SmokeTestCheck(
          name: "guest.sshClosed", ok: true, detail: "no IP reported; skipped"))
        return
      }
      let open = PortProbe.isOpen(host: address, port: sshPort, timeout: .seconds(3))
      checks.append(SmokeTestCheck(
        name: "guest.sshClosed", ok: !open,
        detail: open
          ? "\(address):\(sshPort) accepted a connection" : "\(address):\(sshPort) closed"))
    } catch {
      checks.append(SmokeTestCheck(name: "guest.sshClosed", ok: false, detail: "\(error)"))
    }
  }

  // MARK: - Teardown + leak checks

  private func teardownAndLeakChecks(id: String, checks: inout [SmokeTestCheck]) async {
    do {
      _ = try await client.instanceDelete(id: id)
      checks.append(SmokeTestCheck(name: "instance.delete", ok: true))
    } catch {
      checks.append(SmokeTestCheck(name: "instance.delete", ok: false, detail: "\(error)"))
    }

    checks.append(await instanceStateLeakCheck(id: id))

    let directory = paths.instanceDir(InstanceID(rawValue: id))
    let directoryGone = !FileManager.default.fileExists(atPath: directory.path)
    checks.append(SmokeTestCheck(
      name: "leak.instanceDirectory", ok: directoryGone,
      detail: directoryGone ? "removed" : directory.path))

    let shortId = String(id.prefix(RunnerPaths.shortIDLength))
    let leaked = Self.vmworkerRunning(matching: shortId)
    checks.append(SmokeTestCheck(
      name: "leak.vmworkerProcess", ok: !leaked,
      detail: leaked ? "a vmworker process still references \(shortId)" : "none"))
  }

  /// Polls up to 60s for the instance to reach `deleted`, or for `instance.get` itself to fail
  /// (`NOT_FOUND`, once the daemon has purged the row) -- either is the same fact: nothing is
  /// holding this VM's resources any more.
  private func instanceStateLeakCheck(id: String) async -> SmokeTestCheck {
    let deadline = now().addingTimeInterval(60)
    var lastState = ""
    while true {
      do {
        let instance = try await client.instanceGet(id: id)
        lastState = instance.state
        if instance.state == "deleted" {
          return SmokeTestCheck(name: "leak.instanceState", ok: true, detail: "deleted")
        }
      } catch {
        return SmokeTestCheck(name: "leak.instanceState", ok: true, detail: "not found")
      }
      guard now() < deadline else {
        return SmokeTestCheck(
          name: "leak.instanceState", ok: false, detail: "still \(lastState) after 60s")
      }
      do {
        try await sleep(.seconds(1))
      } catch {
        return SmokeTestCheck(name: "leak.instanceState", ok: false, detail: "cancelled")
      }
    }
  }

  private static func doubleSeconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
  }

  /// Blocking, like every other host-probe subprocess in `runnerctl` (`DoctorChecks.runProcess`):
  /// short-lived by construction, so there is nothing to gain from a background thread.
  private static func vmworkerRunning(matching shortId: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axo", "command"]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()
    do {
      try process.run()
    } catch {
      return false
    }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    return text.split(separator: "\n").contains { $0.contains("vmworker") && $0.contains(shortId) }
  }
}
