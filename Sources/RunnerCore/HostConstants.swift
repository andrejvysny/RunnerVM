/// Platform limits that are not configurable.
public enum HostConstants {
  /// Guest OSes this build can actually run. macOS guests need the VZMacPlatformConfiguration
  /// path (M8); extend this set when it lands.
  public static let supportedGuestOS: Set<GuestOS> = [.linux]
  /// Apple Virtualization.framework refuses a third concurrent macOS guest (macOS EULA §2.B.iii).
  public static let macOSGuestLimit = 2
  /// Tart observed frequent freezes below 4 vCPU for macOS guests.
  public static let macOSMinimumCPUCount = 4
  /// Fixed vsock port the guest agent listens on. Centralized (spec §32).
  public static let guestAgentVsockPort: UInt32 = 4050
}
