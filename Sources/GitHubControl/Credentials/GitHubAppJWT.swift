import Foundation
import RunnerCore
import Security

/// Signs the RS256 JWT that identifies a GitHub App (spec §12).
///
/// CryptoKit has no RSA, so signing goes through Security.framework. Only the DER is kept: `SecKey`
/// is not `Sendable`, and re-importing it costs nothing next to the hourly token refresh it serves.
public struct GitHubAppJWT: Sendable, Hashable {
  /// GitHub caps app JWT lifetime at 10 minutes *including* the backdated `iat`.
  public static let maximumLifetime: Duration = .seconds(480)
  /// GitHub's own guidance: backdate `iat` to absorb clock skew between host and github.com.
  public static let clockSkewAllowance: Duration = .seconds(60)

  public let appID: String
  private let pkcs1DER: Data

  /// - Parameter privateKeyPEM: the `.pem` GitHub hands out (PKCS#1, `BEGIN RSA PRIVATE KEY`).
  ///   A PKCS#8 file (`BEGIN PRIVATE KEY`, what `openssl pkcs8` produces) is unwrapped here,
  ///   because `SecKeyCreateWithData` only accepts PKCS#1.
  public init(appID: String, privateKeyPEM: String) throws {
    guard !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw GitHubControlError.permanentConfiguration(reason: "GitHub App id is empty")
    }
    self.appID = appID
    pkcs1DER = try PEM.rsaPrivateKeyDER(fromPEM: privateKeyPEM)
  }

  public func token(now: Date = Date(), lifetime: Duration = GitHubAppJWT.maximumLifetime) throws -> String {
    let issuedAt = Int(now.timeIntervalSince1970) - Int(Self.clockSkewAllowance.components.seconds)
    let expiry = Int(now.timeIntervalSince1970) + Int(min(lifetime, Self.maximumLifetime).components.seconds)
    let header = try GitHubRequest.encode(Header())
    let claims = try GitHubRequest.encode(Claims(iat: issuedAt, exp: expiry, iss: appID))
    let signingInput = "\(Base64URL.encode(header)).\(Base64URL.encode(claims))"
    let signature = try sign(Data(signingInput.utf8))
    return "\(signingInput).\(Base64URL.encode(signature))"
  }

  private func sign(_ message: Data) throws -> Data {
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
    ]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateWithData(pkcs1DER as CFData, attributes as CFDictionary, &error) else {
      throw GitHubControlError.permanentConfiguration(
        reason: "GitHub App private key is not a usable RSA key: \(Self.describe(&error))"
      )
    }
    guard
      let signature = SecKeyCreateSignature(
        key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, &error
      )
    else {
      throw GitHubControlError.permanentConfiguration(
        reason: "could not sign the GitHub App JWT: \(Self.describe(&error))"
      )
    }
    return signature as Data
  }

  private static func describe(_ error: inout Unmanaged<CFError>?) -> String {
    guard let taken = error?.takeRetainedValue() else { return "unknown Security.framework failure" }
    error = nil
    return CFErrorCopyDescription(taken) as String? ?? "unknown Security.framework failure"
  }

  private struct Header: Encodable {
    let alg = "RS256"
    let typ = "JWT"
  }

  private struct Claims: Encodable {
    let iat: Int
    let exp: Int
    let iss: String
  }
}

enum Base64URL {
  static func encode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func decode(_ string: String) -> Data? {
    var text = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    text += String(repeating: "=", count: (4 - text.count % 4) % 4)
    return Data(base64Encoded: text)
  }
}

/// Just enough PEM/DER to unwrap an RSA private key. A full ASN.1 parser is not warranted.
enum PEM {
  static func rsaPrivateKeyDER(fromPEM pem: String) throws -> Data {
    let lines = pem.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    guard let header = lines.first(where: { $0.hasPrefix("-----BEGIN") }) else {
      throw GitHubControlError.permanentConfiguration(
        reason: "GitHub App private key is not PEM (no BEGIN line)"
      )
    }
    let body = lines.filter { !$0.hasPrefix("-----") }.joined()
    guard let der = Data(base64Encoded: body), !der.isEmpty else {
      throw GitHubControlError.permanentConfiguration(
        reason: "GitHub App private key PEM body is not base64"
      )
    }
    if header.contains("RSA PRIVATE KEY") { return der }
    if header.contains("PRIVATE KEY") { return try unwrapPKCS8(der) }
    throw GitHubControlError.permanentConfiguration(
      reason: "GitHub App private key is a \(header.replacingOccurrences(of: "-", with: "")), "
        + "expected an RSA private key"
    )
  }

  /// PrivateKeyInfo ::= SEQUENCE { version INTEGER, algorithm SEQUENCE, privateKey OCTET STRING }
  private static func unwrapPKCS8(_ der: Data) throws -> Data {
    let bytes = [UInt8](der)
    let outer = try readTLV(tag: 0x30, in: bytes, at: 0)
    let version = try readTLV(tag: 0x02, in: bytes, at: outer.lowerBound)
    let algorithm = try readTLV(tag: 0x30, in: bytes, at: version.upperBound)
    let key = try readTLV(tag: 0x04, in: bytes, at: algorithm.upperBound)
    return Data(bytes[key])
  }

  /// Returns the value range of one DER element, or throws if the tag or length is not what a
  /// PKCS#8 RSA key must contain.
  private static func readTLV(tag: UInt8, in bytes: [UInt8], at offset: Int) throws -> Range<Int> {
    guard offset < bytes.count, bytes[offset] == tag, offset + 1 < bytes.count else {
      throw GitHubControlError.permanentConfiguration(
        reason: "GitHub App private key DER is malformed at byte \(offset)"
      )
    }
    var cursor = offset + 1
    var length = Int(bytes[cursor])
    cursor += 1
    if length & 0x80 != 0 {
      let byteCount = length & 0x7F
      guard byteCount > 0, byteCount <= 4, cursor + byteCount <= bytes.count else {
        throw GitHubControlError.permanentConfiguration(
          reason: "GitHub App private key DER has an unsupported length field"
        )
      }
      length = bytes[cursor ..< (cursor + byteCount)].reduce(0) { ($0 << 8) | Int($1) }
      cursor += byteCount
    }
    guard cursor + length <= bytes.count else {
      throw GitHubControlError.permanentConfiguration(
        reason: "GitHub App private key DER is truncated"
      )
    }
    return cursor ..< (cursor + length)
  }
}
