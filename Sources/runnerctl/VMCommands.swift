import ArgumentParser
import DaemonAPI
import Foundation
import RunnerCore

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
      Metrics.self, SelfTest.self, SSH.self,
    ])

  @OptionGroup var options: GlobalOptions
}

extension VM {
  struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "create", abstract: "Create and boot one instance of a profile.",
      discussion: """
        With --pinned the instance is created for maintenance rather than for jobs: the scheduler \
        never cancels, reaps, recycles or assigns work to it, so it survives scale-to-zero for as \
        long as its --ttl. It still holds real cpu, memory and disk, which is why the ttl is \
        mandatory and capped at 24h — nothing else ever takes a pinned VM away.
        """)

    @OptionGroup var options: GlobalOptions

    @Option(name: .long, help: "Profile name.")
    var profile: String

    @Flag(
      name: .long,
      help: "Create a pinned maintenance instance the scheduler can never cancel.")
    var pinned = false

    @Option(
      name: .long,
      help: ArgumentHelp(
        "How long a --pinned instance lives before the daemon deletes it (10s…24h).",
        discussion: "Duration syntax, e.g. 90s, 15m, 1h30m. Defaults to 15m with --pinned."))
    var ttl: String?

    @Option(
      name: .long,
      help: "Boot this image reference instead of the profile's. Requires --pinned.")
    var image: String?

    func run() async throws {
      let ttlMs = try Create.ttlMilliseconds(ttl, pinned: pinned)
      let instance = try await options.withDaemon {
        try await $0.instanceCreate(
          profile: profile, purpose: pinned ? InstancePurpose.maintenance.rawValue : nil,
          ttlMs: ttlMs, imageOverride: image)
      }
      switch options.output {
      case .json: try JSONOut.print(instance)
      case .human: print(Table.fields(VM.fields(instance), indent: ""))
      }
    }

    /// `--ttl` is only meaningful with `--pinned`; naming one without the other is a mistake worth
    /// reporting locally rather than sending to the daemon to be refused.
    static func ttlMilliseconds(_ text: String?, pinned: Bool) throws -> Int64? {
      guard pinned else {
        guard text == nil else {
          throw ValidationError("--ttl only applies to --pinned instances")
        }
        return nil
      }
      guard let text else { return MaintenanceTTL.defaultMs }
      guard let value = try? DurationValue(parsing: text) else {
        throw ValidationError("invalid --ttl '\(text)'; use a duration such as 15m or 1h30m")
      }
      return value.milliseconds
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

  /// PURPOSE only appears once a maintenance instance exists, the way `runnerctl status` only
  /// prints its `Builds:` line when the daemon has one to report: the ordinary fleet is all
  /// runners, and a column that always says "runner" is a column nobody reads.
  static func table(_ instances: [InstanceInfoDTO]) -> String {
    let showPurpose = instances.contains { $0.isMaintenance }
    let headers = ["ID", "NAME", "PROFILE", "STATE", "VM", "PID", "GEN", "CPU", "MEMORY"]
    return Table.render(
      headers: showPurpose ? headers + ["PURPOSE"] : headers,
      rows: instances.map { instance in
        let row = [
          String(instance.id.prefix(8)), instance.name, instance.profile, instance.state,
          Format.optional(instance.vmState), instance.workerPid.map(String.init) ?? "-",
          "\(instance.workerGeneration)", "\(instance.cpuCount)",
          Format.bytes(instance.memoryBytes),
        ]
        guard showPurpose else { return row }
        return row + [instance.purpose ?? InstancePurpose.runner.rawValue]
      })
  }

  static func fields(_ instance: InstanceInfoDTO) -> [(String, String)] {
    var rows: [(String, String)] = [
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
    // Only for a pinned VM: on an ordinary runner both lines are noise that says nothing.
    if instance.isMaintenance {
      rows.append(("purpose", instance.purpose ?? InstancePurpose.maintenance.rawValue))
      rows.append(("pinned until", Format.optional(instance.pinnedUntil)))
    }
    return rows
  }

  /// Wall-clock age, which is what `reuse.maxAge` is measured against.
  private static func age(_ createdAt: String) -> String {
    guard let created = RFC3339.date(from: createdAt) else { return "-" }
    return Format.duration(seconds: Int64(max(0, Date().timeIntervalSince(created))))
  }
}
