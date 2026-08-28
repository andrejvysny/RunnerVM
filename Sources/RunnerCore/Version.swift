/// The one place the build's version string lives.
///
/// `runnerctl --version` has to answer without a daemon, `system.version` reports the same string
/// over the wire, and `runnerctl version` prints both side by side — three readers that must never
/// disagree, which is only guaranteed if there is a single constant.
public enum RunnerVMVersion {
  public static let current = "0.2.0"
}
