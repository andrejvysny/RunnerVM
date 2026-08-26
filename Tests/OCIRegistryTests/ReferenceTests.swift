import Foundation
@testable import OCIRegistry
import RunnerCore
import Testing

struct OCIReferenceTests {
  @Test func buildsRegistryURLFromTheHost() throws {
    let reference = try OCIReference(parsing: "ghcr.io/acme/runnervm/ubuntu-24:stable")
    #expect(reference.registryURL.absoluteString == "https://ghcr.io/v2/")
    #expect(reference.repositoryPath == "acme/runnervm/ubuntu-24")
    #expect(reference.manifestReference == "stable")
  }

  @Test func keepsThePortInTheHost() throws {
    let reference = try OCIReference(parsing: "registry.internal:5000/team/image:v1")
    #expect(reference.registryURL.absoluteString == "https://registry.internal:5000/v2/")
  }

  @Test(arguments: ["localhost:5000", "127.0.0.1:5000"])
  func downgradesToHTTPOnlyForLoopback(host: String) throws {
    let loopback = try OCIReference(parsing: "\(host)/team/image:v1", insecure: true)
    #expect(loopback.registryURL.scheme == "http")
  }

  @Test func refusesToDowngradeARemoteRegistry() throws {
    let remote = try OCIReference(parsing: "ghcr.io/acme/image:v1", insecure: true)
    #expect(remote.registryURL.scheme == "https")
  }

  @Test func digestWinsOverTag() throws {
    let digest = "sha256:" + String(repeating: "a", count: 64)
    let reference = try OCIReference(parsing: "ghcr.io/acme/image:stable@\(digest)")
    #expect(reference.manifestReference == digest)
  }

  @Test func defaultsToLatestWhenNoTagIsGiven() throws {
    #expect(try OCIReference(parsing: "ghcr.io/acme/image").manifestReference == "latest")
  }

  @Test func canonicalFormDropsTheMovingTag() throws {
    let digest = ImageDigest(rawValue: "sha256:" + String(repeating: "b", count: 64))
    let canonical = try OCIReference(parsing: "ghcr.io/acme/image:stable").canonical(withDigest: digest)
    #expect(canonical.tag == nil)
    #expect(canonical.digest == digest)
    #expect(canonical.description == "ghcr.io/acme/image@\(digest.rawValue)")
  }

  @Test func rejectsRegistrylessShorthand() {
    #expect(throws: ImageError.self) { try OCIReference(parsing: "ubuntu:24.04") }
  }
}
