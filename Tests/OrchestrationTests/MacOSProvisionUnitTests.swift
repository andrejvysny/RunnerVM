import Darwin
import Foundation
import ImageStore
import OCIRegistry
import RunnerCore
import Testing

@testable import Orchestration

/// The pure pieces a `macosProvision` build is assembled from: `bootpd`'s lease file, the script
/// and agent lookup chains, the result JSON, and the SSH probe.
@Suite struct DHCPLeaseResolverTests {
  /// Exactly what `/var/db/dhcpd_leases` looks like on a Mac that has served a few guests: a
  /// leading `1,` hardware type, and octets with no zero padding.
  static let fixture = """
    {
    \tname=ubuntu
    \tip_address=192.168.64.4
    \thw_address=1,2:a:1b:c:5:6
    \tidentifier=1,2:a:1b:c:5:6
    \tlease=0x68b1c2d3
    }
    {
    \tname=macos
    \tip_address=192.168.64.7
    \thw_address=1,ee:ff:0:11:22:33
    \tidentifier=1,ee:ff:0:11:22:33
    \tlease=0x68b1c2ff
    }
    """

  @Test func everyCompleteStanzaIsParsedInFileOrder() {
    let leases = DHCPLeaseResolver.parse(Self.fixture)

    #expect(leases.count == 2)
    #expect(leases[0].ipAddress == "192.168.64.4")
    #expect(leases[0].hardwareAddress == "2:a:1b:c:5:6")
    #expect(leases[0].name == "ubuntu")
    #expect(leases[1].ipAddress == "192.168.64.7")
  }

  /// The bite: `spec.json` writes `02:0a:1b:0c:05:06`, `bootpd` writes `2:a:1b:c:5:6`.
  @Test(arguments: [
    "02:0a:1b:0c:05:06", "2:A:1B:C:5:6", "1,02:0a:1b:0c:05:06", "02:0A:1B:0C:05:06",
  ])
  func aPaddedOrUnpaddedMACFindsTheSameLease(macAddress: String) {
    #expect(DHCPLeaseResolver.address(in: Self.fixture, macAddress: macAddress) == "192.168.64.4")
  }

  @Test func aZeroOctetSurvivesNormalization() {
    #expect(DHCPLeaseResolver.normalize("ee:ff:00:11:22:33") == "ee:ff:0:11:22:33")
    #expect(DHCPLeaseResolver.address(in: Self.fixture, macAddress: "ee:ff:00:11:22:33")
      == "192.168.64.7")
  }

  @Test func aMACWithNoLeaseFindsNothing() {
    #expect(DHCPLeaseResolver.address(in: Self.fixture, macAddress: "02:99:99:99:99:99") == nil)
    #expect(DHCPLeaseResolver.address(in: "", macAddress: "02:0a:1b:0c:05:06") == nil)
  }

  /// A `bootpd` that re-leased the same client a different address appends a stanza rather than
  /// rewriting the old one, so the *last* match is the live lease.
  @Test func theMostRecentStanzaWins() {
    let text = Self.fixture + """

      {
      \tname=ubuntu
      \tip_address=192.168.64.9
      \thw_address=1,2:a:1b:c:5:6
      }
      """

    #expect(DHCPLeaseResolver.address(in: text, macAddress: "02:0a:1b:0c:05:06") == "192.168.64.9")
  }

  /// One malformed stanza must not hide the lease being looked for: this file is written by a
  /// system daemon nobody here controls.
  @Test func aStanzaMissingAFieldIsSkippedRatherThanFailingTheParse() {
    let text = """
      {
      \tname=broken
      \tlease=0x1
      }
      """ + "\n" + Self.fixture

    #expect(DHCPLeaseResolver.parse(text).count == 2)
    #expect(DHCPLeaseResolver.address(in: text, macAddress: "02:0a:1b:0c:05:06") == "192.168.64.4")
  }

  @Test func anUnknownKeyIsIgnored() {
    let text = """
      {
      \tname=future
      \tip_address=192.168.64.20
      \thw_address=1,2:2:2:2:2:2
      \tsomething_new=whatever
      }
      """

    #expect(DHCPLeaseResolver.address(in: text, macAddress: "02:02:02:02:02:02") == "192.168.64.20")
  }

  // MARK: - Waiting

  @Test func theWaitReturnsAsSoonAsTheLeaseAppears() async throws {
    let box = LeaseBox()
    let address = try await DHCPLeaseResolver.wait(
      macAddress: "02:0a:1b:0c:05:06", timeout: .seconds(10), interval: .milliseconds(1),
      reader: { box.take() }, sleep: { _ in })

    #expect(address == "192.168.64.4")
    #expect(box.reads >= 3)
  }

  @Test func theWaitGivesUpWithTheMACInTheError() async throws {
    let error = await #expect(throws: ImageBuildError.self) {
      _ = try await DHCPLeaseResolver.wait(
        macAddress: "02:0a:1b:0c:05:06", timeout: .seconds(0), interval: .milliseconds(1),
        reader: { nil }, sleep: { _ in })
    }

    #expect(error?.code == "BUILD_MACOS_LEASE_NOT_FOUND")
    #expect(error?.message.contains("02:0a:1b:0c:05:06") == true)
  }

  /// The file does not exist at all until the host has served its first lease.
  final class LeaseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var reads: Int { lock.withLock { count } }

    func take() -> String? {
      lock.withLock {
        count += 1
        return count < 3 ? nil : DHCPLeaseResolverTests.fixture
      }
    }
  }
}

@Suite struct MacOSProvisionAssetTests {
  private func tree() throws -> (root: URL, paths: RunnerPaths) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "rvm-assets-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (
      root,
      RunnerPaths(
        rootDir: root.appending(path: "state", directoryHint: .isDirectory),
        runtimeDir: root.appending(path: "run", directoryHint: .isDirectory))
    )
  }

  private func write(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: url)
  }

  @Test func theConfiguredOverrideWinsOverEverythingElse() throws {
    let (root, paths) = try tree()
    defer { try? FileManager.default.removeItem(at: root) }
    let override = root.appending(path: "custom.sh")
    try write(override)
    // Also present at the packaged location, so "wins" is actually being exercised.
    try write(paths.rootDir.appending(path: "scripts/\(MacOSProvisionAssets.scriptName)"))
    var config = ImageBuildConfig()
    config.macosProvisionScript = override.path(percentEncoded: false)

    let resolved = try MacOSProvisionAssets.resolveScript(
      config: config, paths: paths, environment: [:], executable: nil)

    #expect(resolved == override)
  }

  @Test func theEnvironmentSeamComesNextAndTheStateTreeAfterIt() throws {
    let (root, paths) = try tree()
    defer { try? FileManager.default.removeItem(at: root) }
    let fromEnvironment = root.appending(path: "env.sh")
    try write(fromEnvironment)
    let packaged = paths.rootDir.appending(path: "scripts/\(MacOSProvisionAssets.scriptName)")
    try write(packaged)

    #expect(
      try MacOSProvisionAssets.resolveScript(
        config: ImageBuildConfig(), paths: paths,
        environment: ["RUNNERVM_MACOS_PROVISION_SCRIPT": fromEnvironment.path(percentEncoded: false)],
        executable: nil) == fromEnvironment)
    #expect(
      try MacOSProvisionAssets.resolveScript(
        config: ImageBuildConfig(), paths: paths, environment: [:], executable: nil) == packaged)
  }

  /// `<executable>/../share/runnervm/…`, which is where `build-package.sh` stages both files.
  @Test func thePackagedLocationBesideTheExecutableIsFound() throws {
    let (root, paths) = try tree()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appending(path: "usr/local/bin/runnerd")
    try write(executable)
    let script = root.appending(
      path: "usr/local/share/runnervm/scripts/\(MacOSProvisionAssets.scriptName)")
    try write(script)
    let agent = root.appending(
      path: "usr/local/share/runnervm/\(MacOSProvisionAssets.darwinAgentRelativePath)")
    try write(agent)

    #expect(
      try MacOSProvisionAssets.resolveScript(
        config: ImageBuildConfig(), paths: paths, environment: [:], executable: executable)
        .standardizedFileURL == script.standardizedFileURL)
    #expect(
      try MacOSProvisionAssets.resolveDarwinAgent(
        config: ImageBuildConfig(), paths: paths, environment: [:], executable: executable)
        .standardizedFileURL == agent.standardizedFileURL)
  }

  /// A `swift run runnerd` tree: the binary sits under `.build/debug/`, and the repository root is
  /// found by walking up to `Package.swift`.
  @Test func aDevelopmentCheckoutIsFoundByWalkingUpToPackageSwift() throws {
    let (root, paths) = try tree()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = root.appending(path: "checkout", directoryHint: .isDirectory)
    try write(repository.appending(path: "Package.swift"))
    let executable = repository.appending(path: ".build/debug/runnerd")
    try write(executable)
    let script = repository.appending(path: "scripts/\(MacOSProvisionAssets.scriptName)")
    try write(script)
    let agent = repository.appending(path: "GuestAgent/bin/darwin-arm64/runnervm-guest-agent")
    try write(agent)

    #expect(MacOSProvisionAssets.repositoryRoot(from: executable)?.standardizedFileURL
      == repository.standardizedFileURL)
    #expect(
      try MacOSProvisionAssets.resolveScript(
        config: ImageBuildConfig(), paths: paths, environment: [:], executable: executable)
        .standardizedFileURL == script.standardizedFileURL)
    #expect(
      try MacOSProvisionAssets.resolveDarwinAgent(
        config: ImageBuildConfig(), paths: paths, environment: [:], executable: executable)
        .standardizedFileURL == agent.standardizedFileURL)
  }

  @Test func nothingAnywhereNamesEveryPathThatWasTried() throws {
    let (root, paths) = try tree()
    defer { try? FileManager.default.removeItem(at: root) }

    let error = #expect(throws: ImageBuildError.self) {
      _ = try MacOSProvisionAssets.resolveScript(
        config: ImageBuildConfig(), paths: paths, environment: [:], executable: nil)
    }

    #expect(error?.code == "BUILD_MACOS_SCRIPT_MISSING")
    #expect(error?.message.contains(MacOSProvisionAssets.scriptName) == true)
  }
}

@Suite struct MacOSProvisionResultTests {
  private func decode(_ json: String) throws -> MacOSProvisionResult {
    try JSONDecoder().decode(MacOSProvisionResult.self, from: Data(json.utf8))
  }

  @Test func theSuccessShapeDecodes() throws {
    let result = try decode(
      """
      {"ok":true,"runnerVersion":"2.330.0","guestAgentVersion":"0.3.0","hardenProof":true,
       "gracefulShutdown":true,"ssh":false}
      """)

    #expect(result.ok)
    #expect(result.runnerVersion == "2.330.0")
    #expect(result.guestAgentVersion == "0.3.0")
    try result.requireSealable(debugSSH: false)
  }

  @Test func theFailureShapeDecodesAndCarriesItsReason() throws {
    let result = try decode(#"{"ok":false,"error":"ssh never came up","ssh":true}"#)

    let error = #expect(throws: ImageBuildError.self) {
      try result.requireSealable(debugSSH: false)
    }
    #expect(error?.message.contains("ssh never came up") == true)
  }

  /// Lenient by design: a field a future script adds, or one it omits, must not make a result the
  /// daemon cannot read at all.
  @Test func missingFieldsDecodeToTheirSafeDefaults() throws {
    let result = try decode(#"{"ok":true,"unknownKey":42}"#)

    #expect(result.ok)
    #expect(!result.hardenProof)
    #expect(!result.gracefulShutdown)
    #expect(!result.ssh)
    #expect(throws: ImageBuildError.self) { try result.requireSealable(debugSSH: false) }
  }

  /// `--debug-ssh` is the only way a guest with SSH still open may be sealed, and the managed
  /// launcher never sets it.
  @Test func debugSSHSkipsEveryHardeningGate() throws {
    let result = MacOSProvisionResult(
      ok: true, hardenProof: false, gracefulShutdown: false, ssh: true)

    try result.requireSealable(debugSSH: true)
    #expect(throws: ImageBuildError.self) { try result.requireSealable(debugSSH: false) }
  }

  @Test func aMissingResultFileIsItsOwnFailure() {
    let error = #expect(throws: ImageBuildError.self) {
      _ = try MacOSProvisionResult.read(URL(fileURLWithPath: "/nonexistent/result.json"))
    }

    #expect(error?.code == "BUILD_MACOS_PROVISION_FAILED")
  }
}

/// The SSH gate's probe, against a real loopback listener rather than a seam.
@Suite struct TCPPortProbeTests {
  @Test func aBoundListenerReadsAsOpen() throws {
    let (fd, port) = try Self.bindListener()
    defer { close(fd) }

    #expect(TCPPortProbe.isOpen(host: "127.0.0.1", port: port, timeout: .milliseconds(500)))
  }

  @Test func aClosedPortReadsAsClosed() throws {
    let (fd, port) = try Self.bindListener()
    close(fd)

    #expect(!TCPPortProbe.isOpen(host: "127.0.0.1", port: port, timeout: .milliseconds(300)))
  }

  /// Binds an ephemeral loopback listener and reports which port the kernel chose.
  static func bindListener() throws -> (fd: Int32, port: UInt16) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ProbeTestError.failed("socket") }
    var reuse: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    let bound = withUnsafePointer(to: &address) { pointer -> Int32 in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(fd, 1) == 0 else {
      close(fd)
      throw ProbeTestError.failed("bind/listen")
    }
    var actual = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &actual) { pointer -> Int32 in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fd, $0, &length)
      }
    }
    guard named == 0 else {
      close(fd)
      throw ProbeTestError.failed("getsockname")
    }
    return (fd, UInt16(bigEndian: actual.sin_port))
  }

  enum ProbeTestError: Error { case failed(String) }
}

/// `ImagePullPurpose.provisioningBase` (D7): the one purpose that admits an agentless image, and
/// only a macOS Tart one. Everything else it must keep refusing is exercised alongside it, because
/// the whole value of the new case is how narrow it is.
@Suite struct ProvisioningBasePurposeTests {
  private static let macRepository = "cirruslabs/macos-tahoe-base"
  private static let linuxRepository = "cirruslabs/ubuntu"

  private func publishTart(
    _ harness: M2Harness, repository: String, os: String
  ) throws -> TartImagePublisher.Published {
    let directory = harness.tree.root.appending(path: "tart-\(os)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let disk = try PublishedImage.makeDisk(at: directory.appending(path: "disk.img"), seed: 7)
    let nvram = directory.appending(path: "nvram.bin")
    try Data(repeating: 0x5A, count: 64 << 10).write(to: nvram)
    return try TartImagePublisher.publish(
      into: harness.registry, diskURL: disk, nvramURL: nvram,
      staging: directory.appending(path: "publish", directoryHint: .isDirectory),
      repository: repository, tag: "latest", os: os, chunkBytes: PublishedImage.chunkBytes,
      uploadTime: M2Harness.imageClock)
  }

  @Test func aMacOSTartExportIsAdmittedOnlyForProvisioning() async throws {
    try await withHarness { harness in
      let published = try publishTart(harness, repository: Self.macRepository, os: "darwin")
      let reference = published.reference.description

      // The point of the new case: this is the artifact a provisioning run exists to fix.
      let record = try await harness.images.pull(
        reference: reference, purpose: .provisioningBase)
      #expect(record.os == .macos)
      let image = try await harness.images.get(reference: record.digest.rawValue)
      #expect(image.metadata?.hasGuestAgent == false)

      // And every other purpose still refuses it, agentless as it is.
      for purpose in [ImagePullPurpose.instance, .buildBase] {
        let error = await #expect(throws: ImageError.self) {
          _ = try await harness.images.pull(reference: reference, purpose: purpose)
        }
        #expect(error?.code == "IMAGE_NO_GUEST_AGENT")
      }
    }
  }

  /// A Linux Tart import has no provisioning path -- Linux images are built from a Runnerfile --
  /// so the new purpose must not become a way to smuggle one in.
  @Test func aLinuxTartExportIsRefusedEvenForProvisioning() async throws {
    try await withHarness { harness in
      let published = try publishTart(harness, repository: Self.linuxRepository, os: "linux")

      let error = await #expect(throws: ImageError.self) {
        _ = try await harness.images.pull(
          reference: published.reference.description, purpose: .provisioningBase)
      }

      #expect(error?.code == "IMAGE_NO_GUEST_AGENT")
    }
  }

  /// An agentless *RunnerVM* artifact is a sealed image someone published without an agent: a
  /// mistake to report, never a base to provision.
  @Test func anAgentlessRunnerVMArtifactIsRefusedEvenForProvisioning() async throws {
    try await withHarness { harness in
      let published = try await PublishedImage.publish(
        into: harness.registry, at: harness.tree.root.appending(path: "agentless"),
        guestAgent: false)

      for purpose in [ImagePullPurpose.provisioningBase, .instance, .buildBase] {
        let error = await #expect(throws: ImageError.self) {
          _ = try await harness.images.pull(
            reference: published.reference.description, purpose: purpose)
        }
        #expect(error?.code == "IMAGE_NO_GUEST_AGENT", "\(purpose)")
      }
    }
  }

  /// `.storage` still admits everything: importing an image for inspection is not booting it.
  @Test func storageStillAdmitsAnythingReadable() async throws {
    try await withHarness { harness in
      let published = try publishTart(harness, repository: Self.linuxRepository, os: "linux")

      let record = try await harness.images.pull(
        reference: published.reference.description, purpose: .storage)

      #expect(record.state == .ready)
    }
  }
}
