import Foundation

// MARK: - image.build / build.*

/// Starts an in-daemon image build from a `Runnerfile`-style recipe (Phase 5 image builder).
/// Every field but `recipePath` is optional on decode, mirroring `ImageImportRequest`.
public struct ImageBuildRequest: Codable, Sendable, Hashable {
  /// Path to the recipe file on this host; runnerd reads it, so it must be readable by the daemon.
  public var recipePath: String
  /// Build context directory; `nil` uses the recipe's own directory.
  public var contextPath: String?
  /// Local name to alias the resulting image under once the build succeeds.
  public var name: String?
  /// `--build-arg`-style substitutions available to the recipe.
  public var args: [String: String]
  /// Registry-qualified reference to push the finished image to, if any.
  public var push: String?
  public var cpus: Int?
  public var memoryBytes: UInt64?
  public var diskBytes: UInt64?
  public var timeoutMs: Int64?
  /// Skips reusing a previous build's cached base/layers.
  public var noCache: Bool

  public init(
    recipePath: String, contextPath: String? = nil, name: String? = nil,
    args: [String: String] = [:], push: String? = nil, cpus: Int? = nil, memoryBytes: UInt64? = nil,
    diskBytes: UInt64? = nil, timeoutMs: Int64? = nil, noCache: Bool = false
  ) {
    self.recipePath = recipePath
    self.contextPath = contextPath
    self.name = name
    self.args = args
    self.push = push
    self.cpus = cpus
    self.memoryBytes = memoryBytes
    self.diskBytes = diskBytes
    self.timeoutMs = timeoutMs
    self.noCache = noCache
  }
}

extension ImageBuildRequest {
  private enum CodingKeys: String, CodingKey {
    case recipePath, contextPath, name, args, push, cpus, memoryBytes, diskBytes, timeoutMs
    case noCache
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      recipePath: try c.decode(String.self, forKey: .recipePath),
      contextPath: try c.decodeIfPresent(String.self, forKey: .contextPath),
      name: try c.decodeIfPresent(String.self, forKey: .name),
      args: try c.decodeIfPresent([String: String].self, forKey: .args) ?? [:],
      push: try c.decodeIfPresent(String.self, forKey: .push),
      cpus: try c.decodeIfPresent(Int.self, forKey: .cpus),
      memoryBytes: try c.decodeIfPresent(UInt64.self, forKey: .memoryBytes),
      diskBytes: try c.decodeIfPresent(UInt64.self, forKey: .diskBytes),
      timeoutMs: try c.decodeIfPresent(Int64.self, forKey: .timeoutMs),
      noCache: try c.decodeIfPresent(Bool.self, forKey: .noCache) ?? false
    )
  }
}

public struct ImageBuildResponse: Codable, Sendable, Hashable {
  public var buildId: String
  /// `nil` when nothing needed starting -- should not normally happen for a fresh build.
  public var operationId: String?
  public var name: String?
  /// The resolved `FROM` reference the build starts from.
  public var from: String
  public var totalSteps: Int

  public init(buildId: String, operationId: String?, name: String?, from: String, totalSteps: Int) {
    self.buildId = buildId
    self.operationId = operationId
    self.name = name
    self.from = from
    self.totalSteps = totalSteps
  }
}

/// `image_builds` columns, camelCased -- follows `ImageInfoDTO`'s pattern of a flat, readable
/// mirror of the persisted row rather than the raw JSON blobs it stores internally.
public struct BuildInfoDTO: Codable, Sendable, Hashable {
  public var buildId: String
  public var name: String?
  public var state: String
  public var operationId: String?
  public var pushReference: String?
  public var pushOperationId: String?
  public var recipePath: String
  public var recipeSHA256: String
  public var contextPath: String
  public var contextSHA256: String?
  public var fromKind: String
  public var fromReference: String
  public var baseDigest: String?
  public var baseSHA256: String?
  public var cpuCount: Int
  public var memoryBytes: UInt64
  public var diskBytes: UInt64
  public var diskReservationBytes: UInt64
  public var timeoutMs: Int64
  public var buildPath: String
  public var logPath: String
  public var workerPid: Int32?
  public var totalSteps: Int
  public var currentStep: Int
  public var currentInstruction: String?
  public var imageDigest: String?
  public var failureCode: String?
  public var failureMessage: String?
  public var createdAt: String
  public var startedAt: String?
  public var finishedAt: String?
  /// RFC-3339 instant restart recovery first found this build's builder worker alive-or-
  /// unverifiable; `nil` when the build is not pending. While set, the build still holds its host
  /// capacity, its base-image pin and its directory. Absent on daemons predating schema v3.
  public var recoverySince: String?
  /// The resolved `ARG` values the build ran with. Not secrets: the same map is in the image's
  /// provenance and in any pushed OCI config, so showing it here adds no exposure. Absent from
  /// daemons that predate the field.
  public var args: [String: String]?
  public var updatedAt: String

  public init(
    buildId: String, name: String? = nil, state: String, operationId: String? = nil,
    pushReference: String? = nil, pushOperationId: String? = nil, recipePath: String,
    recipeSHA256: String, contextPath: String, contextSHA256: String? = nil, fromKind: String,
    fromReference: String, baseDigest: String? = nil, baseSHA256: String? = nil, cpuCount: Int,
    memoryBytes: UInt64, diskBytes: UInt64, diskReservationBytes: UInt64, timeoutMs: Int64,
    buildPath: String, logPath: String, workerPid: Int32? = nil, totalSteps: Int = 0,
    currentStep: Int = 0, currentInstruction: String? = nil, imageDigest: String? = nil,
    failureCode: String? = nil, failureMessage: String? = nil, createdAt: String,
    startedAt: String? = nil, finishedAt: String? = nil, recoverySince: String? = nil,
    args: [String: String]? = nil, updatedAt: String
  ) {
    self.buildId = buildId
    self.name = name
    self.state = state
    self.operationId = operationId
    self.pushReference = pushReference
    self.pushOperationId = pushOperationId
    self.recipePath = recipePath
    self.recipeSHA256 = recipeSHA256
    self.contextPath = contextPath
    self.contextSHA256 = contextSHA256
    self.fromKind = fromKind
    self.fromReference = fromReference
    self.baseDigest = baseDigest
    self.baseSHA256 = baseSHA256
    self.cpuCount = cpuCount
    self.memoryBytes = memoryBytes
    self.diskBytes = diskBytes
    self.diskReservationBytes = diskReservationBytes
    self.timeoutMs = timeoutMs
    self.buildPath = buildPath
    self.logPath = logPath
    self.workerPid = workerPid
    self.totalSteps = totalSteps
    self.currentStep = currentStep
    self.currentInstruction = currentInstruction
    self.imageDigest = imageDigest
    self.failureCode = failureCode
    self.failureMessage = failureMessage
    self.createdAt = createdAt
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.recoverySince = recoverySince
    self.args = args
    self.updatedAt = updatedAt
  }
}

public struct BuildListResponse: Codable, Sendable, Hashable {
  public var builds: [BuildInfoDTO]

  public init(builds: [BuildInfoDTO]) { self.builds = builds }
}

public struct BuildGetRequest: Codable, Sendable, Hashable {
  public var buildId: String

  public init(buildId: String) { self.buildId = buildId }
}

public struct BuildCancelRequest: Codable, Sendable, Hashable {
  public var buildId: String

  public init(buildId: String) { self.buildId = buildId }
}

public struct BuildCancelResponse: Codable, Sendable, Hashable {
  public var buildId: String
  public var state: String

  public init(buildId: String, state: String) {
    self.buildId = buildId
    self.state = state
  }
}

public struct BuildLogRequest: Codable, Sendable, Hashable {
  /// Wire-level ceiling on `maxBytes`, independent of whatever `build.maxLogBytes` allows the log
  /// file itself to grow to: one chunk must still fit comfortably inside a single RPC envelope.
  public static let maxChunkBytes: Int64 = 262_144

  public var buildId: String
  /// Byte offset into `build.log` to read from.
  public var offset: Int64
  /// `nil` uses `maxChunkBytes`.
  public var maxBytes: Int64?

  public init(buildId: String, offset: Int64 = 0, maxBytes: Int64? = nil) {
    self.buildId = buildId
    self.offset = offset
    self.maxBytes = maxBytes
  }
}

public struct BuildLogResponse: Codable, Sendable, Hashable {
  public var data: String
  /// Offset to pass as the next request's `offset` to continue reading.
  public var nextOffset: Int64
  /// `true` once the build has reached a terminal state and every byte up to `nextOffset` has been
  /// returned -- the caller can stop polling.
  public var done: Bool

  public init(data: String, nextOffset: Int64, done: Bool) {
    self.data = data
    self.nextOffset = nextOffset
    self.done = done
  }
}
