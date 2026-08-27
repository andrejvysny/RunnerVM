import Foundation
import RunnerCore

/// Host memory budget (spec WP9): can this host structurally fit its largest configured workload
/// after `host.reserve.memory`, and is there currently enough free RAM for it right now.
extension DoctorChecks {
  static func freeMemory(
    config: RunnerConfiguration?, capabilities: ProbedCapabilities?
  ) -> DoctorCheck {
    let id = "free_memory"
    let title = "Free memory"
    guard let config else {
      return DoctorCheck(id: id, title: title, status: .warn, detail: "no valid --config; skipped")
    }
    let physical = capabilities?.physicalMemoryBytes ?? ProcessInfo.processInfo.physicalMemory
    let largestProfile = config.profiles.map(\.resources.memoryBytes).max() ?? 0
    let requirement = DoctorCapacity.Requirement(
      physicalBytes: physical, reserveBytes: config.host.reserve.memoryBytes,
      largestProfileMemoryBytes: largestProfile, buildMemoryBytes: config.build.memoryBytes
    )
    guard requirement.physicallyCapable else {
      let needed = max(largestProfile, config.build.memoryBytes)
      return DoctorCheck(
        id: id, title: title, status: .fail,
        detail: "\(Format.bytes(physical)) physical minus \(Format.bytes(requirement.reserveBytes)) "
          + "host.reserve.memory cannot fit the largest configured workload "
          + "(\(Format.bytes(needed)) needed); lower host.reserve.memory, a profile's "
          + "resources.memory, build.memoryBytes, or add RAM"
      )
    }
    let probe = runProcess("/usr/bin/vm_stat", [])
    guard probe.exitCode == 0,
          let free = DoctorCapacity.freeMemoryBytes(fromVMStatOutput: probe.stdout)
    else {
      return DoctorCheck(
        id: id, title: title, status: .warn,
        detail: "\(Format.bytes(physical)) physical is enough for the configured workload, but "
          + "current free memory could not be read from vm_stat"
      )
    }
    guard DoctorCapacity.hasHeadroom(freeBytes: free, neededBytes: requirement.neededBytes) else {
      return DoctorCheck(
        id: id, title: title, status: .warn,
        detail: "\(Format.bytes(free)) free right now, below the "
          + "\(Format.bytes(requirement.neededBytes)) this host needs at peak (reserve + largest "
          + "workload); check for memory pressure from other processes"
      )
    }
    return DoctorCheck(
      id: id, title: title, status: .ok,
      detail: "\(Format.bytes(physical)) physical, \(Format.bytes(free)) free now, "
        + "\(Format.bytes(requirement.neededBytes)) needed at peak"
    )
  }
}
