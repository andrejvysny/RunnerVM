import Foundation

/// Every filesystem location RunnerVM owns (spec §22). Pure path algebra: nothing here touches disk.
public struct RunnerPaths: Hashable, Sendable {
  /// `/Library/Application Support/RunnerVM` in production.
  public let rootDir: URL
  /// Deliberately short, because `sockaddr_un.sun_path` is only 104 bytes on Darwin.
  public let runtimeDir: URL

  public init(rootDir: URL, runtimeDir: URL) {
    self.rootDir = rootDir
    self.runtimeDir = runtimeDir
  }

  // MARK: - Layout

  public var stateDir: URL { rootDir.appending(path: "state", directoryHint: .isDirectory) }
  public var imagesDir: URL { rootDir.appending(path: "images", directoryHint: .isDirectory) }
  public var instancesDir: URL { rootDir.appending(path: "instances", directoryHint: .isDirectory) }
  public var logsDir: URL { rootDir.appending(path: "logs", directoryHint: .isDirectory) }
  public var socketDir: URL { runtimeDir }

  public var imageManifestsDir: URL { imagesDir.appending(path: "manifests", directoryHint: .isDirectory) }
  public var imageBlobsDir: URL { imagesDir.appending(path: "blobs", directoryHint: .isDirectory) }
  public var daemonLogsDir: URL { logsDir.appending(path: "runnerd", directoryHint: .isDirectory) }

  public var databaseURL: URL { stateDir.appending(path: "runnerd.sqlite3") }
  public var daemonSocket: URL { socketDir.appending(path: "runnerd.sock") }

  public func instanceDir(_ id: InstanceID) -> URL {
    instancesDir.appending(path: id.rawValue, directoryHint: .isDirectory)
  }

  /// runnerd <-> vmworker control socket.
  public func workerSocket(_ id: InstanceID) -> URL {
    socketDir.appending(path: "vm-\(Self.shortID(id)).sock")
  }

  /// vmworker's UDS bridge in front of the guest's vsock listener.
  public func agentSocket(_ id: InstanceID) -> URL {
    socketDir.appending(path: "vm-\(Self.shortID(id))-agent.sock")
  }

  /// First 8 characters of the instance UUID, matching the `rvm-<profile>-<shortid>` naming (§125).
  public static func shortID(_ id: InstanceID) -> String {
    String(id.rawValue.prefix(shortIDLength))
  }

  public static let shortIDLength = 8

  // MARK: - Well-known layouts

  public static func production() -> RunnerPaths {
    RunnerPaths(
      rootDir: URL(fileURLWithPath: "/Library/Application Support/RunnerVM", isDirectory: true),
      runtimeDir: URL(fileURLWithPath: "/var/run/runnervm", isDirectory: true)
    )
  }

  /// Developer layout: state under the user's home, sockets under `/tmp` because a home directory
  /// path can easily blow the 104-byte `sun_path` budget.
  public static func development(uid: uid_t, home: URL) -> RunnerPaths {
    RunnerPaths(
      rootDir: home.appending(path: "Library/Application Support/RunnerVM", directoryHint: .isDirectory),
      runtimeDir: URL(fileURLWithPath: "/tmp/runnervm-\(uid)", isDirectory: true)
    )
  }

  // MARK: - Socket path budget

  /// Darwin's `sockaddr_un.sun_path` holds 104 bytes including the NUL terminator; 100 leaves room
  /// for the temporary `.tmp` suffix used when a socket is published atomically.
  public static let socketPathLimit = 100

  /// Checks the daemon socket plus a worst-case worker/agent socket. Short ids are fixed width, so
  /// one synthetic instance covers every real one.
  public func validateSocketPathLengths() throws {
    let sample = InstanceID(rawValue: String(repeating: "f", count: Self.shortIDLength))
    for url in [daemonSocket, workerSocket(sample), agentSocket(sample)] {
      let bytes = url.path(percentEncoded: false).utf8.count
      guard bytes <= Self.socketPathLimit else {
        throw ConfigurationError.socketPathTooLong(
          path: url.path(percentEncoded: false), bytes: bytes, limit: Self.socketPathLimit
        )
      }
    }
  }
}
