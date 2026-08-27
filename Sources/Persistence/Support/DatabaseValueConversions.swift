import GRDB
import RunnerCore

// RunnerCore's typed IDs (`IDs.swift`) and persisted state machines (`StateMachines/*.swift`) are
// plain `RawRepresentable<RawValue == String>` types with zero GRDB dependency, by design — only
// `Persistence` may import GRDB. GRDB already ships a free `DatabaseValueConvertible` witness for
// any `RawRepresentable` type whose `RawValue` itself conforms (String does), so opting each type
// in here is enough to store/fetch it as its raw string; no hand-written `databaseValue` /
// `fromDatabaseValue` bodies are needed. This is also why every Record can declare these columns
// with the RunnerCore type directly instead of a plain `String` plus a manual conversion.
extension InstanceID: DatabaseValueConvertible {}
extension RunnerSessionID: DatabaseValueConvertible {}
extension RunnerProfileID: DatabaseValueConvertible {}
extension GitHubScopeID: DatabaseValueConvertible {}
extension OperationID: DatabaseValueConvertible {}
extension HostID: DatabaseValueConvertible {}
extension ImageDigest: DatabaseValueConvertible {}
extension ImageBuildID: DatabaseValueConvertible {}

extension GuestOS: DatabaseValueConvertible {}
extension InstanceLifecycle: DatabaseValueConvertible {}
extension GitHubScopeKind: DatabaseValueConvertible {}

extension InstanceState: DatabaseValueConvertible {}
extension RunnerSessionState: DatabaseValueConvertible {}
extension HostMode: DatabaseValueConvertible {}
extension ImageBuildState: DatabaseValueConvertible {}
