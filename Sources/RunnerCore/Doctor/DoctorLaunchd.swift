import Foundation

/// Pure `launchctl print` and launchd-plist reading behind `runnerctl doctor`'s launchd checks.
/// Takes recorded text and already-read plist bytes; the `launchctl` invocation and the directory
/// `stat(2)` stay in `runnerctl`, which has no test target of its own.
///
/// The incident these checks exist for (blackpen, 2026-08): launchd could not spawn `runnerd` at
/// all, because the `StandardOutPath` directory the plists redirect to had never been created. The
/// job respawned forever with `runs = 70547` and `last exit code = 78`, `stdio.log` stayed absent,
/// and `launchd_job` still reported "loaded" -- doctor was green on a host where the daemon had
/// never once run.
public enum DoctorLaunchd {
  /// Above this many `runs`, a job is looping rather than having been restarted once or twice.
  public static let noisyRunCount = 10

  /// What the shipped plists set. An older installed plist keeps `5`, and `upgrade` does not
  /// re-render it, so a bad configuration there is retried twelve times a minute.
  public static let minimumThrottleInterval = 30

  /// launchd's own default when a plist carries no `ThrottleInterval`.
  public static let launchdDefaultThrottleInterval = 10

  // MARK: - launchctl print

  /// The two counters `launchctl print` reports that say whether a loaded job is actually staying
  /// up. `nil` means launchd did not print the key (a domain or OS version that words it
  /// differently), which is "unknown", never "zero".
  public struct JobFacts: Sendable, Hashable {
    public var runs: Int?
    public var lastExitCode: Int?

    public init(runs: Int? = nil, lastExitCode: Int? = nil) {
      self.runs = runs
      self.lastExitCode = lastExitCode
    }
  }

  /// `launchctl print <domain>/<label>` prints one indented `key = value` line per field:
  /// ```
  ///     state = running
  ///     runs = 70547
  ///     last exit code = 78
  /// ```
  public static func jobFacts(fromLaunchctlPrint text: String) -> JobFacts {
    JobFacts(
      runs: integerField(named: "runs", in: text),
      lastExitCode: integerField(named: "last exit code", in: text))
  }

  /// Only whole-key matches count: `last exit code` must not be answered by a `runs` lookup, and a
  /// value launchd words rather than numbers (`(never exited)`) reads as unknown.
  private static func integerField(named label: String, in text: String) -> Int? {
    for line in text.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix(label) else { continue }
      let rest = trimmed.dropFirst(label.count).trimmingCharacters(in: .whitespaces)
      guard rest.hasPrefix("=") else { continue }
      return Int(rest.dropFirst().trimmingCharacters(in: .whitespaces))
    }
    return nil
  }

  // MARK: - The installed plist

  /// The fields of an installed plist doctor has an opinion about.
  public struct PlistFacts: Sendable, Hashable {
    public var standardOutPath: String?
    public var standardErrorPath: String?
    public var throttleInterval: Int?

    public init(
      standardOutPath: String? = nil, standardErrorPath: String? = nil,
      throttleInterval: Int? = nil
    ) {
      self.standardOutPath = standardOutPath
      self.standardErrorPath = standardErrorPath
      self.throttleInterval = throttleInterval
    }
  }

  /// `PropertyListSerialization` rather than string matching: what is installed is whatever the
  /// operator's install wrote, which is XML today but binary after any `plutil -convert`.
  /// `nil` means the bytes are not a property list dictionary at all.
  public static func plistFacts(fromPropertyList data: Data) -> PlistFacts? {
    guard
      let object = try? PropertyListSerialization.propertyList(
        from: data, options: [], format: nil),
      let dictionary = object as? [String: Any]
    else { return nil }
    return PlistFacts(
      standardOutPath: dictionary["StandardOutPath"] as? String,
      standardErrorPath: dictionary["StandardErrorPath"] as? String,
      throttleInterval: (dictionary["ThrottleInterval"] as? NSNumber)?.intValue)
  }

  // MARK: - Checks

  /// `launchd_job` for a job launchd has loaded. Loaded is not the same as running: a job that
  /// cannot start reports a climbing `runs` and a non-zero `last exit code`, and that is the only
  /// place the failure is visible when the daemon never gets far enough to write its own log.
  ///
  /// `loaded` is the caller's description of where it found the job, e.g.
  /// `"LaunchDaemon com.runnervm.runnerd loaded in system"`.
  public static func jobCheck(
    loaded: String, facts: JobFacts, stdioLogPath: String?
  ) -> DoctorCheck {
    let id = "launchd_job"
    let title = "launchd job"
    let looping = (facts.runs ?? 0) > noisyRunCount
    let failedExit = (facts.lastExitCode ?? 0) != 0
    guard !looping, !failedExit else {
      let log = stdioLogPath ?? "<state-dir>/logs/runnerd/stdio.log"
      return DoctorCheck(
        id: id, title: title, status: .warn,
        detail: "\(loaded), but launchd reports runs = \(describe(facts.runs)) and "
          + "last exit code = \(describe(facts.lastExitCode)); the job is restarting instead of "
          + "staying up. Read \(log) — an exit code with an empty or missing stdio.log means "
          + "launchd never spawned runnerd at all (see launchd_stdio_dir)"
      )
    }
    return DoctorCheck(
      id: id, title: title, status: .ok,
      detail: "\(loaded) (runs = \(describe(facts.runs)), "
        + "last exit code = \(describe(facts.lastExitCode)))"
    )
  }

  /// `launchd_stdio_dir`: launchd creates the stdio *file* but never its directory, and a missing
  /// directory fails the spawn before `runnerd` runs. A `fail`, not a warning — nothing about the
  /// deployment works until it exists.
  ///
  /// `kickstartTarget` is the `<domain>/<label>` to reload once it does, or `nil` when the caller
  /// cannot tell which domain the job belongs to.
  public static func stdioDirectoryCheck(
    plistPath: String?, facts: PlistFacts?, kickstartTarget: String?,
    directoryExists: (String) -> Bool
  ) -> DoctorCheck {
    let id = "launchd_stdio_dir"
    let title = "launchd stdio directory"
    guard let plistPath else {
      return DoctorCheck(
        id: id, title: title, status: .skip, detail: "no launchd job installed"
      )
    }
    guard let facts else {
      return DoctorCheck(
        id: id, title: title, status: .warn,
        detail: "\(plistPath) could not be read as a property list"
      )
    }
    let directories = [facts.standardOutPath, facts.standardErrorPath]
      .compactMap { $0 }
      .map { ($0 as NSString).deletingLastPathComponent }
      .filter { !$0.isEmpty }
    guard !directories.isEmpty else {
      return DoctorCheck(
        id: id, title: title, status: .ok,
        detail: "\(plistPath) does not redirect stdout or stderr to a file"
      )
    }
    var missing: [String] = []
    for directory in directories where !directoryExists(directory) && !missing.contains(directory) {
      missing.append(directory)
    }
    guard missing.isEmpty else {
      let reload = kickstartTarget.map { " then `launchctl kickstart -k \($0)`" } ?? ""
      return DoctorCheck(
        id: id, title: title, status: .fail,
        detail: "launchd cannot spawn runnerd: \(missing.joined(separator: ", ")) does not exist; "
          + "create it (mkdir -p, owned by the service account)\(reload)"
      )
    }
    return DoctorCheck(
      id: id, title: title, status: .ok,
      detail: "\(directories.joined(separator: ", ")) exists"
    )
  }

  /// `launchd_throttle`: the respawn floor an installed plist actually carries. `upgrade` never
  /// re-renders a plist, so a host installed before the floor was raised keeps retrying a broken
  /// configuration every few seconds forever.
  public static func throttleCheck(plistPath: String?, facts: PlistFacts?) -> DoctorCheck {
    let id = "launchd_throttle"
    let title = "launchd throttle"
    guard let plistPath else {
      return DoctorCheck(
        id: id, title: title, status: .skip, detail: "no launchd job installed"
      )
    }
    guard let facts else {
      return DoctorCheck(
        id: id, title: title, status: .warn,
        detail: "\(plistPath) could not be read as a property list"
      )
    }
    let interval = facts.throttleInterval ?? launchdDefaultThrottleInterval
    guard interval >= minimumThrottleInterval else {
      let source = facts.throttleInterval == nil
        ? "sets no ThrottleInterval (launchd defaults to \(launchdDefaultThrottleInterval)s)"
        : "throttles restarts to one every \(interval)s"
      return DoctorCheck(
        id: id, title: title, status: .warn,
        detail: "\(plistPath) \(source); older plist. Re-run `runnerctl setup` (or "
          + "`scripts/install.sh --launchd daemon|agent`) to re-render it, or edit it to "
          + "ThrottleInterval \(minimumThrottleInterval) and reload the job"
      )
    }
    return DoctorCheck(
      id: id, title: title, status: .ok, detail: "ThrottleInterval \(interval)s"
    )
  }

  private static func describe(_ value: Int?) -> String {
    value.map(String.init) ?? "unknown"
  }
}
