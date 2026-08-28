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
          id: "config_validate", title: "Configuration", status: .skip,
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
        id: "disk_headroom", title: "Disk headroom", status: .skip,
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
  static func profileImages(
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
      .map(describe)
      .joined(separator: ", ")
  }

  /// `ubuntu-24 (2.330.0) missed 2.331.0 released 45 d ago` when the daemon knows which release
  /// the image first fell behind on; just the label and version otherwise.
  private static func describe(_ image: ImageInfoDTO) -> String {
    let label = image.name ?? Format.shortDigest(image.digest)
    guard let version = image.runnerVersion, !version.isEmpty else { return label }
    guard let missed = image.runnerFirstMissedVersion,
          let publishedAt = image.runnerFirstMissedPublishedAt.flatMap(RFC3339.date)
    else { return "\(label) (\(version))" }
    let daysAgo = max(0, Int(Date().timeIntervalSince(publishedAt) / 86_400))
    return "\(label) (\(version)) missed \(missed) released \(daysAgo) d ago"
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

  // MARK: Guest agent presence (spec §58)

  /// A profile pointing at a cached image with no RunnerVM guest agent can never start a job:
  /// `vm create` refuses it with `IMAGE_NO_GUEST_AGENT` before the clone. That is a hard failure,
  /// not a warning -- the profile is misconfigured, not merely behind.
  static func profileImageGuestAgent(
    images: [ImageInfoDTO]?, config: RunnerConfiguration?
  ) -> DoctorCheck {
    let id = "profile_image_guest_agent"
    let title = "Profile image guest agent"
    guard let images else {
      return DoctorCheck(id: id, title: title, status: .warn, detail: "runnerd is not reachable; skipped")
    }
    let agentless = profileImages(images, config: config).filter { $0.guestAgent == false }
    guard agentless.isEmpty else {
      let names = agentless.map { $0.name ?? Format.shortDigest($0.digest) }.joined(separator: ", ")
      return DoctorCheck(
        id: id, title: title, status: .fail,
        detail: "\(agentless.count) profile image(s) carry no RunnerVM guest agent and cannot run "
          + "jobs: \(names). Images imported from tart are inspection-only; build one with "
          + "`runnerctl image build`."
      )
    }
    return DoctorCheck(
      id: id, title: title, status: .ok,
      detail: "every profile image this host has cached carries a guest agent"
    )
  }

  // MARK: GitHub credential presence

  /// Presence only, never a network call (spec §104 lists "GitHub authentication" as a doctor
  /// check; verifying the token actually works is `runnerctl github test`, which does call out).
  static func githubToken(config: RunnerConfiguration?, paths: RunnerPaths) -> DoctorCheck {
    guard let config else {
      return DoctorCheck(
        id: "github_token", title: "GitHub credential", status: .skip,
        detail: "no valid --config; skipped"
      )
    }
    let auth = config.github.auth
    if auth.provider == .app {
      return githubAppTokenCheck(paths: paths)
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

  /// `{clientId|appId, installationId, privateKeyPath}` at `<stateDir>/github-app.json` (spec
  /// §12) -- mirrors `GitHubAppFile`/`GitHubAuthFactory` in `Sources/Orchestration`, duplicated
  /// here rather than imported for the same reason as `githubFileTokenCheck`: `runnerctl` does not
  /// depend on `Orchestration` or `GitHubControl`. Only the field doctor needs (`privateKeyPath`)
  /// is decoded; a descriptor missing `appId`/`installationId` still lets doctor confirm the key
  /// file itself is present and owner-only, which is the actual leak risk this check exists for.
  private struct GitHubAppDescriptor: Decodable {
    var privateKeyPath: String
  }

  static func githubAppTokenCheck(paths: RunnerPaths) -> DoctorCheck {
    let id = "github_token"
    let title = "GitHub credential"
    let descriptorURL = paths.stateDir.appending(path: "github-app.json")
    let descriptorPath = descriptorURL.path
    guard let data = FileManager.default.contents(atPath: descriptorPath) else {
      return DoctorCheck(id: id, title: title, status: .fail, detail: "missing \(descriptorPath)")
    }
    guard let descriptor = try? JSONDecoder().decode(GitHubAppDescriptor.self, from: data) else {
      return DoctorCheck(
        id: id, title: title, status: .fail,
        detail: "\(descriptorPath) is not a valid GitHub App descriptor (missing privateKeyPath)"
      )
    }
    let keyPath = resolvedPrivateKeyPath(descriptor.privateKeyPath, relativeTo: descriptorURL)
    guard FileManager.default.fileExists(atPath: keyPath) else {
      return DoctorCheck(
        id: id, title: title, status: .fail,
        detail: "GitHub App descriptor present at \(descriptorPath), but its private key "
          + "\(keyPath) is missing"
      )
    }
    let mode = (try? FileManager.default.attributesOfItem(atPath: keyPath))?[.posixPermissions]
      as? NSNumber
    guard let mode, mode.uint16Value & 0o077 == 0 else {
      return DoctorCheck(
        id: id, title: title, status: .fail,
        detail: "GitHub App private key \(keyPath) must be owner-only (chmod 600)"
      )
    }
    return DoctorCheck(
      id: id, title: title, status: .ok,
      detail: "GitHub App descriptor present at \(descriptorPath); private key \(keyPath) is "
        + "owner-only"
    )
  }

  /// A relative `privateKeyPath` in `github-app.json` is resolved against the *descriptor's*
  /// directory, matching `GitHubAuthFactory.resolvedPrivateKeyPath`.
  private static func resolvedPrivateKeyPath(
    _ privateKeyPath: String, relativeTo descriptorURL: URL
  ) -> String {
    guard !privateKeyPath.hasPrefix("/") else { return privateKeyPath }
    return descriptorURL.deletingLastPathComponent()
      .appending(path: privateKeyPath).path(percentEncoded: false)
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
