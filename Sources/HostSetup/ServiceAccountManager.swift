import Foundation

/// The account `runnerd` runs as (`docs/design/distribution.md`, "Service account").
public struct ServiceAccountSpec: Sendable, Hashable {
  public var user: String
  public var group: String
  public var realName: String
  /// `<state-dir>/home`. Never `/Users/…`: nothing about this account belongs in the login window,
  /// and the state directory is already the tree it owns.
  public var home: String
  /// The `install.sh` convention already in use: system-account territory, below the 501 the first
  /// human account gets.
  public var idRange: ClosedRange<Int>

  public init(
    user: String = "_runnervm",
    group: String = "_runnervm",
    realName: String = "RunnerVM Service",
    home: String,
    idRange: ClosedRange<Int> = 200...400
  ) {
    self.user = user
    self.group = group
    self.realName = realName
    self.home = home
    self.idRange = idRange
  }

  public var ownership: String { "\(user):\(group)" }
}

/// What `ServiceAccountManager.ensure` did, or would do.
public struct ServiceAccountPlan: Sendable, Hashable {
  public var uid: Int
  public var gid: Int
  public var createdGroup: Bool
  public var createdUser: Bool
  /// True when an existing account's primary group pointed somewhere else and was repointed.
  public var fixedPrimaryGroup: Bool
  /// Every mutating command, in the order it was (or would be) run.
  public var commands: [[String]]

  public var summary: String {
    switch (createdGroup, createdUser, fixedPrimaryGroup) {
    case (_, true, _): "created uid \(uid), gid \(gid)"
    case (_, _, true): "existed; primary group repointed to gid \(gid)"
    default: "already correct (uid \(uid), gid \(gid))"
    }
  }
}

/// Creates and verifies the service principals with `dscl` only — no `sysadminctl`, no interactive
/// password prompt, idempotent. Re-running `setup` on a provisioned host verifies rather than
/// recreates, and repairs exactly one thing: a user whose primary group drifted off the service
/// group.
///
/// This is the single implementation of the sequence `scripts/install.sh`'s
/// `ensure_service_principals` performs; the two must not drift.
public struct ServiceAccountManager: Sendable {
  static let dscl = "/usr/bin/dscl"
  static let mkdir = "/bin/mkdir"
  static let chown = "/usr/sbin/chown"
  static let chmod = "/bin/chmod"

  private let runner: any CommandRunner

  public init(runner: any CommandRunner = DefaultCommandRunner()) {
    self.runner = runner
  }

  public func ensure(_ spec: ServiceAccountSpec) async throws -> ServiceAccountPlan {
    var commands: [[String]] = []
    let (gid, createdGroup) = try await ensureGroup(spec, commands: &commands)
    let (uid, createdUser, fixedPrimaryGroup) = try await ensureUser(
      spec, gid: gid, commands: &commands)
    // `NFSHomeDirectory` has to resolve for anything that reads $HOME for the daemon — git, the
    // GitHub runner's own tooling — even though the account is never logged into.
    try await perform([Self.mkdir, "-p", spec.home], commands: &commands)
    try await perform([Self.chmod, "0750", spec.home], commands: &commands)
    try await perform([Self.chown, spec.ownership, spec.home], commands: &commands)
    return ServiceAccountPlan(
      uid: uid, gid: gid, createdGroup: createdGroup, createdUser: createdUser,
      fixedPrimaryGroup: fixedPrimaryGroup, commands: commands)
  }

  // MARK: - Group

  private func ensureGroup(
    _ spec: ServiceAccountSpec, commands: inout [[String]]
  ) async throws -> (gid: Int, created: Bool) {
    let record = "/Groups/\(spec.group)"
    if let existing = try await readPrimaryGroupID(record) {
      return (existing, false)
    }
    let used = try await usedIDs(list: "/Groups", attribute: "PrimaryGroupID")
    guard let gid = spec.idRange.first(where: { !used.contains($0) }) else {
      throw SetupError.noFreeID(range: spec.idRange, kind: "GID")
    }
    try await perform([Self.dscl, ".", "-create", record], commands: &commands)
    try await perform(
      [Self.dscl, ".", "-create", record, "PrimaryGroupID", "\(gid)"], commands: &commands)
    try await perform(
      [Self.dscl, ".", "-create", record, "RealName", spec.realName], commands: &commands)
    // '*' is "no password will ever authenticate", not "empty password".
    try await perform([Self.dscl, ".", "-create", record, "Password", "*"], commands: &commands)
    return (gid, true)
  }

  // MARK: - User

  private func ensureUser(
    _ spec: ServiceAccountSpec, gid: Int, commands: inout [[String]]
  ) async throws -> (uid: Int, created: Bool, fixedPrimaryGroup: Bool) {
    let record = "/Users/\(spec.user)"
    if let existingPrimaryGroup = try await readPrimaryGroupID(record) {
      let uid = try await readUniqueID(record) ?? gid
      guard existingPrimaryGroup != gid else { return (uid, false, false) }
      try await perform(
        [Self.dscl, ".", "-create", record, "PrimaryGroupID", "\(gid)"], commands: &commands)
      return (uid, false, true)
    }
    let uid = try await freeUID(spec, preferring: gid)
    try await perform([Self.dscl, ".", "-create", record], commands: &commands)
    // No login shell: the account exists to own files and run launchd jobs, never to log in.
    try await perform(
      [Self.dscl, ".", "-create", record, "UserShell", "/usr/bin/false"], commands: &commands)
    try await perform(
      [Self.dscl, ".", "-create", record, "RealName", spec.realName], commands: &commands)
    try await perform(
      [Self.dscl, ".", "-create", record, "UniqueID", "\(uid)"], commands: &commands)
    try await perform(
      [Self.dscl, ".", "-create", record, "PrimaryGroupID", "\(gid)"], commands: &commands)
    try await perform(
      [Self.dscl, ".", "-create", record, "NFSHomeDirectory", spec.home], commands: &commands)
    try await perform([Self.dscl, ".", "-create", record, "Password", "*"], commands: &commands)
    try await perform([Self.dscl, ".", "-create", record, "IsHidden", "1"], commands: &commands)
    return (uid, true, false)
  }

  /// Prefers `uid == gid` when that number is free, purely so the pair reads as one identity in
  /// `ls -n` output; falls back to the first free id in the range.
  private func freeUID(_ spec: ServiceAccountSpec, preferring gid: Int) async throws -> Int {
    let used = try await usedIDs(list: "/Users", attribute: "UniqueID")
    if !used.contains(gid) { return gid }
    guard let uid = spec.idRange.first(where: { !used.contains($0) }) else {
      throw SetupError.noFreeID(range: spec.idRange, kind: "UID")
    }
    return uid
  }

  // MARK: - Reads

  private func readPrimaryGroupID(_ record: String) async throws -> Int? {
    try await readNumericAttribute(record, "PrimaryGroupID")
  }

  private func readUniqueID(_ record: String) async throws -> Int? {
    try await readNumericAttribute(record, "UniqueID")
  }

  /// `dscl . -read <record> <attr>` prints `PrimaryGroupID: 200`, or fails when the record does
  /// not exist — which is the "missing" answer, not an error.
  private func readNumericAttribute(_ record: String, _ attribute: String) async throws -> Int? {
    let result = try await runner.run([Self.dscl, ".", "-read", record, attribute])
    guard result.isSuccess else { return nil }
    return Self.parseAttribute(result.stdout, attribute: attribute).flatMap(Int.init)
  }

  private func usedIDs(list: String, attribute: String) async throws -> Set<Int> {
    let result = try await runner.run([Self.dscl, ".", "-list", list, attribute])
    guard result.isSuccess else { return [] }
    return Self.parseIDList(result.stdout)
  }

  private func perform(_ argv: [String], commands: inout [[String]]) async throws {
    commands.append(argv)
    try await runner.runChecked(argv)
  }

  // MARK: - Parsers

  /// `dscl . -read` prints `<Attribute>: <value>`; a multi-valued attribute wraps onto indented
  /// continuation lines, which this deliberately ignores — every attribute read here is scalar.
  public static func parseAttribute(_ output: String, attribute: String) -> String? {
    let prefix = "\(attribute):"
    for line in output.split(separator: "\n") where line.hasPrefix(prefix) {
      let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
      return value.isEmpty ? nil : value
    }
    return nil
  }

  /// `dscl . -list /Users UniqueID` prints `<name><spaces><id>` per line. Rows whose id is not an
  /// integer (a corrupt or non-local record) are skipped rather than failing the whole scan.
  public static func parseIDList(_ output: String) -> Set<Int> {
    var ids: Set<Int> = []
    for line in output.split(separator: "\n") {
      guard let last = line.split(separator: " ").last, let id = Int(last) else { continue }
      ids.insert(id)
    }
    return ids
  }
}
