import Foundation
import RunnerCore

/// The two host-side files a managed macOS provisioning build shells out to, and the JSON the
/// first of them writes back.
///
/// Resolution follows `BuildSeed.resolveAgent`'s order exactly — configuration first (an operator
/// override must always win), then the environment seam tests use, then the packaged location
/// `install.sh` writes, then a development checkout — so an operator only ever has to learn one
/// rule for "where does the daemon look for the things it ships alongside itself".
enum MacOSProvisionAssets {
  static let scriptName = "provision-macos-tart.sh"
  static let darwinAgentRelativePath = "guest-agent/darwin-arm64/runnervm-guest-agent"

  /// `<scriptsRoot>/provision-macos-tart.sh`, in candidate order.
  static func resolveScript(
    config: ImageBuildConfig, paths: RunnerPaths,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    executable: URL? = Bundle.main.executableURL
  ) throws -> URL {
    try resolve(
      what: "the macOS provisioning script (\(scriptName))",
      candidates: candidates(
        override: config.macosProvisionScript,
        environmentKey: "RUNNERVM_MACOS_PROVISION_SCRIPT", environment: environment,
        stateRelative: "scripts/\(scriptName)", shareRelative: "scripts/\(scriptName)",
        repositoryRelative: "scripts/\(scriptName)", paths: paths, executable: executable))
  }

  /// The darwin/arm64 guest-agent binary the script installs into the guest.
  static func resolveDarwinAgent(
    config: ImageBuildConfig, paths: RunnerPaths,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    executable: URL? = Bundle.main.executableURL
  ) throws -> URL {
    try resolve(
      what: "the darwin/arm64 guest agent",
      candidates: candidates(
        override: config.macosGuestAgentPath,
        environmentKey: "RUNNERVM_MACOS_GUEST_AGENT", environment: environment,
        stateRelative: darwinAgentRelativePath, shareRelative: darwinAgentRelativePath,
        // `make -C GuestAgent build-darwin` writes here; `build-package.sh` copies it into
        // `share/runnervm/guest-agent/darwin-arm64/` from exactly this path.
        repositoryRelative: "GuestAgent/bin/darwin-arm64/runnervm-guest-agent",
        paths: paths, executable: executable))
  }

  private static func resolve(what: String, candidates: [URL]) throws -> URL {
    var tried: [String] = []
    for candidate in candidates {
      let path = candidate.path(percentEncoded: false)
      if FileManager.default.isReadableFile(atPath: path) { return candidate }
      tried.append(path)
    }
    throw ImageBuildError.macosScriptMissing(what: what, tried: tried)
  }

  private static func candidates(
    override: String?, environmentKey: String, environment: [String: String],
    stateRelative: String, shareRelative: String, repositoryRelative: String,
    paths: RunnerPaths, executable: URL?
  ) -> [URL] {
    var result: [URL] = []
    if let override, !override.isEmpty { result.append(URL(fileURLWithPath: override)) }
    if let value = environment[environmentKey], !value.isEmpty {
      result.append(URL(fileURLWithPath: value))
    }
    result.append(paths.rootDir.appending(path: stateRelative))
    if let executable {
      result.append(
        executable.deletingLastPathComponent()
          .appending(path: "../share/runnervm/\(shareRelative)").standardizedFileURL)
      if let root = repositoryRoot(from: executable) {
        result.append(root.appending(path: repositoryRelative))
      }
    }
    return result
  }

  /// A development checkout containing `executable`, found by walking up from it looking for the
  /// `Package.swift` at the top of this repository. `swift run runnerd` puts the binary at
  /// `<repo>/.build/<config>/runnerd`, which is three levels down; the bound is generous enough
  /// for an `arm64-apple-macosx` triple subdirectory and cheap enough to be unconditional.
  static func repositoryRoot(from executable: URL) -> URL? {
    var directory = executable.deletingLastPathComponent().standardizedFileURL
    for _ in 0..<6 {
      let manifest = directory.appending(path: "Package.swift")
      if FileManager.default.isReadableFile(atPath: manifest.path(percentEncoded: false)) {
        return directory
      }
      let parent = directory.deletingLastPathComponent().standardizedFileURL
      if parent == directory { return nil }
      directory = parent
    }
    return nil
  }
}

/// What `provision-macos-tart.sh --attach --result <path>` writes, in both its shapes.
///
/// The script guarantees the file exists the moment it exits, whatever the exit code, so this is
/// parsed on every outcome and its `error` is what a failure reports. Every field is optional and
/// decoding is lenient: a result the daemon cannot read is reported as such rather than crashing
/// a build that may already have produced a guest worth diagnosing.
struct MacOSProvisionResult: Codable, Sendable, Equatable {
  var ok: Bool
  var runnerVersion: String?
  var guestAgentVersion: String?
  /// The lockdown was run *and* proven, not merely attempted.
  var hardenProof: Bool
  /// The guest took itself down after the lockdown instead of being force-stopped.
  var gracefulShutdown: Bool
  /// Whether SSH is still reachable in the guest that is about to be sealed.
  var ssh: Bool
  var error: String?

  init(
    ok: Bool, runnerVersion: String? = nil, guestAgentVersion: String? = nil,
    hardenProof: Bool = false, gracefulShutdown: Bool = false, ssh: Bool = false,
    error: String? = nil
  ) {
    self.ok = ok
    self.runnerVersion = runnerVersion
    self.guestAgentVersion = guestAgentVersion
    self.hardenProof = hardenProof
    self.gracefulShutdown = gracefulShutdown
    self.ssh = ssh
    self.error = error
  }

  private enum CodingKeys: String, CodingKey {
    case ok, runnerVersion, guestAgentVersion, hardenProof, gracefulShutdown, ssh, error
  }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      ok: try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false,
      runnerVersion: try c.decodeIfPresent(String.self, forKey: .runnerVersion),
      guestAgentVersion: try c.decodeIfPresent(String.self, forKey: .guestAgentVersion),
      hardenProof: try c.decodeIfPresent(Bool.self, forKey: .hardenProof) ?? false,
      gracefulShutdown: try c.decodeIfPresent(Bool.self, forKey: .gracefulShutdown) ?? false,
      ssh: try c.decodeIfPresent(Bool.self, forKey: .ssh) ?? false,
      error: try c.decodeIfPresent(String.self, forKey: .error))
  }

  static func read(_ url: URL) throws -> MacOSProvisionResult {
    guard let data = FileManager.default.contents(atPath: url.path(percentEncoded: false)) else {
      throw ImageBuildError.macosProvisionFailed(
        reason: "the provisioning script wrote no result at "
          + url.path(percentEncoded: false))
    }
    do {
      return try JSONDecoder().decode(MacOSProvisionResult.self, from: data)
    } catch {
      throw ImageBuildError.macosProvisionFailed(
        reason: "the provisioning result is not readable JSON: \(error)")
    }
  }

  /// The gate a sealable guest has to pass. `debugSSH` is the only way SSH may still be open, and
  /// the managed launcher never sets it — it exists for a future operator-driven build that wants
  /// to keep a guest reachable for diagnosis, and such an image is marked `ssh: true` in its
  /// capabilities so nothing can mistake it for a hardened one.
  func requireSealable(debugSSH: Bool) throws {
    guard ok else {
      throw ImageBuildError.macosProvisionFailed(reason: error ?? "no reason recorded")
    }
    if debugSSH { return }
    guard hardenProof else {
      throw ImageBuildError.macosProvisionFailed(
        reason: "the seal-time SSH lockdown was not proven; the guest would ship reachable "
          + "with the base image's well-known credential")
    }
    guard gracefulShutdown else {
      throw ImageBuildError.macosProvisionFailed(
        reason: "the guest did not shut itself down after the lockdown")
    }
    guard !ssh else {
      throw ImageBuildError.macosProvisionFailed(reason: "SSH is still open in the sealed guest")
    }
  }
}
