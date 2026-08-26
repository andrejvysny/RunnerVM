import RunnerCore

// GRDB exports a deprecated `PersistenceError` typealias (`= RecordError`) at module scope, which
// collides with `RunnerCore.PersistenceError` (the type this module actually uses) wherever both
// `GRDB` and `RunnerCore` are imported. A module-local declaration shadows an imported one during
// unqualified lookup, so this single typealias resolves every unqualified `PersistenceError` use
// across the module to the RunnerCore type instead of forcing `RunnerCore.PersistenceError`
// everywhere.
typealias PersistenceError = RunnerCore.PersistenceError
