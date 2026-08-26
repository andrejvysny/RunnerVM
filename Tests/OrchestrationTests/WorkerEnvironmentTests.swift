import Darwin
import Foundation
import RunnerCore
import Testing

@testable import Orchestration

@Suite struct WorkerEnvironmentTests {
  @Test func allowlistsOnlyKnownVariablesAndDropsSecrets() {
    let parent: [String: String] = [
      "RUNNERVM_GITHUB_TOKEN": "ghp_secret",
      "GITHUB_TOKEN": "gh_secret",
      "RUNNERVM_REGISTRY_TOKEN": "registry_secret",
      "AWS_SECRET_ACCESS_KEY": "aws_secret",
      "PATH": "/custom/bin",
      "HOME": "/Users/test",
    ]

    let result = WorkerEnvironment.build(from: parent)

    #expect(result == ["PATH": "/custom/bin", "HOME": "/Users/test"])
  }

  @Test func missingPATHFallsBackToAMinimalSearchPath() {
    let result = WorkerEnvironment.build(from: ["HOME": "/Users/test"])

    #expect(result["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
    #expect(result["HOME"] == "/Users/test")
  }

  /// Process-level regression test: spawns a real child through `ProcessWorkerLauncher` with a
  /// GitHub credential set in the parent's actual environment, and asserts the secret never
  /// reaches the child's environment -- exercising the allowlist through `posix_spawn` itself,
  /// not just the pure `build` function.
  @Test func realSpawnNeverForwardsSecretsToTheWorkerProcess() async throws {
    setenv("RUNNERVM_GITHUB_TOKEN", "very-secret", 1)
    defer { unsetenv("RUNNERVM_GITHUB_TOKEN") }

    let tree = try TempTree()
    defer { tree.remove() }

    let scriptURL = tree.root.appending(path: "env-stub")
    try Data("#!/bin/sh\nenv\n".utf8).write(to: scriptURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path(percentEncoded: false))

    let logURL = tree.root.appending(path: "worker.log")
    let request = WorkerLaunchRequest(
      instanceId: InstanceID(rawValue: "test-instance"),
      specPath: tree.root.appending(path: "spec.json"),
      socketDir: tree.root.appending(path: "sockets", directoryHint: .isDirectory),
      generation: 1, nonce: "nonce", logPath: logURL)

    let launcher = ProcessWorkerLauncher(executable: scriptURL)
    let handle = try await launcher.launch(request)

    var status: Int32 = 0
    var waited: pid_t = 0
    repeat {
      waited = waitpid(handle.pid, &status, 0)
    } while waited == -1 && errno == EINTR

    let log = try String(contentsOf: logURL, encoding: .utf8)
    #expect(log.contains("PATH="))
    #expect(!log.contains("very-secret"))
    #expect(!log.contains("RUNNERVM_GITHUB_TOKEN"))
  }
}
