import Foundation
import RunnerCore

/// `instances/<id>/spec.json`, written by runnerd and read by vmworker.
///
/// A field-for-field mirror of `VirtualizationCore.VMInstanceSpec`: Orchestration must never link
/// Virtualization.framework (spec §7.2), so the two declarations are kept in step by
/// `InstanceSpecFileTests` pinning the JSON keys rather than by the compiler.
///
/// `InstanceStore.materialize` serialises this with the same settings vmworker decodes with
/// (`.sortedKeys`, `.iso8601`), and the fencing digest is taken over the bytes that actually
/// landed on disk — never over a re-encoding of this value.
struct InstanceSpecFile: Codable, Sendable, Equatable {
  var id: InstanceID
  var imageDigest: ImageDigest
  var os: GuestOS
  var cpuCount: Int
  var memoryBytes: UInt64
  var diskBytes: UInt64
  var macAddress: String
  var serialConsole: Bool
  var hardDeadline: Date?

  init(
    id: InstanceID, imageDigest: ImageDigest, os: GuestOS, cpuCount: Int, memoryBytes: UInt64,
    diskBytes: UInt64, macAddress: String, serialConsole: Bool = true, hardDeadline: Date? = nil
  ) {
    self.id = id
    self.imageDigest = imageDigest
    self.os = os
    self.cpuCount = cpuCount
    self.memoryBytes = memoryBytes
    self.diskBytes = diskBytes
    self.macAddress = macAddress
    self.serialConsole = serialConsole
    self.hardDeadline = hardDeadline
  }

  /// Locally administered unicast address (`02:` prefix), so a guest can never collide with a real
  /// vendor MAC on the host LAN.
  static func randomMACAddress() -> String {
    var bytes = [UInt8](repeating: 0, count: 6)
    for index in 1..<6 { bytes[index] = UInt8.random(in: 0...255) }
    bytes[0] = 0x02
    return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
  }
}
