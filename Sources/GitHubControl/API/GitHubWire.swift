import Foundation

/// Request and response shapes of the REST endpoints RunnerVM uses. Kept private to the module:
/// nothing outside GitHubControl sees GitHub's JSON.
enum Wire {
  struct JITConfigRequest: Encodable {
    let name: String
    let runnerGroupID: Int64
    let labels: [String]
    let workFolder: String?

    private enum CodingKeys: String, CodingKey {
      case name, labels
      case runnerGroupID = "runner_group_id"
      case workFolder = "work_folder"
    }
  }

  struct JITConfigResponse: Decodable {
    let runner: GitHubRunner
    let encodedJITConfig: String

    private enum CodingKeys: String, CodingKey {
      case runner
      case encodedJITConfig = "encoded_jit_config"
    }
  }

  struct RunnersPage: Decodable {
    let totalCount: Int?
    let runners: [GitHubRunner]

    private enum CodingKeys: String, CodingKey {
      case runners
      case totalCount = "total_count"
    }
  }

  struct RunnerGroupsPage: Decodable {
    let totalCount: Int?
    let runnerGroups: [RunnerGroup]

    private enum CodingKeys: String, CodingKey {
      case totalCount = "total_count"
      case runnerGroups = "runner_groups"
    }
  }

  struct Release: Decodable {
    let tagName: String
    /// RFC 3339. The grace window in `RunnerVersionPolicy` is measured from this, so a release
    /// without it cannot be judged for staleness.
    let publishedAt: String?
    /// Both default to "not draft/prerelease" when GitHub omits them, matching its own docs.
    let draft: Bool?
    let prerelease: Bool?

    private enum CodingKeys: String, CodingKey {
      case tagName = "tag_name"
      case publishedAt = "published_at"
      case draft, prerelease
    }
  }

  struct AuthenticatedUser: Decodable {
    let login: String
  }
}
