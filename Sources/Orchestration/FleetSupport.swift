import DaemonAPI
import Foundation
import Persistence
import RunnerCore

/// The pure parts of `fleet.*`: key validation, the guest install command, address choice and the
/// state vocabulary. Kept free of actors and I/O so each rule is testable without a daemon.
enum FleetSupport {
  static let keyType = "ssh-ed25519"
  static let maxKeyBytes = 512
  static let sshPort: Int64 = 22
  static let arch = "arm64"
  /// A deleted instance stays visible to `fleet.list` this long so the plugin observes `deleted`.
  static let deletedVisibility: TimeInterval = 10 * 60

  /// Only "$1" (user), "$2" (home) and "$3" (key) are ever expanded: the key reaches the shell as
  /// an argv element, never as part of the script text.
  static let installScript = """
    set -eu; umask 077; d="$2/.ssh"; mkdir -p "$d"; chmod 700 "$d"; \
    printf '%s\\n' "$3" > "$d/authorized_keys.tmp"; \
    mv -f "$d/authorized_keys.tmp" "$d/authorized_keys"; chmod 600 "$d/authorized_keys"; \
    chown -R "$1" "$d"
    """

  static func installArgv(user: String, home: String, key: String) -> [String] {
    ["/bin/sh", "-c", installScript, "rvm-fleet", user, home, key]
  }

  static func home(user: String, guestOS: GuestOS) -> String {
    guestOS == .macos ? "/Users/\(user)" : "/home/\(user)"
  }

  // MARK: - Key validation

  /// Exactly one OpenSSH `ssh-ed25519 <base64>[ comment]` line whose blob is a real ed25519 key.
  static func validatePublicKey(_ key: String) throws {
    guard key.utf8.count <= maxKeyBytes else { throw invalid("longer than \(maxKeyBytes) bytes") }
    guard key.utf8.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else {
      throw invalid("must be a single printable-ASCII line")
    }
    let fields = key.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    guard fields.count == 2 || fields.count == 3, fields[0] == keyType else {
      throw invalid("expected '\(keyType) <base64>' with an optional comment")
    }
    guard isBase64Field(fields[1]) else { throw invalid("the key field is not base64") }
    if fields.count == 3, !isComment(fields[2]) {
      throw invalid("the comment may only use [A-Za-z0-9@._-], at most 64 characters")
    }
    guard let blob = Data(base64Encoded: fields[1]), isEd25519Blob(blob) else {
      throw invalid("the key blob is not an ed25519 public key")
    }
  }

  private static func invalid(_ reason: String) -> FleetError { .invalidPublicKey(reason: reason) }

  private static func isBase64Field(_ text: String) -> Bool {
    let body = text.reversed().drop { $0 == "=" }
    guard !body.isEmpty, text.count - body.count <= 2 else { return false }
    return body.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/") }
  }

  private static func isComment(_ text: String) -> Bool {
    text.count <= 64
      && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "@._-".contains($0)) }
  }

  /// `string "ssh-ed25519"` followed by `string <32-byte key>`, each length-prefixed (RFC 4253).
  private static func isEd25519Blob(_ blob: Data) -> Bool {
    let bytes = [UInt8](blob)
    let name = Array(keyType.utf8)
    guard bytes.count == 4 + name.count + 4 + 32 else { return false }
    func length(at offset: Int) -> Int {
      bytes[offset...(offset + 3)].reduce(0) { $0 << 8 | Int($1) }
    }
    guard length(at: 0) == name.count, Array(bytes[4..<(4 + name.count)]) == name else {
      return false
    }
    return length(at: 4 + name.count) == 32
  }

  // MARK: - Address

  /// The agent's own pick when it is a valid IPv4, else the first address that is not loopback,
  /// link-local or inside 172.16.0.0/12 (docker/bridge networks inside the guest).
  static func address(primary: String?, addresses: [String]) -> String? {
    if let primary, ipv4(primary) != nil { return primary }
    return addresses.first { candidate in
      guard let octets = ipv4(candidate), octets != [0, 0, 0, 0] else { return false }
      if octets[0] == 127 || (octets[0] == 169 && octets[1] == 254) { return false }
      return !(octets[0] == 172 && (16...31).contains(octets[1]))
    }
  }

  private static func ipv4(_ text: String) -> [Int]? {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    let octets = parts.compactMap { part -> Int? in
      guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), let value = Int(part),
            (0...255).contains(value) else { return nil }
      return value
    }
    return octets.count == 4 ? octets : nil
  }

  // MARK: - State

  /// `Proto/fleet.md`: the four-value vocabulary the plugin sees.
  static func state(for state: InstanceState) -> String {
    switch state {
    case .planned, .preparing, .cloning, .startingWorker, .startingVM, .waitingForAgent:
      "creating"
    case .idle: "running"
    case .stopping, .deleting: "deleting"
    case .stopped, .interrupted, .failed, .orphaned, .deleted: "deleted"
    case .configuringRunner, .runnerStarting, .runnerOnline, .busy, .cleaning: "running"
    }
  }

  /// Whether `fleet.list` reports the row: any live one, a deleted one only while recent.
  static func isListed(_ record: InstanceRecord, now: Date) -> Bool {
    guard record.state == .deleted else { return true }
    let marker = record.deletedAt?.date ?? record.stoppedAt?.date ?? record.createdAt.date
    return now.timeIntervalSince(marker) <= deletedVisibility
  }
}
