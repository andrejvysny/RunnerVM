import Foundation
import RunnerCore
import Virtualization

/// The per-instance macOS machine identifier (`machine-identifier.bin`).
///
/// A `VZMacMachineIdentifier` is the guest's ECID: macOS binds its activation state, its keychain
/// and parts of the boot policy in the auxiliary storage to it, so the identifier minted for an
/// instance must survive every restart of that instance and must never be shared with another. It
/// is therefore instance state, kept beside `nvram.bin` in the instance directory and never sealed
/// into an image (spec §24 keeps instance identity out of `ImageMetadata`).
///
/// Nothing here needs the virtualization entitlement: minting and re-decoding an identifier are
/// pure data operations, which is what lets the whole file be unit-tested on an unsigned build.
public enum MacOSMachineIdentity {
  /// Decodes an existing identifier.
  ///
  /// Any failure is one error: an unreadable file and a file whose bytes the framework rejects are
  /// the same operational problem -- this instance can no longer be booted as the machine it was.
  public static func load(at url: URL) throws -> VZMacMachineIdentifier {
    let path = url.path(percentEncoded: false)
    guard let data = FileManager.default.contents(atPath: path),
          let identifier = VZMacMachineIdentifier(dataRepresentation: data)
    else {
      throw VMError.macOSMachineIdentifierInvalid(path: path)
    }
    return identifier
  }

  /// Generates a fresh identifier and persists it.
  ///
  /// Written to a sibling temporary and renamed, so a crash mid-write leaves either the previous
  /// identifier or nothing at all -- never a truncated one that would strand the instance's
  /// auxiliary storage.
  @discardableResult
  public static func create(at url: URL) throws -> VZMacMachineIdentifier {
    let identifier = VZMacMachineIdentifier()
    let temporary = url.deletingLastPathComponent()
      .appendingPathComponent("\(url.lastPathComponent).tmp-\(getpid())")
    try writeAtomically(identifier.dataRepresentation, to: url, via: temporary)
    return identifier
  }

  /// `load` when the file exists, else `create`.
  ///
  /// The caller must already hold the instance's `WorkerLock`: that lock -- not any check here --
  /// is what stops two workers from racing to mint two identities for one instance. Documented
  /// rather than enforced, because the lock is a process-wide `fcntl` record lock that this
  /// value-free helper has no handle on.
  public static func loadOrCreate(at url: URL) throws -> (identifier: VZMacMachineIdentifier, created: Bool) {
    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
      return (try create(at: url), true)
    }
    return (try load(at: url), false)
  }

  /// Create-write-fsync-rename at 0600. `Data.write(options: .atomic)` would do the rename but not
  /// the fsync, and the identifier has to be on the platter before the guest boots against it.
  private static func writeAtomically(_ data: Data, to url: URL, via temporary: URL) throws {
    let path = url.path(percentEncoded: false)
    let temporaryPath = temporary.path(percentEncoded: false)
    let descriptor = open(temporaryPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw VMError.macOSMachineIdentifierInvalid(path: path) }
    var succeeded = false
    defer {
      close(descriptor)
      if !succeeded { try? FileManager.default.removeItem(at: temporary) }
    }
    let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    guard written == data.count, fsync(descriptor) == 0 else {
      throw VMError.macOSMachineIdentifierInvalid(path: path)
    }
    guard rename(temporaryPath, path) == 0 else {
      throw VMError.macOSMachineIdentifierInvalid(path: path)
    }
    succeeded = true
  }
}
