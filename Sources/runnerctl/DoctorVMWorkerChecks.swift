import Foundation
import RunnerCore

/// vmworker location, entitlement, and `probe` checks. Kept separate from `DoctorChecks.swift`
/// because host-capability facts produced here (`ProbedCapabilities`/`hostFacts`) are also
/// consumed by `DoctorConfigChecks.swift`'s configuration-validation check.
extension DoctorChecks {
  /// `RUNNERVM_VMWORKER` first; then next to this very `runnerctl` binary (the dev `.build/debug`
  /// layout); then `<prefix>/libexec/runnervm/vmworker` derived from a `<prefix>/bin/runnerctl`
  /// (the production layout `scripts/install.sh` creates).
  static func locateVMWorker() -> String? {
    let env = ProcessInfo.processInfo.environment["RUNNERVM_VMWORKER"]
    if let env, !env.isEmpty { return env }
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let binDir = exe.deletingLastPathComponent()
    let sibling = binDir.appendingPathComponent("vmworker")
    if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling.path }
    let prefixed = binDir.deletingLastPathComponent()
      .appendingPathComponent("libexec/runnervm/vmworker")
    if FileManager.default.isExecutableFile(atPath: prefixed.path) { return prefixed.path }
    return nil
  }

  static func vmworkerBinary(path: String?) -> DoctorCheck {
    guard let path else {
      return DoctorCheck(
        id: "vmworker_binary", title: "vmworker binary", status: .fail,
        detail: "not found next to runnerctl and RUNNERVM_VMWORKER is unset"
      )
    }
    let entitled = codesignHasVirtualizationEntitlement(path: path)
    return DoctorCheck(
      id: "vmworker_binary", title: "vmworker binary", status: entitled ? .ok : .fail,
      detail: entitled
        ? "\(path) is signed with com.apple.security.virtualization"
        : "\(path) is not signed with the virtualization entitlement; run scripts/sign-dev.sh "
        + "or scripts/install.sh"
    )
  }

  static func codesignHasVirtualizationEntitlement(path: String) -> Bool {
    let result = runProcess("/usr/bin/codesign", ["-d", "--entitlements", ":-", path])
    return result.stdout.contains("com.apple.security.virtualization")
  }

  /// Mirrors `VirtualizationCore.HostCapabilities` field-for-field so `vmworker probe`'s stock
  /// `JSONEncoder` output (no key strategy override) decodes without a shared module dependency —
  /// `runnerctl` deliberately does not link `VirtualizationCore` (spec §7.2).
  struct ProbedCapabilities: Decodable {
    var virtualizationSupported: Bool
    var architecture: String
    var hostOSVersion: String
    var logicalCPUCount: Int
    var physicalMemoryBytes: UInt64
    var minimumAllowedCPUCount: Int
    var maximumAllowedCPUCount: Int
    var minimumAllowedMemoryBytes: UInt64
    var maximumAllowedMemoryBytes: UInt64
    var nestedVirtualizationSupported: Bool
    var macOSGuestLimit: Int
  }

  static func probeCapabilities(path: String) -> ProbedCapabilities? {
    let result = runProcess(path, ["probe"])
    guard result.exitCode == 0, let data = result.stdout.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(ProbedCapabilities.self, from: data)
  }

  static func vmworkerProbe(path: String?, capabilities: ProbedCapabilities?) -> DoctorCheck {
    guard path != nil else {
      return DoctorCheck(
        id: "vmworker_probe", title: "vmworker probe", status: .fail,
        detail: "skipped: no vmworker binary found"
      )
    }
    guard let capabilities else {
      return DoctorCheck(
        id: "vmworker_probe", title: "vmworker probe", status: .fail,
        detail: "vmworker probe did not return valid JSON"
      )
    }
    guard capabilities.virtualizationSupported else {
      return DoctorCheck(
        id: "vmworker_probe", title: "vmworker probe", status: .fail,
        detail: "probe succeeded but reports virtualizationSupported=false"
      )
    }
    return DoctorCheck(
      id: "vmworker_probe", title: "vmworker probe", status: .ok,
      detail: "virtualization supported; macOS guest limit \(capabilities.macOSGuestLimit), "
        + "nested virtualization \(capabilities.nestedVirtualizationSupported)"
    )
  }

  static func hostFacts(_ capabilities: ProbedCapabilities) -> HostFacts {
    HostFacts(
      logicalCPUCount: capabilities.logicalCPUCount,
      physicalMemoryBytes: capabilities.physicalMemoryBytes,
      minimumAllowedCPUCount: capabilities.minimumAllowedCPUCount,
      maximumAllowedCPUCount: capabilities.maximumAllowedCPUCount,
      minimumAllowedMemoryBytes: capabilities.minimumAllowedMemoryBytes,
      maximumAllowedMemoryBytes: capabilities.maximumAllowedMemoryBytes
    )
  }

  /// Fallback when `vmworker probe` could not run: the machine's own limits, same shape as
  /// `ConfigFile.localFacts()` in `ConfigCommands.swift`.
  static func localHostFacts() -> HostFacts {
    let info = ProcessInfo.processInfo
    return HostFacts(
      logicalCPUCount: info.activeProcessorCount, physicalMemoryBytes: info.physicalMemory,
      minimumAllowedCPUCount: 1, maximumAllowedCPUCount: info.activeProcessorCount,
      minimumAllowedMemoryBytes: ByteSize.mebibytes(128).bytes,
      maximumAllowedMemoryBytes: info.physicalMemory
    )
  }
}
