import Foundation
import RunnerCore

/// `release-manifest.json`, the machine-readable pointer every release carries
/// (`docs/design/distribution.md`, "Release artifacts and manifest"). `scripts/bootstrap.sh` reads
/// the same document with `jq`; this is the Swift half, used by `runnerctl upgrade`.
///
/// Decoding is lenient in exactly the way the rest of the wire types are: the four fields an
/// installer cannot proceed without are required, and everything else falls back to what a release
/// built before that key existed meant.
public struct ReleaseManifest: Codable, Sendable, Hashable {
  /// `0.2.0` — no leading `v`. The git tag is `v` + this.
  public var version: String
  public var architecture: String
  public var minimumMacOS: String
  /// The pkg asset's file name, e.g. `RunnerVM-macos-arm64.pkg`.
  public var package: String
  /// 64 lowercase hex characters.
  public var sha256: String
  public var signed: Bool
  public var license: String

  public init(
    version: String,
    architecture: String = "arm64",
    minimumMacOS: String = "15.0",
    package: String,
    sha256: String,
    signed: Bool = false,
    license: String = "Apache-2.0"
  ) {
    self.version = version
    self.architecture = architecture
    self.minimumMacOS = minimumMacOS
    self.package = package
    self.sha256 = sha256
    self.signed = signed
    self.license = license
  }

  private enum CodingKeys: String, CodingKey {
    case version, architecture, minimumMacOS, package, sha256, signed, license
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      version: try c.decode(String.self, forKey: .version),
      architecture: try c.decodeIfPresent(String.self, forKey: .architecture) ?? "arm64",
      minimumMacOS: try c.decodeIfPresent(String.self, forKey: .minimumMacOS) ?? "15.0",
      package: try c.decode(String.self, forKey: .package),
      sha256: try c.decode(String.self, forKey: .sha256),
      // A release published before the key existed was unsigned; that is the safe default,
      // because it makes `upgrade` warn rather than silently skip the warning.
      signed: try c.decodeIfPresent(Bool.self, forKey: .signed) ?? false,
      license: try c.decodeIfPresent(String.self, forKey: .license) ?? "Apache-2.0")
  }

  /// The one-line summary `--check` and the pre-drain confirmation both print.
  public var summary: String {
    "\(version) (\(package), \(architecture), macOS \(minimumMacOS)+, "
      + "\(signed ? "signed" : "unsigned"))"
  }

  public static func decode(_ json: String) throws -> ReleaseManifest {
    guard let data = json.data(using: .utf8) else {
      throw UpgradeError.manifestInvalid(detail: "not UTF-8")
    }
    do {
      return try JSONDecoder().decode(ReleaseManifest.self, from: data)
    } catch {
      throw UpgradeError.manifestInvalid(detail: "\(error)")
    }
  }

  /// Refuses before anything is downloaded, exactly where `bootstrap.sh`'s
  /// `verify_manifest_platform` refuses: a manifest for another architecture or a newer macOS is
  /// not something to discover after `installer -pkg` has already run.
  public func validatePlatform(
    architecture hostArchitecture: String = ReleaseManifest.hostArchitecture,
    macOSMajor: Int = ReleaseManifest.hostMacOSMajor
  ) throws {
    guard architecture == hostArchitecture else {
      throw UpgradeError.platformUnsupported(
        detail: "release \(version) is \(architecture); this host is \(hostArchitecture)")
    }
    guard let required = Int(minimumMacOS.split(separator: ".").first ?? "") else {
      throw UpgradeError.manifestInvalid(detail: "unparsable minimumMacOS '\(minimumMacOS)'")
    }
    guard macOSMajor >= required else {
      throw UpgradeError.platformUnsupported(
        detail: "release \(version) requires macOS \(minimumMacOS)+; this host is \(macOSMajor)")
    }
  }

  // MARK: - Host facts

  /// `arm64` on every machine RunnerVM supports; read rather than assumed, so a manifest/host
  /// mismatch is reported with the truth.
  public static var hostArchitecture: String {
    var size = 0
    sysctlbyname("hw.machine", nil, &size, nil, 0)
    guard size > 0 else { return "unknown" }
    var buffer = [UInt8](repeating: 0, count: size)
    sysctlbyname("hw.machine", &buffer, &size, nil, 0)
    let terminator = buffer.firstIndex(of: 0) ?? buffer.count
    return String(decoding: buffer[..<terminator], as: UTF8.self)
  }

  public static var hostMacOSMajor: Int {
    ProcessInfo.processInfo.operatingSystemVersion.majorVersion
  }
}

// MARK: - Where a release is fetched from

/// Resolves the three URLs an upgrade needs. `latest` uses GitHub's `/releases/latest/download/`
/// redirect — the same URL shape the `curl | sudo bash` one-liner uses — so "upgrade to whatever is
/// current" never has to list tags first.
public struct ReleaseSource: Sendable, Hashable {
  public static let defaultRepository = "andrejvysny/RunnerVM"
  public static let manifestName = "release-manifest.json"

  /// Always ends with `/`.
  public let baseURL: String

  public init(baseURL: String) {
    self.baseURL = baseURL.hasSuffix("/") ? baseURL : baseURL + "/"
  }

  public static func latest(repository: String = defaultRepository) -> ReleaseSource {
    ReleaseSource(baseURL: "https://github.com/\(repository)/releases/latest/download")
  }

  /// `version` may be given with or without the `v`; the tag always carries it.
  public static func tagged(
    _ version: String, repository: String = defaultRepository
  ) -> ReleaseSource {
    let tag = version.hasPrefix("v") ? version : "v\(version)"
    return ReleaseSource(baseURL: "https://github.com/\(repository)/releases/download/\(tag)")
  }

  /// `--version` when given, `RUNNERVM_PKG_URL` when set (the same operator seam `bootstrap.sh`
  /// exposes, for a mirror or a local `file://` directory), else `latest`.
  public static func resolve(
    version: String?, overrideURL: String? = nil, repository: String = defaultRepository
  ) -> ReleaseSource {
    if let version, !version.isEmpty { return .tagged(version, repository: repository) }
    if let overrideURL, !overrideURL.isEmpty { return ReleaseSource(baseURL: overrideURL) }
    return .latest(repository: repository)
  }

  public var manifestURL: String { baseURL + Self.manifestName }

  public func assetURL(_ name: String) -> String { baseURL + name }
}

// MARK: - Errors

/// Failures the upgrader raises itself. Command failures still surface as
/// `SetupError.commandFailed`: the two share `CommandRunner`, and an `installer` exit code should
/// read the same wherever it came from.
public enum UpgradeError: RunnerError {
  case manifestUnreachable(url: String, detail: String)
  case manifestInvalid(detail: String)
  case platformUnsupported(detail: String)
  case checksumMismatch(detail: String)
  case declined(step: String)
  case notRoot

  public var code: String {
    switch self {
    case .manifestUnreachable: "UPGRADE_MANIFEST_UNREACHABLE"
    case .manifestInvalid: "UPGRADE_MANIFEST_INVALID"
    case .platformUnsupported: "UPGRADE_PLATFORM_UNSUPPORTED"
    case .checksumMismatch: "UPGRADE_CHECKSUM_MISMATCH"
    case .declined: "UPGRADE_DECLINED"
    case .notRoot: "UPGRADE_NOT_ROOT"
    }
  }

  public var message: String {
    switch self {
    case let .manifestUnreachable(url, detail):
      "cannot reach \(url): \(detail)"
    case let .manifestInvalid(detail):
      "release-manifest.json is not usable: \(detail)"
    case let .platformUnsupported(detail):
      "\(detail); nothing was installed"
    case let .checksumMismatch(detail):
      "\(detail); nothing was installed"
    case let .declined(step):
      "aborted at \(step); nothing was changed"
    case .notRoot:
      "upgrade installs a pkg and reloads the launchd job, so it needs root: "
        + "re-run as `sudo runnerctl upgrade`"
    }
  }

  public var retryable: Bool {
    switch self {
    case .manifestUnreachable: true
    default: false
    }
  }
}
