import Foundation

/// Pure memory-budget arithmetic behind `runnerctl doctor`'s `free_memory` check (spec WP9).
public enum DoctorCapacity {
  /// What the host must be physically capable of, independent of what happens to be free right
  /// now: the largest single demand it may ever face (a profile's VM, or a build) has to fit
  /// inside physical RAM once `host.reserve.memory` is set aside.
  public struct Requirement: Sendable, Equatable {
    public var physicalBytes: UInt64
    public var reserveBytes: UInt64
    public var largestProfileMemoryBytes: UInt64
    public var buildMemoryBytes: UInt64

    public init(
      physicalBytes: UInt64, reserveBytes: UInt64, largestProfileMemoryBytes: UInt64,
      buildMemoryBytes: UInt64
    ) {
      self.physicalBytes = physicalBytes
      self.reserveBytes = reserveBytes
      self.largestProfileMemoryBytes = largestProfileMemoryBytes
      self.buildMemoryBytes = buildMemoryBytes
    }

    /// A profile VM and a build never have to run at the same time by the reserve's own
    /// accounting (`host.overcommit.memory` stays 1.0, spec §16), so this is the largest single
    /// demand the host has to clear, not the sum of every demand.
    public var neededBytes: UInt64 {
      reserveBytes + max(largestProfileMemoryBytes, buildMemoryBytes)
    }

    /// FAIL half: could this host, structurally, ever fit its largest configured workload? A
    /// `false` here is a configuration/hardware mismatch, not a transient condition.
    public var physicallyCapable: Bool { physicalBytes >= neededBytes }
  }

  /// WARN half: is there actually enough free memory *right now* for the same floor? Unlike
  /// `Requirement.physicallyCapable`, this is dynamic -- other processes can eat into it even on a
  /// host that is structurally capable.
  public static func hasHeadroom(freeBytes: UInt64, neededBytes: UInt64) -> Bool {
    freeBytes >= neededBytes
  }

  // MARK: - vm_stat parsing

  /// `vm_stat`'s free-page count times its reported page size, e.g.:
  /// ```
  /// Mach Virtual Memory Statistics: (page size of 16384 bytes)
  /// Pages free:                               123456.
  /// ```
  /// `nil` when either figure is missing -- a format doctor has never seen rather than "0 free".
  public static func freeMemoryBytes(fromVMStatOutput text: String) -> UInt64? {
    guard let pageSize = pageSize(fromVMStatOutput: text),
          let freePages = unsignedField(named: "Pages free", in: text)
    else { return nil }
    return pageSize * freePages
  }

  private static func pageSize(fromVMStatOutput text: String) -> UInt64? {
    guard let header = text.split(separator: "\n", maxSplits: 1).first,
          let marker = header.range(of: "page size of ")
    else { return nil }
    let digits = header[marker.upperBound...].prefix { $0.isNumber }
    return UInt64(digits)
  }

  private static func unsignedField(named label: String, in text: String) -> UInt64? {
    for line in text.split(separator: "\n") {
      guard line.hasPrefix(label), let colon = line.firstIndex(of: ":") else { continue }
      let rest = line[line.index(after: colon)...]
        .trimmingCharacters(in: .whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: "."))
      return UInt64(rest)
    }
    return nil
  }
}
