import Foundation

/// What `pkgutil --check-signature` and `spctl --assess -t install -vv` said about a package.
///
/// A pure parser, deliberately: Apple's wording is a contract nobody here controls, so the single
/// place it is interpreted takes captured tool output as a `String` and answers with a verdict --
/// no process spawning, no file system, and a fixture per shape in `PackageSignatureTests`.
/// `Upgrader` owns running the tools; this owns what their output means.
///
/// Keyed on structure rather than on prose. The certificate-chain line names the leaf identity and
/// its team in parentheses, the `Notarization:` line names the notary verdict, and `spctl`'s
/// `source=` line names what Gatekeeper matched. The `Status:` sentence ("signed by a developer
/// certificate issued by Apple for distribution") is never consulted -- it is the part of the
/// output most likely to be reworded, and it says nothing the chain line does not.
public enum PackageSignature: Equatable, Sendable {
  /// No Developer ID Installer chain: a local build, or something built by somebody else.
  case unsigned
  /// Signed by `team`. `notarized` is the fact this host verified, never the manifest's claim.
  case developerID(team: String, notarized: Bool)

  /// The signing team, `nil` when the package carries no Developer ID Installer signature.
  public var team: String? {
    switch self {
    case .unsigned: nil
    case let .developerID(team, _): team
    }
  }

  public var isNotarized: Bool {
    switch self {
    case .unsigned: false
    case let .developerID(_, notarized): notarized
    }
  }

  /// The one line the upgrade ladder carries.
  public var summary: String {
    switch self {
    case .unsigned:
      "unsigned"
    case let .developerID(team, notarized):
      "Developer ID Installer (\(team)), \(notarized ? "notarized" : "NOT notarized")"
    }
  }

  /// Signed by somebody other than the publisher this build expects.
  ///
  /// The one refusal in the whole upgrade path with no override, on the package being installed
  /// and on the cached one a rollback reinstalls alike -- so both callers ask this exact question.
  /// An unpinned build (`expectedTeamID == nil`) has nobody to compare against and refuses nobody;
  /// an unsigned package is not foreign either, it is the weaker, confirmable case.
  public func isForeign(to expectedTeamID: String?) -> Bool {
    guard let expectedTeamID, case let .developerID(team, _) = self else { return false }
    return team != expectedTeamID
  }

  // MARK: - Parsing

  /// - Parameters:
  ///   - pkgutil: combined output of `pkgutil --check-signature <pkg>`. The exit code is not
  ///     evidence and is not passed in: the tool exits 1 for an unsigned package, which is an
  ///     answer rather than a failure.
  ///   - spctl: combined output of `spctl --assess -t install -vv <pkg>`, or `nil` when it was not
  ///     run. `-vv` is part of the contract (without it there is no `source=` line), and both
  ///     streams have to be merged by the caller because spctl writes its assessment to stderr.
  ///   - spctlAssessmentsEnabled: `spctl --status` answered `assessments enabled`. With Gatekeeper
  ///     off, spctl answers for a policy that is not running, so the stapled ticket that `pkgutil`
  ///     reports -- which is checked offline -- is what stands instead.
  public static func parse(
    pkgutil: String, spctl: String?, spctlAssessmentsEnabled: Bool
  ) -> PackageSignature {
    guard let team = developerIDTeam(in: pkgutil) else { return .unsigned }
    let notarized = spctlAssessmentsEnabled
      ? assessedAsNotarized(spctl ?? "")
      : notaryTrusted(in: pkgutil)
    return .developerID(team: team, notarized: notarized)
  }

  private static let chainLeafMarker = "Developer ID Installer:"

  /// The team on the first `Developer ID Installer: NAME (TEAMID)` chain line, which is entry 1 --
  /// the leaf. The intermediates are named "Developer ID Certification Authority", so the marker
  /// alone already picks the leaf out; taking the first match keeps that true even if Apple ever
  /// prints the chain differently.
  private static func developerIDTeam(in output: String) -> String? {
    for line in output.split(whereSeparator: \.isNewline) {
      guard let identity = chainEntryIdentity(of: line) else { continue }
      if let team = teamID(inParenthesesOf: identity) { return team }
    }
    return nil
  }

  /// What follows `Developer ID Installer:` when the line really is a chain entry: optional
  /// indentation, an optional `N. ` entry number, then the marker at the start of what is left.
  ///
  /// Anchored rather than searched for anywhere on the line, matching `bootstrap.sh`. `pkgutil`
  /// echoes the package it was given in its first line (`Package "<path>":`), and part of that
  /// path comes from the manifest -- so a substring match lets a crafted package path or version
  /// spell out a chain line and forge a publisher.
  private static func chainEntryIdentity(of line: Substring) -> Substring? {
    var rest = line.drop { $0 == " " || $0 == "\t" }
    let number = rest.prefix { $0.isASCII && $0.isNumber }
    if !number.isEmpty, rest.dropFirst(number.count).first == "." {
      rest = rest.dropFirst(number.count + 1).drop { $0 == " " }
    }
    guard rest.hasPrefix(chainLeafMarker) else { return nil }
    return rest.dropFirst(chainLeafMarker.count)
  }

  /// The last parenthesised group on the line that has the shape of an Apple Team ID. Last,
  /// because a company name may itself contain parentheses ("Acme (Europe) (ABCDE12345)"); shape
  /// is exactly ten ASCII alphanumerics, which is what Apple issues. Anything else is not read as
  /// an identity at all, so a malformed line can neither authorise an install nor be mistaken for
  /// a publisher.
  ///
  /// Groups are scanned across the whole identity, so text after the team ("(ABCDE12345)
  /// [expired]") does not hide it, and a group of any other length leaves the package unsigned.
  private static func teamID(inParenthesesOf text: Substring) -> String? {
    var found: String?
    var current: String?
    for character in text {
      switch character {
      case "(":
        current = ""
      case ")":
        if let candidate = current, isTeamID(candidate) { found = candidate }
        current = nil
      default:
        current?.append(character)
      }
    }
    return found
  }

  static func isTeamID(_ text: String) -> Bool {
    text.count == 10 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
  }

  /// `Notarization: trusted by the Apple notary service`, the stapled ticket's verdict.
  ///
  /// Matched on the value's first word rather than on "contains trusted": a negative wording
  /// ("not trusted", "untrusted") contains the word too, and reading one of those as evidence is
  /// the exact failure this parser exists to prevent.
  private static func notaryTrusted(in output: String) -> Bool {
    for line in output.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("Notarization:") else { continue }
      let verdict = trimmed.dropFirst("Notarization:".count)
        .trimmingCharacters(in: .whitespaces)
      if verdict == "trusted" || verdict.hasPrefix("trusted ") { return true }
    }
    return false
  }

  /// Gatekeeper accepted the package *and* says the acceptance came from a notarized Developer ID
  /// signature. Both halves are required: a `source=` line on its own does not say the policy let
  /// the package through, and an assessment that was rejected is not evidence of anything.
  private static func assessedAsNotarized(_ output: String) -> Bool {
    var accepted = false
    var notarizedSource = false
    for line in output.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasSuffix(": rejected") { return false }
      if trimmed.hasSuffix(": accepted") { accepted = true }
      if trimmed == "source=Notarized Developer ID" { notarizedSource = true }
    }
    return accepted && notarizedSource
  }
}
