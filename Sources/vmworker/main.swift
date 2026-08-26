import ArgumentParser
import Foundation
import VirtualizationCore

// Synchronous main on purpose: Virtualization.framework callbacks are delivered on the queue the
// VM was created with (we use main), and Swift ≥6.4 async main no longer drains the Dispatch main
// queue (see tart Root.swift:35-41). `run` will park in dispatchMain() once implemented (M2).
struct VMWorker: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "vmworker",
    abstract: "RunnerVM per-VM worker process. One process owns exactly one VZVirtualMachine.",
    subcommands: [Run.self, Probe.self, DebugCall.self, PrepareNVRAM.self],
    defaultSubcommand: nil
  )
}

struct Probe: ParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Print host virtualization capabilities.")

  @Flag(name: .long, help: "Emit JSON (default is JSON; flag kept for forward compatibility).")
  var json = false

  func run() throws {
    let caps = HostCapabilities.probe()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(caps)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
  }
}

VMWorker.main()
