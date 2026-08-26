import Foundation
import RunnerCore

/// The host's stable identity, persisted next to the database so a restart keeps the same
/// `host.id` row and every `instances.host_id` foreign key stays valid.
public enum HostIdentity {
  public static let fileName = "host-id"

  public static func load(stateDir: URL) throws -> HostID {
    let url = stateDir.appending(path: fileName)
    if let text = try? String(contentsOf: url, encoding: .utf8) {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return HostID(rawValue: trimmed) }
    }
    let generated = HostID.generate()
    do {
      try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
      // `.atomic` writes a sibling temp file and renames, so a crash never leaves a partial id.
      try Data("\(generated.rawValue)\n".utf8).write(to: url, options: .atomic)
    } catch {
      throw OrchestrationError.hostIdentityUnwritable(
        path: url.path(percentEncoded: false), reason: String(describing: error))
    }
    return generated
  }
}
