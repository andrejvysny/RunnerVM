import Foundation
import RunnerCore
import Testing

private struct Cause: Error, Sendable, CustomStringConvertible {
  var description: String { "root cause" }
}

@Suite struct RunnerErrorTests {
  @Test func specExamplesClassifyAsDocumented() {
    #expect(GitHubControlError.rateLimited(retryAfter: nil).code == "GITHUB_RATE_LIMITED")
    #expect(GitHubControlError.rateLimited(retryAfter: nil).retryable)
    #expect(ImageError.incompatibleHost(reason: "arch").code == "IMAGE_INCOMPATIBLE_HOST")
    #expect(!ImageError.incompatibleHost(reason: "arch").retryable)
  }

  @Test func descriptionIncludesCodeMessageAndCause() {
    let error = VMError.workerSpawnFailed(reason: "posix_spawn EAGAIN", cause: Cause())
    #expect(error.description.contains("VM_WORKER_SPAWN_FAILED"))
    #expect(error.description.contains("posix_spawn EAGAIN"))
    #expect(error.description.contains("root cause"))
    #expect(error.underlying != nil)
  }

  @Test func underlyingDefaultsToNil() {
    #expect(VMError.guestStopTimeout.underlying == nil)
    #expect(SchedulerError.hostOffline.underlying == nil)
    #expect(GuestAgentError.unhealthy(reason: "x").underlying == nil)
  }

  @Test func gitHubErrorClassRetryabilityMatchesSpec() {
    let retryable: Set<GitHubErrorClass> = [.rateLimited, .transientServer, .transport]
    for errorClass in GitHubErrorClass.allCases {
      #expect(errorClass.retryable == retryable.contains(errorClass), "\(errorClass.rawValue)")
    }
    #expect(GitHubErrorClass.allCases.count == 9)
  }

  @Test func gitHubErrorsMapOntoTheirClass() {
    #expect(GitHubControlError.authenticationFailed(reason: "bad pat").errorClass == .authentication)
    #expect(GitHubControlError.notFound(resource: "org").errorClass == .notFound)
    #expect(GitHubControlError.transport(cause: nil).errorClass == .transport)
    #expect(GitHubControlError.scaleSetSessionExpired(scaleSetName: "s").errorClass == .transientServer)
    #expect(GitHubControlError.scaleSetSessionExpired(scaleSetName: "s").retryable)
    #expect(!GitHubControlError.jitGenerationFailed(reason: "boom").retryable)
  }

  @Test func retryAfterIsExposedOnlyForRateLimits() {
    #expect(GitHubControlError.rateLimited(retryAfter: .seconds(60)).retryAfter == .seconds(60))
    #expect(GitHubControlError.conflict(reason: "x").retryAfter == nil)
    #expect(GitHubControlError.rateLimited(retryAfter: .seconds(60)).message.contains("1m"))
  }

  @Test func everyCodeIsUpperSnakeCase() {
    let errors: [any RunnerError] = [
      VMError.specInvalid(reason: "x"),
      VMError.macOSGuestLimitReached(limit: 2),
      ImageError.pullTimeout(reference: "r"),
      ImageError.diskSmallerThanImage(requestedBytes: 1, imageBytes: 2),
      GitHubControlError.permanentConfiguration(reason: "x"),
      GitHubControlError.publicRepositoryNotAllowed(scope: "s"),
      SchedulerError.insufficientMemory(requestedBytes: 1, availableBytes: 0),
      GuestAgentError.bootIDChanged(previous: "a", current: "b"),
      PersistenceError.staleWrite(entity: "instance", id: "1", expectedState: "idle", actualState: "busy"),
      ConfigurationError.unsupportedVersion(found: 2, supported: 1),
      StateTransitionError(machine: "InstanceState", from: "idle", to: "deleted"),
    ]
    for error in errors {
      #expect(error.code.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" }, "\(error.code)")
      #expect(!error.message.isEmpty, "\(error.code)")
    }
  }

  @Test func retryabilitySplitsTransientFromPermanent() {
    #expect(VMError.bootTimeout(stage: "agent").retryable)
    #expect(!VMError.workerFenced(reason: "generation").retryable)
    #expect(PersistenceError.busy(reason: "locked").retryable)
    #expect(!PersistenceError.corrupted(reason: "malformed").retryable)
    #expect(SchedulerError.insufficientCPU(requested: 8, availableBudget: 4).retryable)
    #expect(!SchedulerError.unknownProfile(name: "x").retryable)
    #expect(!ConfigurationError.applyConflict(reason: "x").retryable)
    #expect(GuestAgentError.notReady(reason: "booting").retryable)
    #expect(!GuestAgentError.cleanupFailed(reason: "docker").retryable)
  }

  /// M8.1 pinned these codes into `failure.json` and the operator-facing surfaces; every one is a
  /// permanent misconfiguration, so none may be graded retryable.
  @Test func macOSPlatformErrorsAreStableAndPermanent() {
    let expected: [(VMError, String)] = [
      (.macOSHardwareModelMissing, "VM_MACOS_HARDWARE_MODEL_MISSING"),
      (.macOSHardwareModelInvalid(reason: "not base64"), "VM_MACOS_HARDWARE_MODEL_INVALID"),
      (.macOSHardwareModelUnsupported, "VM_MACOS_HARDWARE_MODEL_UNSUPPORTED"),
      (.macOSMachineIdentifierInvalid(path: "/i/machine-identifier.bin"),
       "VM_MACOS_MACHINE_IDENTIFIER_INVALID"),
      (.macOSAuxiliaryStorageMissing(path: "/i/nvram.bin"), "VM_MACOS_AUXILIARY_STORAGE_MISSING"),
      (.macOSProfileCPUTooSmall(requested: 4, minimum: 6), "VM_MACOS_PROFILE_CPU_TOO_SMALL"),
      (.macOSProfileMemoryTooSmall(requestedBytes: 1, minimumBytes: 2),
       "VM_MACOS_PROFILE_MEMORY_TOO_SMALL"),
    ]
    for (error, code) in expected {
      #expect(error.code == code)
      #expect(!error.retryable, "\(code)")
      #expect(error.underlying == nil, "\(code)")
      #expect(!error.message.isEmpty, "\(code)")
    }
  }

  @Test func macOSSizingMessagesNameBothFigures() {
    let cpu = VMError.macOSProfileCPUTooSmall(requested: 4, minimum: 6)
    #expect(cpu.message == "profile requests 4 vCPU but the image requires at least 6")

    let memory = VMError.macOSProfileMemoryTooSmall(
      requestedBytes: ByteSize.gibibytes(2).bytes, minimumBytes: ByteSize.gibibytes(8).bytes)
    #expect(memory.message.contains("2GiB"))
    #expect(memory.message.contains("8GiB"))
  }

  @Test func byteSizesAppearHumanReadableInMessages() {
    let error = SchedulerError.insufficientMemory(
      requestedBytes: ByteSize.gibibytes(12).bytes, availableBytes: ByteSize.gibibytes(4).bytes
    )
    #expect(error.message.contains("12GiB"))
    #expect(error.message.contains("4GiB"))
  }
}
