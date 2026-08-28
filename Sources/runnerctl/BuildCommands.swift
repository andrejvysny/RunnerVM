import ArgumentParser
import DaemonAPI
import Foundation

/// `runnerctl build list|show|log|cancel` -- inspecting and controlling image builds already
/// under way. Starting one is `runnerctl image build` (`ImageBuildCommand.swift`); this command
/// only ever reads or cancels an existing `image_builds` row.
struct BuildCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "build",
    abstract: "Inspect and control in-daemon image builds.",
    subcommands: [List.self, Show.self, Log.self, Cancel.self])

  @OptionGroup var options: GlobalOptions
}

extension BuildCommand {
  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "list", abstract: "List image builds known to the daemon.")

    @OptionGroup var options: GlobalOptions

    func run() async throws {
      let response = try await options.withDaemon { try await $0.buildList() }
      switch options.output {
      case .json: try JSONOut.print(response)
      case .human: print(BuildCommand.table(response.builds))
      }
    }
  }

  struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "show", abstract: "Show one image build in full.")

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Build id.")
    var id: String

    func run() async throws {
      let build = try await options.withDaemon { try await $0.buildGet(buildId: id) }
      switch options.output {
      case .json: try JSONOut.print(build)
      case .human: print(Table.fields(BuildCommand.fields(build), indent: ""))
      }
    }
  }

  struct Log: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "log", abstract: "Print (or tail) a build's log.")

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Build id.")
    var id: String

    @Option(name: .long, help: "Byte offset into the log to start from.")
    var offset: Int64 = 0

    @Flag(name: .long, help: "Keep polling until the build reaches a terminal state.")
    var follow = false

    func run() async throws {
      try await options.withDaemon { client in
        var offset = self.offset
        while true {
          let chunk = try await client.buildLog(buildId: id, offset: offset)
          if !chunk.data.isEmpty { FileHandle.standardOutput.write(Data(chunk.data.utf8)) }
          offset = chunk.nextOffset
          guard follow, !chunk.done else { return }
          try await Task.sleep(for: .milliseconds(500))
        }
      }
    }
  }

  struct Cancel: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "cancel", abstract: "Cancel a build that has not yet reached a terminal state.")

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Build id.")
    var id: String

    func run() async throws {
      let response = try await options.withDaemon { try await $0.buildCancel(buildId: id) }
      switch options.output {
      case .json: try JSONOut.print(response)
      case .human: print("\(response.buildId) \(response.state)")
      }
    }
  }

  static func table(_ builds: [BuildInfoDTO]) -> String {
    Table.render(
      headers: ["ID", "KIND", "NAME", "STATE", "STEP", "FROM", "AGE"],
      rows: builds.map {
        [
          String($0.buildId.prefix(8)), kind($0), Format.optional($0.name), $0.state, step($0),
          $0.fromReference, age($0.createdAt),
        ]
      })
  }

  /// A daemon predating the field reports no kind at all, and every build on one is a Runnerfile
  /// build -- so the column is honest rather than blank in that case.
  private static func kind(_ build: BuildInfoDTO) -> String {
    build.kind ?? "runnerfile"
  }

  static func fields(_ build: BuildInfoDTO) -> [(String, String)] {
    var rows: [(String, String)] = [
      ("id", build.buildId),
      ("kind", kind(build)),
      ("name", Format.optional(build.name)),
      ("state", build.state),
      ("from", "\(build.fromKind): \(build.fromReference)"),
      ("base digest", Format.optional(build.baseDigest)),
      // A `macosProvision` build has no Runnerfile: `recipe path` is the provisioning script it
      // shelled out to, and its sha256 pins exactly which version of it ran.
      ("recipe path", build.recipePath),
      ("recipe sha256", Format.shortDigest(build.recipeSHA256)),
      ("context path", build.contextPath),
      ("context sha256", Format.optional(build.contextSHA256)),
      ("cpu", "\(build.cpuCount)"),
      ("memory", Format.bytes(build.memoryBytes)),
      ("disk", Format.bytes(build.diskBytes)),
      ("disk reserved", Format.bytes(build.diskReservationBytes)),
      ("timeout", Format.duration(seconds: build.timeoutMs / 1_000)),
      ("step", step(build)),
      ("instruction", Format.optional(build.currentInstruction)),
      ("image digest", Format.optional(build.imageDigest)),
      ("operation", Format.optional(build.operationId)),
      ("push reference", Format.optional(build.pushReference)),
      ("push operation", Format.optional(build.pushOperationId)),
      ("log path", build.logPath),
      ("failure code", Format.optional(build.failureCode)),
      ("failure detail", Format.optional(build.failureMessage)),
      ("created", build.createdAt),
      ("started", Format.optional(build.startedAt)),
      ("finished", Format.optional(build.finishedAt)),
      ("updated", build.updatedAt),
    ]
    // Only on a managed provisioning run, where they are the whole point of the build.
    if let managedName = build.managedName {
      rows.append(("managed image", managedName))
      rows.append(("source digest", Format.optional(build.sourceDigest)))
    }
    // Only when set, so its presence is the signal: this build's VM could not be proven dead, and
    // it is still holding host capacity because of it.
    if let since = build.recoverySince {
      rows.append(("Recovery pending since", since))
    }
    // Labelled as non-secret on purpose: the same values sit in the image provenance and in any
    // pushed OCI config, and an operator reading this table should know that.
    if let args = build.args, !args.isEmpty {
      let rendered = args.keys.sorted().map { "\($0)=\(args[$0] ?? "")" }.joined(separator: " ")
      rows.append(("args (non-secret, recorded in provenance)", rendered))
    }
    return rows
  }

  private static func step(_ build: BuildInfoDTO) -> String {
    build.totalSteps > 0 ? "\(build.currentStep)/\(build.totalSteps)" : "-"
  }

  /// Wall-clock age, matching `VM.age`.
  private static func age(_ createdAt: String) -> String {
    guard let created = RFC3339.date(from: createdAt) else { return "-" }
    return Format.duration(seconds: Int64(max(0, Date().timeIntervalSince(created))))
  }
}
