import ConfigLoader
import Foundation
import GRDB
import Persistence
import RunnerCore
import Testing

@testable import Orchestration

@Suite struct ConfigApplierTests {
  private func makeApplier(_ tree: TempTree) throws -> (ConfigApplier, RunnerDatabase) {
    let db = try RunnerDatabase.inMemory()
    return (ConfigApplier(store: GRDBConfigStore(db: db), stateDir: tree.root), db)
  }

  @Test func firstApplyAddsEveryScopeAndProfile() async throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let (applier, db) = try makeApplier(tree)
    let outcome = try await applier.apply(
      try exampleConfiguration(), yaml: ExampleConfig.example, actor: "test")

    #expect(outcome.diff.addedScopes == ["engineering"])
    #expect(Set(outcome.diff.addedProfiles) == ["ubuntu-24"])
    #expect(outcome.diff.disabledProfiles.isEmpty)

    let profiles = try await GRDBProfileRepository(db: db).list()
    #expect(profiles.count == 1)
    #expect(profiles.allSatisfy { $0.enabled })
  }

  @Test func reapplyingTheSameDocumentChangesNothing() async throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let (applier, _) = try makeApplier(tree)
    let config = try exampleConfiguration()
    _ = try await applier.apply(config, yaml: ExampleConfig.example, actor: "test")
    let second = try await applier.apply(config, yaml: ExampleConfig.example, actor: "test")

    #expect(second.diff.isEmpty)
    #expect(second.diff.changeCount == 0)
  }

  @Test func removingAProfileDisablesItAndReaddingRestoresIt() async throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let (applier, db) = try makeApplier(tree)
    let profiles = GRDBProfileRepository(db: db)
    let full = try exampleWithSecondProfile()

    _ = try await applier.apply(full, yaml: "version: 1\n", actor: "test")
    let removed = try await applier.apply(
      try exampleConfiguration(), yaml: "version: 1\n", actor: "test")
    #expect(removed.diff.disabledProfiles == ["ubuntu-22"])
    let disabled = try await profiles.get(name: "ubuntu-22")
    #expect(disabled?.enabled == false)
    // The row survives so history and foreign keys stay intact.
    #expect(disabled != nil)

    let restored = try await applier.apply(full, yaml: "version: 1\n", actor: "test")
    #expect(restored.diff.updatedProfiles == ["ubuntu-22"])
    let reenabled = try await profiles.get(name: "ubuntu-22")
    #expect(reenabled?.enabled == true)
  }

  @Test func removingAScopeDisablesItWithoutDeletingIt() async throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let (applier, db) = try makeApplier(tree)
    var config = try exampleConfiguration()
    _ = try await applier.apply(config, yaml: ExampleConfig.example, actor: "test")

    config.profiles = []
    config.github.scopes = []
    let outcome = try await applier.apply(config, yaml: "version: 1\n", actor: "test")
    #expect(outcome.diff.disabledScopes == ["engineering"])
    #expect(Set(outcome.diff.disabledProfiles) == ["ubuntu-24"])
    let scopes = try await GRDBScopeRepository(db: db).list()
    #expect(scopes.count == 1)
    #expect(scopes[0].enabled == false)
  }

  @Test func changingAProfileFieldReportsAnUpdate() async throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let (applier, db) = try makeApplier(tree)
    var config = try exampleConfiguration()
    _ = try await applier.apply(config, yaml: ExampleConfig.example, actor: "test")

    config.profiles[0].resources.cpuCount = 8
    let outcome = try await applier.apply(config, yaml: "version: 1\n", actor: "test")
    #expect(outcome.diff.updatedProfiles == ["ubuntu-24"])
    let stored = try await GRDBProfileRepository(db: db).get(name: "ubuntu-24")
    #expect(stored?.cpuCount == 8)
  }

  @Test func applyRecordsAnOperationAndAnAuditEvent() async throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let (applier, db) = try makeApplier(tree)
    let outcome = try await applier.apply(
      try exampleConfiguration(), yaml: ExampleConfig.example, actor: "tester")

    let operations = try await GRDBOperationRepository(db: db).list(state: nil)
    #expect(operations.count == 1)
    #expect(operations[0].id == outcome.operationId)
    #expect(operations[0].kind == "apply-config")
    #expect(operations[0].resourceType == "config")

    let audits = try await db.read { db in
      try AuditEventRecord.fetchAll(db)
    }
    #expect(audits.count == 1)
    #expect(audits[0].kind == "config.changed")
    #expect(audits[0].actor == "tester")
  }

  @Test func appliedYAMLIsPersistedForConfigGet() async throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let (applier, _) = try makeApplier(tree)
    _ = try await applier.apply(
      try exampleConfiguration(), yaml: ExampleConfig.example, actor: "test")

    let persisted = applier.loadApplied()
    #expect(persisted?.yaml == ExampleConfig.example)
    #expect(FileManager.default.fileExists(atPath: applier.appliedConfigURL.path))
  }

  @Test func nothingIsPersistedBeforeTheFirstApply() throws {
    let tree = try TempTree()
    defer { tree.remove() }
    let (applier, _) = try makeApplier(tree)
    #expect(applier.loadApplied() == nil)
  }
}
