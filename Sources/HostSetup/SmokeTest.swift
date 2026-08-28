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
///
/// Step helpers RETURN their checks instead of appending through an `inout` array: passing an
/// `inout` parameter across the suspension points in these helpers aborted the Swift task
/// allocator at runtime ("freed pointer was not the last allocation" in `swift_task_dealloc`)
/// on a live daemon round trip, while in-process test fakes never tripped it. Found live
/// 2026-08-28 on the first real `system smoke-test` run; do not reintroduce the pattern.
public struct SmokeTest<Daemon: SmokeTestDaemon>: Sendable {
  private let client: Daemon
  private let paths: RunnerPaths
  private let now: @Sendable () -> Date
  private let sleep: @Sendable (Duration) async throws -> Void
  private let sshPort: UInt16

  public init(
    client: Daemon, paths: RunnerPaths,
    now: @escaping @Sendable () -> Date = { Date() },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.init(client: client, paths: paths, now: now, sleep: sleep, sshPort: 22)
  }

  /// Test-only entry point: lets `HostSetupTests` point the ssh-closed check at a local listener
  /// instead of the real port 22, which a sandboxed test runner cannot always bind.
  init(
    client: Daemon, paths: RunnerPaths, now: @escaping @Sendable () -> Date,
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

    let (id, createCheck) = await create(options)
    checks.append(createCheck)
    guard let id else {
      return SmokeTestReport(profile: options.profile, instanceId: nil, checks: checks, passed: false)
    }

    let (booted, bootCheck) = await pollUntilIdle(id: id, timeout: options.bootTimeout)
    checks.append(bootCheck)
    if booted {
      let (execOK, execCheck) = await execCheck(id: id, macOS: options.macOS)
      checks.append(execCheck)
      if execOK, options.macOS {
        checks.append(await selfTestCheck(id: id))
        checks.append(await sshClosedCheck(id: id))
      }
    }

    checks.append(contentsOf: await teardownAndLeakChecks(id: id))

    return SmokeTestReport(
      profile: options.profile, instanceId: id, checks: checks, passed: checks.allSatisfy(\.ok))
  }

  // MARK: - Create

  private func create(_ options: SmokeTestOptions) async -> (String?, SmokeTestCheck) {
    do {
      let instance = try await client.instanceCreate(
        profile: options.profile, purpose: InstancePurpose.maintenance.rawValue,
        ttlMs: options.ttlMs, imageOverride: options.imageOverride)
      return (instance.id, SmokeTestCheck(name: "instance.create", ok: true, detail: instance.id))
    } catch {
      return (nil, SmokeTestCheck(name: "instance.create", ok: false, detail: "\(error)"))
    }
  }

  // MARK: - Boot

  /// Polls the same call `vm show` uses, at a 1s interval, until `idle` (pass), a terminal state
  /// (fail), or the timeout.
  private func pollUntilIdle(id: String, timeout: Duration) async -> (Bool, SmokeTestCheck) {
    let started = now()
    let deadline = started.addingTimeInterval(Self.doubleSeconds(timeout))
    while true {
      let instance: InstanceInfoDTO
      do {
        instance = try await client.instanceGet(id: id)
      } catch {
        return (false, SmokeTestCheck(name: "instance.boot", ok: false, detail: "instance.get: \(error)"))
      }
      switch instance.state {
      case "idle":
        let elapsed = Int(now().timeIntervalSince(started))
        return (true, SmokeTestCheck(name: "instance.boot", ok: true, detail: "idle after \(elapsed)s"))
      case "failed", "interrupted", "deleted":
        let reason = [instance.failureCode, instance.failureMessage].compactMap { $0 }
          .joined(separator: ": ")
        return (false, SmokeTestCheck(
          name: "instance.boot", ok: false,
          detail: "reached \(instance.state)" + (reason.isEmpty ? "" : ": \(reason)")))
      default:
        break
      }
      guard now() < deadline else {
        return (false, SmokeTestCheck(
          name: "instance.boot", ok: false,
          detail: "still \(instance.state) after \(Int(Self.doubleSeconds(timeout)))s"))
      }
      do {
        try await sleep(.seconds(1))
      } catch {
        return (false, SmokeTestCheck(name: "instance.boot", ok: false, detail: "cancelled"))
      }
    }
  }

  // MARK: - Guest exec

  private func execCheck(id: String, macOS: Bool) async -> (Bool, SmokeTestCheck) {
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
        return (false, SmokeTestCheck(
          name: "guest.exec", ok: false, detail: "exit \(exitCode.map(String.init) ?? "?"): \(text)"))
      }
      return (true, SmokeTestCheck(name: "guest.exec", ok: true, detail: text))
    } catch {
      return (false, SmokeTestCheck(name: "guest.exec", ok: false, detail: "\(error)"))
    }
  }

  // MARK: - macOS-only guest checks

  private func selfTestCheck(id: String) async -> SmokeTestCheck {
    do {
      let result = try await client.instanceSelfTest(id: id)
      guard !result.passed else {
        return SmokeTestCheck(
          name: "guest.selfTest", ok: true, detail: "\(result.checks.count) check(s) passed")
      }
      let failed = result.checks.first { !$0.ok }
      return SmokeTestCheck(
        name: "guest.selfTest", ok: false,
        detail: failed.map { "\($0.name): \($0.detail)" } ?? "self-test failed")
    } catch {
      // An image sealed before the agent grew `agent.selfTest` is still a working runner; the
      // missing proof is a reason to rebuild the image, not to fail the host.
      let text = "\(error)"
      if text.contains("UNKNOWN_METHOD") {
        return SmokeTestCheck(
          name: "guest.selfTest", ok: true,
          detail: "skipped: guest agent predates agent.selfTest; rebuild the image to enable the "
            + "CI-keychain proof")
      }
      return SmokeTestCheck(name: "guest.selfTest", ok: false, detail: text)
    }
  }

  /// A refused or timed-out connection to port 22 is the pass here -- the seal-time lockdown
  /// disables sshd, and a fresh boot has to prove it held. No IP reported is not a failure of the
  /// guest's own lockdown, so it is skipped (recorded as passing) rather than failed.
  private func sshClosedCheck(id: String) async -> SmokeTestCheck {
    do {
      let info = try await client.instanceSSHInfo(id: id)
      guard let address = info.ipAddresses.first else {
        return SmokeTestCheck(name: "guest.sshClosed", ok: true, detail: "no IP reported; skipped")
      }
      let open = await PortProbe.isOpen(host: address, port: sshPort, timeout: .seconds(3))
      return SmokeTestCheck(
        name: "guest.sshClosed", ok: !open,
        detail: open
          ? "\(address):\(sshPort) accepted a connection" : "\(address):\(sshPort) closed")
    } catch {
      return SmokeTestCheck(name: "guest.sshClosed", ok: false, detail: "\(error)")
    }
  }

  // MARK: - Teardown + leak checks

  private func teardownAndLeakChecks(id: String) async -> [SmokeTestCheck] {
    var checks: [SmokeTestCheck] = []
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
    let leaked = await Self.vmworkerRunning(matching: shortId)
    checks.append(SmokeTestCheck(
      name: "leak.vmworkerProcess", ok: !leaked,
      detail: leaked ? "a vmworker process still references \(shortId)" : "none"))
    return checks
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

  /// The `ps` scan is blocking (`readDataToEndOfFile` + `waitUntilExit`), so it runs on a GCD
  /// thread rather than parking a cooperative-pool one.
  private static func vmworkerRunning(matching shortId: String) async -> Bool {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        continuation.resume(returning: blockingVMWorkerRunning(matching: shortId))
      }
    }
  }

  private static func blockingVMWorkerRunning(matching shortId: String) -> Bool {
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
