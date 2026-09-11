import Foundation
import RunnerCore
import Testing

@testable import HostSetup

/// The three pure pieces `runnerctl upgrade` is built on: the manifest document, version ordering,
/// and URL resolution. `scripts/bootstrap.sh` parses the same document with `jq`, so the shapes
/// these tests pin are a two-implementation contract, not an internal detail.
@Suite struct ReleaseManifestTests {
  /// The nine-key document `scripts/build-package.sh` writes for an unsigned (dev) build.
  static let full = """
    {
      "version": "0.3.0",
      "architecture": "arm64",
      "minimumMacOS": "15.0",
      "package": "RunnerVM-macos-arm64.pkg",
      "sha256": "abc123",
      "signed": false,
      "teamId": "",
      "notarized": false,
      "license": "Apache-2.0"
    }
    """

  /// The same document for a release built with the Developer ID certificates.
  static let signedFull = """
    {
      "version": "0.3.0",
      "architecture": "arm64",
      "minimumMacOS": "15.0",
      "package": "RunnerVM-macos-arm64.pkg",
      "sha256": "abc123",
      "signed": true,
      "teamId": "A1B2C3D4E5",
      "notarized": true,
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
    #expect(manifest.teamId == "")
    #expect(manifest.notarized == false)
    #expect(manifest.license == "Apache-2.0")
  }

  @Test func decodesTheSigningKeysOfASignedRelease() throws {
    let manifest = try ReleaseManifest.decode(Self.signedFull)

    #expect(manifest.signed)
    #expect(manifest.teamId == "A1B2C3D4E5")
    #expect(manifest.notarized)
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
    // Same reasoning for the two signing keys added in v0.3.0: a release that predates them
    // claims nothing, and `upgrade` verifies the package itself either way.
    #expect(manifest.teamId == "")
    #expect(manifest.notarized == false)
  }

  @Test func unknownKeysFromANewerReleaseAreIgnored() throws {
    let manifest = try ReleaseManifest.decode(
      #"{"version":"0.9.0","package":"p.pkg","sha256":"ab","sbom":"p.pkg.spdx.json"}"#)

    #expect(manifest.version == "0.9.0")
  }

  /// The name is appended to a release URL, written into the cache directory and handed to
  /// `installer`. `scripts/bootstrap.sh`'s `verify_pkg_name` refuses exactly these, and the two
  /// installers have to refuse the same documents -- so this is checked at decode, before the
  /// download, rather than wherever the string is first used.
  @Test func aPackageNameThatIsNotAPlainPkgFileIsRefused() {
    let refused = [
      "../../etc/cron.d/evil.pkg",
      "/tmp/evil.pkg",
      "-o/tmp/evil.pkg",
      "-rf.pkg",
      "RunnerVM macos.pkg",
      "RunnerVM;reboot.pkg",
      "RunnerVM-macos-arm64.dmg",
      "RunnerVM-macos-arm64.pkg.exe",
      ".pkg",
      "",
    ]
    for name in refused {
      #expect(throws: UpgradeError.self, "\(name)") {
        try ReleaseManifest.decode(
          #"{"version":"0.3.0","package":"\#(name)","sha256":"ab"}"#)
      }
    }
  }

  @Test func aVersionThatIsNotAPlainSemverTokenIsRefused() {
    for version in ["../0.3.0", "0.3.0/..", "0.3", "v0.3.0", "0.3.0-", "0.3.0-rc 1", "0.3.0\n", ""] {
      #expect(throws: UpgradeError.self, "\(version)") {
        try ReleaseManifest.decode(
          #"{"version":"\#(version)","package":"RunnerVM-macos-arm64.pkg","sha256":"ab"}"#)
      }
    }
    for version in ["0.3.0", "0.3.0-rc.1", "10.20.30-beta-2"] {
      #expect(throws: Never.self, "\(version)") {
        try ReleaseManifest.decode(
          #"{"version":"\#(version)","package":"RunnerVM-macos-arm64.pkg","sha256":"ab"}"#)
      }
    }
  }

  /// `Character.isNumber` is true for every Unicode decimal digit, so a version in Arabic-Indic
  /// digits would decode here and be refused by `bootstrap.sh`'s `*[!0-9]*` glob. The version
  /// names the cache directory, so the two installers have to agree on what one may contain.
  @Test func aVersionInNonASCIIDigitsIsRefusedLikeBashRefusesIt() throws {
    for version in ["\u{0661}.\u{0662}.\u{0663}", "0.\u{0663}.0", "\u{FF11}.0.0"] {
      #expect(throws: UpgradeError.self, "\(version)") {
        try ReleaseManifest.decode(
          #"{"version":"\#(version)","package":"p.pkg","sha256":"ab"}"#)
      }
    }
    #expect(try ReleaseManifest.decode(
      #"{"version":"0.3.0","package":"p.pkg","sha256":"ab"}"#).version == "0.3.0")
  }

  @Test func theNamesAReleaseActuallyUsesAreAccepted() throws {
    for name in ["RunnerVM-macos-arm64.pkg", "r.pkg", "RunnerVM_0.3.0-rc.1.pkg"] {
      let manifest = try ReleaseManifest.decode(
        #"{"version":"0.3.0","package":"\#(name)","sha256":"ab"}"#)
      #expect(manifest.package == name)
    }
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

  /// What `--check` prints under "manifest claims". It is a label on the release, which is why it
  /// names the team the *manifest* states -- the gate compares the package's own signature.
  @Test func theSigningClaimRepeatsTheManifestNotTheSignature() throws {
    #expect(try ReleaseManifest.decode(Self.signedFull).signingClaim
      == "signed+notarized (A1B2C3D4E5)")
    #expect(try ReleaseManifest.decode(Self.full).signingClaim == "unsigned")
    #expect(try ReleaseManifest.decode(
      #"{"version":"0.3.0","package":"p.pkg","sha256":"ab","signed":true}"#).signingClaim
      == "signed, not notarized (team not stated)")
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

  /// The tag shape `docs/release.md` uses is `v0.3.0-rc.1`, so the tenth candidate is `rc.10` --
  /// and a lexical comparison puts that *before* `rc.9`, which would make `upgrade --check` offer
  /// an rc host the previous candidate as if it were newer.
  @Test func preReleaseSuffixesOrderNumericallyByDotSegment() throws {
    func version(_ text: String) throws -> SemanticVersion {
      try #require(SemanticVersion(tag: text))
    }

    #expect(try version("0.3.0-rc.9") < version("0.3.0-rc.10"))
    #expect(!(try version("0.3.0-rc.10") < version("0.3.0-rc.9")))
    #expect(try version("0.3.0-rc.2") < version("0.3.0-rc.10"))
    #expect(try version("0.3.0-rc.10") < version("0.3.0"))
    // Equal segments then a longer identifier: `rc` precedes `rc.1`.
    #expect(try version("0.3.0-rc") < version("0.3.0-rc.1"))
    // A non-numeric segment still compares as text, and the parts before the suffix still win.
    #expect(try version("0.3.0-alpha.1") < version("0.3.0-rc.1"))
    #expect(try version("0.3.0-rc.10") < version("0.3.1-rc.1"))
    #expect(!(try version("0.3.0-rc.10") < version("0.3.0-rc.10")))
    // A leading zero is not a semver number, so `rc.01` and `rc.1` stay two distinct suffixes
    // with a stable order rather than comparing equivalent while being unequal.
    #expect(try version("0.3.0-rc.01") < version("0.3.0-rc.1"))
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

  /// The same precedence `scripts/bootstrap.sh` documents (`RUNNERVM_PKG_URL` >
  /// `RUNNERVM_VERSION` > latest). Two installers that disagree about where a release comes from
  /// only show it on the host that has both set, which is the worst place to find out.
  @Test func resolvePrefersTheOverrideThenTheVersionThenLatest() {
    #expect(ReleaseSource.resolve(version: "v0.3.0", overrideURL: "file:///mirror").baseURL
      == "file:///mirror/")
    #expect(ReleaseSource.resolve(version: "v0.3.0", overrideURL: nil).baseURL
      == "https://github.com/andrejvysny/RunnerVM/releases/download/v0.3.0/")
    #expect(ReleaseSource.resolve(version: nil, overrideURL: "file:///mirror").baseURL
      == "file:///mirror/")
    #expect(ReleaseSource.resolve(version: "v0.3.0", overrideURL: "").baseURL
      == "https://github.com/andrejvysny/RunnerVM/releases/download/v0.3.0/")
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
