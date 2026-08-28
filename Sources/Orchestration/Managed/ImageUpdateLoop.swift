import Foundation

/// `DaemonRuntime`'s image-update loop, split out to keep the composition root under its line
/// budget. Mirrors `startMaintenanceLoop`: one long-lived `Task`, cancelled and awaited by
/// `teardown`.
extension DaemonRuntime {
  /// The image update sweep (`images.updates`, phase D6), on its own cadence again -- hours, not
  /// the maintenance loop's minutes. The first pass waits `firstCycleDelay`: daemon start is
  /// already resolving every profile image, and a registry burst on top of that buys nothing.
  ///
  /// The interval is re-read from the service on every iteration rather than captured, so a
  /// `config.apply` that changes `images.updates.interval` takes effect on the next sleep instead
  /// of at the next restart. A disabled policy still ticks; the sweep itself is what no-ops, which
  /// is what keeps `image.update.run` working on a host that never updates by itself.
  func startImageUpdateLoop(_ updates: ImageUpdateService) -> Task<Void, Never> {
    Task {
      // Before the first sleep: a row a previous process left mid-pull would otherwise be skipped
      // by every sweep for the life of this daemon.
      await updates.recoverInterrupted()
      do {
        try await Task.sleep(for: await updates.firstCycleDelay())
      } catch {
        return
      }
      while !Task.isCancelled {
        await updates.runScheduledCycle()
        do {
          try await Task.sleep(for: await updates.nextDelay())
        } catch {
          return
        }
      }
    }
  }
}
