import Foundation

/// Build provenance for a sealed image (spec §24): exactly which inputs went in, so a given
/// `metadata.json` is enough to rebuild the same image without consulting the build host.
///
/// Every field is optional. An image built before provenance existed simply has none, and a build
/// that could not resolve one input still records the ones it could -- decoding must never fail
/// because a field is missing, which is what keeps `schemaVersion` at 1.
extension ImageMetadata {
  public struct Provenance: Codable, Sendable, Equatable, Hashable {
    /// The stock cloud image the build started from.
    public struct BaseImage: Codable, Sendable, Equatable, Hashable {
      /// Where the bytes came from: a URL when downloaded, otherwise the local path.
      public var source: String?
      /// `sha256:<hex>` of the base disk as it was fed to the builder.
      public var sha256: String?

      public init(source: String? = nil, sha256: String? = nil) {
        self.source = source
        self.sha256 = sha256
      }
    }

    /// The `actions/runner` release installed into `/opt/actions-runner`.
    public struct ActionsRunner: Codable, Sendable, Equatable, Hashable {
      /// Resolved release version, never the mutable string "latest".
      public var version: String?
      /// `sha256:<hex>` of the release tarball, verified inside the guest before extraction.
      public var sha256: String?
      public var url: String?
      /// How `sha256` was established: `"operator"` (an explicit `--runner-sha256` pin),
      /// `"github-release-asset"` (GitHub's own release asset digest metadata -- the default
      /// trust anchor), or `"download"` (only the host's own download hash, recorded when
      /// `--allow-unverified-runner` was needed because GitHub had no digest for the asset).
      public var digestSource: String?

      public init(
        version: String? = nil, sha256: String? = nil, url: String? = nil,
        digestSource: String? = nil
      ) {
        self.version = version
        self.sha256 = sha256
        self.url = url
        self.digestSource = digestSource
      }
    }

    /// The RunnerVM guest agent binary baked into the image.
    public struct GuestAgent: Codable, Sendable, Equatable, Hashable {
      /// Commit of this repository the agent was built from.
      public var gitCommit: String?
      /// `sha256:<hex>` of the installed binary.
      public var sha256: String?
      /// What `runnervm-guest-agent -version` printed inside the built guest.
      public var reportedVersion: String?

      public init(gitCommit: String? = nil, sha256: String? = nil, reportedVersion: String? = nil) {
        self.gitCommit = gitCommit
        self.sha256 = sha256
        self.reportedVersion = reportedVersion
      }
    }

    /// The host side of the build: what ran it, and from which tree.
    public struct Builder: Codable, Sendable, Equatable, Hashable {
      public var gitCommit: String?
      /// Repository-relative path of the build script.
      public var script: String?
      public var hostOSVersion: String?
      public var builtAt: String?

      public init(
        gitCommit: String? = nil, script: String? = nil, hostOSVersion: String? = nil,
        builtAt: String? = nil
      ) {
        self.gitCommit = gitCommit
        self.script = script
        self.hostOSVersion = hostOSVersion
        self.builtAt = builtAt
      }
    }

    /// The Docker Engine apt repository the image was provisioned from.
    public struct Docker: Codable, Sendable, Equatable, Hashable {
      /// The full `deb` line's URL plus suite, e.g. `https://download.docker.com/linux/ubuntu noble stable`.
      public var repository: String?
      /// Installed `docker-ce` package version, as `dpkg-query` reports it.
      public var version: String?

      public init(repository: String? = nil, version: String? = nil) {
        self.repository = repository
        self.version = version
      }
    }

    public var baseImage: BaseImage?
    public var actionsRunner: ActionsRunner?
    public var guestAgent: GuestAgent?
    public var builder: Builder?
    public var docker: Docker?
    /// Whether the build ran a full `apt upgrade`; `false` makes the package list reproducible
    /// against a pinned archive snapshot.
    public var packageUpgrade: Bool?
    /// `dpkg-query -W -f='${Package}=${Version}'` from the sealed guest. Long by design -- this is
    /// the manifest a rebuild is diffed against.
    public var packages: [String]?
    /// Guest kernel `uname -r` at seal time.
    public var kernelVersion: String?
    /// `sha256:<hex>` of the sealed `disk.img`.
    ///
    /// This is the *content identity* the local image digest is derived from: `ImageStore` hashes
    /// the disk into the `disk` layer digest, and `LocalImageManifest.computeDigest` folds that
    /// layer digest together with the `metadata.json` digest to produce `sha256:<image digest>`.
    /// Two hosts that seal byte-identical disks and byte-identical metadata therefore get the same
    /// image digest.
    public var diskSHA256: String?
    /// True when this build could not recover the guest's `RVM-MANIFEST` block (or the block
    /// decoded with no `packages`) and sealed anyway only because `--allow-partial-provenance`
    /// was passed. Absent or `false` means the build failed closed instead of a silent gap.
    public var partial: Bool?
    /// Why `partial` is true, e.g. "no usable RVM-MANIFEST block in serial.log".
    public var partialReason: String?

    public init(
      baseImage: BaseImage? = nil, actionsRunner: ActionsRunner? = nil,
      guestAgent: GuestAgent? = nil, builder: Builder? = nil, docker: Docker? = nil,
      packageUpgrade: Bool? = nil, packages: [String]? = nil, kernelVersion: String? = nil,
      diskSHA256: String? = nil, partial: Bool? = nil, partialReason: String? = nil
    ) {
      self.baseImage = baseImage
      self.actionsRunner = actionsRunner
      self.guestAgent = guestAgent
      self.builder = builder
      self.docker = docker
      self.packageUpgrade = packageUpgrade
      self.packages = packages
      self.kernelVersion = kernelVersion
      self.diskSHA256 = diskSHA256
      self.partial = partial
      self.partialReason = partialReason
    }
  }
}
