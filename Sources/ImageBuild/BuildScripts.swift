import Foundation

/// POSIX `sh` fragments a `RecipePlan` step turns into `agent.exec` argv (`["/bin/sh", "-c", ...]`).
/// Kept as plain strings (not files) so they travel inside the daemon/agent binaries with no extra
/// packaging step. Every script starts with `set -eu` and pins nothing to `latest` -- callers
/// resolve concrete versions (runner, packages) before a script ever runs.
public enum BuildScripts {
  /// Where the extracted build context lands inside the guest.
  public static let contextRoot = "/var/lib/runnervm/context"
  /// Where the read-only context ISO is mounted before extraction.
  public static let contextMount = "/run/runnervm/context-iso"

  /// Waits for the context ISO (block device labeled `rvmctx`), mounts it read-only, and extracts
  /// `context.tar` into `contextRoot`. Runs once per build, before the first `COPY`.
  public static let mountContext = #"""
    set -eu
    DEV=""
    i=0
    while [ "$i" -lt 30 ]; do
      DEV="$(lsblk -rno PATH,LABEL 2>/dev/null | awk 'tolower($2)=="rvmctx"{print $1; exit}')"
      if [ -n "$DEV" ]; then break; fi
      i=$((i + 1))
      sleep 1
    done
    if [ -z "$DEV" ]; then DEV=/dev/disk/by-label/rvmctx; fi
    mkdir -p \#(contextMount)
    mkdir -p \#(contextRoot)
    mount -o ro "$DEV" \#(contextMount)
    tar -xpf \#(contextMount)/context.tar -C \#(contextRoot) --no-same-owner
    umount \#(contextMount)
    df -h /
    """#

  /// Docker's own COPY rules: a trailing `/` on the destination, or more than one source, means
  /// "copy into this directory" (created with `mkdir -p`); otherwise the destination is the exact
  /// target path (its parent directory is created instead). `workdir` resolves a relative
  /// destination the same way `RecipePlanner` does, so this is safe to call directly in tests.
  public static func copy(
    sources: [String], destination: String, chown: String?, workdir: String?, contextRoot: String
  ) -> String {
    let dest = resolveDestination(destination, workdir: workdir)
    let isDirectory = dest.hasSuffix("/") || sources.count > 1
    var lines = ["set -eu"]
    lines.append("mkdir -p " + shQuote(isDirectory ? dest : parentDirectory(of: dest)))
    for source in sources {
      lines.append("cp -a " + shQuote(contextRoot + "/" + source) + " " + shQuote(dest))
    }
    if let chown {
      lines.append("chown -R " + shQuote(chown) + " " + shQuote(dest))
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func resolveDestination(_ destination: String, workdir: String?) -> String {
    if destination.hasPrefix("/") { return destination }
    let base = workdir ?? "/"
    if destination.isEmpty || destination == "." {
      return base.hasSuffix("/") ? base : base + "/"
    }
    return base.hasSuffix("/") ? base + destination : base + "/" + destination
  }

  private static func parentDirectory(of path: String) -> String {
    guard let idx = path.lastIndex(of: "/") else { return "." }
    let parent = String(path[..<idx])
    return parent.isEmpty ? "/" : parent
  }

  private static func shQuote(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// Emits a machine-parseable `BuildProbeReport` (see its doc for the exact format) so a builder
  /// can confirm what actually landed in the guest, not just what the recipe asked for.
  public static let probe = #"""
    set -eu
    KERNEL="$(uname -r)"
    ARCH="$(uname -m)"
    # actions/runner ships no version file; the deps manifest names its own package as
    # "Runner.Listener/<version>", which is the only place the number appears on disk.
    RUNNER_FROM_DEPS="$(grep -o '"Runner.Listener/[0-9][0-9.]*"' /opt/actions-runner/bin/Runner.Listener.deps.json 2>/dev/null | head -1 | sed 's|.*/||; s|"||g' || true)"
    RUNNER_FROM_JSON=""
    if [ -f /etc/runnervm-image.json ]; then
      RUNNER_FROM_JSON="$(grep -o '"runnerVersion" *: *"[^"]*"' /etc/runnervm-image.json 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)"$/\1/' || true)"
    fi
    RUNNER_VERSION="$RUNNER_FROM_DEPS"
    if [ -n "$RUNNER_FROM_JSON" ]; then RUNNER_VERSION="$RUNNER_FROM_JSON"; fi
    AGENT_VERSION="$(/usr/local/bin/runnervm-guest-agent -version 2>/dev/null | head -1 || true)"
    DOCKER_VERSION="$(dpkg-query -W -f='${Version}' docker-ce 2>/dev/null || true)"
    # Ubuntu 24.04 socket-activates sshd: ssh.service stays disabled while ssh.socket is enabled.
    if systemctl is-enabled ssh.service ssh.socket 2>/dev/null | grep -qE 'enabled|static'; then
      SSH_ENABLED=true
    else
      SSH_ENABLED=false
    fi
    echo RVM-PROBE-V1
    echo "kernelVersion=$KERNEL"
    echo "architecture=$ARCH"
    echo "runnerVersion=$RUNNER_VERSION"
    echo "guestAgentVersion=$AGENT_VERSION"
    echo "dockerVersion=$DOCKER_VERSION"
    echo "sshEnabled=$SSH_ENABLED"
    echo RVM-PACKAGES-BEGIN
    dpkg-query -W -f='${Package}=${Version}\n' | LC_ALL=C sort
    echo RVM-PACKAGES-END
    """#

  /// Strips instance-specific state before an image is shelved as a template (host keys, hostname,
  /// machine-id, cloud-init's builder-only netplan) -- the guest-side twin of the sealing block in
  /// `scripts/build-ubuntu-image.sh`, generalized to whatever hostname the builder happened to use.
  public static let seal = #"""
    set -eu
    OLD_HOSTNAME="$(cat /etc/hostname 2>/dev/null || true)"
    echo runnervm >/etc/hostname
    if [ -n "$OLD_HOSTNAME" ]; then
      sed -i "s/$OLD_HOSTNAME/runnervm/g" /etc/hosts
    fi
    rm -f /etc/netplan/50-cloud-init.yaml
    netplan generate || true
    rm -f /etc/ssh/ssh_host_*
    touch /etc/cloud/cloud-init.disabled
    if mountpoint -q \#(contextMount) 2>/dev/null; then umount \#(contextMount); fi
    rm -rf \#(contextRoot) /run/runnervm
    apt-get clean
    rm -rf /var/lib/apt/lists/* /var/log/journal/* /tmp/* /var/tmp/*
    : >/etc/machine-id
    if [ -d /var/lib/dbus ]; then ln -sf /etc/machine-id /var/lib/dbus/machine-id; fi
    sync
    fstrim -av || true
    echo RVM-SEAL-OK
    """#
}
