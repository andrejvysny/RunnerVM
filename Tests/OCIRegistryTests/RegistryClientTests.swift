import Foundation
@testable import OCIRegistry
import RunnerCore
import Testing

struct RegistryClientTests {
  private static let repository = "acme/runnervm/ubuntu-24"

  private func sampleManifest(configDigest: String = "sha256:" + String(repeating: "c", count: 64))
    -> OCIManifest
  {
    RunnerVMArtifact.makeManifest(
      config: OCIDescriptor(mediaType: RunnerVMMediaType.config, digest: configDigest, size: 42),
      diskChunks: [
        OCIDescriptor(
          mediaType: RunnerVMMediaType.diskChunk, digest: "sha256:" + String(repeating: "d", count: 64),
          size: 100,
          annotations: [
            RunnerVMAnnotation.chunkIndex: "0",
            RunnerVMAnnotation.chunkUncompressedSize: "1024",
            RunnerVMAnnotation.chunkUncompressedDigest: "sha256:" + String(repeating: "e", count: 64),
          ]
        ),
      ],
      nvram: nil, diskVirtualSize: 1024,
      diskContentDigest: "sha256:" + String(repeating: "f", count: 64),
      createdAt: Fixtures.createdAt
    )
  }

  @Test func manifestEncodingIsDeterministic() throws {
    let manifest = sampleManifest()
    #expect(try manifest.encoded() == (manifest.encoded()))
    #expect(try OCIJSON.digest(manifest.encoded()) == (OCIJSON.digest(manifest.encoded())))
  }

  @Test func manifestRoundTripsThroughTheRegistry() async throws {
    let fake = FakeRegistry()
    defer { fake.shutdown() }
    let client = fake.makeClient()
    let manifest = sampleManifest()

    let pushed = try await client.putManifest(
      manifest, repository: Self.repository, reference: "stable"
    )
    #expect(try pushed.rawValue == (OCIJSON.digest(manifest.encoded())))

    let resolved = try await client.resolve(fake.reference(Self.repository, tag: "stable"))
    #expect(resolved.digest == pushed)
    #expect(resolved.manifest == manifest)
    #expect(resolved.reference.digest == pushed)
    #expect(resolved.reference.tag == nil)
    #expect(try await client.tags(repository: Self.repository) == ["stable"])
  }

  @Test func resolveFollowsAnIndexToTheArm64Entry() async throws {
    let fake = FakeRegistry()
    defer { fake.shutdown() }
    let client = fake.makeClient()
    let manifest = sampleManifest()
    let manifestBytes = try manifest.encoded()
    let manifestDigest = fake.putManifest(
      manifestBytes, repository: Self.repository, reference: ContentDigest.hash(manifestBytes)
    )
    let index = OCIIndex(manifests: [
      OCIDescriptor(
        mediaType: RunnerVMMediaType.ociManifest,
        digest: "sha256:" + String(repeating: "1", count: 64), size: 10,
        platform: OCIPlatform(architecture: "amd64", os: "linux")
      ),
      OCIDescriptor(
        mediaType: RunnerVMMediaType.ociManifest, digest: manifestDigest,
        size: Int64(manifestBytes.count), artifactType: RunnerVMMediaType.artifact,
        platform: OCIPlatform(architecture: "arm64", os: "linux")
      ),
    ])
    try fake.putManifest(
      index.encoded(), repository: Self.repository, reference: "multi",
      mediaType: RunnerVMMediaType.ociIndex
    )

    let resolved = try await client.resolve(fake.reference(Self.repository, tag: "multi"))
    #expect(resolved.digest.rawValue == manifestDigest)
    #expect(resolved.manifest == manifest)
  }

  @Test func indexWithoutASupportedPlatformIsRejected() async throws {
    let fake = FakeRegistry()
    defer { fake.shutdown() }
    let index = OCIIndex(manifests: [
      OCIDescriptor(
        mediaType: RunnerVMMediaType.ociManifest,
        digest: "sha256:" + String(repeating: "1", count: 64), size: 10,
        platform: OCIPlatform(architecture: "amd64", os: "windows")
      ),
    ])
    try fake.putManifest(
      index.encoded(), repository: Self.repository, reference: "multi",
      mediaType: RunnerVMMediaType.ociIndex
    )
    do {
      _ = try await fake.makeClient().resolve(fake.reference(Self.repository, tag: "multi"))
      Issue.record("expected an unsupported manifest error")
    } catch let error as RegistryError {
      #expect(error.code == "REGISTRY_UNSUPPORTED_MANIFEST")
    }
  }

  @Test func missingManifestIsNotFound() async throws {
    let fake = FakeRegistry()
    defer { fake.shutdown() }
    do {
      _ = try await fake.makeClient().resolve(fake.reference(Self.repository, tag: "absent"))
      Issue.record("expected a not-found error")
    } catch let error as RegistryError {
      #expect(error.code == "REGISTRY_NOT_FOUND")
      #expect(!error.retryable)
    }
  }

  @Test func blobExistenceIsReportedWithoutABody() async throws {
    let fake = FakeRegistry()
    defer { fake.shutdown() }
    let digest = fake.putBlob(Data("hello".utf8))
    let client = fake.makeClient()
    #expect(try await client.blobExists(digest, repository: Self.repository))
    #expect(try await !client.blobExists(
      "sha256:" + String(repeating: "0", count: 64),
      repository: Self.repository
    ))
  }

  @Test func chunkedPushRespectsTheConfiguredChunkSize() async throws {
    let fake = FakeRegistry()
    defer { fake.shutdown() }
    let client = fake.makeClient(
      options: RegistryClient.Options(uploadChunkBytes: 1024 * 1024)
    )
    let payload = Fixtures.pattern(seed: 7, count: 5 * 1024 * 1024 + 17)
    let digest = try await client.pushBlob(payload, repository: Self.repository)

    #expect(fake.blob(digest) == payload)
    let patches = fake.requests("PATCH", containing: "/blobs/uploads/")
    #expect(patches.count == 6)
    #expect(patches.allSatisfy { $0.bodyBytes <= 1024 * 1024 })
    // Offsets must be contiguous, which is what the fake's 416 would otherwise have caught.
    var expectedStart = 0
    for patch in patches {
      #expect(patch.header("Content-Range") == "\(expectedStart)-\(expectedStart + patch.bodyBytes - 1)")
      expectedStart += patch.bodyBytes
    }
    #expect(fake.requests("PUT", containing: "/blobs/uploads/").count == 1)
  }

  @Test func smallBlobUsesAMonolithicUpload() async throws {
    let fake = FakeRegistry()
    defer { fake.shutdown() }
    let client = fake.makeClient()
    let digest = try await client.pushBlob(Data("small".utf8), repository: Self.repository)
    #expect(fake.blob(digest) == Data("small".utf8))
    #expect(fake.requests("PATCH", containing: "/blobs/uploads/").isEmpty)
  }

  @Test func registryRejectsAChunkAtOrAboveFourMegabytes() async throws {
    let fake = FakeRegistry()
    defer { fake.shutdown() }
    // GHCR's real limit; a client configured above it must fail loudly, not silently truncate.
    let client = fake.makeClient(options: RegistryClient.Options(uploadChunkBytes: 5 * 1024 * 1024))
    let payload = Fixtures.pattern(seed: 3, count: 12 * 1024 * 1024)
    do {
      _ = try await client.pushBlob(payload, repository: Self.repository)
      Issue.record("expected the oversized chunk to be rejected")
    } catch let error as RegistryError {
      #expect(error.code == "REGISTRY_INVALID_RESPONSE")
      #expect(error.message.contains("413"))
    }
  }

  @Test func blobPullResumesAfterADroppedConnection() async throws {
    let fake = FakeRegistry()
    defer { fake.shutdown() }
    let payload = Fixtures.pattern(seed: 11, count: 6 * 1024 * 1024)
    let digest = fake.putBlob(payload)
    fake.disconnectNextBlobGet(afterBytes: 4 * 1024 * 1024)

    var received = Data()
    try await fake.makeClient().pullBlob(digest, repository: Self.repository) { received.append($0) }

    #expect(received == payload)
    let gets = fake.requests("GET", containing: "/blobs/")
    #expect(gets.count == 2)
    #expect(gets[0].header("Range") == nil)
    #expect(gets[1].header("Range") == "bytes=4194304-")
  }

  @Test func transientFailureIsRetried() async throws {
    let fake = FakeRegistry()
    defer { fake.shutdown() }
    let payload = Data("retry me".utf8)
    let digest = fake.putBlob(payload)
    fake.failNextBlobGet(status: 503)

    var received = Data()
    try await fake.makeClient().pullBlob(digest, repository: Self.repository) { received.append($0) }
    #expect(received == payload)
    #expect(fake.requests("GET", containing: "/blobs/").count == 2)
  }

  @Test func corruptedBlobIsRejectedByDigest() async throws {
    let fake = FakeRegistry()
    defer { fake.shutdown() }
    let digest = fake.putBlob(Fixtures.pattern(seed: 5, count: 4096))
    fake.corruptBlob(digest)

    do {
      try await fake.makeClient().pullBlob(digest, repository: Self.repository) { _ in }
      Issue.record("expected a digest mismatch")
    } catch let error as RegistryError {
      #expect(error.code == "REGISTRY_DIGEST_MISMATCH")
      #expect(!error.retryable)
    }
  }

  @Test func shortBlobIsRejectedAgainstItsDeclaredSize() async throws {
    let fake = FakeRegistry()
    defer { fake.shutdown() }
    let digest = fake.putBlob(Data("four".utf8))
    do {
      try await fake.makeClient().pullBlob(
        digest, repository: Self.repository, expectedSize: 99
      ) { _ in }
      Issue.record("expected a length mismatch")
    } catch let error as RegistryError {
      #expect(error.code == "REGISTRY_INVALID_RESPONSE")
    }
  }
}
