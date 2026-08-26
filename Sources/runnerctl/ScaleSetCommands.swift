import ArgumentParser
import DaemonAPI
import Foundation

struct ScaleSet: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "scaleset",
    abstract: "Inspect the GitHub runner scale sets behind each profile.",
    discussion: """
      One profile maps to one scale set named runnervm-<profile>. The daemon holds one long-poll \
      message session per scale set; CURSOR is the last acknowledged message id in the current \
      session generation, and ADVERTISED is what the next poll reports as the maximum capacity \
      this host can reach.
      """,
    subcommands: [List.self])

  @OptionGroup var options: GlobalOptions
}

extension ScaleSet {
  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "list", abstract: "List scale sets, sessions and demand per profile.")

    @OptionGroup var options: GlobalOptions

    func run() async throws {
      let response = try await options.withDaemon { try await $0.scaleSetList() }
      switch options.output {
      case .json: try JSONOut.print(response)
      case .human: print(ScaleSet.table(response.scaleSets))
      }
    }
  }

  static func table(_ rows: [ScaleSetSummary]) -> String {
    guard !rows.isEmpty else { return "  (no profiles)" }
    return Table.render(
      headers: [
        "PROFILE", "SCALE SET", "ID", "STATE", "SESSION", "GEN", "CURSOR", "DEMAND", "ADVERTISED",
        "HEALTH",
      ],
      rows: rows.map {
        [
          $0.profile,
          Format.optional($0.name),
          $0.githubScaleSetId.map(String.init) ?? "-",
          $0.state,
          $0.sessionState,
          $0.sessionGeneration.map(String.init) ?? "-",
          $0.lastMessageId.map(String.init) ?? "-",
          "\($0.assignedJobs)",
          "\($0.advertisedCapacity)",
          $0.healthy ? "ok" : Format.optional($0.lastError),
        ]
      })
  }
}

extension Debug {
  struct Demand: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "demand",
      abstract: "Override local demand (manual demand provider only).",
      subcommands: [SetDemand.self])

    @OptionGroup var options: GlobalOptions
  }
}

extension Debug.Demand {
  struct SetDemand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "set",
      abstract: "Set the number of jobs assigned to a profile.",
      discussion: """
        Only accepted when runnerd runs the manual demand provider \
        (github.demand: manual in the configuration). With a scale set in front, demand is \
        GitHub's statistics and nothing else.
        """)

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Profile name.")
    var profile: String

    @Argument(help: "Number of assigned jobs.")
    var assignedJobs: Int

    func run() async throws {
      let response = try await options.withDaemon {
        try await $0.debugDemandSet(profile: profile, assignedJobs: assignedJobs)
      }
      switch options.output {
      case .json: try JSONOut.print(response)
      case .human: print("\(response.profile)  demand \(response.assignedJobs)")
      }
    }
  }
}
