import Foundation
import RPC
import RunnerCore
import Testing

@testable import DaemonAPI

/// Wire shape of `image.update.*` (phase D6). These fixtures are the contract: a field added later
/// must keep every one of them decoding.
@Suite struct ImageUpdateDTOTests {
  private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
  }

  @Test func bothRequestsDecodeFromAnEmptyObject() throws {
    #expect(try Self.decode(ImageUpdateCheckRequest.self, "{}").managed == nil)
    #expect(try Self.decode(ImageUpdateRunRequest.self, "{}").managed == nil)
    #expect(
      try Self.decode(ImageUpdateCheckRequest.self, #"{"managed": "ghcr.io/a/b:stable"}"#).managed
        == "ghcr.io/a/b:stable")
    // A newer client may send fields this daemon has never heard of.
    #expect(
      try Self.decode(ImageUpdateRunRequest.self, #"{"managed": "x", "force": true}"#).managed
        == "x")
  }

  @Test func aTrackDecodesFromTheFourFieldsThatAlwaysTravel() throws {
    let track = try Self.decode(ImageUpdateTrackDTO.self, """
      {"name": "ghcr.io/a/b:stable", "kind": "registryTag",
       "sourceReference": "ghcr.io/a/b:stable", "state": "idle"}
      """)
    #expect(track.name == "ghcr.io/a/b:stable")
    #expect(track.kind == "registryTag")
    #expect(track.state == "idle")
    #expect(track.lastSourceDigest == nil)
    #expect(track.currentImageDigest == nil)
    #expect(track.candidateImageDigest == nil)
    #expect(track.lastCheckedAt == nil)
    #expect(track.lastUpdatedAt == nil)
    #expect(track.lastError == nil)
    // A daemon that predates the flag tracked everything it knew about.
    #expect(track.autoUpdate)
  }

  @Test func aTrackReadsEveryField() throws {
    let track = try Self.decode(ImageUpdateTrackDTO.self, """
      {"name": "macos-tahoe", "kind": "macosTart",
       "sourceReference": "ghcr.io/cirruslabs/macos-tahoe-base:latest",
       "lastSourceDigest": "sha256:aa", "currentImageDigest": "sha256:bb",
       "candidateImageDigest": "sha256:cc", "state": "qualifying",
       "lastCheckedAt": "2026-08-28T10:00:00.000Z",
       "lastUpdatedAt": "2026-08-27T10:00:00.000Z",
       "lastError": "boom", "autoUpdate": false}
      """)
    #expect(track.kind == "macosTart")
    #expect(track.sourceReference == "ghcr.io/cirruslabs/macos-tahoe-base:latest")
    #expect(track.lastSourceDigest == "sha256:aa")
    #expect(track.currentImageDigest == "sha256:bb")
    #expect(track.candidateImageDigest == "sha256:cc")
    #expect(track.state == "qualifying")
    #expect(track.lastCheckedAt == "2026-08-28T10:00:00.000Z")
    #expect(track.lastUpdatedAt == "2026-08-27T10:00:00.000Z")
    #expect(track.lastError == "boom")
    #expect(!track.autoUpdate)
  }

  @Test func theResponseToleratesAMissingTracksKey() throws {
    #expect(try Self.decode(ImageUpdateStatusResponse.self, "{}").tracks.isEmpty)
    #expect(try Self.decode(ImageUpdateStatusResponse.self, #"{"tracks": []}"#).tracks.isEmpty)
  }

  @Test func aTrackRoundTripsThroughJSON() throws {
    let track = ImageUpdateTrackDTO(
      name: "ghcr.io/a/b:stable", kind: "registryTag", sourceReference: "ghcr.io/a/b:stable",
      lastSourceDigest: "sha256:aa", currentImageDigest: "sha256:bb", state: "idle",
      lastCheckedAt: "2026-08-28T10:00:00.000Z", autoUpdate: true)
    let response = ImageUpdateStatusResponse(tracks: [track])
    let encoded = try JSONEncoder().encode(response)
    #expect(try JSONDecoder().decode(ImageUpdateStatusResponse.self, from: encoded) == response)
  }

  /// `system.status.updates` is optional for the same reason `builds` is.
  @Test func systemStatusDecodesWithoutAnUpdatesBlock() throws {
    let encoded = try JSONEncoder().encode(sampleStatus())
    let status = try JSONDecoder().decode(SystemStatus.self, from: encoded)
    #expect(status.updates == nil)
  }
}
