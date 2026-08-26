import CryptoKit
import Foundation

/// Content digest of an instance spec file. runnerd compares the digest it recorded at spawn time
/// with the one a worker reports in `worker.hello`, so it must be taken over the exact bytes on
/// disk rather than a re-encoding of the decoded value.
public enum SpecDigest {
  public static func sha256Hex(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  public static func sha256Hex(ofFileAt url: URL) throws -> String {
    sha256Hex(of: try Data(contentsOf: url))
  }
}
