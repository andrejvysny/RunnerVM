import Foundation

/// Failures owned by `vmworker` supervision and the Virtualization layer.
public enum VMError: RunnerError {
  case specInvalid(reason: String)
  case workerSpawnFailed(reason: String, cause: (any Error & Sendable)?)
  /// hello carried a different instance/generation/nonce/specDigest: a stale worker, never trusted.
  case workerFenced(reason: String)
  case workerUnresponsive(reason: String)
  case workerLockHeldByOtherProcess(path: String)
  case bootTimeout(stage: String)
  case guestStopTimeout
  case forceStopFailed(reason: String)
  case unsupportedGuestOS(GuestOS)
  case hostCapabilityMissing(capability: String)
  case macOSGuestLimitReached(limit: Int)
  /// The M8 macOS identity plumbing: an image that cannot describe its platform, a host that
  /// cannot run it, or a profile sized below what the image will boot with. All permanent.
  case macOSHardwareModelMissing
  case macOSHardwareModelInvalid(reason: String)
  case macOSHardwareModelUnsupported
  case macOSMachineIdentifierInvalid(path: String)
  case macOSAuxiliaryStorageMissing(path: String)
  case macOSProfileCPUTooSmall(requested: Int, minimum: Int)
  case macOSProfileMemoryTooSmall(requestedBytes: UInt64, minimumBytes: UInt64)
  /// A macOS profile whose `resources.disk` is not the image's own size. The host would truncate
  /// `disk.img` up, but nothing inside the guest grows the APFS container into that space
  /// (`agent.resizeDisk` answers `NOT_SUPPORTED` on darwin), so the profile would advertise
  /// capacity the job never receives; asking for less is refused by the instance store anyway.
  case macOSDiskResizeUnsupported(requestedBytes: UInt64, imageBytes: UInt64)
  /// A macOS image that never recorded what it needs to boot. Optional on Linux-era metadata; a
  /// macOS image without it moves the first real compatibility failure out of admission and into
  /// `VZVirtualMachineConfiguration.validate()`.
  case macOSImageMinimumsMissing(field: String)

  public var code: String {
    switch self {
    case .specInvalid: "VM_SPEC_INVALID"
    case .workerSpawnFailed: "VM_WORKER_SPAWN_FAILED"
    case .workerFenced: "VM_WORKER_FENCED"
    case .workerUnresponsive: "VM_WORKER_UNRESPONSIVE"
    case .workerLockHeldByOtherProcess: "VM_WORKER_LOCK_HELD"
    case .bootTimeout: "VM_BOOT_TIMEOUT"
    case .guestStopTimeout: "VM_GUEST_STOP_TIMEOUT"
    case .forceStopFailed: "VM_FORCE_STOP_FAILED"
    case .unsupportedGuestOS: "VM_UNSUPPORTED_GUEST_OS"
    case .hostCapabilityMissing: "VM_HOST_CAPABILITY_MISSING"
    case .macOSGuestLimitReached: "VM_MACOS_GUEST_LIMIT_REACHED"
    case .macOSHardwareModelMissing: "VM_MACOS_HARDWARE_MODEL_MISSING"
    case .macOSHardwareModelInvalid: "VM_MACOS_HARDWARE_MODEL_INVALID"
    case .macOSHardwareModelUnsupported: "VM_MACOS_HARDWARE_MODEL_UNSUPPORTED"
    case .macOSMachineIdentifierInvalid: "VM_MACOS_MACHINE_IDENTIFIER_INVALID"
    case .macOSAuxiliaryStorageMissing: "VM_MACOS_AUXILIARY_STORAGE_MISSING"
    case .macOSProfileCPUTooSmall: "VM_MACOS_PROFILE_CPU_TOO_SMALL"
    case .macOSProfileMemoryTooSmall: "VM_MACOS_PROFILE_MEMORY_TOO_SMALL"
    case .macOSDiskResizeUnsupported: "VM_MACOS_DISK_RESIZE_UNSUPPORTED"
    case .macOSImageMinimumsMissing: "VM_MACOS_IMAGE_MINIMUMS_MISSING"
    }
  }

  public var message: String {
    switch self {
    case .specInvalid(let reason): "VM specification rejected: \(reason)"
    case .workerSpawnFailed(let reason, _): "could not spawn vmworker: \(reason)"
    case .workerFenced(let reason): "worker handshake fenced: \(reason)"
    case .workerUnresponsive(let reason): "vmworker did not respond: \(reason)"
    case .workerLockHeldByOtherProcess(let path): "worker lock still held: \(path)"
    case .bootTimeout(let stage): "timed out waiting for \(stage)"
    case .guestStopTimeout: "guest did not stop before the graceful shutdown timeout"
    case .forceStopFailed(let reason): "force stop failed: \(reason)"
    case .unsupportedGuestOS(let os): "guest OS \(os.rawValue) is not supported on this host"
    case .hostCapabilityMissing(let capability): "host lacks required capability: \(capability)"
    case .macOSGuestLimitReached(let limit): "macOS guest limit of \(limit) reached"
    case .macOSHardwareModelMissing:
      "macOS instance has no hardware model; the image metadata must carry macos.hardwareModel"
    case .macOSHardwareModelInvalid(let reason): "macOS hardware model rejected: \(reason)"
    case .macOSHardwareModelUnsupported: "this host cannot run the image's macOS hardware model"
    case .macOSMachineIdentifierInvalid(let path): "macOS machine identifier unusable: \(path)"
    case .macOSAuxiliaryStorageMissing(let path): "macOS auxiliary storage is missing: \(path)"
    case .macOSProfileCPUTooSmall(let requested, let minimum):
      "profile requests \(requested) vCPU but the image requires at least \(minimum)"
    case .macOSProfileMemoryTooSmall(let requested, let minimum):
      "profile requests \(ByteSize(bytes: requested)) of memory but the image requires at least "
        + "\(ByteSize(bytes: minimum))"
    case .macOSDiskResizeUnsupported(let requested, let image):
      "profile requests \(ByteSize(bytes: requested)) of disk but macOS guests cannot resize their "
        + "APFS container in this release; set resources.disk to the image's own "
        + "\(ByteSize(bytes: image)) exactly (or rebuild the image at the size you want)"
    case .macOSImageMinimumsMissing(let field):
      "macOS image metadata has no macos.\(field); re-import it with the value the restore image "
        + "or the source VM reports, so a profile too small to boot is refused at admission"
    }
  }

  public var retryable: Bool {
    switch self {
    // A boot/stop timeout or a busy host is worth another instance; a bad spec or missing
    // capability will fail identically forever.
    case .workerSpawnFailed, .workerUnresponsive, .bootTimeout, .guestStopTimeout,
         .workerLockHeldByOtherProcess, .macOSGuestLimitReached:
      true
    case .specInvalid, .workerFenced, .forceStopFailed, .unsupportedGuestOS, .hostCapabilityMissing,
         .macOSHardwareModelMissing, .macOSHardwareModelInvalid, .macOSHardwareModelUnsupported,
         .macOSMachineIdentifierInvalid, .macOSAuxiliaryStorageMissing, .macOSProfileCPUTooSmall,
         .macOSProfileMemoryTooSmall, .macOSDiskResizeUnsupported, .macOSImageMinimumsMissing:
      false
    }
  }

  public var underlying: (any Error)? {
    if case .workerSpawnFailed(_, let cause) = self { return cause }
    return nil
  }
}
