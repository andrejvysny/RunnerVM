import ArgumentParser
import DaemonAPI
import Foundation
import Security

struct Registry: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "registry",
    abstract: "Manage the credentials runnerd uses to pull and push images.",
    discussion: """
      Credentials are resolved per registry host, in order: RUNNERVM_REGISTRY_USERNAME / \
      RUNNERVM_REGISTRY_PASSWORD, then ~/.docker/config.json (including credential helpers), \
      then the Keychain. `login` writes the Keychain item; by default it writes the *daemon's*, \
      because runnerd is what performs the pull.
      """,
    subcommands: [Login.self, Logout.self, Status.self])

  @OptionGroup var options: GlobalOptions
}

extension Registry {
  struct Login: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "login",
      abstract: "Store a registry username and password.",
      discussion: """
        The password is read from standard input, so it never appears in the process list or the \
        shell history: `echo $GHCR_PAT | runnerctl registry login ghcr.io -u me --password-stdin`.
        """)

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Registry host, e.g. ghcr.io or localhost:5000.")
    var registry: String

    @Option(name: [.customShort("u"), .long], help: "Username. A GHCR PAT pairs with any username.")
    var username: String

    @Flag(name: .long, help: "Read the password from standard input (required).")
    var passwordStdin = false

    @Flag(
      name: .long,
      help: "Write to this user's Keychain instead of the daemon's. For development only.")
    var local = false

    func validate() throws {
      guard passwordStdin else { throw ValidationError("pass --password-stdin") }
    }

    func run() async throws {
      let password = String(
        decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !password.isEmpty else { throw ValidationError("no password on standard input") }
      let response = try local
        ? Registry.storeLocally(registry: registry, username: username, password: password)
        : await options.withDaemon {
          try await $0.registryLogin(
            registry: registry, username: username, password: password)
        }
      switch options.output {
      case .json: try JSONOut.print(response)
      case .human: print("stored \(response.username) for \(response.registry) in \(response.location)")
      }
    }
  }

  struct Logout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "logout", abstract: "Remove a stored registry credential. Idempotent.")

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Registry host.")
    var registry: String

    @Flag(name: .long, help: "Remove from this user's Keychain instead of the daemon's.")
    var local = false

    func run() async throws {
      let response = try local
        ? Registry.removeLocally(registry: registry)
        : await options.withDaemon { try await $0.registryLogout(registry: registry) }
      switch options.output {
      case .json: try JSONOut.print(response)
      case .human:
        print(
          response.removed
            ? "removed the credential for \(response.registry)"
            : "nothing stored for \(response.registry)")
      }
    }
  }

  struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "status",
      abstract: "Show which credential would answer for every registry the profiles name.",
      discussion: """
        Offline: it reports what the daemon's credential chain holds, never what a registry \
        thinks of it. Use `runnerctl image pull` for the live check.
        """)

    @OptionGroup var options: GlobalOptions

    func run() async throws {
      let response = try await options.withDaemon { try await $0.registryStatus() }
      switch options.output {
      case .json: try JSONOut.print(response)
      case .human: print(Registry.table(response.registries))
      }
    }
  }

  static func table(_ registries: [RegistryCredentialDTO]) -> String {
    Table.render(
      headers: ["REGISTRY", "CREDENTIAL", "USERNAME", "PROFILES"],
      rows: registries.map {
        [
          $0.registry, $0.provider ?? "anonymous", Format.optional($0.username),
          $0.profiles.joined(separator: ","),
        ]
      })
  }
}

/// `--local` writes the invoking user's Keychain rather than the daemon's, which is only useful
/// when runnerd runs as that same user. It is the same `kSecClassInternetPassword` item runnerd
/// reads, keyed by registry host.
extension Registry {
  private static func query(_ registry: String) -> [String: Any] {
    [kSecClass as String: kSecClassInternetPassword, kSecAttrServer as String: registry]
  }

  static func storeLocally(
    registry: String, username: String, password: String
  ) throws -> RegistryLoginResponse {
    let attributes: [String: Any] = [
      kSecAttrAccount as String: username,
      kSecValueData as String: Data(password.utf8),
    ]
    var status = SecItemUpdate(query(registry) as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(
        query(registry).merging(attributes) { _, new in new } as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw KeychainFailure(status: status) }
    return RegistryLoginResponse(
      registry: registry, username: username, location: "local keychain \(registry)")
  }

  static func removeLocally(registry: String) throws -> RegistryLogoutResponse {
    let status = SecItemDelete(query(registry) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainFailure(status: status)
    }
    return RegistryLogoutResponse(registry: registry, removed: status == errSecSuccess)
  }

  struct KeychainFailure: Error, CustomStringConvertible {
    let status: OSStatus
    var description: String { "keychain operation failed with status \(status)" }
  }
}
