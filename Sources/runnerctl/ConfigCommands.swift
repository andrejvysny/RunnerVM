import ArgumentParser
import ConfigLoader
import DaemonAPI
import Foundation
import RunnerCore

struct ConfigCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "config",
    abstract: "Print, validate and apply the RunnerVM configuration.",
    subcommands: [Init.self, Validate.self, Apply.self, Get.self])

  @OptionGroup var options: GlobalOptions
}

extension ConfigCommand {
  struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "init", abstract: "Print a configuration that already validates.")

    @OptionGroup var options: GlobalOptions

    func run() throws {
      print(ExampleConfig.example)
    }
  }

  struct Validate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "validate", abstract: "Check a configuration file against this host.")

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Path to the YAML configuration.")
    var file: String

    func run() async throws {
      let yaml = try ConfigFile.read(file)
      let response = try await validate(yaml)
      switch options.output {
      case .json: try JSONOut.print(response)
      case .human: print(ConfigCommand.renderIssues(response.issues, valid: response.valid))
      }
      if !response.valid { throw ExitCode(1) }
    }

    /// Falls back to a local validation so `config validate` still works before the first
    /// `runnerd` start; the fallback cannot see Virtualization limits, so it says so.
    private func validate(_ yaml: String) async throws -> ConfigValidateResponse {
      do {
        return try await options.withDaemon { try await $0.configValidate(yaml: yaml) }
      } catch let error as DaemonClientError where error.isUnreachable {
        writeError("runnerctl: daemon unreachable; validating locally against ProcessInfo facts")
        let config = try ConfigLoader.load(yaml: yaml)
        return ConfigValidateResponse(issues: config.validate(host: ConfigFile.localFacts()))
      }
    }
  }

  struct Apply: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "apply", abstract: "Validate a configuration and make it the desired state.")

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Path to the YAML configuration.")
    var file: String

    func run() async throws {
      let yaml = try ConfigFile.read(file)
      let response = try await options.withDaemon { try await $0.configApply(yaml: yaml) }
      switch options.output {
      case .json: try JSONOut.print(response)
      case .human: print(Apply.render(response))
      }
    }

    private static func render(_ response: ConfigApplyResponse) -> String {
      var lines = ["applied at \(response.appliedAt) (operation \(response.operationId))"]
      let sections: [(String, [String])] = [
        ("scopes added", response.diff.addedScopes),
        ("scopes updated", response.diff.updatedScopes),
        ("scopes disabled", response.diff.disabledScopes),
        ("profiles added", response.diff.addedProfiles),
        ("profiles updated", response.diff.updatedProfiles),
        ("profiles disabled", response.diff.disabledProfiles),
      ]
      let changed = sections.filter { !$0.1.isEmpty }
      lines.append(
        changed.isEmpty
          ? "no changes" : changed.map { "\($0.0): \($0.1.joined(separator: ", "))" }.joined(separator: "\n"))
      for issue in response.issues {
        lines.append("warning \(issue.code) at \(issue.path): \(issue.message)")
      }
      return lines.joined(separator: "\n")
    }
  }

  struct Get: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "get", abstract: "Print the configuration the daemon last applied.")

    @OptionGroup var options: GlobalOptions

    func run() async throws {
      let response = try await options.withDaemon { try await $0.configGet() }
      switch options.output {
      case .json:
        try JSONOut.print(response)
      case .human:
        guard let yaml = response.yaml else {
          writeError("runnerctl: no configuration has been applied on this host")
          throw ExitCode(1)
        }
        print(yaml)
      }
    }
  }

  static func renderIssues(_ issues: [ConfigurationIssue], valid: Bool) -> String {
    guard !issues.isEmpty else { return "configuration is valid" }
    let rows = issues.map { [$0.severity.rawValue, $0.code, $0.path, $0.message] }
    let table = Table.render(headers: ["SEVERITY", "CODE", "PATH", "MESSAGE"], rows: rows)
    return table + "\n\n" + (valid ? "configuration is valid" : "configuration is invalid")
  }
}

enum ConfigFile {
  static func read(_ path: String) throws -> String {
    do {
      return try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    } catch {
      throw ConfigurationError.fileUnreadable(path: path, cause: error as? any Error & Sendable)
    }
  }

  /// Best-effort host facts for the daemon-less fallback: no Virtualization framework here, so
  /// the CPU/memory bounds are the machine's own limits.
  static func localFacts() -> HostFacts {
    let info = ProcessInfo.processInfo
    return HostFacts(
      logicalCPUCount: info.activeProcessorCount,
      physicalMemoryBytes: info.physicalMemory,
      minimumAllowedCPUCount: 1,
      maximumAllowedCPUCount: info.activeProcessorCount,
      minimumAllowedMemoryBytes: ByteSize.mebibytes(128).bytes,
      maximumAllowedMemoryBytes: info.physicalMemory)
  }
}
