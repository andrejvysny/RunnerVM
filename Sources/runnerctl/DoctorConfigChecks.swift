import ConfigLoader
import DaemonAPI
import Foundation
import RunnerCore
import Security

/// Configuration validation, disk headroom, and GitHub credential presence. All three need the
/// loaded `RunnerConfiguration`, so `loadConfig` is the shared entry point the other two consume.
extension DoctorChecks {
  static func loadConfig(
    path: String?, capabilities: ProbedCapabilities?
  ) -> (check: DoctorCheck, config: RunnerConfiguration?) {
    guard let path else {
      return (
        DoctorCheck(
          id: "config_validate", title: "Configuration", status: .warn,
          detail: "no --config given; skipped"
        ), nil
      )
    }
    let yaml: String
    do {
      yaml = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    } catch {
      return (
        DoctorCheck(
          id: "config_validate", title: "Configuration", status: .fail,
          detail: "cannot read \(path): \(error.localizedDescription)"
        ), nil
      )
    }
    let facts = capabilities.map(hostFacts) ?? localHostFacts()
    do {
      let (config, issues) = try ConfigLoader.loadAndValidate(yaml: yaml, host: facts)
      let status: DoctorCheck.Status = issues.isEmpty ? .ok : .warn
      let detail =
        issues.isEmpty
          ? "\(path) is valid"
          : "\(path) is valid with \(issues.count) warning(s): "
          + issues.prefix(3).map(\.code).joined(separator: ", ")
      return (
        DoctorCheck(id: "config_validate", title: "Configuration", status: status, detail: detail),
        config
      )
    } catch let error as any RunnerError {
      return (
        DoctorCheck(
          id: "config_validate", title: "Configuration", status: .fail, detail: error.message
        ), nil
      )
    } catch {
      return (
        DoctorCheck(id: "config_validate", title: "Configuration", status: .fail, detail: "\(error)"),
        nil
      )
    }
  }

  static func diskHeadroom(rootDir: URL, config: RunnerConfiguration?) -> DoctorCheck {
    guard let config else {
      return DoctorCheck(
        id: "disk_headroom", title: "Disk headroom", status: .warn,
        detail: "no valid --config; skipped"
      )
    }
    guard let free = freeBytes(at: rootDir) else {
      return DoctorCheck(
        id: "disk_headroom", title: "Disk headroom", status: .warn,
        detail: "could not read free space at \(rootDir.path)"
      )
    }
    let reserve = config.host.reserve.diskBytes
    let status: DoctorCheck.Status = free >= reserve ? .ok : .fail
    return DoctorCheck(
      id: "disk_headroom", title: "Disk headroom", status: status,
      detail: "\(Format.bytes(free)) free, host.reserve.disk is \(Format.bytes(reserve))"
    )
  }

  // MARK: Runner software freshness (spec §53)

  /// Grades the images the configured profiles actually run from. A `tooOld` one fails: GitHub
  /// stops handing work to a runner that far behind, so the VM would boot and sit idle. `stale`
  /// warns — there is still time to rebuild — and `unknown` is reported as OK with the reason,
  /// because "we could not find out" is not a host problem doctor should fail on.
  static func runnerVersion(
    images: [ImageInfoDTO]?, config: RunnerConfiguration?, authState: String?
  ) -> DoctorCheck {
    guard let images else {
      return check(.warn, "runnerd is not reachable; skipped")
    }
    let referenced = profileImages(images, config: config)
    guard !referenced.isEmpty else {
      return check(.ok, "no locally stored image is referenced by a profile")
    }
    let counts = Dictionary(grouping: referenced, by: \.runnerVersionHealth).mapValues(\.count)
    if let tooOld = counts[.tooOld], tooOld > 0 {
      return check(
        .fail,
        "\(tooOld) profile image(s) are past GitHub's \(RunnerVersionPolicy.graceDays)-day runner "
          + "update window: \(names(referenced, health: .tooOld)). Rebuild and republish them.")
    }
    if let stale = counts[.stale], stale > 0 {
      return check(
        .warn,
        "\(stale) profile image(s) are behind the latest actions/runner release: "
          + "\(names(referenced, health: .stale))")
    }
    if counts[.unknown] == referenced.count {
      return check(.ok, "runner freshness is unknown: \(unknownReason(referenced, authState: authState))")
    }
    return check(.ok, "\(referenced.count) profile image(s) are on the latest actions/runner release")
  }

  private static func check(_ status: DoctorCheck.Status, _ detail: String) -> DoctorCheck {
    DoctorCheck(id: "runner_version", title: "Runner version", status: status, detail: detail)
  }

  /// Without a `--config` doctor cannot know which images matter, so it grades all of them rather
  /// than reporting nothing.
  private static func profileImages(
    _ images: [ImageInfoDTO], config: RunnerConfiguration?
  ) -> [ImageInfoDTO] {
    guard let config, !config.profiles.isEmpty else { return images }
    let wanted = Set(config.profiles.map(\.image))
    return images.filter {
      wanted.contains($0.digest) || $0.name.map(wanted.contains) == true
        || $0.canonicalReference.map(wanted.contains) == true
    }
  }

  private static func names(_ images: [ImageInfoDTO], health: RunnerVersionHealth) -> String {
    images
      .filter { $0.runnerVersionHealth == health }
      .map { $0.name ?? Format.shortDigest($0.digest) }
      .joined(separator: ", ")
  }

  private static func unknownReason(_ images: [ImageInfoDTO], authState: String?) -> String {
    if images.allSatisfy({ ($0.runnerVersion ?? "").isEmpty }) {
      return "no image records a runnerVersion (import them with their sealed metadata.json)"
    }
    guard let authState, authState == "healthy" || authState == "unknown" else {
      return "no usable GitHub credential, so the latest release is unknown"
    }
    return "runnerd has not read the latest actions/runner release yet"
  }

  // MARK: GitHub credential presence

  /// Presence only, never a network call (spec §104 lists "GitHub authentication" as a doctor
  /// check; verifying the token actually works is `runnerctl github test`, which does call out).
  static func githubToken(config: RunnerConfiguration?, paths: RunnerPaths) -> DoctorCheck {
    guard let config else {
      return DoctorCheck(
        id: "github_token", title: "GitHub credential", status: .warn,
        detail: "no valid --config; skipped"
      )
    }
    let auth = config.github.auth
    if auth.provider == .app {
      let path = paths.stateDir.appending(path: "github-app.json").path
      let present = FileManager.default.fileExists(atPath: path)
      return DoctorCheck(
        id: "github_token", title: "GitHub credential", status: present ? .ok : .fail,
        detail: present ? "GitHub App descriptor present at \(path)" : "missing \(path)"
      )
    }
    switch auth.source {
    case .env:
      let present = !(ProcessInfo.processInfo.environment["RUNNERVM_GITHUB_TOKEN"] ?? "").isEmpty
      return DoctorCheck(
        id: "github_token", title: "GitHub credential", status: present ? .ok : .fail,
        detail: present ? "RUNNERVM_GITHUB_TOKEN is set" : "RUNNERVM_GITHUB_TOKEN is unset"
      )
    case .file:
      return githubFileTokenCheck(paths: paths)
    case .keychain:
      return githubKeychainTokenCheck()
    }
  }

  /// Path and mode requirement mirror `GitHubTokenStore.fileName`/`FilePATProvider` in
  /// `Sources/GitHubControl` — duplicated here rather than imported, since `runnerctl` does not
  /// depend on `GitHubControl` (only `Orchestration` does).
  static func githubFileTokenCheck(paths: RunnerPaths) -> DoctorCheck {
    let path = paths.stateDir.appending(path: "github-token").path
    guard FileManager.default.fileExists(atPath: path) else {
      return DoctorCheck(
        id: "github_token", title: "GitHub credential", status: .fail, detail: "missing \(path)"
      )
    }
    let mode = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions]
      as? NSNumber
    guard let mode, mode.uint16Value & 0o077 == 0 else {
      return DoctorCheck(
        id: "github_token", title: "GitHub credential", status: .fail,
        detail: "\(path) must be owner-only (chmod 600)"
      )
    }
    return DoctorCheck(
      id: "github_token", title: "GitHub credential", status: .ok, detail: "token file \(path)"
    )
  }

  /// Service/account match `KeychainPATProvider.defaultService` / `GitHubTokenStore.keychainAccount`.
  static func githubKeychainTokenCheck() -> DoctorCheck {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.runnervm.github",
      kSecAttrAccount as String: "default",
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    query[kSecReturnData as String] = false
    let status = SecItemCopyMatching(query as CFDictionary, nil)
    switch status {
    case errSecSuccess:
      return DoctorCheck(
        id: "github_token", title: "GitHub credential", status: .ok,
        detail: "keychain item com.runnervm.github/default present"
      )
    case errSecItemNotFound:
      return DoctorCheck(
        id: "github_token", title: "GitHub credential", status: .fail,
        detail: "no keychain item; run `runnerctl auth login`"
      )
    default:
      return DoctorCheck(
        id: "github_token", title: "GitHub credential", status: .warn,
        detail: "keychain query failed (status \(status)); is the login keychain unlocked?"
      )
    }
  }
}
