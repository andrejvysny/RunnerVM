import Foundation

/// What the caller wants registered. `runnerGroupID` overrides the scope's own group.
public struct JITRunnerRequest: Sendable, Hashable {
  public var name: String
  public var labels: [String]
  public var runnerGroupID: Int64?
  /// GitHub defaults this to `_work` when omitted.
  public var workFolder: String?

  public init(
    name: String, labels: [String], runnerGroupID: Int64? = nil, workFolder: String? = nil
  ) {
    self.name = name
    self.labels = labels
    self.runnerGroupID = runnerGroupID
    self.workFolder = workFolder
  }
}

/// A just-in-time runner registration (spec §36).
///
/// `encodedJITConfig` is a secret: it registers a runner against the scope for anyone holding it.
/// The type is deliberately **not** `Codable` and **not** `Equatable` so it cannot drift into
/// SQLite, VM metadata or a JSON log line, and `description` prints only its size.
public struct JITRunnerConfig: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public let runnerID: Int64
  public let runnerName: String
  public let encodedJITConfig: String

  public init(runnerID: Int64, runnerName: String, encodedJITConfig: String) {
    self.runnerID = runnerID
    self.runnerName = runnerName
    self.encodedJITConfig = encodedJITConfig
  }

  public var description: String {
    "JITRunnerConfig(runner: \(runnerID), name: \(runnerName), "
      + "jitConfig: <redacted \(encodedJITConfig.utf8.count) bytes>)"
  }

  public var debugDescription: String {
    description
  }
}
