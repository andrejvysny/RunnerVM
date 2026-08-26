import Foundation

/// Syntactic validation of `host/path[:tag][@sha256:hex]` (spec §21, §123 "invalid OCI reference").
///
/// Registry-less shorthand ("ubuntu:24.04") is rejected on purpose: RunnerVM never falls back to an
/// implicit Docker Hub, so every profile must name its registry.
public struct ImageReference: Hashable, Sendable, CustomStringConvertible {
  public let registry: String
  /// Path after the registry, e.g. "acme/runnervm/ubuntu-24".
  public let repository: String
  public let tag: String?
  public let digest: ImageDigest?

  public struct ParseError: Error, Hashable, Sendable, CustomStringConvertible {
    public let input: String
    public let reason: String
    public var description: String { "invalid image reference '\(input)': \(reason)" }
  }

  public init(parsing text: String) throws {
    var rest = Substring(text)
    var parsedDigest: ImageDigest?
    if let at = rest.firstIndex(of: "@") {
      let digestText = String(rest[rest.index(after: at)...])
      guard Self.isValidDigest(digestText) else {
        throw ParseError(input: text, reason: "digest must be sha256:<64 hex>")
      }
      parsedDigest = ImageDigest(rawValue: digestText)
      rest = rest[..<at]
    }
    var parsedTag: String?
    if let colon = rest.lastIndex(of: ":"), !rest[rest.index(after: colon)...].contains("/") {
      let tagText = String(rest[rest.index(after: colon)...])
      guard Self.isValidTag(tagText) else { throw ParseError(input: text, reason: "invalid tag") }
      parsedTag = tagText
      rest = rest[..<colon]
    }
    let components = rest.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count >= 2 else {
      throw ParseError(input: text, reason: "expected <registry>/<path>")
    }
    guard Self.isValidRegistry(String(components[0])) else {
      throw ParseError(input: text, reason: "invalid registry host")
    }
    let path = components.dropFirst()
    guard path.allSatisfy({ Self.isValidPathComponent(String($0)) }) else {
      throw ParseError(input: text, reason: "invalid repository path")
    }
    registry = String(components[0])
    repository = path.joined(separator: "/")
    tag = parsedTag
    digest = parsedDigest
  }

  public static func isValid(_ text: String) -> Bool { (try? ImageReference(parsing: text)) != nil }

  /// Profiles may also point at a locally imported image (v1: `image import --name`): a bare name
  /// with optional tag, or a `sha256:<hex>` digest. Slashes still require a registry host.
  public static func isValidProfileImage(_ text: String) -> Bool {
    if isValid(text) || isValidDigest(text) { return true }
    guard !text.contains("/") else { return false }
    let parts = text.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count <= 2, let name = parts.first, isValidPathComponent(String(name)) else { return false }
    return parts.count == 1 || isValidTag(String(parts[1]))
  }

  public var description: String {
    var out = "\(registry)/\(repository)"
    if let tag { out += ":\(tag)" }
    if let digest { out += "@\(digest.rawValue)" }
    return out
  }

  // MARK: - Component grammar

  static func isValidDigest(_ text: String) -> Bool {
    guard text.hasPrefix("sha256:") else { return false }
    let hex = text.dropFirst("sha256:".count)
    return hex.count == 64 && hex.allSatisfy { $0.isHexDigit && !$0.isUppercase }
  }

  static func isValidTag(_ text: String) -> Bool {
    guard (1...128).contains(text.count), let first = text.first,
          first.isLetter || first.isNumber || first == "_"
    else { return false }
    return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }
  }

  static func isValidRegistry(_ text: String) -> Bool {
    let hostPart = text.split(separator: ":", maxSplits: 1)
    guard let host = hostPart.first, !host.isEmpty else { return false }
    // A bare first label ("acme/ubuntu") is Docker Hub shorthand, which RunnerVM never resolves.
    guard host.contains(".") || hostPart.count == 2 || host == "localhost" else { return false }
    if hostPart.count == 2 {
      guard let port = Int(hostPart[1]), (1...65_535).contains(port) else { return false }
    }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    return labels.allSatisfy { label in
      !label.isEmpty && label.first != "-" && label.last != "-"
        && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }
  }

  static func isValidPathComponent(_ text: String) -> Bool {
    guard !text.isEmpty, let first = text.first, let last = text.last,
          first.isLetter || first.isNumber, last.isLetter || last.isNumber
    else { return false }
    return text.allSatisfy {
      ($0.isLowercase && $0.isLetter) || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-"
    }
  }
}

extension ImageReference: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let text = try container.decode(String.self)
    do {
      try self.init(parsing: text)
    } catch {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "\(error)")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }
}
