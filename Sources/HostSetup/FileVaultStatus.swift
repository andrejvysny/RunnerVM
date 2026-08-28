import Foundation

/// What `fdesetup status` said about the boot volume.
///
/// Reported, never acted on. RunnerVM works either way once the host is up; the trade-off — an
/// encrypted boot volume versus a Mac that comes back on its own after a power cut — is the
/// operator's to make, and `setup` only has to make sure they make it knowingly.
public enum FileVaultStatus: String, Sendable, Codable, CaseIterable {
  case on
  case off
  /// `fdesetup` was unavailable, failed, or printed something this parser does not recognize.
  case unknown

  /// `fdesetup status` prints one of two fixed sentences; anything else is treated as unknown
  /// rather than guessed at.
  public static func parse(output: String, exitCode: Int32) -> FileVaultStatus {
    let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard exitCode == 0, !text.isEmpty else { return .unknown }
    if text.contains("FileVault is Off") { return .off }
    if text.contains("FileVault is On") { return .on }
    return .unknown
  }

  /// The operator-facing caveat, or `nil` when there is nothing to say.
  public var warning: String? {
    switch self {
    case .off:
      nil
    case .on:
      "FileVault is on. After a cold boot the Mac waits at pre-boot authentication before launchd "
        + "runs anything, so this host will not come back unattended after a power cut until "
        + "someone unlocks it. RunnerVM itself is unaffected once the host is up."
    case .unknown:
      "FileVault status could not be read; if it is on, an unattended cold boot will stop at "
        + "pre-boot authentication before runnerd can start."
    }
  }
}
