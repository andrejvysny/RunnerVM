import Foundation

// MARK: - image.update.*

/// `image.update.check {managed?}`: re-resolve every tracked source (or one) against its registry
/// and stop there. No transfer, no qualification, no promotion.
public struct ImageUpdateCheckRequest: Codable, Sendable, Hashable {
  /// `nil` checks every track; a name checks exactly one (`UPDATE_TRACK_NOT_FOUND` otherwise).
  public var managed: String?

  public init(managed: String? = nil) { self.managed = managed }
}

extension ImageUpdateCheckRequest {
  private enum CodingKeys: String, CodingKey { case managed }

  /// Lenient like every other daemon request: an empty object is the "all tracks" form, and an
  /// unknown key from a newer client is ignored rather than rejected.
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(managed: try c.decodeIfPresent(String.self, forKey: .managed))
  }
}

/// `image.update.run {managed?}`: kick a full resolve → pull → qualify → promote cycle. Returns
/// immediately with the pre-cycle snapshots; the cycle itself outlives the call and is followed
/// with `image.update.status`.
public struct ImageUpdateRunRequest: Codable, Sendable, Hashable {
  public var managed: String?

  public init(managed: String? = nil) { self.managed = managed }
}

extension ImageUpdateRunRequest {
  private enum CodingKeys: String, CodingKey { case managed }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(managed: try c.decodeIfPresent(String.self, forKey: .managed))
  }
}

/// One `managed_images` row, camelCased -- the same flat-mirror discipline as `BuildInfoDTO`.
public struct ImageUpdateTrackDTO: Codable, Sendable, Hashable {
  /// For a registry-tag track this is the canonical `<registry>/<repository>:<tag>` reference
  /// itself; for a managed source it is the local alias the promoted image is published under.
  public var name: String
  /// `registryTag` or `macosTart`.
  public var kind: String
  public var sourceReference: String
  /// The upstream *manifest* digest the last check resolved -- not a local content digest.
  public var lastSourceDigest: String?
  /// The local content digest currently promoted for this track.
  public var currentImageDigest: String?
  public var candidateImageDigest: String?
  public var state: String
  public var lastCheckedAt: String?
  public var lastUpdatedAt: String?
  public var lastError: String?
  public var autoUpdate: Bool

  public init(
    name: String, kind: String, sourceReference: String, lastSourceDigest: String? = nil,
    currentImageDigest: String? = nil, candidateImageDigest: String? = nil, state: String,
    lastCheckedAt: String? = nil, lastUpdatedAt: String? = nil, lastError: String? = nil,
    autoUpdate: Bool = true
  ) {
    self.name = name
    self.kind = kind
    self.sourceReference = sourceReference
    self.lastSourceDigest = lastSourceDigest
    self.currentImageDigest = currentImageDigest
    self.candidateImageDigest = candidateImageDigest
    self.state = state
    self.lastCheckedAt = lastCheckedAt
    self.lastUpdatedAt = lastUpdatedAt
    self.lastError = lastError
    self.autoUpdate = autoUpdate
  }
}

extension ImageUpdateTrackDTO {
  private enum CodingKeys: String, CodingKey {
    case name, kind, sourceReference, lastSourceDigest, currentImageDigest, candidateImageDigest
    case state, lastCheckedAt, lastUpdatedAt, lastError, autoUpdate
  }

  /// `name`/`kind`/`sourceReference`/`state` identify the track and always travel; the rest are
  /// optional so a row written before a field existed still decodes. `autoUpdate` defaults to
  /// `true`, which is what an older daemon that never sent the key meant.
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      name: try c.decode(String.self, forKey: .name),
      kind: try c.decode(String.self, forKey: .kind),
      sourceReference: try c.decode(String.self, forKey: .sourceReference),
      lastSourceDigest: try c.decodeIfPresent(String.self, forKey: .lastSourceDigest),
      currentImageDigest: try c.decodeIfPresent(String.self, forKey: .currentImageDigest),
      candidateImageDigest: try c.decodeIfPresent(String.self, forKey: .candidateImageDigest),
      state: try c.decode(String.self, forKey: .state),
      lastCheckedAt: try c.decodeIfPresent(String.self, forKey: .lastCheckedAt),
      lastUpdatedAt: try c.decodeIfPresent(String.self, forKey: .lastUpdatedAt),
      lastError: try c.decodeIfPresent(String.self, forKey: .lastError),
      autoUpdate: try c.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? true
    )
  }
}

/// The answer to all three `image.update.*` methods: `check` and `run` report the same snapshot
/// shape `status` does, so a caller only ever has to render one table.
public struct ImageUpdateStatusResponse: Codable, Sendable, Hashable {
  public var tracks: [ImageUpdateTrackDTO]

  public init(tracks: [ImageUpdateTrackDTO] = []) { self.tracks = tracks }
}

extension ImageUpdateStatusResponse {
  private enum CodingKeys: String, CodingKey { case tracks }

  /// A daemon with no tracks may omit the key entirely rather than sending `[]`.
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(tracks: try c.decodeIfPresent([ImageUpdateTrackDTO].self, forKey: .tracks) ?? [])
  }
}
