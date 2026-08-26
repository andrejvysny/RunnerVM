import ConfigLoader
import Foundation
import RunnerCore

@testable import Orchestration

/// Short root under /tmp: the daemon socket lives inside it and `sun_path` holds 104 bytes.
struct TempTree {
  let root: URL

  init() throws {
    root = URL(
      fileURLWithPath: "/tmp/rvm-orch-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  var paths: RunnerPaths {
    RunnerPaths(
      rootDir: root.appending(path: "state", directoryHint: .isDirectory),
      runtimeDir: root.appending(path: "sock", directoryHint: .isDirectory))
  }

  func file(_ name: String, contents: String) throws -> URL {
    let url = root.appending(path: name)
    try Data(contents.utf8).write(to: url)
    return url
  }

  /// Stand-in for the signed `vmworker probe` binary: prints canned `HostCapabilities` JSON.
  func vmworkerStub() throws -> URL {
    let url = root.appending(path: "vmworker-stub")
    try Data(Self.stubScript.utf8).write(to: url)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
    return url
  }

  /// `ImageStore` publishes image blobs as a read-only tree (files `0o444`, directories `0o555`,
  /// see `Sources/ImageStore/FileSystem.swift`) so a build can't mutate a sealed image by
  /// accident. Deleting through such a directory needs the owner-write bit `removeItem` doesn't
  /// have, so it fails with `EPERM`/"Directory not empty" -- silently, because this is `try?` --
  /// and leaves the whole tree behind as an orphaned `/tmp/rvm-orch-*` directory. Restore
  /// owner-write everywhere under `root` first.
  func remove() {
    makeTreeWritable(root)
    try? FileManager.default.removeItem(at: root)
  }

  private func makeTreeWritable(_ url: URL) {
    let fm = FileManager.default
    restoreOwnerWrite(at: url)
    guard
      let enumerator = fm.enumerator(
        at: url, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in true })
    else { return }
    for case let child as URL in enumerator {
      restoreOwnerWrite(at: child)
    }
  }

  private func restoreOwnerWrite(at url: URL) {
    let fm = FileManager.default
    let path = url.path(percentEncoded: false)
    guard let mode = (try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber
    else { return }
    try? fm.setAttributes([.posixPermissions: mode.uint16Value | 0o200], ofItemAtPath: path)
  }

  private static let stubScript = """
    #!/bin/sh
    cat <<'JSON'
    {
      "virtualizationSupported": true,
      "architecture": "arm64",
      "hostOSVersion": "15.4.0",
      "logicalCPUCount": 12,
      "physicalMemoryBytes": 68719476736,
      "minimumAllowedCPUCount": 1,
      "maximumAllowedCPUCount": 12,
      "minimumAllowedMemoryBytes": 134217728,
      "maximumAllowedMemoryBytes": 68719476736,
      "nestedVirtualizationSupported": false,
      "macOSGuestLimit": 2
    }
    JSON
    """
}

func exampleConfiguration() throws -> RunnerConfiguration {
  try ConfigLoader.load(yaml: ExampleConfig.example)
}

/// A second linux profile alongside the example's `ubuntu-24`, for tests that exercise
/// profile-level add/remove/update diffing against the applier. (The shipped example now carries
/// a single profile since this build rejects macOS guests; see `ExampleConfig`.)
private let secondExampleProfile = RunnerProfileConfig(
  name: "ubuntu-22",
  scope: "engineering",
  image: "ghcr.io/acme/runners/ubuntu-22:stable",
  guestOS: .linux,
  limits: ProfileLimits(maxInstances: 4)
)

func exampleWithSecondProfile() throws -> RunnerConfiguration {
  var config = try exampleConfiguration()
  config.profiles.append(secondExampleProfile)
  return config
}
