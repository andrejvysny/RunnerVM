import Darwin

/// Where the child lands in the process hierarchy.
public enum SpawnPlacement: Sendable {
  /// `POSIX_SPAWN_SETPGROUP` with pgroup `0`: the child leads a brand-new process group whose id
  /// *is* its pid, so `kill(-pid, …)` reaches it and everything it forks. The caller captures
  /// `pgid = pid` at spawn and never re-derives it: `getpgid` answers `ESRCH` for a zombie leader
  /// while `kill(-pgid, …)` on that same group still works.
  case ownProcessGroup
  /// `POSIX_SPAWN_SETSID`: a new session, so the child survives this process's exit and is not in
  /// its terminal process group. A session leader also leads its own group, so `kill(-pid, …)`
  /// still reaches the group -- but nothing here waits for such a child.
  case ownSession
}

/// `posix_spawnattr_t`, initialised the one way every spawn in this repo wants it.
///
/// `POSIX_SPAWN_SETSIGDEF` (full set) + `POSIX_SPAWN_SETSIGMASK` (empty) are not optional extras:
/// runnerd `SIG_IGN`s `SIGTERM`/`SIGINT`/`SIGHUP` for its own graceful shutdown, an *ignored*
/// disposition survives `exec` (a *handled* one does not), and a child that inherits
/// `SIG_IGN`/`SIGTERM` cannot be asked to stop -- only `SIGKILL`ed, which skips every `trap` a
/// shell helper installed. Without them the whole SIGTERM leg of the escalation ladder is dead
/// code.
///
/// `POSIX_SPAWN_CLOEXEC_DEFAULT` closes everything the file actions do not name, keeping the
/// daemon's SQLite handles, listening sockets and lock descriptors out of the child.
public struct SpawnAttributes {
  public var value = posix_spawnattr_t(bitPattern: 0)

  public init(placement: SpawnPlacement) throws {
    guard posix_spawnattr_init(&value) == 0 else { throw SpawnError.pipeFailed(code: errno) }
    var flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
    switch placement {
    case .ownProcessGroup:
      flags |= POSIX_SPAWN_SETPGROUP
      posix_spawnattr_setpgroup(&value, 0)
    case .ownSession:
      flags |= POSIX_SPAWN_SETSID
    }
    posix_spawnattr_setflags(&value, Int16(flags))
    // `SIGKILL`/`SIGSTOP` are in the full set and are simply ignored by the kernel here; naming
    // every signal is what makes an inherited `SIG_IGN` impossible.
    var everything = sigset_t()
    sigfillset(&everything)
    posix_spawnattr_setsigdefault(&value, &everything)
    var nothing = sigset_t()
    sigemptyset(&nothing)
    posix_spawnattr_setsigmask(&value, &nothing)
  }

  public mutating func destroy() {
    posix_spawnattr_destroy(&value)
  }
}

/// `posix_spawn_file_actions_t` with the two shapes this repo uses: a descriptor duplicated onto
/// one of the child's standard fds, or a file opened as one.
public struct SpawnFileActions {
  public var value = posix_spawn_file_actions_t(bitPattern: 0)

  public init() throws {
    guard posix_spawn_file_actions_init(&value) == 0 else {
      throw SpawnError.pipeFailed(code: errno)
    }
  }

  /// `source` must not already equal `target`: `dup2(fd, fd)` is a no-op that leaves `FD_CLOEXEC`
  /// set, and under `POSIX_SPAWN_CLOEXEC_DEFAULT` the child would then find that fd closed.
  /// `ProcessSpawn` moves every child-side descriptor above 2 before calling this.
  public mutating func duplicate(_ source: Int32, onto target: Int32) {
    posix_spawn_file_actions_adddup2(&value, source, target)
  }

  public mutating func open(_ target: Int32, path: String, flags: Int32, mode: mode_t) {
    posix_spawn_file_actions_addopen(&value, target, path, flags, mode)
  }

  public mutating func destroy() {
    posix_spawn_file_actions_destroy(&value)
  }
}

/// `posix_spawn` wants a NULL-terminated `char *const []`; the buffers must outlive the call, so
/// the body runs inside the allocation rather than returning the pointers.
public func withCStrings<T>(
  _ values: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
) -> T {
  var pointers: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
  pointers.append(nil)
  defer { for pointer in pointers where pointer != nil { free(pointer) } }
  return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
}

/// An environment map as the `KEY=VALUE` array `posix_spawn` takes, sorted so two runs of the same
/// request produce the same envp.
public func environmentPairs(_ environment: [String: String]) -> [String] {
  environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
}
