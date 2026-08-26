import ArgumentParser
import DaemonAPI
import Foundation

struct Auth: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "auth",
    abstract: "Manage the GitHub credential runnerd uses.",
    discussion: """
      The token is stored by the daemon in whatever `github.auth.source` names — the macOS \
      Keychain, an owner-only file under the state directory, or (read-only) an environment \
      variable. It travels over runnerd.sock and is never written to the YAML document.
      """,
    subcommands: [Login.self, Status.self, Logout.self])

  @OptionGroup var options: GlobalOptions
}

extension Auth {
  struct Login: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "login", abstract: "Store a GitHub personal access token.")

    @OptionGroup var options: GlobalOptions

    @Flag(name: .long, help: "Read the token from standard input (preferred).")
    var tokenStdin = false

    @Option(name: .long, help: "Token value. Visible in the process list; prefer --token-stdin.")
    var token: String?

    func run() async throws {
      let secret = try readToken()
      let response = try await options.withDaemon { try await $0.authLogin(token: secret) }
      switch options.output {
      case .json: try JSONOut.print(response)
      case .human:
        print("stored in \(response.location)")
        print(Auth.render(response.status))
      }
    }

    private func readToken() throws -> String {
      if tokenStdin {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
      }
      guard let token else {
        throw ValidationError("pass --token-stdin (preferred) or --token <value>")
      }
      return token
    }
  }

  struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "status",
      abstract: "Show the credential the daemon last probed (does not call GitHub).")

    @OptionGroup var options: GlobalOptions

    func run() async throws {
      let status = try await options.withDaemon { try await $0.authStatus() }
      switch options.output {
      case .json: try JSONOut.print(status)
      case .human: print(Auth.render(status))
      }
    }
  }

  struct Logout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "logout", abstract: "Remove the stored token. Idempotent.")

    @OptionGroup var options: GlobalOptions

    func run() async throws {
      let response = try await options.withDaemon { try await $0.authLogout() }
      switch options.output {
      case .json: try JSONOut.print(response)
      case .human:
        print(response.removed ? "removed from \(response.location)" : "nothing stored in \(response.location)")
      }
    }
  }

  static func render(_ status: AuthStatus) -> String {
    var fields: [(String, String)] = [
      ("state", status.login.map { "\(status.state) (\($0))" } ?? status.state),
      ("provider", status.provider),
      ("source", status.source),
      ("location", status.location),
    ]
    if let checkedAt = status.checkedAt { fields.append(("checked", checkedAt)) }
    if let problem = status.problem { fields.append(("problem", problem)) }
    if let hint = status.hint { fields.append(("hint", hint)) }
    return Table.fields(fields, indent: "")
  }
}

struct GitHubCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "github",
    abstract: "Probe GitHub connectivity and per-scope permissions.",
    subcommands: [Test.self])

  @OptionGroup var options: GlobalOptions
}

extension GitHubCommand {
  struct Test: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "test",
      abstract: "Check the credential and every configured scope against GitHub.")

    @OptionGroup var options: GlobalOptions

    func run() async throws {
      let response = try await options.withDaemon { try await $0.githubTest() }
      switch options.output {
      case .json: try JSONOut.print(response)
      case .human: print(GitHubCommand.render(response))
      }
      // A credential or scope problem is a failure an operator has to act on, so it must not
      // exit 0 in a script.
      guard response.auth.state == "healthy",
            response.scopes.allSatisfy({ $0.status == "healthy" })
      else { throw ExitCode(1) }
    }
  }

  static func render(_ response: GitHubTestResponse) -> String {
    var blocks = ["Auth\n" + Table.fields(authFields(response.auth))]
    blocks.append(
      "Scopes\n"
        + Table.render(
          headers: ["NAME", "SLUG", "KIND", "STATUS", "GROUP", "VISIBILITY", "RUNNERS", "PROBLEM"],
          rows: response.scopes.map(row)))
    return blocks.joined(separator: "\n\n")
  }

  private static func authFields(_ auth: AuthStatus) -> [(String, String)] {
    [
      ("state", auth.login.map { "\(auth.state) (\($0))" } ?? auth.state),
      ("source", "\(auth.provider) via \(auth.location)"),
      ("problem", Format.optional(auth.problem)),
      ("hint", Format.optional(auth.hint)),
    ]
  }

  private static func row(_ scope: ScopeHealthDTO) -> [String] {
    [
      scope.name,
      scope.slug,
      scope.kind,
      scope.schedulable ? scope.status : "\(scope.status) (not schedulable)",
      scope.runnerGroupId.map { "\(scope.runnerGroup ?? "default") (\($0))" } ?? "-",
      Format.optional(scope.visibility),
      scope.runnerCount.map(String.init) ?? "-",
      Format.optional(scope.problems.first.map { "\($0.code): \($0.detail)" }),
    ]
  }
}
