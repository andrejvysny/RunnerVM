// Derived from openai/tart@16d186c Sources/tart/OCI/WWWAuthenticate.swift — FSL-1.1-ALv2.
// See PROVENANCE.md.
import Foundation

/// `WWW-Authenticate: <scheme> k=v, k="v, with comma"` (RFC 2617 §3.2.1, RFC 6750 §3).
public struct WWWAuthenticate: Sendable, Equatable {
  public let scheme: String
  public let directives: [String: String]

  public init(parsing raw: String) throws {
    let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
    guard let first = parts.first, !first.isEmpty else {
      throw RegistryError.invalidResponse(
        operation: "authentication challenge", reason: "empty WWW-Authenticate header"
      )
    }
    scheme = String(first)
    guard parts.count == 2 else {
      directives = [:]
      return
    }
    var parsed: [String: String] = [:]
    for directive in Self.splitOutsideQuotes(String(parts[1])) {
      let trimmed = directive.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { continue }
      let pair = trimmed.split(separator: "=", maxSplits: 1)
      guard pair.count == 2 else {
        throw RegistryError.invalidResponse(
          operation: "authentication challenge",
          reason: "directive '\(trimmed)' is not key=value"
        )
      }
      parsed[String(pair[0]).lowercased()] =
        String(pair[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
    directives = parsed
  }

  public var realm: String? {
    directives["realm"]
  }

  public var service: String? {
    directives["service"]
  }

  public var scope: String? {
    directives["scope"]
  }

  public var isBearer: Bool {
    scheme.caseInsensitiveCompare("bearer") == .orderedSame
  }

  public var isBasic: Bool {
    scheme.caseInsensitiveCompare("basic") == .orderedSame
  }

  /// A scope value legitimately contains commas (`repository:a:pull,push`), so a plain split
  /// corrupts the challenge.
  private static func splitOutsideQuotes(_ text: String) -> [String] {
    var result: [String] = []
    var current = ""
    var quoted = false
    for character in text {
      if character == ",", !quoted {
        result.append(current)
        current = ""
        continue
      }
      current.append(character)
      if character == "\"" { quoted.toggle() }
    }
    if !current.isEmpty { result.append(current) }
    return result
  }
}
