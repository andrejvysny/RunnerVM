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

  /// Generates a fresh identifier and persists it durably.
  ///
  /// `DurableFile.atomicReplace` is the whole contract here: unique temporary, full write, the
  /// file's own `fsync`, `rename(2)`, then the directory's `fsync`. A power loss at any point
  /// leaves either the previous identifier or nothing at all -- never a truncated one, and never a
  /// durable-but-unnamed one whose loss would make the next boot mint a *second* virtual Mac
  /// against auxiliary storage bound to the first.
  @discardableResult
  public static func create(at url: URL) throws -> VZMacMachineIdentifier {
    let identifier = VZMacMachineIdentifier()
    do {
      try DurableFile.atomicReplace(identifier.dataRepresentation, at: url, mode: 0o600)
    } catch {
      throw VMError.macOSMachineIdentifierInvalid(path: url.path(percentEncoded: false))
    }
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
}
