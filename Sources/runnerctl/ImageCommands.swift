import ArgumentParser
import DaemonAPI
import Foundation
import RunnerCore

struct Image: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "image",
    abstract: "Import and inspect local VM images.",
    subcommands: [
      Import.self, Pull.self, Push.self, Build.self, List.self, Inspect.self, Delete.self, Prune.self,
    ])

  @OptionGroup var options: GlobalOptions
}

extension Image {
  struct Import: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "import",
      abstract: "Import a raw disk image that already exists on this host.",
      discussion: """
        runnerd reads the file itself, so the path must be readable by the daemon. The bytes are \
        hashed and stored content-addressed; importing identical content twice is a no-op.
        """)

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Path to a raw disk image.")
    var disk: String

    @Option(name: .long, help: "linux or macos.")
    var os: String

    @Option(name: .long, help: "Local name for the image; profiles reference it by this name.")
    var name: String?

    @Option(name: .long, help: "EFI variable store or macOS auxiliary storage to import with it.")
    var nvram: String?

    @Option(
      name: .long,
      help: "Sealed metadata.json to adopt (runner version, capabilities, provenance). Defaults to a metadata.json next to the disk; an explicit path that cannot be used is an error.")
    var metadata: String?

    @Flag(
      name: .long,
      help: "Record that this disk carries no RunnerVM guest agent; such an image cannot run jobs and is only useful as a build/inspection artifact.")
    var noGuestAgent = false

    func validate() throws {
      guard ["linux", "macos"].contains(os) else {
        throw ValidationError("--os must be linux or macos")
      }
    }

    func run() async throws {
      let request = ImageImportRequest(
        path: Image.absolute(disk), nvramPath: nvram.map(Image.absolute), os: os, name: name,
        metadataPath: metadata.map(Image.absolute), guestAgent: noGuestAgent ? false : nil)
      let image = try await options.withDaemon { try await $0.imageImport(request) }
      switch options.output {
      case .json: try JSONOut.print(image)
      case .human: print(Table.fields(Image.fields(image), indent: ""))
      }
    }
  }

  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "list", abstract: "List every locally stored image.")

    @OptionGroup var options: GlobalOptions

    func run() async throws {
      let response = try await options.withDaemon { try await $0.imageList() }
      switch options.output {
      case .json: try JSONOut.print(response)
      case .human: print(Image.table(response.images))
      }
    }
  }

  struct Inspect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "inspect", abstract: "Show one image by digest or local name.")

    @OptionGroup var options: GlobalOptions

    @Argument(help: "sha256:<hex> digest or local name.")
    var ref: String

    func run() async throws {
      let image = try await options.withDaemon { try await $0.imageGet(ref: ref) }
      switch options.output {
      case .json: try JSONOut.print(image)
      case .human: print(Table.fields(Image.fields(image), indent: ""))
      }
    }
  }

  struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "delete",
      abstract: "Delete an image. Refused while any instance or pin still references it.")

    @OptionGroup var options: GlobalOptions

    @Argument(help: "sha256:<hex> digest.")
    var digest: String

    func run() async throws {
      let response = try await options.withDaemon { try await $0.imageDelete(digest: digest) }
      switch options.output {
      case .json: try JSONOut.print(response)
      case .human: print("deleted \(response.digest)")
      }
    }
  }

  struct Prune: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "prune",
      abstract: "Delete unpinned, unreferenced images past the cache retention window.",
      discussion: """
        Refuses to touch a pinned image or one a live instance still references, regardless of \
        age. With `images.cache.maxSize` configured, also evicts the least-recently-used \
        unpinned images -- even recent ones -- until the store is back under budget.
        """)

    @OptionGroup var options: GlobalOptions

    @Flag(name: .long, help: "Report what would be deleted without deleting anything.")
    var dryRun = false

    func run() async throws {
      let response = try await options.withDaemon { try await $0.imagePrune(dryRun: dryRun) }
      switch options.output {
      case .json: try JSONOut.print(response)
      case .human: print(Image.pruneSummary(response))
      }
    }
  }

  static func pruneSummary(_ response: ImagePruneResponse) -> String {
    let summary = Table.fields(
      [
        ("candidates", "\(response.candidates.count)"),
        ("deleted", "\(response.deleted.count)"),
        ("kept (pinned)", "\(response.keptPinned.count)"),
        ("reclaimed", Format.bytes(response.reclaimedBytes)),
        ("stale staging removed", "\(response.staleStagingRemoved)"),
      ], indent: "")
    guard !response.deleted.isEmpty else { return summary }
    let detail = response.deleted.map { "  deleted \(Format.shortDigest($0))" }.joined(separator: "\n")
    return summary + "\n\n" + detail
  }

  /// Kept as strings rather than importing `OCIRegistry`: runnerctl talks to the daemon over the
  /// socket and does not link the registry module.
  static let artifactFormats = ["runnervm", "tart"]

  static func absolute(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
      .path(percentEncoded: false)
  }

  static func table(_ images: [ImageInfoDTO]) -> String {
    Table.render(
      headers: ["NAME", "DIGEST", "OS", "STATE", "RUNNER", "VIRTUAL", "ON DISK", "PINS"],
      rows: images.map {
        [
          Format.optional($0.name), Format.shortDigest($0.digest), $0.os, $0.state, runner($0),
          Format.bytes($0.virtualSizeBytes), Format.bytes($0.allocatedSizeBytes), "\($0.pinCount)",
        ]
      })
  }

  /// `2.336.0 (stale)`. A healthy image prints the bare version — the annotation is there to be
  /// noticed, so it only appears when something is actually behind (spec §53).
  static func runner(_ image: ImageInfoDTO) -> String {
    guard let version = image.runnerVersion, !version.isEmpty else { return "-" }
    switch image.runnerVersionHealth {
    case .healthy: return version
    case .stale: return "\(version) (stale)"
    case .tooOld: return "\(version) (too old)"
    case .unknown: return "\(version) (unknown)"
    }
  }

  static func fields(_ image: ImageInfoDTO) -> [(String, String)] {
    [
      ("digest", image.digest),
      ("name", Format.optional(image.name)),
      ("reference", Format.optional(image.canonicalReference)),
      ("os", image.os),
      ("architecture", image.architecture),
      ("state", image.state),
      ("virtual size", Format.bytes(image.virtualSizeBytes)),
      ("on disk", Format.bytes(image.allocatedSizeBytes)),
      ("runner", runner(image)),
      ("runner health", image.runnerVersionHealth.rawValue),
      ("source", source(image)),
      ("guest agent", guestAgent(image)),
      ("pins", "\(image.pinCount)"),
      ("path", image.localPath),
      ("created", image.createdAt),
      ("pulled", Format.optional(image.pulledAt)),
    ] + provenanceFields(image.provenance)
  }

  /// `tart (imported)` is worth calling out: such an image is read-only provenance, never a thing
  /// that can run a job. A daemon that predates the field reports nothing, so say so rather than
  /// guessing `runnervm`.
  static func source(_ image: ImageInfoDTO) -> String {
    switch image.sourceFormat {
    case "tart": "tart (imported)"
    case let value?: value
    case nil: "-"
    }
  }

  static func guestAgent(_ image: ImageInfoDTO) -> String {
    switch image.guestAgent {
    case true?: "present"
    case false?: "absent"
    case nil: "-"
    }
  }

  /// Provenance is only as complete as the build that sealed it, so every row is dropped when its
  /// value is missing rather than printed as `-`; an image with no provenance adds nothing.
  static func provenanceFields(_ source: ImageProvenanceSummaryDTO?) -> [(String, String)] {
    guard let source else { return [] }
    let rows: [(String, String?)] = [
      ("built at", source.builtAt),
      ("builder commit", source.builderCommit),
      ("base image", source.baseImageSource),
      ("base sha256", source.baseImageSHA256),
      ("runner sha256", source.runnerSHA256),
      ("guest agent commit", source.guestAgentCommit),
      ("docker", source.dockerVersion),
      ("kernel", source.kernelVersion),
      ("package upgrade", source.packageUpgrade.map { $0 ? "yes" : "no" }),
      ("packages", source.packageCount.map(String.init)),
      ("disk sha256", source.diskSHA256),
    ]
    return rows.compactMap { label, value in value.map { (label, $0) } }
  }
}
