import Foundation
import RunnerCore
import Testing

@testable import HostSetup

/// The three pure pieces `runnerctl upgrade` is built on: the manifest document, version ordering,
/// and URL resolution. `scripts/bootstrap.sh` parses the same document with `jq`, so the shapes
/// these tests pin are a two-implementation contract, not an internal detail.
@Suite struct ReleaseManifestTests {
  static let full = """
    {
      "version": "0.3.0",
      "architecture": "arm64",
      "minimumMacOS": "15.0",
      "package": "RunnerVM-macos-arm64.pkg",
      "sha256": "abc123",
      "signed": false,
      "license": "Apache-2.0"
    }
    """

  // MARK: - Decoding

  @Test func decodesTheDocumentScriptsBuildPackageWrites() throws {
    let manifest = try ReleaseManifest.decode(Self.full)

    #expect(manifest.version == "0.3.0")
    #expect(manifest.architecture == "arm64")
    #expect(manifest.minimumMacOS == "15.0")
    #expect(manifest.package == "RunnerVM-macos-arm64.pkg")
    #expect(manifest.sha256 == "abc123")
    #expect(manifest.signed == false)
    #expect(manifest.license == "Apache-2.0")
  }

  /// A release published before a key existed still has to install.
  @Test func optionalKeysFallBackRatherThanFailing() throws {
    let manifest = try ReleaseManifest.decode(
      #"{"version":"0.3.0","package":"p.pkg","sha256":"deadbeef"}"#)

    #expect(manifest.architecture == "arm64")
    #expect(manifest.minimumMacOS == "15.0")
    #expect(manifest.license == "Apache-2.0")
    // Unsigned is the safe default: it makes upgrade warn rather than silently skip the warning.
    #expect(manifest.signed == false)
  }

  @Test func unknownKeysFromANewerReleaseAreIgnored() throws {
    let manifest = try ReleaseManifest.decode(
      #"{"version":"0.9.0","package":"p.pkg","sha256":"ab","notarized":true}"#)

    #expect(manifest.version == "0.9.0")
  }

  @Test func aManifestWithoutTheFieldsAnInstallerNeedsIsRefused() {
    #expect(throws: UpgradeError.self) {
      try ReleaseManifest.decode(#"{"version":"0.3.0"}"#)
    }
    #expect(throws: UpgradeError.self) {
      try ReleaseManifest.decode("not json at all")
    }
  }

  @Test func summaryNamesTheSigningState() throws {
    let manifest = try ReleaseManifest.decode(Self.full)

    #expect(manifest.summary.contains("0.3.0"))
    #expect(manifest.summary.contains("unsigned"))
  }

  // MARK: - Platform gate

  @Test func aManifestForAnotherArchitectureIsRefusedBeforeAnythingIsDownloaded() throws {
    var manifest = try ReleaseManifest.decode(Self.full)
    manifest.architecture = "x86_64"

    #expect(throws: UpgradeError.self) {
      try manifest.validatePlatform(architecture: "arm64", macOSMajor: 26)
    }
  }

  @Test func aManifestRequiringANewerMacOSIsRefused() throws {
    var manifest = try ReleaseManifest.decode(Self.full)
    manifest.minimumMacOS = "27.0"

    #expect(throws: UpgradeError.self) {
      try manifest.validatePlatform(architecture: "arm64", macOSMajor: 26)
    }
  }

  @Test func aMatchingPlatformPasses() throws {
    let manifest = try ReleaseManifest.decode(Self.full)

    try manifest.validatePlatform(architecture: "arm64", macOSMajor: 15)
  }

  // MARK: - SemanticVersion

  /// One implementation, shared with the runner-version-health policy in `RunnerCore`: release
  /// tags and `actions/runner` versions must never be ordered by two different rules. Only the
  /// pre-release suffix differs, and it is opt-in — see `aPreReleaseSuffixIsTagOnly`.
  @Test func parsesEveryFormATagTakes() {
    #expect(SemanticVersion(tag: "0.2.0") == SemanticVersion(major: 0, minor: 2, patch: 0))
    #expect(SemanticVersion(tag: "v0.2.0") == SemanticVersion(major: 0, minor: 2, patch: 0))
    #expect(SemanticVersion(tag: " 1.10.3 ") == SemanticVersion(major: 1, minor: 10, patch: 3))
    // Missing components read as zero, so "0.2" and "0.2.0" are the same release.
    #expect(SemanticVersion(tag: "0.2") == SemanticVersion(major: 0, minor: 2, patch: 0))
    #expect(
      SemanticVersion(tag: "0.3.0-rc1")
        == SemanticVersion(major: 0, minor: 3, patch: 0, suffix: "rc1"))
  }

  /// `actions/runner` never publishes a suffix, and the runner-version-health policy reports a
  /// string it does not recognise as `unknown` rather than guessing which side of a release a
  /// `-beta` build falls on. So the strict initializer keeps refusing one.
  @Test func aPreReleaseSuffixIsTagOnly() {
    #expect(SemanticVersion("2.336.0-beta") == nil)
    #expect(SemanticVersion(tag: "2.336.0-beta") != nil)
  }

  @Test func refusesAnythingThatIsNotAVersion() {
    #expect(SemanticVersion(tag: "") == nil)
    #expect(SemanticVersion(tag: "latest") == nil)
    #expect(SemanticVersion(tag: "0.2.0.1") == nil)
    #expect(SemanticVersion(tag: "0.x.0") == nil)
    #expect(SemanticVersion(tag: nil) == nil)
  }

  @Test func ordersByComponentThenTreatsAPreReleaseAsEarlier() throws {
    func version(_ text: String) throws -> SemanticVersion {
      try #require(SemanticVersion(tag: text))
    }
    let base = try version("0.2.0")

    #expect(try base < version("0.2.1"))
    #expect(try base < version("0.3.0"))
    #expect(try base < version("1.0.0"))
    #expect(try version("0.3.0-rc1") < version("0.3.0"))
    #expect(try version("0.3.0-rc1") < version("0.3.0-rc2"))
    #expect(!(base < base))
  }

  @Test func descriptionRoundTrips() throws {
    #expect(try #require(SemanticVersion(tag: "v0.3.0-rc1")).description == "0.3.0-rc1")
    #expect(try #require(SemanticVersion(tag: "0.2")).description == "0.2.0")
  }

  // MARK: - ReleaseSource

  @Test func latestUsesTheSameRedirectTheCurlOneLinerUses() {
    let source = ReleaseSource.latest()

    #expect(source.manifestURL
      == "https://github.com/andrejvysny/RunnerVM/releases/latest/download/release-manifest.json")
    #expect(source.assetURL("RunnerVM-macos-arm64.pkg")
      == "https://github.com/andrejvysny/RunnerVM/releases/latest/download/RunnerVM-macos-arm64.pkg")
  }

  @Test func anExplicitVersionResolvesToItsTagDirectory() {
    #expect(ReleaseSource.tagged("v0.3.0").manifestURL
      == "https://github.com/andrejvysny/RunnerVM/releases/download/v0.3.0/release-manifest.json")
    // The tag always carries the v, whether the operator typed one or not.
    #expect(ReleaseSource.tagged("0.3.0").baseURL == ReleaseSource.tagged("v0.3.0").baseURL)
  }

  @Test func resolvePrefersTheVersionThenTheOverrideThenLatest() {
    #expect(ReleaseSource.resolve(version: "v0.3.0", overrideURL: "file:///mirror").baseURL
      == "https://github.com/andrejvysny/RunnerVM/releases/download/v0.3.0/")
    #expect(ReleaseSource.resolve(version: nil, overrideURL: "file:///mirror").baseURL
      == "file:///mirror/")
    #expect(ReleaseSource.resolve(version: nil, overrideURL: nil).baseURL
      == ReleaseSource.latest().baseURL)
  }

  @Test func aTrailingSlashIsNormalisedRatherThanDoubled() {
    #expect(ReleaseSource(baseURL: "file:///m/").assetURL("a.pkg") == "file:///m/a.pkg")
    #expect(ReleaseSource(baseURL: "file:///m").assetURL("a.pkg") == "file:///m/a.pkg")
  }

  // MARK: - UpgradeCheck

  @Test func verdictComparesTheInstalledStringAgainstTheManifest() {
    func verdict(current: String, released: String) -> UpgradeCheck.Verdict {
      UpgradeCheck(
        current: current,
        manifest: ReleaseManifest(version: released, package: "p.pkg", sha256: "ab")).verdict
    }

    #expect(verdict(current: "0.2.0", released: "0.3.0") == .upgradeAvailable)
    #expect(verdict(current: "0.2.0", released: "0.2.0") == .upToDate)
    #expect(verdict(current: "0.3.0", released: "0.2.0") == .newerInstalled)
    #expect(verdict(current: "dev", released: "0.2.0") == .unknown)
  }

  /// An uncomparable pair still offers the upgrade: a version string nobody can parse is not a
  /// reason to refuse to install a release the operator asked for.
  @Test func onlyAnUpToDateOrNewerHostIsANoOp() {
    func available(current: String, released: String) -> Bool {
      UpgradeCheck(
        current: current,
        manifest: ReleaseManifest(version: released, package: "p.pkg", sha256: "ab"))
        .upgradeAvailable
    }

    #expect(available(current: "0.2.0", released: "0.3.0"))
    #expect(available(current: "dev", released: "0.3.0"))
    #expect(!available(current: "0.2.0", released: "0.2.0"))
    #expect(!available(current: "0.4.0", released: "0.3.0"))
  }
}
