// Ported from github.com/actions/scaleset@v0.4.0 (MIT) client.go, config.go — see PROVENANCE.md.

import Foundation
import RunnerCore

/// Actions-service endpoint paths. The service is a Team Foundation descendant, which is why the
/// paths read the way they do; this is the only place they exist (spec §50).
enum ActionsEndpoint {
  static let scaleSets = "/_apis/runtime/runnerscalesets"
  static let runnerGroups = "/_apis/runtime/runnergroups"
  /// Runners are "agents" in pool 0.
  static let runners = "/_apis/distributedtask/pools/0/agents"

  static func scaleSet(_ id: Int64) -> String { "\(scaleSets)/\(id)" }
  static func sessions(_ scaleSetID: Int64) -> String { "\(scaleSet(scaleSetID))/sessions" }
  static func session(_ scaleSetID: Int64, _ sessionID: String) -> String {
    "\(sessions(scaleSetID))/\(sessionID)"
  }

  static func acquireJobs(_ scaleSetID: Int64) -> String { "\(scaleSet(scaleSetID))/acquirejobs" }
  static func jitConfig(_ scaleSetID: Int64) -> String { "\(scaleSet(scaleSetID))/generatejitconfig" }
  static func runner(_ id: Int64) -> String { "\(runners)/\(id)" }
}

/// URL, JSON and `Duration` plumbing shared by the connection and its sessions.
enum ActionsURL {
  /// Joins a path onto the tenant URL (which carries its own path prefix, e.g. `/tenant/123/`)
  /// and adds `api-version` unless the caller already supplied one.
  static func join(
    base: URL, path: String, query: [URLQueryItem], apiVersion: String?
  ) throws -> URL {
    guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
      throw GitHubControlError.permanentConfiguration(reason: "invalid Actions service URL \(base)")
    }
    var prefix = components.percentEncodedPath
    while prefix.hasSuffix("/") { prefix.removeLast() }
    let suffix = path.hasPrefix("/") ? path : "/" + path
    components.percentEncodedPath = prefix + suffix
    var items = query
    if let apiVersion, !items.contains(where: { $0.name == "api-version" }) {
      items.append(URLQueryItem(name: "api-version", value: apiVersion))
    }
    components.queryItems = items.isEmpty ? nil : items
    guard let url = components.url else {
      throw GitHubControlError.permanentConfiguration(
        reason: "could not build an Actions service URL for \(path)"
      )
    }
    return url
  }

  static func decode<T: Decodable>(_ type: T.Type, from data: Data, label: String) throws -> T {
    do {
      return try JSONDecoder().decode(T.self, from: trimmingByteOrderMark(data))
    } catch {
      // The body is never echoed: an Actions response can carry a JIT config or a queue token.
      throw GitHubControlError.invalidResponse(
        reason: "\(label): could not decode \(T.self) from the Actions service response"
      )
    }
  }

  static func encode(_ value: some Encodable, label: String) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    do {
      return try encoder.encode(value)
    } catch {
      throw GitHubControlError.permanentConfiguration(reason: "\(label): could not encode the body")
    }
  }

  /// The Actions service prefixes some responses with a UTF-8 BOM, which `JSONDecoder` rejects.
  static func trimmingByteOrderMark(_ data: Data) -> Data {
    let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
    guard data.count >= 3, Array(data.prefix(3)) == bom else { return data }
    return data.dropFirst(3)
  }

  /// `URLRequest` reads a 0 timeout as "use the 60 s default", which would silently drop a
  /// sub-second deadline.
  static func seconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return max(0.001, Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
  }
}

/// The `githubConfigUrl` the Actions service keys a tenant by: the browser URL of the org or
/// repository, never the API URL.
enum ActionsConfigURL {
  static func forScope(_ scope: GitHubScope, base: URL) -> URL {
    switch scope {
    case let .organization(owner, _):
      base.appendingPathComponent(owner)
    case let .repository(owner, repository):
      base.appendingPathComponent(owner).appendingPathComponent(repository)
    }
  }

  /// Inverse of the Go client's `gitHubAPIURL`: `api.github.com` ⇄ `github.com`, and a GHES
  /// `/api/v3` prefix drops away.
  static func base(fromAPIBaseURL api: URL) -> URL {
    guard var components = URLComponents(url: api, resolvingAgainstBaseURL: false) else { return api }
    if let host = components.host, host.lowercased().hasPrefix("api.") {
      components.host = String(host.dropFirst(4))
    }
    components.path = ""
    components.query = nil
    return components.url ?? api
  }
}

/// The Actions admin token is a JWT. Only its `exp` claim is read — the signature is the service's
/// business — so the token can be refreshed before it dies mid-flight.
enum ActionsJWT {
  static func expiry(of token: String, scope: String) throws -> Date {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count >= 2, let payload = base64URLDecode(String(parts[1])),
          let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
          let exp = object["exp"] as? NSNumber
    else {
      throw GitHubControlError.invalidResponse(
        reason: "Actions admin token for \(scope) is not a JWT carrying an exp claim"
      )
    }
    return Date(timeIntervalSince1970: exp.doubleValue)
  }

  static func base64URLDecode(_ value: String) -> Data? {
    var text = value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = text.count % 4
    if remainder > 0 { text += String(repeating: "=", count: 4 - remainder) }
    return Data(base64Encoded: text)
  }
}
