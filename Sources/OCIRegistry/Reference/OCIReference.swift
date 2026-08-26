import Foundation
import RunnerCore

/// A `RunnerCore.ImageReference` plus the transport facts the registry client needs.
///
/// The reference grammar itself lives in `ImageReference` (spec §21, §123); this type only adds URL
/// construction and the tag → digest promotion that every pull performs before a VM starts.
public struct OCIReference: Sendable, Hashable, CustomStringConvertible {
  public let image: ImageReference
  /// Plain HTTP. Honoured only for loopback registries, so a typo in a profile can never downgrade
  /// a real pull to cleartext.
  public let insecure: Bool

  public init(_ image: ImageReference, insecure: Bool = false) {
    self.image = image
    self.insecure = insecure
  }

  public init(parsing text: String, insecure: Bool = false) throws {
    guard let parsed = try? ImageReference(parsing: text) else {
      throw ImageError.referenceInvalid(reference: text)
    }
    self.init(parsed, insecure: insecure)
  }

  public var registry: String {
    image.registry
  }

  public var repositoryPath: String {
    image.repository
  }

  public var tag: String? {
    image.tag
  }

  public var digest: ImageDigest? {
    image.digest
  }

  public var description: String {
    image.description
  }

  /// `https://<registry>/v2/`.
  public var registryURL: URL {
    // Force-unwrap is safe: `ImageReference` already validated the host and optional port.
    URL(string: "\(scheme)://\(registry)/v2/")!
  }

  public var scheme: String {
    usesPlainHTTP ? "http" : "https"
  }

  var usesPlainHTTP: Bool {
    insecure && Self.isLoopback(registry)
  }

  /// What goes into `/v2/<name>/manifests/<reference>`: an immutable digest wins over a tag.
  public var manifestReference: String {
    if let digest { return digest.rawValue }
    return tag ?? Self.defaultTag
  }

  /// The immutable form stored on the instance record (spec §21). The tag is dropped: it is a
  /// moving label and keeping it would suggest the pair was verified together.
  public func canonical(withDigest digest: ImageDigest) -> OCIReference {
    // Composed from already-validated parts, so parsing cannot fail.
    let reference = try! ImageReference(parsing: "\(registry)/\(repositoryPath)@\(digest.rawValue)")
    return OCIReference(reference, insecure: insecure)
  }

  public static let defaultTag = "latest"

  static func isLoopback(_ registry: String) -> Bool {
    let host = registry.split(separator: ":", maxSplits: 1).first.map(String.init) ?? registry
    return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
  }
}
