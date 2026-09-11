import Testing

@testable import HostSetup

/// Tool output the parser has to keep understanding, kept in one place because `UpgraderTests`
/// scripts the same strings through `RecordingCommandRunner`.
///
/// Provenance matters here more than in most fixtures: this is a parsing contract with Apple, so
/// anything not captured from a real run is marked, and the marked ones are replaced with captured
/// output at the first signed release candidate (PLAN 4.1's local dry run).
enum SignatureFixtures {
  /// The team on the captured Developer ID chain below.
  static let capturedTeam = "FYF2F5GFX4"
  /// Some other publisher's team, for the refusal that has no override.
  static let foreignTeam = "A1B2C3D4E5"

  /// Captured: `pkgbuild`-produced unsigned pkg, macOS 26, `pkgutil --check-signature` (exit 1).
  static let unsignedPkgutil = """
    Package "test.pkg":
       Status: no signature
    """

  /// Captured: the same package, `spctl --assess -t install -vv` (exit 3, on stderr).
  static let unsignedSpctl = """
    test.pkg: rejected
    source=no usable signature
    """

  /// Captured from a third-party Developer ID Installer package that Apple has notarized
  /// (`pkgutil --check-signature`, macOS 26, exit 0). Verbatim apart from trailing whitespace on
  /// the wrapped fingerprint lines.
  static let notarizedPkgutil = """
    Package "quarto--1.10.18.pkg":
       Status: signed by a developer certificate issued by Apple for distribution
       Notarization: trusted by the Apple notary service
       Signed with a trusted timestamp on: 2026-07-24 13:46:37 +0000
       Certificate Chain:
        1. Developer ID Installer: RStudio Inc. (FYF2F5GFX4)
           Expires: 2031-05-21 22:28:17 +0000
           SHA256 Fingerprint:
               A3 21 2A 1F 72 36 54 2F 3C 3D 16 11 3F 30 03 A1 8A A3 43 56 D2 35
               D7 4A E7 EC AA 19 17 3A 2D 8D
           ------------------------------------------------------------------------
        2. Developer ID Certification Authority
           Expires: 2031-09-17 00:00:00 +0000
           SHA256 Fingerprint:
               F1 6C D3 C5 4C 7F 83 CE A4 BF 1A 3E 6A 08 19 C8 AA A8 E4 A1 52 8F
               D1 44 71 5F 35 06 43 D2 DF 3A
           ------------------------------------------------------------------------
        3. Apple Root CA
           Expires: 2035-02-09 21:40:36 +0000
           SHA256 Fingerprint:
               B0 B1 73 0E CB C7 FF 45 05 14 2C 49 F1 29 5E 6E DA 6B CA ED 7E 2C
               68 C5 BE 91 B5 A1 10 01 F0 24
    """

  /// Captured from the same package: `spctl --assess -t install -vv` (exit 0, on stderr).
  static let notarizedSpctl = """
    /Users/x/quarto--1.10.18.pkg: accepted
    source=Notarized Developer ID
    origin=Developer ID Installer: RStudio Inc. (FYF2F5GFX4)
    """

  /// synthetic; replace with captured output at the first rc.
  /// A Developer ID Installer signature with no notary ticket: pkgutil prints no `Notarization:`
  /// line at all for one, which is what makes the absence -- not a phrase -- the signal.
  static let signedPkgutil = """
    Package "RunnerVM-macos-arm64.pkg":
       Status: signed by a developer certificate issued by Apple for distribution
       Signed with a trusted timestamp on: 2026-09-01 10:00:00 +0000
       Certificate Chain:
        1. Developer ID Installer: RunnerVM (FYF2F5GFX4)
           Expires: 2031-05-21 22:28:17 +0000
        2. Developer ID Certification Authority
           Expires: 2031-09-17 00:00:00 +0000
        3. Apple Root CA
           Expires: 2035-02-09 21:40:36 +0000
    """

  /// synthetic; replace with captured output at the first rc.
  static let signedSpctl = """
    /state/upgrades/0.3.0/RunnerVM-macos-arm64.pkg: rejected
    source=Unnotarized Developer ID
    origin=Developer ID Installer: RunnerVM (FYF2F5GFX4)
    """

  /// synthetic; replace with captured output at the first rc. Same shape as `notarizedPkgutil`,
  /// signed by somebody else.
  static let foreignPkgutil = """
    Package "RunnerVM-macos-arm64.pkg":
       Status: signed by a developer certificate issued by Apple for distribution
       Notarization: trusted by the Apple notary service
       Certificate Chain:
        1. Developer ID Installer: Someone Else (A1B2C3D4E5)
           Expires: 2031-05-21 22:28:17 +0000
        2. Developer ID Certification Authority
           Expires: 2031-09-17 00:00:00 +0000
    """

  /// synthetic; replace with captured output at the first rc.
  static let foreignSpctl = """
    /state/upgrades/0.3.0/RunnerVM-macos-arm64.pkg: accepted
    source=Notarized Developer ID
    origin=Developer ID Installer: Someone Else (A1B2C3D4E5)
    """
}

/// The parser `runnerctl upgrade` and `scripts/bootstrap.sh` both depend on being right about.
///
/// Everything here is pure: captured tool output in, a verdict out. The point of the suite is that
/// Apple's wording is a contract nobody in this repo controls, so each shape the tools produce has
/// a fixture, and each thing the parser must NOT be fooled by has one too.
@Suite struct PackageSignatureTests {
  // MARK: - The three shapes a release can have

  @Test func anUnsignedPackageHasNoIdentityAtAll() {
    let signature = PackageSignature.parse(
      pkgutil: SignatureFixtures.unsignedPkgutil, spctl: SignatureFixtures.unsignedSpctl,
      spctlAssessmentsEnabled: true)

    #expect(signature == .unsigned)
    #expect(signature.team == nil)
    #expect(!signature.isNotarized)
    #expect(signature.summary == "unsigned")
  }

  @Test func aNotarizedPackageYieldsItsLeafTeamAndTheVerifiedNotarization() {
    let signature = PackageSignature.parse(
      pkgutil: SignatureFixtures.notarizedPkgutil, spctl: SignatureFixtures.notarizedSpctl,
      spctlAssessmentsEnabled: true)

    #expect(signature == .developerID(team: SignatureFixtures.capturedTeam, notarized: true))
    // The leaf, not the intermediate: "Developer ID Certification Authority" is entry 2 and has
    // no team in parentheses, so a parser that scanned the whole chain would still have to pick.
    #expect(signature.team == "FYF2F5GFX4")
    #expect(signature.summary.contains("notarized"))
  }

  @Test func aSignedPackageWithNoNotaryTicketKeepsTheTeamAndLosesTheNotarization() {
    let signature = PackageSignature.parse(
      pkgutil: SignatureFixtures.signedPkgutil, spctl: SignatureFixtures.signedSpctl,
      spctlAssessmentsEnabled: true)

    #expect(signature == .developerID(team: SignatureFixtures.capturedTeam, notarized: false))
    #expect(signature.summary.contains("NOT notarized"))
  }

  // MARK: - Which tool is the authority

  /// With Gatekeeper running, spctl is the only notarization evidence: a ticket pkgutil still
  /// reports as trusted but that Gatekeeper refuses (revoked, or blocked by policy) is not one
  /// this host may install silently.
  @Test func spctlOverridesPkgutilWhenAssessmentsAreEnabled() {
    let signature = PackageSignature.parse(
      pkgutil: SignatureFixtures.notarizedPkgutil,
      spctl: """
        /state/upgrades/0.3.0/RunnerVM-macos-arm64.pkg: rejected
        source=Notarized Developer ID
        """,
      spctlAssessmentsEnabled: true)

    #expect(signature == .developerID(team: SignatureFixtures.capturedTeam, notarized: false))
  }

  /// With assessments disabled, spctl answers for a policy that is not running -- so the stapled
  /// ticket pkgutil reports is what stands, and the upgrader says so loudly.
  @Test func theStapledTicketDecidesWhenAssessmentsAreDisabled() {
    #expect(
      PackageSignature.parse(
        pkgutil: SignatureFixtures.notarizedPkgutil, spctl: nil, spctlAssessmentsEnabled: false)
        == .developerID(team: SignatureFixtures.capturedTeam, notarized: true))
    #expect(
      PackageSignature.parse(
        pkgutil: SignatureFixtures.signedPkgutil, spctl: nil, spctlAssessmentsEnabled: false)
        == .developerID(team: SignatureFixtures.capturedTeam, notarized: false))
  }

  /// A host where spctl could not be run at all (missing, or it failed) leaves an empty string,
  /// not evidence.
  @Test func absentSpctlOutputIsNotNotarization() {
    #expect(
      PackageSignature.parse(
        pkgutil: SignatureFixtures.notarizedPkgutil, spctl: nil, spctlAssessmentsEnabled: true)
        == .developerID(team: SignatureFixtures.capturedTeam, notarized: false))
    #expect(
      PackageSignature.parse(
        pkgutil: SignatureFixtures.notarizedPkgutil, spctl: "", spctlAssessmentsEnabled: true)
        == .developerID(team: SignatureFixtures.capturedTeam, notarized: false))
  }

  // MARK: - What the parser must not be fooled by

  /// `contains("trusted")` would read both of these as a notarized package.
  @Test func aNegatedNotarizationLineIsNotEvidence() {
    for wording in ["Notarization: not trusted by the Apple notary service",
                    "Notarization: untrusted"] {
      let signature = PackageSignature.parse(
        pkgutil: SignatureFixtures.signedPkgutil.replacingOccurrences(
          of: "   Status:", with: "   \(wording)\n   Status:"),
        spctl: nil, spctlAssessmentsEnabled: false)

      #expect(signature == .developerID(team: SignatureFixtures.capturedTeam, notarized: false))
    }
  }

  /// A `source=` line describes what Gatekeeper matched, not what it decided.
  @Test func aRejectedAssessmentIsNotEvidenceEvenWithTheNotarizedSource() {
    let signature = PackageSignature.parse(
      pkgutil: SignatureFixtures.signedPkgutil,
      spctl: """
        RunnerVM-macos-arm64.pkg: rejected
        source=Notarized Developer ID
        """,
      spctlAssessmentsEnabled: true)

    #expect(!signature.isNotarized)
  }

  /// The package's own path is echoed back by spctl, and part of that path comes from the
  /// manifest (`<state>/upgrades/<version>/<package>`). A manifest carrying newlines in its
  /// version can therefore put whole lines into spctl's output -- but it cannot make spctl accept
  /// the package, and the assessment verdict is checked, so the forged lines buy nothing.
  @Test func linesForgedThroughThePackagePathAreNotEvidence() {
    let signature = PackageSignature.parse(
      pkgutil: SignatureFixtures.unsignedPkgutil,
      spctl: """
        /state/upgrades/0.3.0
        forged: accepted
        source=Notarized Developer ID
        x/RunnerVM-macos-arm64.pkg: rejected
        source=no usable signature
        """,
      spctlAssessmentsEnabled: true)

    #expect(signature == .unsigned)
    // And with a real signature under it, the forged acceptance still loses to the real verdict.
    #expect(!PackageSignature.parse(
      pkgutil: SignatureFixtures.signedPkgutil,
      spctl: """
        /state/upgrades/0.3.0
        forged: accepted
        source=Notarized Developer ID
        x/RunnerVM-macos-arm64.pkg: rejected
        """,
      spctlAssessmentsEnabled: true).isNotarized)
  }

  /// The mirror of the spctl case: `pkgutil` echoes the package it was handed in its first line,
  /// and part of that path comes from the manifest -- so a package name or version that spells out
  /// a chain line must not become an identity. The marker is anchored to the start of the line
  /// (after indentation and the `N. ` entry number), exactly as `bootstrap.sh` anchors it.
  @Test func aChainLineSpelledOutInThePackagePathIsNotAnIdentity() {
    let inline = PackageSignature.parse(
      pkgutil: "Package \"/state/upgrades/0.3.0 "
        + "Developer ID Installer: Evil (A1B2C3D4E5) "
        + "Notarization: trusted by the Apple notary service/RunnerVM.pkg\":\n"
        + "   Status: no signature",
      spctl: nil, spctlAssessmentsEnabled: false)

    #expect(inline == .unsigned)

    // The same forgery with newlines in it: the `Notarization:` line now stands on its own, and
    // still buys nothing, because no line is a chain entry.
    let multiline = PackageSignature.parse(
      pkgutil: """
        Package "/state/upgrades/0.3.0
        x Developer ID Installer: Evil (A1B2C3D4E5)
        Notarization: trusted by the Apple notary service
        /RunnerVM.pkg":
           Status: no signature
        """,
      spctl: nil, spctlAssessmentsEnabled: false)

    #expect(multiline == .unsigned)
  }

  /// The chain entry as pkgutil actually indents it, with and without the entry number, and with
  /// text after the team -- an expiry note, a revocation marker -- still names the publisher.
  @Test func theAnchoredMarkerStillMatchesEveryRealChainLine() {
    for line in ["    1. Developer ID Installer: RunnerVM (FYF2F5GFX4)",
                 "1. Developer ID Installer: RunnerVM (FYF2F5GFX4)",
                 "Developer ID Installer: RunnerVM (FYF2F5GFX4)",
                 "\t2.  Developer ID Installer: RunnerVM (FYF2F5GFX4)",
                 "    1. Developer ID Installer: RunnerVM (FYF2F5GFX4) [expired]"] {
      #expect(
        PackageSignature.parse(pkgutil: line, spctl: nil, spctlAssessmentsEnabled: false).team
          == SignatureFixtures.capturedTeam,
        "\(line)")
    }
  }

  /// Nine characters is not a Team ID, so the line names nobody -- the confirmable case, never an
  /// identity that could be compared against the pin.
  @Test func aTeamGroupOfTheWrongLengthLeavesThePackageUnsigned() {
    for line in ["    1. Developer ID Installer: RunnerVM (ABCDE1234)",
                 "    1. Developer ID Installer: RunnerVM (ABCDE123456)"] {
      #expect(
        PackageSignature.parse(pkgutil: line, spctl: nil, spctlAssessmentsEnabled: false)
          == .unsigned,
        "\(line)")
    }
  }

  @Test func aCompanyNameWithParenthesesStillYieldsTheTeam() {
    let signature = PackageSignature.parse(
      pkgutil: """
        Package "x.pkg":
           Certificate Chain:
            1. Developer ID Installer: Acme (Europe) Ltd (A1B2C3D4E5)
        """,
      spctl: nil, spctlAssessmentsEnabled: false)

    #expect(signature.team == SignatureFixtures.foreignTeam)
  }

  /// Anything that is not the documented structure reads as unsigned, which is the confirmable
  /// case -- never as an identity, which could authorise or be mistaken for a publisher.
  @Test func malformedOutputReadsAsUnsigned() {
    let inputs = [
      "",
      "   ",
      "not pkgutil output at all",
      // Truncated before the chain.
      "Package \"x.pkg\":\n   Status: signed by a developer certificate issued by Apple",
      // The leaf line with no team in it.
      "    1. Developer ID Installer: RunnerVM",
      // A team of the wrong length, and one with a character Apple does not issue.
      "    1. Developer ID Installer: RunnerVM (SHORT)",
      "    1. Developer ID Installer: RunnerVM (ABCDE-1234)",
      // The intermediates alone.
      "    2. Developer ID Certification Authority\n    3. Apple Root CA",
    ]
    for input in inputs {
      #expect(
        PackageSignature.parse(pkgutil: input, spctl: nil, spctlAssessmentsEnabled: false)
          == .unsigned,
        "\(input)")
    }
  }

  @Test func theTeamShapeIsExactlyWhatAppleIssues() {
    #expect(PackageSignature.isTeamID("FYF2F5GFX4"))
    #expect(!PackageSignature.isTeamID("FYF2F5GFX"))
    #expect(!PackageSignature.isTeamID("FYF2F5GFX45"))
    #expect(!PackageSignature.isTeamID(""))
    #expect(!PackageSignature.isTeamID("FYF2F5GFX."))
  }

  // MARK: - The pin

  @Test func onlyASignatureFromAnotherTeamIsForeign() {
    let ours = PackageSignature.developerID(team: SignatureFixtures.capturedTeam, notarized: true)
    let theirs = PackageSignature.developerID(
      team: SignatureFixtures.foreignTeam, notarized: true)

    #expect(!ours.isForeign(to: SignatureFixtures.capturedTeam))
    #expect(theirs.isForeign(to: SignatureFixtures.capturedTeam))
    // An unsigned package is the weaker, confirmable case, not the refusal.
    #expect(!PackageSignature.unsigned.isForeign(to: SignatureFixtures.capturedTeam))
    // A build with no pin has nobody to compare against and refuses nobody.
    #expect(!theirs.isForeign(to: nil))
    // Exact match: the pin is a literal, so a differently-cased team is somebody else.
    #expect(ours.isForeign(to: SignatureFixtures.capturedTeam.lowercased()))
  }
}
