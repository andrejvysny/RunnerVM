import DaemonAPI
import Foundation
import HostSetup
import RunnerCore

/// `smoke_test`, `--deep` only: the same instance-boot-exec-teardown proof `runnerctl system
/// smoke-test` runs by hand, folded into doctor. Costs a real cold boot, which is why it is gated
/// behind `--deep` alongside `image_store_integrity`'s full re-hash.
extension DoctorChecks {
  static func smokeTest(
    paths: RunnerPaths, daemonSocket: URL, images: [ImageInfoDTO]?
  ) async -> DoctorCheck {
    let id = "smoke_test"
    let title = "Smoke test"
    guard images != nil else {
      return DoctorCheck(id: id, title: title, status: .skip, detail: "daemon is not reachable")
    }
    let client: DaemonClient
    do {
      client = try await DaemonClient.connect(socketPath: daemonSocket)
    } catch {
      return DoctorCheck(id: id, title: title, status: .skip, detail: "daemon is not reachable")
    }
    defer { Task { await client.close() } }

    let profiles: [ProfileSummary]
    do {
      profiles = try await client.profileList().profiles
    } catch {
      return DoctorCheck(
        id: id, title: title, status: .skip, detail: "profile.list failed: \(error)")
    }
    let candidates = profiles.filter { $0.enabled && $0.guestOS == GuestOS.linux.rawValue }
    guard let images, let profile = candidates.first(where: { imageIsLocal($0.image, images: images) })
    else {
      let reason = candidates.isEmpty
        ? "no enabled linux profile"
        : "no enabled linux profile's image is cached locally"
      return DoctorCheck(id: id, title: title, status: .skip, detail: reason)
    }

    let smokeTest = SmokeTest(client: client, paths: paths)
    let report = await smokeTest.run(
      SmokeTestOptions(profile: profile.name, bootTimeout: .seconds(120), macOS: false))
    guard report.passed else {
      let failed = report.checks.first { !$0.ok }?.name ?? "unknown"
      let instanceNote = report.instanceId.map { " (instance \($0))" } ?? ""
      return DoctorCheck(
        id: id, title: title, status: .fail,
        detail: "profile \(profile.name): \(failed) failed" + instanceNote)
    }
    return DoctorCheck(
      id: id, title: title, status: .ok,
      detail: "profile \(profile.name) booted, execed and cleaned up"
    )
  }

  private static func imageIsLocal(_ ref: String, images: [ImageInfoDTO]) -> Bool {
    images.contains {
      $0.digest == ref || $0.name == ref || $0.canonicalReference == ref
    }
  }
}
