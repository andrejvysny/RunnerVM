import Foundation
import Virtualization

/// Coarse lifecycle of a guest, as reported over the worker protocol.
///
/// Raw values are the wire strings of `WorkerProtocol.WorkerVMState`; the two enums are kept
/// separate because VirtualizationCore must not depend on the RPC stack (see Package.swift).
public enum VMRunState: String, Sendable, Hashable, CaseIterable {
  case stopped, starting, running, stopping, error
}

public enum VMRuntimeEvent: Sendable, Hashable {
  case stateChanged(VMRunState)
  case guestDidStop
  case stoppedWithError(String)
}

public enum VMRuntimeError: Error, CustomStringConvertible {
  case noSocketDevice
  case notRunning(VMRunState)
  case posix(operation: String, errno: Int32)

  public var description: String {
    switch self {
    case .noSocketDevice: "VM has no virtio socket device"
    case .notRunning(let state): "VM is \(state.rawValue), not running"
    case .posix(let operation, let code): "\(operation) failed: \(String(cString: strerror(code)))"
    }
  }
}

/// Owns exactly one `VZVirtualMachine`.
///
/// Virtualization.framework delivers every callback on the queue the VM was created with and
/// rejects use from any other queue, so the VM is created with `DispatchQueue.main` and the whole
/// type is pinned to the main actor. vmworker parks in `dispatchMain()` to service that queue.
@MainActor
public final class VMRuntime {
  private let vm: VZVirtualMachine
  private let delegate: VMRuntimeDelegate
  private var observation: NSKeyValueObservation?
  private let continuation: AsyncStream<VMRuntimeEvent>.Continuation
  /// Single-consumer stream of lifecycle transitions.
  public let events: AsyncStream<VMRuntimeEvent>
  public private(set) var lastError: String?

  public init(configuration: VZVirtualMachineConfiguration) {
    let vm = VZVirtualMachine(configuration: configuration, queue: .main)
    self.vm = vm
    self.delegate = VMRuntimeDelegate()
    (events, continuation) = AsyncStream<VMRuntimeEvent>.makeStream(bufferingPolicy: .unbounded)
    delegate.owner = self
    vm.delegate = delegate
    observation = vm.observe(\.state, options: [.new]) { [weak self] _, _ in
      MainActor.assumeIsolated { self?.emitStateChange() }
    }
  }

  public var state: VMRunState { Self.map(vm.state) }

  /// Pure translation of the framework's state machine, so the mapping is testable without the
  /// virtualization entitlement.
  public nonisolated static func map(_ state: VZVirtualMachine.State) -> VMRunState {
    switch state {
    case .stopped: return .stopped
    case .starting: return .starting
    case .running: return .running
    // Pause is never requested by RunnerVM; if the framework reports it, the guest is still
    // resident and the instance is still occupying capacity.
    case .pausing, .paused, .resuming: return .running
    case .stopping: return .stopping
    case .error: return .error
    // Save/restore only occur around suspend-to-disk, which behaves like a boot to callers.
    case .saving, .restoring: return .starting
    @unknown default: return .error
    }
  }

  public func start() async throws {
    try await vm.start()
  }

  /// ACPI shutdown request. Returns false when the framework refuses to deliver it (guest not
  /// running, or no ACPI support), in which case only `forceStop()` remains.
  @discardableResult
  public func requestStop() throws -> Bool {
    guard vm.canRequestStop else { return false }
    try vm.requestStop()
    return true
  }

  public func forceStop() async throws {
    guard vm.state != .stopped else { return }
    try await vm.stop()
  }

  /// Opens one vsock connection to `port` in the guest and hands back an owned file descriptor.
  ///
  /// The descriptor is `dup`ed: `VZVirtioSocketConnection` closes its own descriptor when it is
  /// deallocated, and the caller (NIO, or a relay thread) needs a descriptor whose lifetime it
  /// controls. Both descriptors refer to the same socket, so exactly one close happens per side.
  public func connectToGuest(port: UInt32) async throws -> CInt {
    let current = Self.map(vm.state)
    guard current == .running else { throw VMRuntimeError.notRunning(current) }
    guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else {
      throw VMRuntimeError.noSocketDevice
    }
    let connection = try await device.connect(toPort: port)
    let descriptor = dup(connection.fileDescriptor)
    guard descriptor >= 0 else { throw VMRuntimeError.posix(operation: "dup", errno: errno) }
    return descriptor
  }

  public func finishEvents() {
    continuation.finish()
  }

  // MARK: - Callbacks

  private func emitStateChange() {
    continuation.yield(.stateChanged(Self.map(vm.state)))
  }

  fileprivate func guestDidStop() {
    continuation.yield(.guestDidStop)
  }

  fileprivate func stopped(with message: String) {
    lastError = message
    continuation.yield(.stoppedWithError(message))
  }
}

/// `VZVirtualMachineDelegate` cannot be an actor, and the framework invokes it on the VM's queue —
/// which is the main queue, hence `assumeIsolated`.
private final class VMRuntimeDelegate: NSObject, VZVirtualMachineDelegate {
  weak var owner: VMRuntime?

  func guestDidStop(_ virtualMachine: VZVirtualMachine) {
    let runtime = owner
    MainActor.assumeIsolated { runtime?.guestDidStop() }
  }

  func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
    let runtime = owner
    let message = String(describing: error)
    MainActor.assumeIsolated { runtime?.stopped(with: message) }
  }

  func virtualMachine(
    _ virtualMachine: VZVirtualMachine, networkDevice: VZNetworkDevice,
    attachmentWasDisconnectedWithError error: any Error
  ) {
    let runtime = owner
    let message = "network attachment disconnected: \(error)"
    MainActor.assumeIsolated { runtime?.stopped(with: message) }
  }
}
