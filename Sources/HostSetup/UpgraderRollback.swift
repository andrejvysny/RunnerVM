import Foundation
import RunnerCore

/// The conditional half of `docs/design/distribution.md`'s upgrade policy.
///
/// Rollback fires only when `doctor` fails **and** `MAX(version)` in `schema_migrations` is
/// unchanged — i.e. the new binaries never ran a migration. If the schema advanced, migrations are
/// one-way and restoring the old database under old binaries would be a data-loss event dressed up
/// as a recovery, so RunnerVM prints the manual steps instead and stops.
extension Upgrader {
  /// Reinstalls the cached previous pkg and restores the backup taken before the swap.
  ///
  /// Refuses rather than improvises: every precondition is re-checked here, so a caller that got
  /// the verdict wrong cannot talk this into running.
  @discardableResult
  public func rollback(_ report: inout UpgradeReport) async -> Bool {
    guard report.installed else {
      report.record(UpgradeReport.Name.rollback, false, "nothing was installed; nothing to undo")
      return false
    }
    guard report.schemaUnchanged else {
      report.record(
        UpgradeReport.Name.rollback, false,
        "refused: the schema moved to v\(report.schemaAfter.map(String.init) ?? "unknown")")
      printManualRestoration(report)
      return false
    }
    guard let package = report.previousPackagePath, let backup = report.backupDirectory else {
      report.record(UpgradeReport.Name.rollback, false, "refused: no cached pkg or backup")
      printManualRestoration(report)
      return false
    }

    deps.io.heading("Rolling back to \(report.fromVersion)")
    do {
      _ = try? await deps.runner.run([
        Self.launchctl, "bootout", "\(domainTarget)/\(LaunchdManager.label)",
      ])
      try await deps.runner.runChecked([Self.installer, "-pkg", package, "-target", "/"])
      try await restoreState(from: backup, owner: report.stateOwner)
      try await deps.runner.runChecked([Self.launchctl, "bootstrap", domainTarget, plistPath])
      _ = try await deps.launchd.waitForSocket(at: socketPath, timeout: options.socketTimeout)
      report.record(
        UpgradeReport.Name.rollback, true, "restored \(report.fromVersion) from \(backup)")
      return true
    } catch {
      report.record(UpgradeReport.Name.rollback, false, Self.describe(error))
      printManualRestoration(report)
      return false
    }
  }

  /// The database first, then the configuration, then ownership: the daemon is not running while
  /// this happens, so ordering only matters for the failure case, where a half-restored database
  /// with the old config beside it is the more recoverable shape.
  private func restoreState(from backup: String, owner: String?) async throws {
    try await deps.runner.runChecked([Self.cp, "-p", "\(backup)/runnerd.sqlite3", databasePath])
    // `.backup` writes one complete file; a stale write-ahead log left next to it belongs to the
    // database that was just replaced and would be replayed over the restored one.
    try await deps.runner.runChecked([
      Self.rm, "-f", "\(databasePath)-wal", "\(databasePath)-shm",
    ])
    if deps.fileExists("\(backup)/config.yaml") {
      try await deps.runner.runChecked([Self.cp, "-p", "\(backup)/config.yaml", configPath])
    }
    guard let owner, !owner.isEmpty else { return }
    // Restoring as root would leave files the service account cannot write, and the daemon would
    // come back up unable to open its own database.
    try await deps.runner.runChecked([Self.chown, owner, databasePath])
    if deps.fileExists(configPath) {
      try await deps.runner.runChecked([Self.chown, owner, configPath])
    }
  }

  /// What an operator has to type when RunnerVM will not do it for them. Names the exact backup
  /// directory and the exact pkg, because "restore your backup" is not actionable at 2am.
  public func printManualRestoration(_ report: UpgradeReport) {
    let io = deps.io
    io.heading("Manual restoration")
    if report.schemaUnchanged {
      io.say("The database schema did not move, but the automatic rollback could not run.")
    } else {
      io.say("The database schema advanced from v\(report.schemaBefore.map(String.init) ?? "?") "
        + "to v\(report.schemaAfter.map(String.init) ?? "?").")
      io.say("Migrations are one-way: restoring the old database under the old binaries would")
      io.say("lose everything the new schema recorded. Nothing has been rolled back.")
    }
    io.say("")
    guard let backup = report.backupDirectory else {
      io.say("No backup directory was created — the upgrade failed before that step, so the")
      io.say("host still holds its original database and configuration.")
      return
    }
    io.say("Backup taken before the upgrade: \(backup)")
    io.say("  config.yaml       the configuration as it was")
    io.say("  runnerd.sqlite3   a consistent copy of the database")
    io.say("  versions.json     from/to versions and the schema version at that point")
    io.say("")
    if let package = report.previousPackagePath {
      io.say("To go back to \(report.fromVersion) by hand:")
      io.say("  sudo launchctl bootout \(domainTarget)/\(LaunchdManager.label)")
      io.say("  sudo installer -pkg \(package) -target /")
      io.say("  sudo cp \(backup)/runnerd.sqlite3 \(databasePath)")
      io.say("  sudo rm -f \(databasePath)-wal \(databasePath)-shm")
      io.say("  sudo cp \(backup)/config.yaml \(configPath)")
      if let owner = report.stateOwner {
        io.say("  sudo chown \(owner) \(databasePath) \(configPath)")
      }
      io.say("  sudo launchctl bootstrap \(domainTarget) \(plistPath)")
    } else {
      io.say("No cached package for \(report.fromVersion) is on this host, so going back needs")
      io.say("the pkg from its GitHub release:")
      io.say("  https://github.com/\(ReleaseSource.defaultRepository)/releases/tag/"
        + "v\(report.fromVersion)")
    }
    io.say("")
    io.say("Then re-check the host with:  sudo runnerctl doctor")
  }
}
