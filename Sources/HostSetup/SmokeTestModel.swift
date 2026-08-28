import DaemonAPI
import Foundation

/// What one `SmokeTest.run` needs to know before it creates anything.
public struct SmokeTestOptions: Sendable {
  public var profile: String
  /// Maintenance-only, same as `runnerctl vm create --pinned --image`.
  public var imageOverride: String?
  public var ttlMs: Int64
  /// How long to wait for the clone to reach `idle` before `instance.boot` fails.
  public var bootTimeout: Duration
  /// Drives the macOS-only checks (`instance.selfTest`, the ssh-closed probe). Set from the
  /// profile's `guestOS` -- never guessed from the image -- so a caller that has not yet looked
  /// the profile up cannot silently run the Linux subset against a macOS guest.
  public var macOS: Bool

  public init(
    profile: String, imageOverride: String? = nil, ttlMs: Int64 = MaintenanceTTL.defaultMs,
    bootTimeout: Duration = .seconds(240), macOS: Bool
  ) {
    self.profile = profile
    self.imageOverride = imageOverride
    self.ttlMs = ttlMs
    self.bootTimeout = bootTimeout
    self.macOS = macOS
  }
}

/// One step of a smoke test, in the order `SmokeTest.run` performed it. Mirrors
/// `GuestControl.SelfTestCheck`'s shape on purpose: same three fields, same "detail is always a
/// string, never absent" convention.
public struct SmokeTestCheck: Codable, Sendable, Hashable {
  public var name: String
  public var ok: Bool
  public var detail: String

  public init(name: String, ok: Bool, detail: String = "") {
    self.name = name
    self.ok = ok
    self.detail = detail
  }
}

/// The full result of `SmokeTest.run`. `instanceId` is `nil` only when `instance.create` itself
/// failed -- there was never anything to tear down or leak-check.
public struct SmokeTestReport: Codable, Sendable, Hashable {
  public var profile: String
  public var instanceId: String?
  public var checks: [SmokeTestCheck]
  public var passed: Bool

  public init(profile: String, instanceId: String?, checks: [SmokeTestCheck], passed: Bool) {
    self.profile = profile
    self.instanceId = instanceId
    self.checks = checks
    self.passed = passed
  }
}
