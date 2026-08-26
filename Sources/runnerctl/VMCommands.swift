import ArgumentParser
import DaemonAPI
import Foundation

struct VM: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "vm",
    abstract: "Create and control VM instances directly (debug surface).",
    discussion: """
      In production the scheduler owns instance lifecycle; these commands exist to exercise a \
      profile end to end without GitHub demand.
      """,
    subcommands: [
      Create.self, List.self, Show.self, Stop.self, Delete.self, Taint.self, Exec.self,
      Metrics.self, SSH.self,
    ])

  @OptionGroup var options: GlobalOptions
}

extension VM {
  struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "create", abstract: "Create and boot one instance of a profile.")

    @OptionGroup var options: GlobalOptions

    @Option(name: .long, help: "Profile name.")
    var profile: String

    func run() async throws {
      let instance = try await options.withDaemon { try await $0.instanceCreate(profile: profile) }
      switch options.output {
      case .json: try JSONOut.print(instance)
      case .human: print(Table.fields(VM.fields(instance), indent: ""))
      }
    }
  }

  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "list", abstract: "List instances known to the daemon.")

    @OptionGroup var options: GlobalOptions

    @Flag(name: .long, help: "Include instances that have already been deleted.")
    var all = false

    func run() async throws {
      let response = try await options.withDaemon { try await $0.instanceList() }
      let instances = all ? response.instances : response.instances.filter { $0.state != "deleted" }
      switch options.output {
      case .json: try JSONOut.print(InstanceListResponse(instances: instances))
      case .human: print(VM.table(instances))
      }
    }
  }

  struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "show", abstract: "Show one instance in full.")

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Instance id.")
    var id: String

    func run() async throws {
      let instance = try await options.withDaemon { try await $0.instanceGet(id: id) }
      switch options.output {
      case .json: try JSONOut.print(instance)
      case .human: print(Table.fields(VM.fields(instance), indent: ""))
      }
    }
  }

  struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "stop", abstract: "Shut the guest down and stop its worker.")

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Instance id.")
    var id: String

    @Flag(name: .long, help: "Skip the ACPI request and pull the plug.")
    var force = false

    func run() async throws {
      let instance = try await options.withDaemon {
        try await $0.instanceStop(id: id, force: force)
      }
      switch options.output {
      case .json: try JSONOut.print(instance)
      case .human: print("\(instance.id) \(instance.state)")
      }
    }
  }

  struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "delete",
      abstract: "Stop the instance if needed, then remove its directory and unpin its image.")

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Instance id.")
    var id: String

    func run() async throws {
      let instance = try await options.withDaemon { try await $0.instanceDelete(id: id) }
      switch options.output {
      case .json: try JSONOut.print(instance)
      case .human: print("\(instance.id) \(instance.state)")
      }
    }
  }

  struct Taint: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "taint",
      abstract: "Mark an instance untrustworthy so it never runs another job.",
      discussion: """
        An idle instance is recycled immediately; one that is running a job is retired as soon \
        as the job ends (spec 126).
        """)

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Instance id.")
    var id: String

    @Option(name: .long, help: "Why the instance may no longer be trusted.")
    var reason: String = "MANUAL"

    func run() async throws {
      let instance = try await options.withDaemon {
        try await $0.instanceTaint(id: id, reason: reason)
      }
      switch options.output {
      case .json: try JSONOut.print(instance)
      case .human: print("\(instance.id) \(instance.state) tainted=\(reason)")
      }
    }
  }

  static func table(_ instances: [InstanceInfoDTO]) -> String {
    Table.render(
      headers: ["ID", "NAME", "PROFILE", "STATE", "VM", "PID", "GEN", "CPU", "MEMORY"],
      rows: instances.map {
        [
          String($0.id.prefix(8)), $0.name, $0.profile, $0.state, Format.optional($0.vmState),
          $0.workerPid.map(String.init) ?? "-", "\($0.workerGeneration)", "\($0.cpuCount)",
          Format.bytes($0.memoryBytes),
        ]
      })
  }

  static func fields(_ instance: InstanceInfoDTO) -> [(String, String)] {
    [
      ("id", instance.id),
      ("name", instance.name),
      ("profile", instance.profile),
      ("image", Format.shortDigest(instance.imageDigest)),
      ("state", instance.state),
      ("lifecycle", instance.lifecycle),
      ("vm state", Format.optional(instance.vmState)),
      ("worker pid", instance.workerPid.map(String.init) ?? "-"),
      ("generation", "\(instance.workerGeneration)"),
      ("cpu", "\(instance.cpuCount)"),
      ("memory", Format.bytes(instance.memoryBytes)),
      ("disk", Format.bytes(instance.diskBytes)),
      ("disk reserved", Format.bytes(instance.diskReservationBytes)),
      ("created", instance.createdAt),
      ("age", age(instance.createdAt)),
      ("started", Format.optional(instance.startedAt)),
      ("agent ready", Format.optional(instance.agentReadyAt)),
      ("boot id", Format.optional(instance.bootId)),
      ("jobs consumed", "\(instance.jobsConsumed)"),
      ("tainted", instance.tainted ? Format.optional(instance.taintReason) : "no"),
      ("retire after session", Format.yesNo(instance.retireAfterSession)),
      ("stopped", Format.optional(instance.stoppedAt)),
      ("failure", Format.optional(instance.failureCode)),
      ("failure detail", Format.optional(instance.failureMessage)),
    ]
  }

  /// Wall-clock age, which is what `reuse.maxAge` is measured against.
  private static func age(_ createdAt: String) -> String {
    guard let created = RFC3339.date(from: createdAt) else { return "-" }
    return Format.duration(seconds: Int64(max(0, Date().timeIntervalSince(created))))
  }
}
