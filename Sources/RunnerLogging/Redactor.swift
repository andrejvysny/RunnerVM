import Foundation
import Logging

/// Central secret redaction for log messages and metadata (spec §42:
/// "Sensitive fields MUST be redacted centrally... Do not rely on every
/// callsite remembering to redact.").
///
/// Applied by `JSONLogHandler` to every message and metadata value before
/// they are written. Callers never redact by hand.
public struct Redactor: Sendable {
  private struct Rule: Sendable {
    let name: String
    let regex: NSRegularExpression
  }

  private let rules: [Rule]
  private let base64Rule: Rule
  private let sensitiveMetadataKeyRegex: NSRegularExpression

  /// Redaction rule set covering spec §42's minimum list: Authorization/Bearer
  /// headers, GitHub PAT/App/installation tokens, PEM private keys, JIT
  /// configs and other sensitive metadata keys, and long base64 blobs.
  public static let standard = Redactor()

  private init() {
    self.rules = [
      Rule(
        name: "pem-private-key",
        regex: Redactor.makeRegex(
          #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#
        )
      ),
      Rule(
        name: "authorization-header",
        regex: Redactor.makeRegex(#"Authorization:\s*[^\r\n,;"']+"#, caseInsensitive: true)
      ),
      Rule(
        name: "bearer-token",
        regex: Redactor.makeRegex(#"\bBearer\s+\S+"#, caseInsensitive: true)
      ),
      Rule(
        name: "github-token",
        regex: Redactor.makeRegex(
          #"\b(ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|ghu_[A-Za-z0-9]{20,}|"#
            + #"ghs_[A-Za-z0-9]{20,}|ghr_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b"#
        )
      ),
    ]
    self.base64Rule = Rule(name: "base64-blob", regex: Redactor.makeRegex(#"[A-Za-z0-9+/=]{200,}"#))
    self.sensitiveMetadataKeyRegex = Redactor.makeRegex(
      "jitconfig|jit_config|encodedjitconfig|password|secret|token|"
        + "private_key|registry_password|access_token|installation_token",
      caseInsensitive: true
    )
  }

  private static func makeRegex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
    var options: NSRegularExpression.Options = [.dotMatchesLineSeparators]
    if caseInsensitive { options.insert(.caseInsensitive) }
    // Patterns are fixed string literals; a failure here is a programming error, not runtime data.
    return try! NSRegularExpression(pattern: pattern, options: options)
  }

  /// Redacts secrets embedded in free-text (log messages, string metadata values).
  public func redact(_ input: String) -> String {
    var result = input
    for rule in rules {
      result = Self.replace(rule, in: result)
    }
    return Self.redactBase64Blobs(base64Rule, in: result)
  }

  private static func replace(_ rule: Rule, in string: String) -> String {
    let range = NSRange(string.startIndex..<string.endIndex, in: string)
    let template = NSRegularExpression.escapedTemplate(for: "[REDACTED:\(rule.name)]")
    return rule.regex.stringByReplacingMatches(in: string, options: [], range: range, withTemplate: template)
  }

  /// Redacts long base64 runs, except ones immediately preceded by `ssh-rsa `/`ssh-ed25519 `
  /// (public keys are not secrets — spec: "ssh-(rsa|ed25519) AAAA… private-looking keys
  /// are not secrets").
  private static func redactBase64Blobs(_ rule: Rule, in string: String) -> String {
    var result = ""
    var searchStart = string.startIndex
    while searchStart < string.endIndex,
      let match = rule.regex.firstMatch(
        in: string, options: [], range: NSRange(searchStart..<string.endIndex, in: string)),
      let matchRange = Range(match.range, in: string)
    {
      result += string[searchStart..<matchRange.lowerBound]
      let preceding = string[string.startIndex..<matchRange.lowerBound]
      if preceding.hasSuffix("ssh-rsa ") || preceding.hasSuffix("ssh-ed25519 ") {
        result += string[matchRange]
      } else {
        result += "[REDACTED:\(rule.name)]"
      }
      searchStart = matchRange.upperBound
    }
    result += string[searchStart...]
    return result
  }

  /// Redacts logging metadata, recursing into nested dictionaries and arrays. A metadata
  /// key matching a sensitive-name pattern (e.g. `jitConfig`, `password`) has its entire
  /// value replaced regardless of content.
  public func redact(metadata: Logger.Metadata) -> Logger.Metadata {
    var result: Logger.Metadata = [:]
    for (key, value) in metadata {
      result[key] = isSensitiveKey(key) ? .string("[REDACTED:metadata-key]") : redactValue(value)
    }
    return result
  }

  private func redactValue(_ value: Logger.MetadataValue) -> Logger.MetadataValue {
    switch value {
    case .string(let string):
      return .string(redact(string))
    case .stringConvertible(let convertible):
      return .string(redact(convertible.description))
    case .dictionary(let nested):
      return .dictionary(redact(metadata: nested))
    case .array(let values):
      return .array(values.map(redactValue))
    }
  }

  private func isSensitiveKey(_ key: String) -> Bool {
    let range = NSRange(key.startIndex..<key.endIndex, in: key)
    return sensitiveMetadataKeyRegex.firstMatch(in: key, options: [], range: range) != nil
  }
}
