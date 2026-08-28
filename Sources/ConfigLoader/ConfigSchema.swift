import Yams

/// Per-path allow-list used to reject unrecognized YAML keys. Swift's synthesized `Decodable`
/// silently ignores keys it doesn't know about, so a typo'd field (`hots:` for `host:`) would
/// otherwise decode successfully and just vanish; this walk runs over the raw `Yams.Node` tree,
/// independent of `ConfigDTO`, and catches that before decoding starts.
enum ConfigSchema {
  // swiftformat:disable:next redundantSendable — needed: `root`/etc. are static lets of this type.
  indirect enum Shape: Sendable {
    case scalar
    case object([String: Shape])
    case list(Shape)
  }

  private static let resources: Shape = .object(["cpu": .scalar, "memory": .scalar, "disk": .scalar])

  private static let timeouts: Shape = .object([
    "vmBoot": .scalar, "agentReady": .scalar, "runnerOnline": .scalar, "gracefulShutdown": .scalar,
    "imagePull": .scalar, "clone": .scalar, "jitGeneration": .scalar, "jobMaxRuntime": .scalar,
    "cleanup": .scalar,
  ])

  private static let profile: Shape = .object([
    "name": .scalar, "scope": .scalar, "image": .scalar, "os": .scalar, "lifecycle": .scalar,
    "resources": resources,
    "warmPool": .object(["minIdle": .scalar, "maxIdle": .scalar, "idleTTL": .scalar]),
    "limits": .object(["maxInstances": .scalar]),
    "ssh": .object(["enabled": .scalar]),
    "reuse": .object([
      "maxJobs": .scalar, "maxAge": .scalar, "recycleOnFailure": .scalar, "maxRestarts": .scalar,
      "acknowledgeSharedHost": .scalar,
    ]),
    "timeouts": timeouts,
    "allowHostedLabelShadowing": .scalar,
  ])

  static let root: Shape = .object([
    "version": .scalar,
    "host": .object([
      "reserve": .object(["cpu": .scalar, "memory": .scalar, "disk": .scalar]),
      "overcommit": .object(["cpu": .scalar, "memory": .scalar]),
      "maxVMs": .scalar,
      "limits": .object(["concurrentImagePulls": .scalar, "concurrentVMStarts": .scalar]),
    ]),
    "github": .object([
      "auth": .object(["provider": .scalar, "source": .scalar]),
      "scopes": .list(.object([
        "name": .scalar, "type": .scalar, "owner": .scalar,
        "repository": .scalar, "runnerGroup": .scalar,
      ])),
      "demand": .scalar,
    ]),
    "profiles": .list(profile),
    "security": .object(["allowPublicRepositories": .scalar]),
    "metrics": .object(["prometheus": .object(["enabled": .scalar, "listen": .scalar])]),
    "diagnostics": .object(["failedInstanceRetention": .scalar]),
    "images": .object([
      "cache": .object(["maxSize": .scalar, "keepRecentlyUsed": .scalar]),
      "limits": .object(["maxVirtualDiskSize": .scalar, "maxLayers": .scalar]),
    ]),
    "imageUpdates": .object(["recycleReusable": .scalar, "denyTooOldRunner": .scalar]),
    "build": .object([
      "cpu": .scalar, "memory": .scalar, "disk": .scalar, "timeout": .scalar,
      "stepTimeout": .scalar, "maxConcurrent": .scalar, "cacheDir": .scalar,
      "guestAgentPath": .scalar, "recipeFileName": .scalar, "maxContextSize": .scalar,
      "maxLogSize": .scalar, "maxSteps": .scalar,
      "cache": .object([
        "maxBytes": .scalar, "minimumHostFreeBytes": .scalar, "maxEntries": .scalar,
      ]),
    ]),
    "logging": .object([
      "file": .object(["enabled": .scalar, "maxSize": .scalar, "maxFiles": .scalar]),
      "retention": .object(["instanceLogs": .scalar]),
      "collectRunnerDiagnostics": .scalar,
      "diagnosticsTimeout": .scalar,
    ]),
  ])

  /// Path of the first key not present in the allow-list, in document order, or `nil` when clean.
  /// Type mismatches (a mapping where a scalar was expected, etc.) are left to `ConfigDTO`
  /// decoding, which reports them with a proper `DecodingError`-derived reason.
  static func firstUnknownKey(in node: Node, shape: Shape = root, path: String = "") -> String? {
    switch shape {
    case .scalar:
      return nil
    case let .object(fields):
      return firstUnknownKey(inObject: node, fields: fields, path: path)
    case let .list(elementShape):
      guard let sequence = node.sequence else { return nil }
      for (index, element) in sequence.enumerated() {
        if let found = firstUnknownKey(in: element, shape: elementShape, path: "\(path)[\(index)]") {
          return found
        }
      }
      return nil
    }
  }

  private static func firstUnknownKey(inObject node: Node, fields: [String: Shape], path: String) -> String? {
    guard let mapping = node.mapping else { return nil }
    for (keyNode, valueNode) in mapping {
      guard let key = keyNode.string else { continue }
      let childPath = path.isEmpty ? key : "\(path).\(key)"
      guard let childShape = fields[key] else { return childPath }
      if let found = firstUnknownKey(in: valueNode, shape: childShape, path: childPath) {
        return found
      }
    }
    return nil
  }
}
