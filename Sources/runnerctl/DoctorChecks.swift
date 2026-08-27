import DaemonAPI
import Foundation
import RunnerCore

/// Orchestrator plus the checks that need neither `vmworker` nor a configuration file: host
/// platform, filesystem, host sleep, launchd, and the daemon socket. vmworker-related checks are
/// in `DoctorVMWorkerChecks.swift`; configuration/GitHub-credential checks are in
/// `DoctorConfigChecks.swift`. One small static function per spec §104 line item (plus the
/// host-sleep and launchd-job checks the implementation plan adds); no sleeping anywhere here.
enum DoctorChecks {
  static func runAll(
    paths: RunnerPaths, configPath: String?, daemonSocket: URL, serviceUser: String? = nil,
    deep: Bool = false
  ) async -> DoctorReport {
    var checks: [DoctorCheck] = [appleSilicon(), macOSVersion()]

    let workerPath = locateVMWorker()
    checks.append(vmworkerBinary(path: workerPath))
    let capabilities = workerPath.flatMap(probeCapabilities)
    checks.append(vmworkerProbe(path: workerPath, capabilities: capabilities))

    checks.append(stateDirWritable(paths.rootDir))
    checks.append(socketPathLengths(paths))
    checks.append(serviceUserOwnership(paths: paths, overrideServiceUser: serviceUser))
    checks.append(runtimeDirPerms(paths: paths, overrideServiceUser: serviceUser))

    let loaded = loadConfig(path: configPath, capabilities: capabilities)
    checks.append(loaded.check)
    checks.append(diskHeadroom(rootDir: paths.rootDir, config: loaded.config))
    checks.append(freeMemory(config: loaded.config, capabilities: capabilities))
    checks.append(githubToken(config: loaded.config, paths: paths))

    checks.append(buildTools())
    checks.append(buildToolsServiceContext(rootDirPath: paths.rootDir.path, overrideServiceUser: serviceUser))
    checks.append(buildGuestAgent(paths: paths, config: loaded.config))
    checks.append(buildRecipes(paths: paths))

    checks.append(await imageStoreIntegrity(paths: paths, deep: deep))
    checks.append(await guestAgentImage(paths: paths))

    checks.append(hostSleepDisabled())
    checks.append(launchdJobLoaded())
    checks.append(loginKeychainUnlocked())

    let (daemonCheck, status, images) = await daemonReachable(url: daemonSocket)
    checks.append(daemonCheck)
    if let status { checks.append(daemonHealth(status)) }
    checks.append(
      runnerVersion(images: images, config: loaded.config, authState: status?.github.authState))
    checks.append(profileImageGuestAgent(images: images, config: loaded.config))

    return DoctorReport(checks: checks)
  }

  // MARK: Host platform

  static func appleSilicon() -> DoctorCheck {
    let arch = machineArchitecture()
    return DoctorCheck(
      id: "apple_silicon", title: "Apple Silicon", status: arch == "arm64" ? .ok : .fail,
      detail: arch == "arm64"
        ? "hw.machine=arm64"
        : "hw.machine=\(arch); Apple Virtualization guests require Apple Silicon"
    )
  }

  static func macOSVersion() -> DoctorCheck {
    let os = ProcessInfo.processInfo.operatingSystemVersion
    let supported = ProcessInfo.processInfo.isOperatingSystemAtLeast(
      OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
    )
    let version = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    return DoctorCheck(
      id: "macos_version", title: "macOS version", status: supported ? .ok : .fail,
      detail: supported ? "macOS \(version)" : "macOS \(version); RunnerVM requires macOS 15+"
    )
  }

  static func machineArchitecture() -> String {
    var size = 0
    sysctlbyname("hw.machine", nil, &size, nil, 0)
    guard size > 0 else { return "unknown" }
    var buffer = [UInt8](repeating: 0, count: size)
    sysctlbyname("hw.machine", &buffer, &size, nil, 0)
    let terminator = buffer.firstIndex(of: 0) ?? buffer.count
    return String(decoding: buffer[..<terminator], as: UTF8.self)
  }

  // MARK: Filesystem

  /// Spec §23: state path writable, APFS clone support. When the directory does not exist yet
  /// (a fresh host before the first install), this checks the nearest existing ancestor instead
  /// of failing outright — `scripts/install.sh` or the daemon's own bootstrap creates it.
  static func stateDirWritable(_ rootDir: URL) -> DoctorCheck {
    let manager = FileManager.default
    let exists = manager.fileExists(atPath: rootDir.path)
    let ancestor = nearestExistingAncestor(of: rootDir)
    let writable = manager.isWritableFile(atPath: ancestor.path)
    let clonable = volumeSupportsCloning(at: ancestor)
    guard writable else {
      return DoctorCheck(
        id: "state_dir", title: "State directory", status: .fail,
        detail: "\(ancestor.path) is not writable; cannot create \(rootDir.path)"
      )
    }
    let cloneNote = clonable ? "APFS clone support: yes" : "APFS clone support: no (full copies)"
    guard exists else {
      return DoctorCheck(
        id: "state_dir", title: "State directory", status: .warn,
        detail: "\(rootDir.path) does not exist yet (will be created on install/first run); "
          + cloneNote
      )
    }
    return DoctorCheck(
      id: "state_dir", title: "State directory", status: .ok,
      detail: "\(rootDir.path) exists and is writable; " + cloneNote
    )
  }

  static func nearestExistingAncestor(of url: URL) -> URL {
    var candidate = url.standardizedFileURL
    while !FileManager.default.fileExists(atPath: candidate.path), candidate.pathComponents.count > 1 {
      candidate = candidate.deletingLastPathComponent()
    }
    return candidate
  }

  static func volumeSupportsCloning(at url: URL) -> Bool {
    let values = try? url.resourceValues(forKeys: [.volumeSupportsFileCloningKey])
    return values?.volumeSupportsFileCloning ?? false
  }

  static func freeBytes(at url: URL) -> UInt64? {
    let ancestor = nearestExistingAncestor(of: url)
    let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
    guard let values = try? ancestor.resourceValues(forKeys: keys),
          let capacity = values.volumeAvailableCapacityForImportantUsage, capacity > 0
    else { return nil }
    return UInt64(capacity)
  }

  static func socketPathLengths(_ paths: RunnerPaths) -> DoctorCheck {
    do {
      try paths.validateSocketPathLengths()
      return DoctorCheck(
        id: "socket_paths", title: "Socket path lengths", status: .ok,
        detail: "\(paths.socketDir.path) fits the sun_path budget"
      )
    } catch let error as ConfigurationError {
      return DoctorCheck(
        id: "socket_paths", title: "Socket path lengths", status: .fail, detail: error.message
      )
    } catch {
      return DoctorCheck(
        id: "socket_paths", title: "Socket path lengths", status: .fail, detail: "\(error)"
      )
    }
  }

  // MARK: Host sleep (plan: v1 does not tolerate host sleep)

  static func hostSleepDisabled() -> DoctorCheck {
    let result = runProcess("/usr/bin/pmset", ["-g"])
    guard result.exitCode == 0, let minutes = sleepMinutes(fromPmsetOutput: result.stdout) else {
      return DoctorCheck(
        id: "host_sleep", title: "Host sleep", status: .warn,
        detail: "could not determine the system sleep setting from pmset -g"
      )
    }
    guard minutes == 0 else {
      return DoctorCheck(
        id: "host_sleep", title: "Host sleep", status: .warn,
        detail: "system sleep is not disabled (sleep=\(minutes)); a sleeping host drops running "
          + "VMs. Run: sudo pmset sleep 0"
      )
    }
    return DoctorCheck(
      id: "host_sleep", title: "Host sleep", status: .ok, detail: "system sleep is disabled"
    )
  }

  /// `pmset -g` prints one `sleep <n>` line among several `*sleep` keys (`displaysleep`,
  /// `disksleep`); anchoring to line start with only leading whitespace excludes those.
  static func sleepMinutes(fromPmsetOutput text: String) -> Int? {
    for line in text.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("sleep ") || trimmed.hasPrefix("sleep\t") else { continue }
      let value = trimmed.dropFirst("sleep".count).trimmingCharacters(in: .whitespaces)
        .split(separator: " ").first.map(String.init)
      return value.flatMap { Int($0) }
    }
    return nil
  }

  // MARK: launchd

  static func launchdJobLoaded() -> DoctorCheck {
    let uid = getuid()
    let gui = runProcess("/bin/launchctl", ["print", "gui/\(uid)/com.runnervm.runnerd"])
    if gui.exitCode == 0 {
      return DoctorCheck(
        id: "launchd_job", title: "launchd job", status: .ok,
        detail: "LaunchAgent com.runnervm.runnerd loaded in gui/\(uid)"
      )
    }
    let system = runProcess("/bin/launchctl", ["print", "system/com.runnervm.runnerd"])
    if system.exitCode == 0 {
      return DoctorCheck(
        id: "launchd_job", title: "launchd job", status: .ok,
        detail: "LaunchDaemon com.runnervm.runnerd loaded in system"
      )
    }
    return DoctorCheck(
      id: "launchd_job", title: "launchd job", status: .warn,
      detail: "no com.runnervm.runnerd job loaded (gui or system); install one with "
        + "scripts/install.sh --launchd agent|daemon, or start runnerd manually for testing"
    )
  }

  // MARK: Daemon

  /// Also pulls the image catalogue over the same connection: the runner-version check needs the
  /// per-image freshness the daemon graded, and doctor should not open a second socket for it.
  static func daemonReachable(
    url: URL
  ) async -> (check: DoctorCheck, status: SystemStatus?, images: [ImageInfoDTO]?) {
    do {
      let client = try await DaemonClient.connect(socketPath: url)
      defer { Task { await client.close() } }
      let status = try await client.status()
      let images = try? await client.imageList().images
      return (
        DoctorCheck(
          id: "daemon_socket", title: "Daemon socket", status: .ok,
          detail: "\(url.path) reachable (\(status.daemon.state.rawValue))"
        ), status, images
      )
    } catch {
      return (
        DoctorCheck(
          id: "daemon_socket", title: "Daemon socket", status: .warn,
          detail: "\(url.path) unreachable (runnerd not running, or a different --socket-dir)"
        ),
        nil, nil
      )
    }
  }

  static func daemonHealth(_ status: SystemStatus) -> DoctorCheck {
    DoctorCheck(
      id: "daemon_health", title: "Daemon health", status: .ok,
      detail: "pid \(status.daemon.pid), mode \(status.daemon.mode), "
        + "\(status.capacity.runningVMs) VM(s) running"
    )
  }
}

// MARK: - Subprocess

struct ProcessResult {
  var exitCode: Int32
  var stdout: String
}

/// Blocking on purpose: doctor is a short-lived CLI invocation and every subprocess here
/// (codesign, vmworker probe, pmset, launchctl) is expected to finish in well under a second.
func runProcess(_ launchPath: String, _ arguments: [String]) -> ProcessResult {
  guard FileManager.default.isExecutableFile(atPath: launchPath) else {
    return ProcessResult(exitCode: -1, stdout: "")
  }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: launchPath)
  process.arguments = arguments
  let stdoutPipe = Pipe()
  process.standardOutput = stdoutPipe
  process.standardError = Pipe()
  do {
    try process.run()
  } catch {
    return ProcessResult(exitCode: -1, stdout: "")
  }
  let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return ProcessResult(
    exitCode: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self)
  )
}
