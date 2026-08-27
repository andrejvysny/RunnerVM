import Testing

@testable import ImageBuild

@Suite struct BuildArgumentPolicyTests {
  @Test(arguments: [
    "ghp_0123456789abcdefghijklmnopqrstuvwxyz", "gho_x", "ghu_x", "ghs_x", "ghr_x",
    "github_pat_11AAAA", "AKIAIOSFODNN7EXAMPLE", "ASIAXXXX",
    "-----BEGIN OPENSSH PRIVATE KEY-----", "  ghp_leading_space",
  ])
  func recognisesKnownCredentialShapes(value: String) {
    #expect(BuildArgumentPolicy.looksLikeSecret(value))
  }

  @Test(arguments: ["2.336.0", "latest", "", "sha256:abc", "https://example.com", "ghpx", "AKI"])
  func leavesOrdinaryValuesAlone(value: String) {
    #expect(!BuildArgumentPolicy.looksLikeSecret(value))
  }

  @Test func reportsTheFirstOffendingKeyDeterministically() {
    let args = ["Z_TOKEN": "ghp_1", "A_TOKEN": "gho_2", "RUNNER_VERSION": "2.336.0"]
    #expect(BuildArgumentPolicy.firstSecretLookingArgument(in: args) == "A_TOKEN")
    #expect(BuildArgumentPolicy.firstSecretLookingArgument(in: ["RUNNER_VERSION": "2.336.0"]) == nil)
  }
}
