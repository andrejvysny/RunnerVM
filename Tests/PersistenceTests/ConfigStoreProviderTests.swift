import RunnerCore
import Testing

@testable import Persistence

@Suite struct ConfigStoreProviderTests {
  private static func config(profiles: [RunnerProfileConfig]) -> RunnerConfiguration {
    RunnerConfiguration(
      github: GitHubConfig(scopes: [
        GitHubScopeConfig(name: "acme", kind: .organization, owner: "acme"),
      ]),
      profiles: profiles)
  }

  @Test func appliesAGitLabProfileWithNoScope() async throws {
    let db = try TestDatabase.make()
    let gitlab = RunnerProfileConfig(
      name: "glab", scope: nil, provider: .gitlab, image: "ghcr.io/a/b:c", guestOS: .linux)
    let github = RunnerProfileConfig(
      name: "ghub", scope: "acme", image: "ghcr.io/a/b:c", guestOS: .linux)
    let store = GRDBConfigStore(db: db)
    _ = try await store.apply(Self.config(profiles: [gitlab, github]), actor: "test")

    let repo = GRDBProfileRepository(db: db)
    let glab = try #require(try await repo.get(name: "glab"))
    #expect(glab.provider == .gitlab)
    #expect(glab.scopeId == nil)
    #expect(try glab.decodedConfig().provider == .gitlab)
    let ghub = try #require(try await repo.get(name: "ghub"))
    #expect(ghub.provider == .github)
    #expect(ghub.scopeId != nil)

    // Re-applying an unchanged document is a no-op diff.
    let again = try await store.apply(Self.config(profiles: [gitlab, github]), actor: "test")
    #expect(again.diff.updatedProfiles.isEmpty)
  }

  @Test func aGitHubProfileNamingAnUnknownScopeIsAForeignKeyViolation() async throws {
    let db = try TestDatabase.make()
    let profile = RunnerProfileConfig(
      name: "ghub", scope: "nope", image: "ghcr.io/a/b:c", guestOS: .linux)
    await #expect(throws: Persistence.PersistenceError.self) {
      _ = try await GRDBConfigStore(db: db).apply(Self.config(profiles: [profile]), actor: "test")
    }
  }

  @Test func aProfileCannotChangeProvider() async throws {
    let db = try TestDatabase.make()
    let store = GRDBConfigStore(db: db)
    let github = RunnerProfileConfig(
      name: "flip", scope: "acme", image: "ghcr.io/a/b:c", guestOS: .linux)
    _ = try await store.apply(Self.config(profiles: [github]), actor: "test")
    let gitlab = RunnerProfileConfig(
      name: "flip", scope: nil, provider: .gitlab, image: "ghcr.io/a/b:c", guestOS: .linux)
    await #expect(throws: Persistence.PersistenceError.self) {
      _ = try await store.apply(Self.config(profiles: [gitlab]), actor: "test")
    }
    let row = try #require(try await GRDBProfileRepository(db: db).get(name: "flip"))
    #expect(row.provider == .github)
  }
}
