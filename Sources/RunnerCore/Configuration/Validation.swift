import Foundation

/// Host limits validation compares against. Supplied by VirtualizationCore at runtime so that
/// RunnerCore stays free of the Virtualization framework.
public struct HostFacts: Hashable, Sendable, Codable {
  public var logicalCPUCount: Int
  public var physicalMemoryBytes: UInt64
  /// `VZVirtualMachineConfiguration.minimumAllowedCPUCount` and friends.
  public var minimumAllowedCPUCount: Int
  public var maximumAllowedCPUCount: Int
  public var minimumAllowedMemoryBytes: UInt64
  public var maximumAllowedMemoryBytes: UInt64

  public init(
    logicalCPUCount: Int,
    physicalMemoryBytes: UInt64,
    minimumAllowedCPUCount: Int,
    maximumAllowedCPUCount: Int,
    minimumAllowedMemoryBytes: UInt64,
    maximumAllowedMemoryBytes: UInt64
  ) {
    self.logicalCPUCount = logicalCPUCount
    self.physicalMemoryBytes = physicalMemoryBytes
    self.minimumAllowedCPUCount = minimumAllowedCPUCount
    self.maximumAllowedCPUCount = maximumAllowedCPUCount
    self.minimumAllowedMemoryBytes = minimumAllowedMemoryBytes
    self.maximumAllowedMemoryBytes = maximumAllowedMemoryBytes
  }
}

/// One validation finding. `code` is stable API: CLI output, tests and docs key off it.
public struct ConfigurationIssue: Hashable, Sendable, Codable, CustomStringConvertible {
  public enum Severity: String, Sendable, Codable, CaseIterable {
    case error
    case warning
  }

  public var severity: Severity
  public var code: String
  /// Dotted location, e.g. `profiles[1].resources.cpu`.
  public var path: String
  public var message: String

  public init(severity: Severity, code: String, path: String, message: String) {
    self.severity = severity
    self.code = code
    self.path = path
    self.message = message
  }

  public static func error(_ code: String, _ path: String, _ message: String) -> ConfigurationIssue {
    ConfigurationIssue(severity: .error, code: code, path: path, message: message)
  }

  public static func warning(_ code: String, _ path: String, _ message: String) -> ConfigurationIssue {
    ConfigurationIssue(severity: .warning, code: code, path: path, message: message)
  }

  public var description: String { "\(severity.rawValue) \(code) at \(path): \(message)" }
}

extension Array where Element == ConfigurationIssue {
  public var errors: [ConfigurationIssue] { filter { $0.severity == .error } }
  public var warnings: [ConfigurationIssue] { filter { $0.severity == .warning } }
  public var hasErrors: Bool { contains { $0.severity == .error } }
  public func first(code: String) -> ConfigurationIssue? { first { $0.code == code } }
  public func contains(code: String) -> Bool { contains { $0.code == code } }
}

extension RunnerConfiguration {
  /// Spec §123: every obvious configuration mistake is caught at apply time, not on the first job.
  /// Returns findings rather than throwing so `runnerctl config validate` can list them all.
  public func validate(host facts: HostFacts) -> [ConfigurationIssue] {
    var issues: [ConfigurationIssue] = []
    if version != Self.currentVersion {
      issues.append(.error(
        "CONFIG_UNSUPPORTED_VERSION", "version",
        "version \(version) is not supported (expected \(Self.currentVersion))"
      ))
    }
    issues += host.validate(facts: facts)
    issues += github.validate()
    issues += validateProfiles(facts: facts)
    issues += validateMacOSAggregates()
    issues += security.validate()
    issues += metrics.validate()
    issues += diagnostics.validate()
    issues += images.validate()
    issues += logging.validate()
    issues += build.validate(facts: facts)
    return issues
  }

  /// Convenience for call sites that only care whether the configuration is usable.
  public func validated(host facts: HostFacts) throws -> [ConfigurationIssue] {
    let issues = validate(host: facts)
    guard !issues.hasErrors else { throw ConfigurationError.validationFailed(issues: issues.errors) }
    return issues
  }
}
