import Foundation
import GRDB
import RunnerCore

/// Mirrors the `managed_images` table (`docs/db_schema_v4.sql`). `name` is the primary key: the
/// stable local name operators and profiles refer to (parallel to `image_aliases.name`, but for an
/// image this daemon keeps auto-updating rather than one a build produced once).
public struct ManagedImageRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
  public var name: String
  public var kind: ManagedImageKind
  public var sourceReference: String
  public var lastSourceDigest: String?
  public var currentImageDigest: ImageDigest?
  public var candidateImageDigest: ImageDigest?
  /// JSON array of prior `current_image_digest` values, most recent last. Decode/encode via
  /// `decodedPreviousDigests()` / `ManagedImageRecord.encodePreviousDigests(_:)`.
  public var previousDigestsJson: String
  public var state: ManagedImageState
  public var lastCheckedAt: DatabaseDate?
  public var lastUpdatedAt: DatabaseDate?
  public var lastError: String?
  public var autoUpdate: Bool
  public var updatedAt: DatabaseDate

  public init(
    name: String, kind: ManagedImageKind, sourceReference: String, lastSourceDigest: String? = nil,
    currentImageDigest: ImageDigest? = nil, candidateImageDigest: ImageDigest? = nil,
    previousDigestsJson: String = "[]", state: ManagedImageState = .idle,
    lastCheckedAt: DatabaseDate? = nil, lastUpdatedAt: DatabaseDate? = nil, lastError: String? = nil,
    autoUpdate: Bool = true, updatedAt: DatabaseDate
  ) {
    self.name = name
    self.kind = kind
    self.sourceReference = sourceReference
    self.lastSourceDigest = lastSourceDigest
    self.currentImageDigest = currentImageDigest
    self.candidateImageDigest = candidateImageDigest
    self.previousDigestsJson = previousDigestsJson
    self.state = state
    self.lastCheckedAt = lastCheckedAt
    self.lastUpdatedAt = lastUpdatedAt
    self.lastError = lastError
    self.autoUpdate = autoUpdate
    self.updatedAt = updatedAt
  }

  public static let databaseTableName = "managed_images"

  private enum CodingKeys: String, CodingKey {
    case name, kind, state
    case sourceReference = "source_reference"
    case lastSourceDigest = "last_source_digest"
    case currentImageDigest = "current_image_digest"
    case candidateImageDigest = "candidate_image_digest"
    case previousDigestsJson = "previous_digests_json"
    case lastCheckedAt = "last_checked_at"
    case lastUpdatedAt = "last_updated_at"
    case lastError = "last_error"
    case autoUpdate = "auto_update"
    case updatedAt = "updated_at"
  }
}

extension ManagedImageRecord {
  /// Decodes `previousDigestsJson` back into an ordered list of prior digests. Throws
  /// `PersistenceError.encodingFailed` rather than a raw `DecodingError` so callers only need to
  /// handle `RunnerError` (mirrors `RunnerProfileRecord.decodedConfig`).
  public func decodedPreviousDigests() throws -> [ImageDigest] {
    do {
      return try JSONDecoder().decode([ImageDigest].self, from: Data(previousDigestsJson.utf8))
    } catch {
      throw PersistenceError.encodingFailed(entity: "managed_images.previous_digests_json", cause: error)
    }
  }

  /// Encodes `digests` for `previousDigestsJson`. Same error-wrapping discipline as
  /// `decodedPreviousDigests`, in the encode direction.
  public static func encodePreviousDigests(_ digests: [ImageDigest]) throws -> String {
    do {
      return String(decoding: try JSONEncoder().encode(digests), as: UTF8.self)
    } catch {
      throw PersistenceError.encodingFailed(entity: "managed_images.previous_digests_json", cause: error)
    }
  }
}
