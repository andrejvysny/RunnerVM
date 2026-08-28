import DaemonAPI
import Foundation
import RunnerCore

/// `setup`'s macOS tail: provision the managed image, size the profile to it, activate it, prove it.
///
/// This is the part that cannot be planned up front. A macOS profile's `resources.disk` must equal
/// the image's virtual size *exactly* — a macOS guest cannot resize its APFS container — and that
/// number does not exist until a local build → qualify → promote run has produced an image. So the
/// plan ships the macOS profile commented out, this step runs the provisioning, and only then is a
/// third configuration document rendered with the profile live and sized.
///
/// Every failure here is recorded and survived, never fatal: the host is already a working Linux
/// runner host by the time this runs, and a two-hour macOS provisioning run that fails must not
/// undo that.
extension HostInstaller {
  func macOSStep(
    _ daemon: any SetupDaemon, plan: SetupPlan, report: inout SetupReport
  ) async {
    guard let managed = plan.managed.first(where: { $0.kind == .macosTart }),
          let profile = plan.macOSProfile
    else { return }

    guard let track = await provision(daemon, managed: managed, report: &report) else {
      printRetry(managed: managed, plan: plan)
      return
    }
    guard let diskBytes = await imageSize(daemon, managed: managed, track: track, report: &report)
    else {
      printRetry(managed: managed, plan: plan)
      return
    }
    guard await activate(daemon, plan: plan, diskBytes: diskBytes, report: &report) else {
      printRetry(managed: managed, plan: plan)
      return
    }
    await smokeTest(daemon, plan: plan, profile: profile, report: &report)
  }

  // MARK: - Provision

  /// Starts the managed run and follows it to a resting state. `image.update.run` returns as soon
  /// as the tracks are claimed — a whole macOS image does not fit inside the socket's idle timeout
  /// — so the progress this prints comes from polling `image.update.status`.
  private func provision(
    _ daemon: any SetupDaemon, managed: ManagedImageSourceConfig, report: inout SetupReport
  ) async -> ImageUpdateTrackDTO? {
    let io = deps.io
    io.say("")
    io.say("provisioning the macOS image from \(managed.source) …")
    io.say("This builds, qualifies and promotes a local image and can take an hour or more.")
    do {
      _ = try await daemon.imageUpdateRun(managed: managed.name)
    } catch {
      report.record(SetupReport.Name.macOSImage, false, describe(error))
      return nil
    }

    var lastState = ""
    var waited = Duration.zero
    while true {
      let track: ImageUpdateTrackDTO?
      do {
        track = try await daemon.imageUpdateStatus().tracks.first { $0.name == managed.name }
      } catch {
        report.record(SetupReport.Name.macOSImage, false, describe(error))
        return nil
      }
      guard let track else {
        report.record(
          SetupReport.Name.macOSImage, false, "the daemon has no track named \(managed.name)")
        return nil
      }
      if track.state != lastState {
        lastState = track.state
        io.say("  \(track.state)")
      }
      // `idle` and `failed` are the only resting states `ManagedImageState` has; everything else
      // means a pass still owns the row.
      if track.state == ManagedImageState.failed.rawValue {
        report.record(
          SetupReport.Name.macOSImage, false, track.lastError ?? "the provisioning run failed")
        return nil
      }
      if track.state == ManagedImageState.idle.rawValue {
        guard let digest = track.currentImageDigest else {
          report.record(
            SetupReport.Name.macOSImage, false,
            track.lastError ?? "the run finished without promoting an image")
          return nil
        }
        report.record(SetupReport.Name.macOSImage, true, digest)
        return track
      }
      guard waited < macOSTimeout else {
        report.record(
          SetupReport.Name.macOSImage, false,
          "still \(track.state) after \(Int(Self.seconds(macOSTimeout)))s; the run continues in "
            + "the daemon")
        return nil
      }
      do {
        try await deps.sleep(macOSPollInterval)
      } catch {
        report.record(SetupReport.Name.macOSImage, false, describe(error))
        return nil
      }
      waited += macOSPollInterval
    }
  }

  // MARK: - Size

  /// The promoted digest is asked for by digest, not by alias: the alias is what a profile resolves
  /// through at boot, but the track already knows exactly which bytes were promoted, and asking for
  /// those removes a resolution step that could answer with a different image.
  private func imageSize(
    _ daemon: any SetupDaemon, managed: ManagedImageSourceConfig, track: ImageUpdateTrackDTO,
    report: inout SetupReport
  ) async -> UInt64? {
    let reference = track.currentImageDigest ?? managed.name
    do {
      let image = try await daemon.imageGet(ref: reference)
      guard image.virtualSizeBytes > 0 else {
        report.record(
          SetupReport.Name.macOSProfile, false, "\(reference) reports a zero virtual size")
        return nil
      }
      return image.virtualSizeBytes
    } catch {
      report.record(SetupReport.Name.macOSProfile, false, describe(error))
      return nil
    }
  }

  // MARK: - Activate

  /// The third `config apply` of an install, and the only one that can be written after the images
  /// exist rather than before.
  private func activate(
    _ daemon: any SetupDaemon, plan: SetupPlan, diskBytes: UInt64, report: inout SetupReport
  ) async -> Bool {
    let yaml = plan.configActivatingMacOS(diskBytes: diskBytes)
    do {
      let response = try await daemon.configApply(yaml: yaml)
      // Same discipline as the first apply: the file on disk has to match what the daemon now
      // holds, or a restart would silently undo the activation.
      let staged = try deps.writeTemporary(yaml, "config.yaml")
      try await deps.runner.runChecked([Self.install, "-m", "0640", staged, plan.configPath])
      try await deps.runner.runChecked([Self.chown, plan.account.ownership, plan.configPath])
      report.record(
        SetupReport.Name.macOSProfile, true,
        "\(plan.macOSProfile?.name ?? "macos") disk \(diskBytes)B "
          + "(\(response.diff.changeCount) change(s))")
      return true
    } catch {
      report.record(SetupReport.Name.macOSProfile, false, describe(error))
      return false
    }
  }

  // MARK: - Prove

  /// The macOS subset of the smoke test — `instance.selfTest` and the ssh-closed probe on top of
  /// the Linux checks — now that there is a profile to boot.
  private func smokeTest(
    _ daemon: any SetupDaemon, plan: SetupPlan, profile: PlannedProfile, report: inout SetupReport
  ) async {
    deps.io.say("booting one \(profile.name) instance to verify the macOS image …")
    let paths = RunnerPaths(
      rootDir: URL(fileURLWithPath: plan.stateDir, isDirectory: true),
      runtimeDir: URL(fileURLWithPath: plan.runtimeDir, isDirectory: true))
    let smoke = SmokeTest(client: daemon, paths: paths)
    let result = await smoke.run(SmokeTestOptions(profile: profile.name, macOS: true))
    let failed = result.checks.first { !$0.ok }
    report.record(
      SetupReport.Name.macOSSmokeTest, result.passed,
      result.passed
        ? "\(result.checks.count) check(s) passed"
        : failed.map { "\($0.name): \($0.detail)" } ?? "failed")
  }

  private func printRetry(managed: ManagedImageSourceConfig, plan: SetupPlan) {
    let io = deps.io
    io.say("")
    io.say("This host is still a working Linux runner host; only the macOS half is incomplete.")
    io.say("Retry the provisioning run with:")
    io.say("  sudo runnerctl image update run --managed \(managed.name)")
    io.say("then re-run `sudo runnerctl setup --macos` to activate the profile, or edit")
    io.say("\(plan.configPath) by hand.")
  }

  static func seconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
  }
}
