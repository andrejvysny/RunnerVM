import Foundation

/// What a build argument is allowed to be.
///
/// `ARG` values are **not secrets**: they are persisted in the build row (`image_builds.args_json`),
/// written into the sealed image's provenance and pushed inside the OCI config of the artifact.
/// Nothing redacts them, on purpose — an argument that had to be hidden would be a secret with a
/// misleading name. This policy refuses the credential shapes that can be recognised outright so
/// a token does not reach any of those places by accident; everything subtler is documented as
/// the operator's responsibility (`docs/image-build.md`, "Build arguments are not secrets").
public enum BuildArgumentPolicy {
  /// Prefixes that identify a credential with near certainty: GitHub token families, AWS access
  /// key ids, PEM blocks.
  static let secretPrefixes = [
    "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "AKIA", "ASIA", "-----BEGIN",
  ]

  public static func looksLikeSecret(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return secretPrefixes.contains { trimmed.hasPrefix($0) }
  }

  /// The first argument whose value looks like a credential, by key, or `nil`.
  public static func firstSecretLookingArgument(in args: [String: String]) -> String? {
    args.keys.sorted().first { looksLikeSecret(args[$0] ?? "") }
  }
}
