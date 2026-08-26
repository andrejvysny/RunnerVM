import Darwin
import Foundation
import RunnerCore

/// The one place every GitHub secret file (PAT token file, App descriptor JSON, App private key
/// PEM) is opened and read.
///
/// A naive reader stats a path, likes what it sees, then opens the same path to read it — between
/// those two steps the path can be swapped for a symlink to something the caller has no business
/// reading. This type instead `open()`s first (`O_NOFOLLOW` rejects a symlinked last component
/// outright), `fstat()`s the resulting descriptor, and only reads a descriptor that has already
/// passed every check. Every check runs against that descriptor, never against `path` a second
/// time, so nothing between `open()` and the read can change what is being verified.
public enum SecureFile {
  /// How loose a secret file's mode is allowed to be.
  public enum Policy: Sendable {
    /// No group or other bits at all — required for anything that is itself a bearer secret (a
    /// PAT, a private key).
    case ownerOnly
    /// Group-read is tolerated; group write/execute and every "other" bit are not — for a
    /// descriptor that names other files rather than carrying a secret itself.
    case ownerAndGroupRead

    fileprivate var disallowedBits: mode_t {
      switch self {
      case .ownerOnly: 0o077
      case .ownerAndGroupRead: 0o037
      }
    }

    fileprivate var requirement: String {
      switch self {
      case .ownerOnly: "owner-only (chmod 600)"
      case .ownerAndGroupRead: "owner/group-readable at most (chmod 640)"
      }
    }
  }

  /// No secret RunnerVM reads is legitimately anywhere near this size; anything bigger is either
  /// misconfiguration or an attempt to exhaust memory.
  private static let maxBytes: Int64 = 1 << 20

  /// Opens `path` with `O_NOFOLLOW`, `fstat()`s the descriptor, checks it against `policy` and
  /// `expectedOwner`, and only then reads it.
  public static func read(
    path: String, label: String, policy: Policy = .ownerOnly, expectedOwner: uid_t = geteuid()
  ) throws -> Data {
    let descriptor = try openRegularFile(path: path, label: label)
    do {
      try verify(
        descriptor: descriptor, path: path, label: label, policy: policy, expectedOwner: expectedOwner
      )
    } catch {
      close(descriptor)
      throw error
    }
    return try readAll(descriptor: descriptor, path: path, label: label)
  }

  /// `read(path:label:policy:expectedOwner:)`, decoded as UTF-8.
  public static func readString(
    path: String, label: String, policy: Policy = .ownerOnly, expectedOwner: uid_t = geteuid()
  ) throws -> String {
    let data = try read(path: path, label: label, policy: policy, expectedOwner: expectedOwner)
    guard let string = String(data: data, encoding: .utf8) else {
      throw GitHubControlError.permanentConfiguration(reason: "\(label) \(path) is not valid UTF-8")
    }
    return string
  }

  // MARK: - Open

  /// `O_NOFOLLOW` makes a symlinked last path component fail here with `ELOOP` instead of being
  /// silently followed — that is the race this type exists to close.
  private static func openRegularFile(path: String, label: String) throws -> CInt {
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      let code = errno
      switch code {
      case ENOENT:
        throw GitHubControlError.notFound(resource: "\(label) \(path)")
      case ELOOP:
        throw GitHubControlError.permanentConfiguration(
          reason: "\(label) \(path) is a symlink; secrets must be regular files"
        )
      default:
        throw GitHubControlError.permanentConfiguration(
          reason: "cannot open \(label) \(path): \(String(cString: strerror(code)))"
        )
      }
    }
    return descriptor
  }

  // MARK: - Verify

  private static func verify(
    descriptor: CInt, path: String, label: String, policy: Policy, expectedOwner: uid_t
  ) throws {
    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
      throw GitHubControlError.permanentConfiguration(
        reason: "cannot stat \(label) \(path): \(String(cString: strerror(errno)))"
      )
    }
    guard (info.st_mode & S_IFMT) == S_IFREG else {
      throw GitHubControlError.permanentConfiguration(reason: "\(label) \(path) is not a regular file")
    }
    guard info.st_uid == expectedOwner else {
      throw GitHubControlError.permanentConfiguration(
        reason: "\(label) \(path) is owned by uid \(info.st_uid) but runnerd runs as uid "
          + "\(expectedOwner); chown \(expectedOwner) \(path)"
      )
    }
    let mode = info.st_mode & 0o777
    guard mode & policy.disallowedBits == 0 else {
      throw GitHubControlError.permanentConfiguration(
        reason: "\(label) \(path) is mode \(String(mode, radix: 8)); it must be \(policy.requirement)"
      )
    }
    guard info.st_size <= maxBytes else {
      throw GitHubControlError.permanentConfiguration(
        reason: "\(label) \(path) is larger than the 1 MiB limit for a secret file"
      )
    }
  }

  // MARK: - Read

  /// Takes ownership of `descriptor`: from here on it closes exactly once — whether this returns
  /// or throws — via `FileHandle`'s `closeOnDealloc`.
  private static func readAll(descriptor: CInt, path: String, label: String) throws -> Data {
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      return try handle.readToEnd() ?? Data()
    } catch {
      throw GitHubControlError.permanentConfiguration(
        reason: "cannot read \(label) \(path): \(error.localizedDescription)"
      )
    }
  }
}
