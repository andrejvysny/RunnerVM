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

  /// In-daemon image builds (Phase 4/5 image builder): each build gets `builds/<id>/vm/...`, the
  /// same clone-then-publish layout an instance gets under `instances/<id>/`.
  public var buildsDir: URL { stateDir.appending(path: "builds", directoryHint: .isDirectory) }
  public func buildDir(_ id: ImageBuildID) -> URL {
    buildsDir.appending(path: id.rawValue, directoryHint: .isDirectory)
  }
  /// The build's VM directory proper (disk, nvram, spec, seed, context). Nested under `buildDir`
  /// rather than being it, so future build-only artifacts (the recipe copy, push manifests) have
  /// somewhere to live alongside the VM without crowding its directory.
  public func buildVMDir(_ id: ImageBuildID) -> URL {
    buildDir(id).appending(path: "vm", directoryHint: .isDirectory)
  }

  /// Per-build *logs*, mirroring `instanceLogsDir`: outlives the build directory, which goes away
  /// once the build is deleted.
  public var buildLogsDir: URL { logsDir.appending(path: "builds", directoryHint: .isDirectory) }
  public func buildLogDir(_ id: ImageBuildID) -> URL {
    buildLogsDir.appending(path: id.rawValue, directoryHint: .isDirectory)
  }
  public func buildLogFile(_ id: ImageBuildID) -> URL {
    buildLogDir(id).appending(path: "build.log")
  }

  /// Where a build caches a `FROM cloudImage:`/`FROM registry:` base before staging its VM.
  public var baseImageCacheDir: URL {
    rootDir.appending(path: "cache", directoryHint: .isDirectory)
      .appending(path: "base-images", directoryHint: .isDirectory)
  }

  /// Builder workers get their own socket namespace, separate from `socketDir`'s instance sockets:
  /// a build and an instance can share the same short id prefix without colliding.
  public var buildSocketDir: URL { socketDir.appending(path: "build", directoryHint: .isDirectory) }

  /// Per-instance *logs*, deliberately separate from `instances/<id>/`: the instance directory is
  /// the VM's disk and goes away with the VM, while its serial console, worker output and
  /// collected guest diagnostics have to outlive it (spec §74, §131).
  public var instanceLogsDir: URL { logsDir.appending(path: "instances", directoryHint: .isDirectory) }

  public var databaseURL: URL { stateDir.appending(path: "runnerd.sqlite3") }
  public var daemonSocket: URL { socketDir.appending(path: "runnerd.sock") }

  /// The daemon's own rotating JSON log.
  public var daemonLogFile: URL { daemonLogsDir.appending(path: "runnerd.log") }

  /// The machine-readable lifecycle event stream.
  public var eventsLogFile: URL { logsDir.appending(path: "events.jsonl") }

  public func instanceDir(_ id: InstanceID) -> URL {
    instancesDir.appending(path: id.rawValue, directoryHint: .isDirectory)
  }

  public func instanceLogDir(_ id: InstanceID) -> URL {
    instanceLogsDir.appending(path: id.rawValue, directoryHint: .isDirectory)
  }

  /// Where `afterSession` streams the guest's `_diag` tarball before an ephemeral VM is destroyed.
  public func instanceDiagnosticsDir(_ id: InstanceID) -> URL {
    instanceLogDir(id).appending(path: "diag", directoryHint: .isDirectory)
  }

  /// runnerd <-> vmworker control socket.
  public func workerSocket(_ id: InstanceID) -> URL {
    socketDir.appending(path: "vm-\(Self.shortID(id)).sock")
  }

  /// vmworker's UDS bridge in front of the guest's vsock listener.
  public func agentSocket(_ id: InstanceID) -> URL {
    socketDir.appending(path: "vm-\(Self.shortID(id))-agent.sock")
  }

  /// runnerd <-> build vmworker control socket, under the builder's own namespace.
  public func buildWorkerSocket(_ id: ImageBuildID) -> URL {
    buildSocketDir.appending(path: "vm-\(Self.shortID(id)).sock")
  }

  /// vmworker's UDS bridge in front of the build guest's vsock listener.
  public func buildAgentSocket(_ id: ImageBuildID) -> URL {
    buildSocketDir.appending(path: "vm-\(Self.shortID(id))-agent.sock")
  }

  /// First 8 characters of the id, matching the `rvm-<profile>-<shortid>` naming (§125). Generic
  /// over `TypedID` so instance and build ids share one implementation.
  public static func shortID(_ id: some TypedID) -> String {
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
