import ArgumentParser
import Dispatch
import Foundation
import Logging
import RunnerCore
import RunnerLogging
import Virtualization
import VirtualizationCore
import WorkerProtocol

/// `vmworker run` — one process, one VM, one instance directory (Proto/worker_protocol.md).
struct Run: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Own one VZVirtualMachine and serve the worker protocol.")

  @Option(name: .long, help: "Instance UUID; must match the spec.") var instance: String
  @Option(name: .long, help: "Path to spec.json. Its directory is the instance directory.") var spec: String
  @Option(name: .long, help: "Directory the worker and agent sockets are published in.") var socketDir: String
  @Option(name: .long, help: "Fencing generation supplied by runnerd.") var generation: Int
  @Option(name: .long, help: "Incarnation nonce supplied by runnerd.") var nonce: String
  @Option(name: .long, help: "Initial lease TTL in milliseconds.") var leaseTtlMs: Int64 = 30_000
  @Option(name: .long, help: "Idle time after lease expiry before self-stop.") var orphanIdleMs: Int64 = 600_000

  func run() throws {
    let logger = Self.makeLogger(instance: instance, generation: generation)
    let specURL = URL(fileURLWithPath: spec)
    let loaded = try Self.loadSpec(specURL, instance: instance, logger: logger)
    let paths = VMRuntimePaths(directory: specURL.deletingLastPathComponent())

    let lock = try Self.acquireLock(paths: paths, logger: logger)
    // Linux images may ship without an EFI variable store; the store is per-instance state.
    if loaded.spec.os == .linux, !FileManager.default.fileExists(atPath: paths.nvram.path) {
      try LinuxVMPlatform.createVariableStore(at: paths.nvram)
      logger.info("created EFI variable store", metadata: ["path": "\(paths.nvram.path)"])
    }
    let configuration = try Self.buildConfiguration(spec: loaded.spec, paths: paths, logger: logger)
    let options = Self.makeOptions(loaded, instance: instance, run: self)

    let service = MainActor.assumeIsolated {
      WorkerService(
        options: options, runtime: VMRuntime(configuration: configuration), logger: logger)
    }
    Task { @MainActor in
      do {
        try await service.startServing()
      } catch {
        logger.error("startup failed", metadata: ["error": .string("\(error)")])
        Foundation.exit(WorkerExitCode.vzStartFailed.rawValue)
      }
    }
    logger.info("worker locked instance", metadata: ["lock_fd": .stringConvertible(lock.descriptor)])
    // Parks the process on the queue the VM was created with; never returns.
    dispatchMain()
  }

  // MARK: - Startup steps

  private static func makeLogger(instance: String, generation: Int) -> Logger {
    LoggingSystemBootstrap.bootstrapJSON(minimumLevel: .debug)
    var logger = Logger(component: .vmworker)
    logger[metadataKey: "instance_id"] = .string(instance)
    logger[metadataKey: "worker_pid"] = .stringConvertible(getpid())
    logger[metadataKey: "generation"] = .stringConvertible(generation)
    return logger
  }

  private static func loadSpec(
    _ url: URL, instance: String, logger: Logger
  ) throws -> (spec: VMInstanceSpec, digest: String) {
    do {
      let digest = try SpecDigest.sha256Hex(ofFileAt: url)
      let spec = try VMInstanceSpec.load(contentsOf: url)
      guard spec.id.rawValue == instance else {
        logger.error("spec id mismatch", metadata: ["spec_id": .string(spec.id.rawValue)])
        throw ExitCode(WorkerExitCode.specInvalid.rawValue)
      }
      return (spec, digest)
    } catch let code as ExitCode {
      throw code
    } catch {
      logger.error("spec unreadable", metadata: ["error": .string("\(error)")])
      throw ExitCode(WorkerExitCode.specInvalid.rawValue)
    }
  }

  private static func acquireLock(paths: VMRuntimePaths, logger: Logger) throws -> WorkerLock {
    do {
      return try WorkerLock.acquire(url: paths.workerLock)
    } catch let error as WorkerLockError {
      logger.error("instance lock unavailable", metadata: ["error": .string("\(error)")])
      throw ExitCode(WorkerExitCode.lockHeld.rawValue)
    }
  }

  private static func buildConfiguration(
    spec: VMInstanceSpec, paths: VMRuntimePaths, logger: Logger
  ) throws -> VZVirtualMachineConfiguration {
    // A cloud-init NoCloud seed is a build-time-only extra: scripts/build-ubuntu-image.sh drops
    // seed.img into the instance directory, runner instances never have one (spec §60).
    var readOnlyDisks: [URL] = []
    if FileManager.default.fileExists(atPath: paths.seedDisk.path) {
      readOnlyDisks.append(paths.seedDisk)
      logger.info("attaching read-only seed disk", metadata: ["path": "\(paths.seedDisk.path)"])
    }
    do {
      return try VMConfigurationBuilder(spec: spec, paths: paths, readOnlyDisks: readOnlyDisks)
        .build(validate: true)
    } catch {
      logger.error("vz configuration invalid", metadata: ["error": .string("\(error)")])
      throw ExitCode(WorkerExitCode.vzConfigInvalid.rawValue)
    }
  }

  private static func makeOptions(
    _ loaded: (spec: VMInstanceSpec, digest: String), instance: String, run: Run
  ) -> WorkerService.Options {
    let shortID = RunnerPaths.shortID(loaded.spec.id)
    let socketDir = URL(fileURLWithPath: run.socketDir, isDirectory: true)
    return WorkerService.Options(
      instanceId: InstanceID(rawValue: instance), generation: run.generation, nonce: run.nonce,
      specDigest: loaded.digest,
      workerSocket: socketDir.appendingPathComponent("vm-\(shortID).sock"),
      agentSocket: socketDir.appendingPathComponent("vm-\(shortID)-agent.sock"),
      orphanIdle: TimeInterval(run.orphanIdleMs) / 1000, initialLeaseTtlMs: run.leaseTtlMs,
      hardDeadline: loaded.spec.hardDeadline)
  }
}
