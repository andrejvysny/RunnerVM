/// Platform limits that are not configurable.
public enum HostConstants {
  /// Guest OSes this build can actually run. Both have a platform builder in VirtualizationCore;
  /// the set stays explicit so a future guest OS is refused at config-validation time rather than
  /// discovered when vmworker cannot build a configuration for it.
  public static let supportedGuestOS: Set<GuestOS> = [.linux, .macos]
  /// Two concurrent macOS guests per host is RunnerVM's fixed default, matching Apple's standard
  /// macOS license allowance (two additional macOS instances per Apple-branded Mac) and the
  /// supported Virtualization.framework operating model -- not a framework error code we rely on.
  public static let macOSGuestLimit = 2
  /// Tart observed frequent freezes below 4 vCPU for macOS guests.
  public static let macOSMinimumCPUCount = 4
  /// Fixed vsock port the guest agent listens on. Centralized (spec §32).
  public static let guestAgentVsockPort: UInt32 = 4050
}
