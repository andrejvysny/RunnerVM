import Foundation

/// Parsed output of `BuildScripts.probe`: what the builder VM turned out to have, gathered after
/// the recipe's own steps ran (actual package versions, kernel, whether the runner/agent/docker
/// installed correctly) rather than assumed from the recipe text.
public struct BuildProbeReport: Sendable, Hashable {
  public var runnerVersion: String?
  public var guestAgentVersion: String?
  public var dockerVersion: String?
  public var kernelVersion: String?
  public var architecture: String?
  public var sshEnabled: Bool
  public var packages: [String]

  public init(
    runnerVersion: String?, guestAgentVersion: String?, dockerVersion: String?,
    kernelVersion: String?, architecture: String?, sshEnabled: Bool, packages: [String]
  ) {
    self.runnerVersion = runnerVersion
    self.guestAgentVersion = guestAgentVersion
    self.dockerVersion = dockerVersion
    self.kernelVersion = kernelVersion
    self.architecture = architecture
    self.sshEnabled = sshEnabled
    self.packages = packages
  }

  private static let header = "RVM-PROBE-V1"
  private static let packagesBegin = "RVM-PACKAGES-BEGIN"
  private static let packagesEnd = "RVM-PACKAGES-END"

  public static func parse(_ text: String) throws -> BuildProbeReport {
    var lines = ArraySlice(text.components(separatedBy: "\n"))
    while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
      lines = lines.dropFirst()
    }
    guard lines.first?.trimmingCharacters(in: .whitespaces) == header else {
      throw RecipeError.probeMalformed(reason: "missing \(header) header")
    }
    lines = lines.dropFirst()

    var fields: [String: String] = [:]
    while let line = lines.first, line.trimmingCharacters(in: .whitespaces) != packagesBegin {
      if let eq = line.firstIndex(of: "=") {
        fields[String(line[..<eq])] = String(line[line.index(after: eq)...])
      }
      lines = lines.dropFirst()
    }
    guard lines.first != nil else {
      throw RecipeError.probeMalformed(reason: "missing \(packagesBegin) marker")
    }
    lines = lines.dropFirst()

    var packages: [String] = []
    var sawEnd = false
    while let line = lines.first {
      if line.trimmingCharacters(in: .whitespaces) == packagesEnd {
        sawEnd = true
        break
      }
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if !trimmed.isEmpty { packages.append(trimmed) }
      lines = lines.dropFirst()
    }
    guard sawEnd else { throw RecipeError.probeMalformed(reason: "missing \(packagesEnd) marker") }

    func value(_ key: String) -> String? {
      guard let raw = fields[key], !raw.isEmpty else { return nil }
      return raw
    }
    return BuildProbeReport(
      runnerVersion: value("runnerVersion"), guestAgentVersion: value("guestAgentVersion"),
      dockerVersion: value("dockerVersion"), kernelVersion: value("kernelVersion"),
      architecture: value("architecture"), sshEnabled: fields["sshEnabled"] == "true",
      packages: packages
    )
  }
}
