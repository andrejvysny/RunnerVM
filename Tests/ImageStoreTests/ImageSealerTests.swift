import Foundation
import RunnerCore
import Testing
@testable import ImageStore

@Suite struct ImageSealerTests {
  @Test func sealRoundTripsAnInstanceIntoANewImage() async throws {
    let env = try TempStore()
    let disk = try env.makeSparseDisk(named: "base.img")
    let base = try await env.images.importLocal(disk: disk, nvram: nil, metadata: TempStore.linuxMetadata())
    let store = env.instanceStore()
    let id = InstanceID.generate()
    let instance = try await store.materialize(
      instanceId: id, image: base.digest, diskBytes: TempStore.diskBytes,
      spec: SampleSpec(instanceId: id.rawValue)
    )

    // The builder VM did some work, and left host-side diagnostics behind.
    try env.overwrite(instance.layout.disk, at: 8192, with: Data(repeating: 0xCD, count: 4096))
    try FileSystem.write(Data("boot log".utf8), to: instance.layout.serialLog, mode: 0o600)
    try FileSystem.write(Data("worker log".utf8), to: instance.layout.workerLog, mode: 0o600)
    let expected = try SHA256Hasher.hashFile(at: instance.layout.disk)

    let sealer = ImageSealer(images: env.images)
    let sealed = try await sealer.seal(
      instanceDirectory: instance.layout.directory,
      as: TempStore.linuxMetadata(runnerVersion: "2.320.0"), name: "ubuntu-24-xcode"
    )

    #expect(sealed.created)
    #expect(sealed.digest != base.digest)
    #expect(sealed.manifest.name == "ubuntu-24-xcode")
    // Diagnostics are never layers.
    #expect(sealed.manifest.layers.map(\.role) == [.disk])
    #expect(sealed.manifest.layer(.disk)?.digest == expected)
    #expect(try env.blobFiles().count == 2)

    // The sealed image is usable as a base in turn.
    let child = InstanceID.generate()
    let cloned = try await store.materialize(
      instanceId: child, image: sealed.digest, diskBytes: TempStore.diskBytes,
      spec: SampleSpec(instanceId: child.rawValue)
    )
    #expect(try SHA256Hasher.hashFile(at: cloned.layout.disk) == expected)
    try await env.images.verify(digest: sealed.digest)
  }

  @Test func sealIsIdempotentForAnUnchangedInstance() async throws {
    let env = try TempStore()
    let disk = try env.makeSparseDisk(named: "base.img")
    let metadata = TempStore.linuxMetadata()
    let base = try await env.images.importLocal(disk: disk, nvram: nil, metadata: metadata)
    let store = env.instanceStore()
    let id = InstanceID.generate()
    let instance = try await store.materialize(
      instanceId: id, image: base.digest, diskBytes: TempStore.diskBytes,
      spec: SampleSpec(instanceId: id.rawValue)
    )

    let sealed = try await ImageSealer(images: env.images).seal(
      instanceDirectory: instance.layout.directory, as: metadata, name: "same"
    )
    #expect(sealed.digest == base.digest)
    #expect(!sealed.created)
    #expect(try env.blobFiles().count == 1)
  }

  @Test func sealRejectsADirectoryWithoutADisk() async throws {
    let env = try TempStore()
    let empty = env.root.appending(path: "not-an-instance", directoryHint: .isDirectory)
    try FileSystem.ensureDirectory(empty, permissions: 0o700)
    await #expect(throws: ImageError.self) {
      try await ImageSealer(images: env.images).seal(
        instanceDirectory: empty, as: TempStore.linuxMetadata(), name: "x"
      )
    }
  }

  @Test func sealRefusesWhileAWorkerHoldsTheLock() async throws {
    let env = try TempStore()
    let disk = try env.makeSparseDisk(named: "base.img")
    let base = try await env.images.importLocal(disk: disk, nvram: nil, metadata: TempStore.linuxMetadata())
    let store = env.instanceStore()
    let id = InstanceID.generate()
    let instance = try await store.materialize(
      instanceId: id, image: base.digest, diskBytes: TempStore.diskBytes,
      spec: SampleSpec(instanceId: id.rawValue)
    )

    try await LockHolder.whileHolding(instance.layout.workerLock) {
      let holder = try await store.workerLockHolder(instanceId: id)
      #expect(holder != nil)
      await #expect(throws: VMError.self) {
        try await ImageSealer(images: env.images).seal(
          instanceDirectory: instance.layout.directory,
          as: TempStore.linuxMetadata(runnerVersion: "2.320.0"), name: "busy"
        )
      }
    }
    let released = try await store.workerLockHolder(instanceId: id)
    #expect(released == nil)
  }
}

/// `F_GETLK` never reports a lock held by the calling process, so proving the fencing check works
/// needs a real second process holding a POSIX record lock — exactly what vmworker does.
enum LockHolder {
  static func whileHolding(_ url: URL, _ body: () async throws -> Void) async throws {
    let script = """
    import fcntl, sys
    handle = open(sys.argv[1], 'r+')
    fcntl.lockf(handle, fcntl.LOCK_EX)
    sys.stdout.write('locked\\n')
    sys.stdout.flush()
    sys.stdin.readline()
    """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", script, url.path(percentEncoded: false)]
    let output = Pipe()
    process.standardOutput = output
    process.standardInput = Pipe()
    try process.run()
    defer {
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
    }

    var seen = Data()
    while !seen.contains(UInt8(ascii: "\n")) {
      let chunk = output.fileHandleForReading.availableData
      if chunk.isEmpty { break }
      seen.append(chunk)
    }
    try await body()
  }
}
