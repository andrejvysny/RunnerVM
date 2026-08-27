import ArgumentParser
import DaemonAPI
import Foundation

/// `image pull` / `image push`. Both are long-running: runnerd answers as soon as the transfer is
/// under way and hands back an operation id, and these commands follow it.
extension Image {
  struct Pull: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "pull",
      abstract: "Pull an image from an OCI registry into the local store.",
      discussion: """
        The reference must name its registry -- RunnerVM never falls back to an implicit Docker \
        Hub. A tag is resolved to an immutable digest before anything is downloaded, and a digest \
        already in the store is returned without moving a byte. Concurrent pulls of the same \
        digest share one transfer. Credentials come from the daemon: see `runnerctl registry`.

        The artifact format is detected from the manifest; --format pins it and refuses anything \
        else before a byte moves. A tart image (--format tart) is imported read-only: it carries \
        no RunnerVM guest agent, so it can be inspected and re-pushed in RunnerVM format but \
        never run a job.
        """)

    @OptionGroup var options: GlobalOptions

    @Argument(help: "ghcr.io/acme/runners/ubuntu-24:stable or …@sha256:<hex>.")
    var reference: String

    @Option(
      name: .long,
      help: "runnervm or tart. Default: auto-detect from the manifest.")
    var format: String?

    @Flag(
      inversion: .prefixedNo,
      help: "Wait for the pull to finish. --no-wait returns the operation id immediately.")
    var wait = true

    func validate() throws {
      guard let format else { return }
      guard Image.artifactFormats.contains(format) else {
        throw ValidationError("--format must be one of \(Image.artifactFormats.joined(separator: ", "))")
      }
    }

    func run() async throws {
      let response = try await options.withDaemon {
        try await $0.imagePull(reference: reference, format: format)
      }
      if response.alreadyPresent || !wait || response.operationId == nil {
        try report(response)
        return
      }
      let operation = try await OperationWaiter.wait(
        options, id: response.operationId!, label: "pulling \(response.reference)")
      guard operation.state == "succeeded" else { throw Image.failed(operation) }
      let image = try await options.withDaemon { try await $0.imageGet(ref: response.reference) }
      switch options.output {
      case .json: try JSONOut.print(image)
      case .human: print(Table.fields(Image.fields(image), indent: ""))
      }
    }

    private func report(_ response: ImagePullResponse) throws {
      switch options.output {
      case .json:
        try JSONOut.print(response)
      case .human where response.alreadyPresent:
        print("already present: \(response.reference)")
      case .human:
        print("pulling \(response.reference) (operation \(Format.optional(response.operationId)))")
      }
    }
  }

  struct Push: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "push",
      abstract: "Publish a locally stored image to an OCI registry.",
      discussion: """
        The image keeps its local identity: pushing does not change which reference this host \
        resolved it from. The registry's immutable `@sha256:` form is reported once the transfer \
        finishes.
        """)

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Local sha256:<hex> digest or the name the image was imported under.")
    var image: String

    @Argument(help: "Target reference, e.g. ghcr.io/acme/runners/ubuntu-24:stable.")
    var reference: String

    @Flag(
      inversion: .prefixedNo,
      help: "Wait for the push to finish. --no-wait returns the operation id immediately.")
    var wait = true

    func run() async throws {
      let response = try await options.withDaemon {
        try await $0.imagePush(image: image, reference: reference)
      }
      guard wait, let operationId = response.operationId else {
        switch options.output {
        case .json: try JSONOut.print(response)
        case .human:
          print("pushing \(response.reference) (operation \(Format.optional(response.operationId)))")
        }
        return
      }
      let operation = try await OperationWaiter.wait(
        options, id: operationId, label: "pushing \(response.reference)")
      guard operation.state == "succeeded" else { throw Image.failed(operation) }
      switch options.output {
      case .json: try JSONOut.print(operation)
      case .human: print("pushed \(Format.shortDigest(response.digest)) to \(response.reference)")
      }
    }
  }

  /// A finished-but-not-succeeded operation is the operator's error, so it must not exit 0.
  static func failed(_ operation: OperationInfo) -> any Error {
    writeError(
      "runnerctl: \(Format.optional(operation.errorCode)): "
        + Format.optional(operation.errorMessage))
    return ExitCode(1)
  }
}

/// Polls one `operations` row until it leaves `running`. One connection for the whole wait: the
/// daemon socket closes a connection that has been silent for 60 s, and the poll keeps it alive.
enum OperationWaiter {
  static let interval: Duration = .milliseconds(500)

  static func wait(
    _ options: GlobalOptions, id: String, label: String
  ) async throws -> OperationInfo {
    try await options.withDaemon { client in
      let startedAt = Date()
      defer { clear() }
      while true {
        let operation = try await client.operationGet(id: id)
        guard operation.state == "running" || operation.state == "pending" else { return operation }
        tick(label: label, since: startedAt)
        try await Task.sleep(for: interval)
      }
    }
  }

  /// Only on a terminal: a redirected `runnerctl image pull > log` must not collect thousands of
  /// carriage returns.
  private static func tick(label: String, since: Date) {
    guard isatty(STDERR_FILENO) == 1 else { return }
    let elapsed = Int64(Date().timeIntervalSince(since).rounded())
    FileHandle.standardError.write(Data("\r\(label) … \(Format.duration(seconds: elapsed))".utf8))
  }

  private static func clear() {
    guard isatty(STDERR_FILENO) == 1 else { return }
    FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
  }
}
