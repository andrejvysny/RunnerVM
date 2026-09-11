/// The publisher `runnerctl upgrade` and `scripts/bootstrap.sh` pin release packages to
/// (`docs/design/distribution.md`, "Signing and notarization").
///
/// The reference is compiled into the binary, never read from the release. `release-manifest.json`
/// travels with the package it describes, so a manifest naming its own signer proves nothing;
/// what the installers check is that the leaf of the package's Developer ID Installer certificate
/// chain -- read out of `pkgutil --check-signature` -- carries exactly this team.
public enum RunnerVMSigning {
  /// The Apple Team ID (`^[A-Z0-9]{10}$`) every published RunnerVM package is signed by, or `nil`
  /// in a build made before those certificates existed.
  ///
  /// `nil` is not an override: an unpinned build still refuses nothing silently. It says
  /// "publisher team not pinned in this build" and decides on the notarization evidence alone.
  /// It is a *release* blocker rather than an install blocker -- `release.yml`'s first step fails
  /// while the signing secrets are empty -- so a published release is never produced by a
  /// toolchain that cannot name its own publisher.
  ///
  /// The operator sets this literal once the Developer ID certificates exist, together with the
  /// same value in `scripts/bootstrap.sh`; the two implementations of the gate must agree.
  public static let expectedTeamID: String? = nil
}
