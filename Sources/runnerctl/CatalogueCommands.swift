import ArgumentParser
import DaemonAPI
import Foundation

struct Profile: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "profile",
    abstract: "Inspect runner profiles.",
    subcommands: [List.self, Show.self])

  @OptionGroup var options: GlobalOptions
}

extension Profile {
  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "list", abstract: "List every configured profile.")

    @OptionGroup var options: GlobalOptions

    func run() async throws {
      let response = try await options.withDaemon { try await $0.profileList() }
      switch options.output {
      case .json: try JSONOut.print(response)
      case .human: print(Profile.table(response.profiles))
      }
    }
  }

  struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "show", abstract: "Show one profile in full.")

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Profile name.")
    var name: String

    func run() async throws {
      let profile = try await options.withDaemon { try await $0.profileGet(name: name) }
      switch options.output {
      case .json: try JSONOut.print(profile)
      case .human: print(Table.fields(Profile.fields(profile), indent: ""))
      }
    }
  }

  static func table(_ profiles: [ProfileSummary]) -> String {
    Table.render(
      headers: ["NAME", "SCOPE", "OS", "LIFECYCLE", "CPU", "MEMORY", "DISK", "MAX", "ENABLED"],
      rows: profiles.map {
        [
          $0.name, $0.scope, $0.guestOS, $0.lifecycle, "\($0.cpuCount)",
          Format.bytes($0.memoryBytes), Format.bytes($0.diskBytes),
          $0.maxInstances.map(String.init) ?? "-", Format.yesNo($0.enabled),
        ]
      })
  }

  static func fields(_ profile: ProfileSummary) -> [(String, String)] {
    [
      ("name", profile.name),
      ("scope", profile.scope),
      ("image", profile.image),
      ("os", profile.guestOS),
      ("lifecycle", profile.lifecycle),
      ("cpu", "\(profile.cpuCount)"),
      ("memory", Format.bytes(profile.memoryBytes)),
      ("disk", Format.bytes(profile.diskBytes)),
      ("warm pool", "min \(profile.minIdle) / max \(profile.maxIdle)"),
      ("max instances", profile.maxInstances.map(String.init) ?? "unbounded"),
      ("ssh", Format.yesNo(profile.sshEnabled)),
      ("enabled", Format.yesNo(profile.enabled)),
      ("updated", profile.updatedAt),
    ]
  }
}

struct Scope: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "scope",
    abstract: "Inspect GitHub scopes.",
    subcommands: [List.self, Show.self])

  @OptionGroup var options: GlobalOptions
}

extension Scope {
  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "list", abstract: "List every configured GitHub scope.")

    @OptionGroup var options: GlobalOptions

    func run() async throws {
      let response = try await options.withDaemon { try await $0.scopeList() }
      switch options.output {
      case .json: try JSONOut.print(response)
      case .human: print(Scope.table(response.scopes))
      }
    }
  }

  struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "show", abstract: "Show one GitHub scope in full.")

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Scope name.")
    var name: String

    func run() async throws {
      let scope = try await options.withDaemon { try await $0.scopeGet(name: name) }
      switch options.output {
      case .json: try JSONOut.print(scope)
      case .human:
        print(
          Table.fields(
            [
              ("name", scope.name),
              ("kind", scope.kind),
              ("target", scope.slug),
              ("runner group", Format.optional(scope.runnerGroup)),
              ("enabled", Format.yesNo(scope.enabled)),
              ("health", scope.health),
              ("updated", scope.updatedAt),
            ], indent: ""))
      }
    }
  }

  static func table(_ scopes: [ScopeSummary]) -> String {
    Table.render(
      headers: ["NAME", "KIND", "TARGET", "GROUP", "ENABLED", "HEALTH"],
      rows: scopes.map {
        [
          $0.name, $0.kind, $0.slug, Format.optional($0.runnerGroup), Format.yesNo($0.enabled),
          $0.health,
        ]
      })
  }
}
