import Foundation
@testable import GitHubControl
import RunnerCore
import Testing

/// `SecureFile` is the shared open()+fstat() reader behind every GitHub secret file (spec §12,
/// §79): a PAT token file, a GitHub App descriptor, and a GitHub App private key all go through
/// it, so its checks are exercised directly here rather than through each caller.
struct SecureFileTests {
  private static let content = "top-secret\n"

  @Test func readsAnOwnerOnlyRegularFile() async throws {
    try await withFile(mode: 0o600) { url in
      let data = try SecureFile.read(path: url.path(percentEncoded: false), label: "test file")
      #expect(String(data: data, encoding: .utf8) == Self.content)
    }
  }

  @Test func readStringDecodesUTF8() async throws {
    try await withFile(mode: 0o600) { url in
      let string = try SecureFile.readString(path: url.path(percentEncoded: false), label: "test file")
      #expect(string == Self.content)
    }
  }

  @Test func groupReadableIsRejectedUnderOwnerOnly() async throws {
    try await withFile(mode: 0o640) { url in
      let error = captureThrow {
        try SecureFile.read(path: url.path(percentEncoded: false), label: "test file", policy: .ownerOnly)
      }
      let github = try #require(error as? GitHubControlError)
      #expect(github.errorClass == .permanentConfiguration)
      #expect(github.message.contains("640"))
    }
  }

  @Test func groupReadableIsAcceptedUnderOwnerAndGroupRead() async throws {
    try await withFile(mode: 0o640) { url in
      let data = try SecureFile.read(
        path: url.path(percentEncoded: false), label: "test file", policy: .ownerAndGroupRead
      )
      #expect(String(data: data, encoding: .utf8) == Self.content)
    }
  }

  @Test func worldReadableIsRejectedUnderBothPolicies() async throws {
    try await withFile(mode: 0o644) { url in
      for policy: SecureFile.Policy in [.ownerOnly, .ownerAndGroupRead] {
        let error = captureThrow {
          try SecureFile.read(path: url.path(percentEncoded: false), label: "test file", policy: policy)
        }
        let github = try #require(error as? GitHubControlError)
        #expect(github.errorClass == .permanentConfiguration)
        #expect(github.message.contains("644"))
      }
    }
  }

  @Test func symlinkToAnOtherwiseValidFileIsRejected() async throws {
    try await withFile(mode: 0o600) { url in
      let link = url.deletingLastPathComponent().appending(path: "link")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
      let error = captureThrow {
        try SecureFile.read(path: link.path(percentEncoded: false), label: "test file")
      }
      let github = try #require(error as? GitHubControlError)
      #expect(github.errorClass == .permanentConfiguration)
      #expect(github.message.contains("symlink"))
    }
  }

  @Test func directoryIsRejected() throws {
    let directory = URL.temporaryDirectory.appending(path: "runnervm-securefile-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let error = captureThrow {
      try SecureFile.read(path: directory.path(percentEncoded: false), label: "test file")
    }
    let github = try #require(error as? GitHubControlError)
    #expect(github.errorClass == .permanentConfiguration)
    #expect(github.message.contains("not a regular file"))
  }

  @Test func missingFileIsNotFound() {
    let error = captureThrow {
      try SecureFile.read(path: "/nonexistent/runnervm/secret-\(UUID().uuidString)", label: "test file")
    }
    #expect((error as? GitHubControlError)?.errorClass == .notFound)
  }

  @Test func wrongOwnerIsRejectedWithTheOwnerMessage() async throws {
    try await withFile(mode: 0o600) { url in
      let wrongOwner = geteuid() + 1
      let error = captureThrow {
        try SecureFile.read(
          path: url.path(percentEncoded: false), label: "test file", expectedOwner: wrongOwner
        )
      }
      let github = try #require(error as? GitHubControlError)
      #expect(github.errorClass == .permanentConfiguration)
      #expect(github.message.contains("owned by uid"))
      #expect(github.message.contains("\(wrongOwner)"))
    }
  }

  // MARK: - Helpers

  private func captureThrow(_ body: () throws -> Data) -> (any Error)? {
    do {
      _ = try body()
      return nil
    } catch {
      return error
    }
  }

  private func withFile(mode: Int, _ body: (URL) async throws -> Void) async throws {
    let directory = URL.temporaryDirectory.appending(path: "runnervm-securefile-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "secret")
    try Data(Self.content.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    try await body(url)
  }
}
