import Foundation
@testable import GitHubControl
import RunnerCore
import Security
import Testing

struct GitHubAppAuthTests {
  /// A throwaway 2048-bit RSA key. `SecKeyCreateRandomKey` without `kSecAttrIsPermanent` never
  /// touches the keychain, so this cannot prompt.
  static func makeKey() throws -> (pkcs1: Data, publicKey: SecKey) {
    var error: Unmanaged<CFError>?
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeySizeInBits as String: 2048,
    ]
    guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
      throw GitHubControlError.permanentConfiguration(reason: "cannot generate a test RSA key")
    }
    guard let der = SecKeyCopyExternalRepresentation(key, &error) as Data?,
          let publicKey = SecKeyCopyPublicKey(key)
    else {
      throw GitHubControlError.permanentConfiguration(reason: "cannot export the test RSA key")
    }
    return (der, publicKey)
  }

  static func pem(_ der: Data, label: String) -> String {
    let body = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
    return "-----BEGIN \(label)-----\n\(body)\n-----END \(label)-----\n"
  }

  /// PrivateKeyInfo ::= SEQUENCE { INTEGER 0, AlgorithmIdentifier(rsaEncryption), OCTET STRING }
  static func pkcs8(wrapping pkcs1: Data) -> Data {
    let algorithm: [UInt8] = [
      0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00,
    ]
    var inner = Data([0x02, 0x01, 0x00])
    inner.append(contentsOf: algorithm)
    inner.append(der(tag: 0x04, value: pkcs1))
    return der(tag: 0x30, value: inner)
  }

  private static func der(tag: UInt8, value: Data) -> Data {
    var out = Data([tag])
    if value.count < 0x80 {
      out.append(UInt8(value.count))
    } else {
      var length: [UInt8] = []
      var remaining = value.count
      while remaining > 0 {
        length.insert(UInt8(remaining & 0xFF), at: 0)
        remaining >>= 8
      }
      out.append(UInt8(0x80 | length.count))
      out.append(contentsOf: length)
    }
    out.append(value)
    return out
  }

  private func claims(_ token: String, part: Int) throws -> [String: Any] {
    let segments = token.split(separator: ".")
    let data = try #require(Base64URL.decode(String(segments[part])))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  // MARK: - JWT (spec §12)

  @Test func signsAnRS256JWTWithTheExpectedClaims() throws {
    let key = try Self.makeKey()
    let jwt = try GitHubAppJWT(appID: "123456", privateKeyPEM: Self.pem(key.pkcs1, label: "RSA PRIVATE KEY"))
    let token = try jwt.token(now: Fixture.now)

    let segments = token.split(separator: ".")
    #expect(segments.count == 3)

    let header = try claims(token, part: 0)
    #expect(header["alg"] as? String == "RS256")
    #expect(header["typ"] as? String == "JWT")

    let payload = try claims(token, part: 1)
    let epoch = Int(Fixture.now.timeIntervalSince1970)
    #expect(payload["iss"] as? String == "123456")
    // `iat` is backdated for clock skew and the whole window stays inside GitHub's 10 minutes.
    #expect(payload["iat"] as? Int == epoch - 60)
    #expect(payload["exp"] as? Int == epoch + 480)
    #expect((payload["exp"] as? Int ?? 0) - (payload["iat"] as? Int ?? 0) <= 600)
  }

  @Test func theSignatureVerifiesAgainstThePublicKey() throws {
    let key = try Self.makeKey()
    let jwt = try GitHubAppJWT(appID: "1", privateKeyPEM: Self.pem(key.pkcs1, label: "RSA PRIVATE KEY"))
    let token = try jwt.token(now: Fixture.now)
    let segments = token.split(separator: ".")
    let signingInput = Data("\(segments[0]).\(segments[1])".utf8)
    let signature = try #require(Base64URL.decode(String(segments[2])))

    var error: Unmanaged<CFError>?
    let verified = SecKeyVerifySignature(
      key.publicKey, .rsaSignatureMessagePKCS1v15SHA256, signingInput as CFData,
      signature as CFData, &error
    )
    #expect(verified)
  }

  @Test func acceptsAPKCS8PrivateKey() throws {
    let key = try Self.makeKey()
    let pem = Self.pem(Self.pkcs8(wrapping: key.pkcs1), label: "PRIVATE KEY")
    let jwt = try GitHubAppJWT(appID: "1", privateKeyPEM: pem)
    try #expect(try jwt.token(now: Fixture.now).split(separator: ".").count == 3)
  }

  @Test func rejectsSomethingThatIsNotAPrivateKey() throws {
    #expect(throws: GitHubControlError.self) {
      try GitHubAppJWT(appID: "1", privateKeyPEM: "not a pem at all")
    }
    #expect(throws: GitHubControlError.self) {
      try GitHubAppJWT(
        appID: "1", privateKeyPEM: "-----BEGIN CERTIFICATE-----\nQUJD\n-----END CERTIFICATE-----"
      )
    }
    #expect(throws: GitHubControlError.self) {
      try GitHubAppJWT(appID: "", privateKeyPEM: Self.pem(Self.makeKey().pkcs1, label: "RSA PRIVATE KEY"))
    }
  }

  // MARK: - Installation token

  @Test func mintsAndCachesAnInstallationToken() async throws {
    let server = FakeGitHubServer()
    defer { server.shutdown() }
    let path = "/app/installations/42/access_tokens"
    server.stub(
      .post, path,
      .json("{\"token\":\"ghs_installationtoken\",\"expires_at\":\"2023-11-14T23:13:20Z\"}", status: 201)
    )

    let key = try Self.makeKey()
    let provider = try GitHubAppCredentialProvider(
      appID: "123456", installationID: 42,
      privateKeyPEM: Self.pem(key.pkcs1, label: "RSA PRIVATE KEY"),
      baseURL: server.baseURL, session: server.makeSession(), now: { Fixture.now }
    )

    let credential = try await provider.credential()
    #expect(credential.token == "ghs_installationtoken")
    #expect(credential.kind == .installation)
    #expect(credential.expiresAt == Date(timeIntervalSince1970: 1_700_003_600))

    // The app JWT, not the installation token, authenticates this exchange.
    let recorded = try #require(server.requests(.post, path).first)
    #expect(recorded.header("Authorization")?.hasPrefix("Bearer eyJ") == true)

    _ = try await provider.credential()
    #expect(server.requests(.post, path).count == 1)

    await provider.invalidate()
    _ = try await provider.credential()
    #expect(server.requests(.post, path).count == 2)
  }

  @Test func expiredCachedTokenIsRefreshed() async throws {
    let server = FakeGitHubServer()
    defer { server.shutdown() }
    let path = "/app/installations/7/access_tokens"
    server.stub(
      .post, path,
      .json("{\"token\":\"first\",\"expires_at\":\"2023-11-14T22:13:30Z\"}", status: 201),
      .json("{\"token\":\"second\",\"expires_at\":\"2023-11-14T23:13:20Z\"}", status: 201)
    )

    let key = try Self.makeKey()
    let provider = try GitHubAppCredentialProvider(
      appID: "1", installationID: 7, privateKeyPEM: Self.pem(key.pkcs1, label: "RSA PRIVATE KEY"),
      baseURL: server.baseURL, session: server.makeSession(), now: { Fixture.now }
    )

    // Expires 10 s out, inside the 60 s refresh margin, so it is never reused.
    try #expect(try await provider.credential().token == "first")
    try #expect(try await provider.credential().token == "second")
  }
}
