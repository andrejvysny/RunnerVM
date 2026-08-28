import Foundation
import RunnerCore

/// Finds a guest's IPv4 address in macOS `bootpd`'s lease file (`/var/db/dhcpd_leases`).
///
/// A macOS guest has no vsock channel until the provisioning run installs the guest agent, so for
/// exactly one stage of a `macosProvision` build the only way to reach it is over the NAT network
/// Virtualization.framework attaches it to — and the only host-side record of which address the
/// shared-network DHCP server handed out is this file.
///
/// The format is `bootpd`'s own, one brace-delimited stanza per lease:
/// ```
/// {
///     name=runnervm
///     ip_address=192.168.64.7
///     hw_address=1,a:bb:c:dd:ee:f
///     identifier=1,a:bb:c:dd:ee:f
///     lease=0x68b1c2d3
/// }
/// ```
/// `hw_address` carries a leading `1,` (the ARP hardware type) and — the part that actually bites —
/// **no zero padding**: a MAC runnerd wrote into `spec.json` as `02:0a:0b:0c:0d:0e` appears here as
/// `2:a:b:c:d:e`. Both sides are therefore normalized to unpadded lowercase hex before comparison.
enum DHCPLeaseResolver {
  static let defaultLeasePath = "/var/db/dhcpd_leases"

  /// One parsed stanza. Only the two fields anything here needs; everything else is ignored so an
  /// unknown key a future macOS adds cannot make a lease unreadable.
  struct Lease: Sendable, Equatable {
    var ipAddress: String
    /// Already normalized (`1,` stripped, lowercase, unpadded).
    var hardwareAddress: String
    var name: String?
  }

  // MARK: - Parsing

  /// Every complete lease in `text`, in file order. A stanza missing either field it is keyed on
  /// is skipped rather than failing the parse: this file is written by a system daemon nobody
  /// here controls, and one malformed entry must not hide the lease we are looking for.
  static func parse(_ text: String) -> [Lease] {
    var leases: [Lease] = []
    var ip: String?
    var hardware: String?
    var name: String?
    var inside = false
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("{") {
        inside = true
        (ip, hardware, name) = (nil, nil, nil)
        continue
      }
      if line.hasPrefix("}") {
        if inside, let ip, let hardware {
          leases.append(Lease(ipAddress: ip, hardwareAddress: hardware, name: name))
        }
        inside = false
        continue
      }
      guard inside, let separator = line.firstIndex(of: "=") else { continue }
      let key = line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      switch key {
      case "ip_address": ip = value
      case "hw_address": hardware = normalize(value)
      case "name": name = value
      default: continue
      }
    }
    return leases
  }

  /// The address a lease was handed to `macAddress`, or `nil`.
  ///
  /// Last match wins: `bootpd` appends a new stanza when a client comes back with a different
  /// address, and the most recent one is the live lease.
  static func address(in text: String, macAddress: String) -> String? {
    let wanted = normalize(macAddress)
    guard !wanted.isEmpty else { return nil }
    return parse(text).last { $0.hardwareAddress == wanted }?.ipAddress
  }

  /// `1,0a:0B:...` → `a:b:...`. Strips the ARP hardware type prefix, lowercases, and drops leading
  /// zeros from every octet, which is the form `bootpd` writes and `spec.json` does not.
  static func normalize(_ address: String) -> String {
    var text = address.trimmingCharacters(in: .whitespaces).lowercased()
    if let comma = text.lastIndex(of: ",") {
      text = String(text[text.index(after: comma)...])
    }
    return text.split(separator: ":", omittingEmptySubsequences: false)
      .map { octet -> String in
        let trimmed = octet.drop { $0 == "0" }
        return trimmed.isEmpty ? "0" : String(trimmed)
      }
      .joined(separator: ":")
  }

  // MARK: - Polling

  /// Reads `url` as UTF-8, or `nil` when it does not exist yet (a host that has never served a
  /// lease has no file at all).
  static func read(_ url: URL) -> String? {
    guard let data = FileManager.default.contents(atPath: url.path(percentEncoded: false)) else {
      return nil
    }
    return String(decoding: data, as: UTF8.self)
  }

  /// Waits for `macAddress` to appear, polling `reader` until `timeout` elapses.
  ///
  /// `reader` and `sleep` are injected so the parser and the wait can both be tested without a
  /// real lease file and without real time; production passes `read(_:)` and `Task.sleep`.
  static func wait(
    macAddress: String, timeout: Duration, interval: Duration = .seconds(2),
    reader: @Sendable () -> String?,
    sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) async throws -> String {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while true {
      if let text = reader(), let address = address(in: text, macAddress: macAddress) {
        return address
      }
      guard ContinuousClock.now < deadline else { break }
      try await sleep(interval)
      try Task.checkCancellation()
    }
    throw ImageBuildError.macosLeaseNotFound(
      macAddress: macAddress, seconds: Int(timeout.components.seconds))
  }
}
