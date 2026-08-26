import ArgumentParser
import Dispatch
import Foundation
import RPC
import VirtualizationCore

/// `vmworker debug-call` — one worker-protocol request from the shell. Hidden: it is an operator
/// and test tool, not part of the runnerd contract.
struct DebugCall: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "debug-call", abstract: "Send one worker RPC request to a vmworker socket.",
    shouldDisplay: false)

  @Option(name: .long) var socket: String
  @Option(name: .long) var method: String
  @Option(name: .long, help: "JSON object payload; defaults to {}.") var payload: String = "{}"
  @Option(name: .long, help: "Call deadline in seconds.") var timeout: Int = 15

  func run() throws {
    let request = try StrictJSON.parse(payload)
    let url = URL(fileURLWithPath: socket)
    let seconds = timeout
    let method = self.method
    let result = Box()
    let done = DispatchSemaphore(value: 0)
    Task {
      do {
        let client = try await RPCClient.connect(protocol: .worker, socketPath: url)
        let response = try await client.call(
          method: method, payload: request, deadline: .seconds(seconds))
        result.value = response.encodedString()
        await client.close()
      } catch {
        result.failure = "\(error)"
      }
      done.signal()
    }
    done.wait()
    if let failure = result.failure {
      FileHandle.standardError.write(Data("\(failure)\n".utf8))
      throw ExitCode(1)
    }
    print(result.value ?? "{}")
  }
}

/// The call runs on the cooperative pool while `run()` blocks on a semaphore, so the result needs
/// a reference the two sides share.
private final class Box: @unchecked Sendable {
  var value: String?
  var failure: String?
}

/// `vmworker prepare-nvram` — creates an empty EFI variable store. InstanceStore owns this in
/// production; the subcommand exists so an instance directory can be assembled by hand.
struct PrepareNVRAM: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "prepare-nvram", abstract: "Create an EFI variable store at PATH.",
    shouldDisplay: false)

  @Argument var path: String

  func run() throws {
    try LinuxVMPlatform.createVariableStore(at: URL(fileURLWithPath: path))
    print(path)
  }
}
