// Derived from openai/tart@16d186c Sources/tart/Credentials/DockerConfigCredentialsProvider.swift —
// FSL-1.1-ALv2. See PROVENANCE.md.
import Foundation

/// `~/.docker/config.json`: inline base64 `auths`, then `credHelpers`/`credsStore` resolved by
/// running `docker-credential-<helper> get`.
///
/// Reads the same file `docker login` writes, so an operator who already authenticated to GHCR
/// needs no RunnerVM-specific setup.
public struct DockerConfigCredentials: RegistryCredentialProvider {
  /// Runs `docker-credential-<helper> get`, feeding it the host on stdin. Injected so tests never
  /// depend on a helper being installed.
  public typealias HelperRunner = @Sendable (_ helper: String, _ registry: String) throws -> Data

  public struct HelperFailure: Error, CustomStringConvertible, Sendable {
    public let helper: String
    public let reason: String
    public var description: String {
      "docker-credential-\(helper): \(reason)"
    }
  }

  /// Long enough for a Keychain unlock prompt, short enough that a wedged helper cannot stall a
  /// pull indefinitely.
  public static let helperTimeout: Duration = .seconds(10)

  private let configURL: URL
  private let runHelper: HelperRunner

  public init(
    configURL: URL = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".docker/config.json"),
    helperRunner: @escaping HelperRunner = DockerConfigCredentials.runSubprocessHelper
  ) {
    self.configURL = configURL
    runHelper = helperRunner
  }

  public func credential(for registry: String) async throws -> RegistryCredential? {
    guard FileManager.default.fileExists(atPath: configURL.path(percentEncoded: false)) else {
      return nil
    }
    let config = try JSONDecoder().decode(DockerConfig.self, from: Data(contentsOf: configURL))
    if let inline = config.inlineCredential(for: registry) { return inline }
    guard let helper = config.helper(for: registry) else { return nil }
    let output = try runHelper(helper, registry)
    guard !output.isEmpty else {
      throw HelperFailure(helper: helper, reason: "produced no output")
    }
    let decoded = try JSONDecoder().decode(DockerHelperOutput.self, from: output)
    return RegistryCredential(username: decoded.Username, password: decoded.Secret)
  }

  // MARK: - Subprocess

  public static let runSubprocessHelper: HelperRunner = { helper, registry in
    let binary = "docker-credential-\(helper)"
    guard let executable = resolveExecutable(binary) else {
      throw HelperFailure(helper: helper, reason: "not found in PATH")
    }
    let process = Process()
    process.executableURL = executable
    process.arguments = ["get"]
    let output = Pipe()
    let input = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    process.standardInput = input
    try process.run()
    try? input.fileHandleForWriting.write(contentsOf: Data("\(registry)\n".utf8))
    try? input.fileHandleForWriting.close()
    let data = try output.fileHandleForReading.readToEnd() ?? Data()
    try waitOrTerminate(process, helper: helper)
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
      throw HelperFailure(helper: helper, reason: "exited with status \(process.terminationStatus)")
    }
    return data
  }

  /// `Process.waitUntilExit` has no timeout, so poll instead and kill a helper that hangs on a
  /// Keychain prompt nobody is there to answer.
  private static func waitOrTerminate(_ process: Process, helper: String) throws {
    let deadline = ContinuousClock.now.advanced(by: helperTimeout)
    while process.isRunning {
      if ContinuousClock.now > deadline {
        process.terminate()
        throw HelperFailure(helper: helper, reason: "timed out after \(helperTimeout)")
      }
      usleep(20000)
    }
    process.waitUntilExit()
  }

  private static func resolveExecutable(_ name: String) -> URL? {
    let search = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
    for directory in search.split(separator: ":") {
      let candidate = URL(fileURLWithPath: String(directory)).appending(path: name)
      if FileManager.default.isExecutableFile(atPath: candidate.path(percentEncoded: false)) {
        return candidate
      }
    }
    return nil
  }
}

// MARK: - Wire shapes

struct DockerConfig: Decodable {
  var auths: [String: DockerAuthEntry]?
  var credHelpers: [String: String]?
  var credsStore: String?

  func inlineCredential(for registry: String) -> RegistryCredential? {
    for key in DockerConfig.hostKeys(registry) {
      if let entry = auths?[key], let credential = entry.credential() { return credential }
    }
    return nil
  }

  func helper(for registry: String) -> String? {
    for key in DockerConfig.hostKeys(registry) {
      if let helper = credHelpers?[key] { return helper }
    }
    return credsStore
  }

  /// `docker login ghcr.io` writes the bare host, but older clients wrote a full URL; accept both.
  static func hostKeys(_ registry: String) -> [String] {
    [registry, "https://\(registry)", "https://\(registry)/v1/", "http://\(registry)"]
  }
}

struct DockerAuthEntry: Decodable {
  var auth: String?
  var username: String?
  var password: String?

  func credential() -> RegistryCredential? {
    if let username, let password { return RegistryCredential(username: username, password: password) }
    guard let auth, let data = Data(base64Encoded: auth),
          let text = String(data: data, encoding: .utf8),
          let separator = text.firstIndex(of: ":")
    else { return nil }
    return RegistryCredential(
      username: String(text[text.startIndex ..< separator]),
      password: String(text[text.index(after: separator)...])
    )
  }
}

struct DockerHelperOutput: Decodable {
  // swiftlint:disable:next identifier_name - the helper protocol capitalises these keys.
  var Username: String
  var Secret: String
}
