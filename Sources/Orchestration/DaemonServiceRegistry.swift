import DaemonAPI
import Foundation
import Logging
import OCIRegistry
import Persistence
import RPC
import RunnerCore

/// `image.pull`, `image.push` and the `registry.*` credential surface. Split out of
/// `DaemonServiceImpl.swift` to keep that file under its line budget; every member runs
/// actor-isolated on `DaemonServiceImpl` exactly as if it were declared there.
extension DaemonServiceImpl {
  // MARK: - image.pull / image.push

  /// Returns as soon as the tag is resolved and the transfer is under way. Everything expensive
  /// happens after the reply, tracked by the `pull-image` operation (spec §119, §137).
  ///
  /// Tag resolution deliberately happens inside the call: an unreachable registry, a bad
  /// credential or a missing repository is the operator's answer, and it should arrive as
  /// `REGISTRY_AUTH` / `REGISTRY_NOT_FOUND` on this call rather than in an operation row.
  func imagePull(_ request: ImagePullRequest) async throws -> ImagePullResponse {
    let pressure = await diskPressure.refresh(floorBytes: reserveDiskFloor())
    guard pressure.state != .critical else {
      throw OrchestrationError.diskPressureCritical(
        freeBytes: pressure.freeBytes, floorBytes: pressure.floorBytes)
    }
    let start = try await images.startPull(
      reference: request.reference, format: try Self.artifactFormat(request.format))
    return ImagePullResponse(
      reference: start.reference,
      manifestDigest: start.manifestDigest.rawValue,
      operationId: start.operationId?.rawValue,
      alreadyPresent: start.localDigest != nil,
      digest: start.localDigest?.rawValue)
  }

  func imagePush(_ request: ImagePushRequest) async throws -> ImagePushResponse {
    let start = try await images.startPush(imageRef: request.image, to: request.reference)
    return ImagePushResponse(
      reference: start.reference, digest: start.digest.rawValue,
      operationId: start.operationId?.rawValue)
  }

  /// `nil` auto-detects. A value the daemon does not know is the caller's mistake, and saying so
  /// here is better than silently falling back to auto-detection.
  static func artifactFormat(_ raw: String?) throws -> ImageArtifactFormat? {
    guard let raw else { return nil }
    guard let format = ImageArtifactFormat(rawValue: raw) else {
      throw ImageError.metadataInvalid(
        reason: "unknown image format '\(raw)'; expected one of "
          + ImageArtifactFormat.allCases.map(\.rawValue).joined(separator: ", ")
      )
    }
    return format
  }

  // MARK: - registry.*

  /// The daemon owns the Keychain item, so a `runnerctl` running as a different user still
  /// authenticates the pulls runnerd actually performs (spec §79).
  func registryLogin(_ request: RegistryLoginRequest) async throws -> RegistryLoginResponse {
    let registry = try Self.registryHost(request.registry)
    guard !request.username.isEmpty, !request.password.isEmpty else {
      throw DaemonServiceError.unavailable(reason: "username and password must both be set")
    }
    try registryCredentials.keychain.store(
      RegistryCredential(username: request.username, password: request.password), server: registry)
    // Never the password, and never the username at anything above debug: this line goes to a
    // shared log.
    logger.notice("registry credential stored", metadata: ["registry": .string(registry)])
    try? await audit.record(
      kind: "registry.login", actor: actorName, resourceType: "registry", resourceId: registry,
      detail: JSONValue.object(["username": .string(request.username)]).encodedString())
    return RegistryLoginResponse(
      registry: registry, username: request.username, location: "keychain \(registry)")
  }

  func registryLogout(_ request: RegistryLogoutRequest) async throws -> RegistryLogoutResponse {
    let registry = try Self.registryHost(request.registry)
    let removed = try registryCredentials.keychain.remove(server: registry)
    if removed {
      logger.notice("registry credential removed", metadata: ["registry": .string(registry)])
      try? await audit.record(
        kind: "registry.logout", actor: actorName, resourceType: "registry", resourceId: registry,
        detail: nil)
    }
    return RegistryLogoutResponse(registry: registry, removed: removed)
  }

  /// Offline by construction: it asks each credential provider what it holds, never a registry.
  /// The set of registries comes from the profiles, because those are the pulls that have to work.
  func registryStatus() async throws -> RegistryStatusResponse {
    var profilesByRegistry: [String: [String]] = [:]
    for row in try await profiles.list() {
      guard let config = try? row.decodedConfig(),
            let reference = ImageManager.registryReference(config.image)
      else { continue }
      profilesByRegistry[reference.registry, default: []].append(row.name)
    }
    var result: [RegistryCredentialDTO] = []
    for (registry, names) in profilesByRegistry.sorted(by: { $0.key < $1.key }) {
      let probed = await registryCredentials.probe(registry: registry)
      result.append(
        RegistryCredentialDTO(
          registry: registry, provider: probed?.provider.rawValue, username: probed?.username,
          profiles: names.sorted()))
    }
    return RegistryStatusResponse(registries: result)
  }

  /// Accepts a bare host (`ghcr.io`, `localhost:5000`) and tolerates a full reference being pasted
  /// in by mistake, which is the most common way this argument is got wrong.
  private static func registryHost(_ text: String) throws -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let reference = ImageManager.registryReference(trimmed) { return reference.registry }
    let host = trimmed.split(separator: "/", maxSplits: 1).first.map(String.init) ?? trimmed
    guard ImageReference.isValid("\(host)/placeholder") else {
      throw ImageError.referenceInvalid(reference: text)
    }
    return host
  }
}
