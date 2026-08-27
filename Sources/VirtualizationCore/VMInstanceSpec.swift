import Foundation
import RunnerCore

/// Immutable per-instance VM parameters handed to vmworker (spec §29). Runner-oriented only.
public struct VMInstanceSpec: Codable, Sendable, Equatable {
  public var id: InstanceID
  public var imageDigest: ImageDigest
  public var os: GuestOS
  public var cpuCount: Int
  public var memoryBytes: UInt64
  public var diskBytes: UInt64
  public var macAddress: String
  /// Serial console captured to `serial.log` for boot diagnostics (spec §131).
  public var serialConsole: Bool
  /// Absolute wall-clock instant after which vmworker stops the VM even while the agent bridge is
  /// busy (Proto/worker_protocol.md orphan policy). Absent means "no deadline".
  public var hardDeadline: Date?

  public init(
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
}

extension VMInstanceSpec {
  /// The single codec for `spec.json`. RFC 3339 timestamps keep the file consistent with the wire
  /// envelopes (Proto/envelope.md); the default `Date` strategy would emit reference-epoch doubles.
  public static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  public static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  public static func load(contentsOf url: URL) throws -> VMInstanceSpec {
    try decoder().decode(VMInstanceSpec.self, from: Data(contentsOf: url))
  }

  public func encoded() throws -> Data {
    try Self.encoder().encode(self)
  }
}

/// Filesystem locations of one instance's runtime files. Single owner: InstanceStore (M2).
public struct VMRuntimePaths: Sendable, Equatable {
  public var directory: URL
  public var disk: URL { directory.appendingPathComponent("disk.img") }
  /// EFI variable store (Linux) or macOS auxiliary storage.
  public var nvram: URL { directory.appendingPathComponent("nvram.bin") }
  public var serialLog: URL { directory.appendingPathComponent("serial.log") }
  /// Optional extra read-only disk (cloud-init NoCloud seed for image builds).
  public var seedDisk: URL { directory.appendingPathComponent("seed.img") }
  /// Optional extra read-only disk: the build context, attached only inside a build VM.
  public var contextDisk: URL { directory.appendingPathComponent("context.img") }
  /// Instance-scoped exclusive `fcntl` lock held by the owning vmworker.
  public var workerLock: URL { directory.appendingPathComponent("worker.lock") }
  public var spec: URL { directory.appendingPathComponent("spec.json") }

  public init(directory: URL) {
    // Virtualization.framework rejects paths containing symlinks (tart VM.swift:161-165).
    self.directory = directory.resolvingSymlinksInPath()
  }
}
