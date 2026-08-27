import Foundation
import ImageStore
import RunnerCore

/// The cloud-init NoCloud seed a *bootstrap* build boots with (`FROM cloud-image:`).
///
/// Deliberately minimal, and deliberately not a port of `scripts/build-ubuntu-image.sh`'s seed: the
/// recipe owns everything imperative now. cloud-init here only has to get the stock cloud image to
/// the point where the guest agent answers on vsock -- console plumbing, networking, the `runner`
/// account, the agent binary and its unit. No `packages:`, no `power_state:`: the builder decides
/// when the VM stops, and a `poweroff` in the seed would race the first `agent.exec`.
public enum BuildSeed {
  /// Where the seed files are laid out before `hdiutil` turns them into `seed.img`.
  public static let volumeName = "cidata"
  private static let hdiutil = "/usr/bin/hdiutil"

  // MARK: - Guest agent binary

  /// Lookup order for the Linux guest-agent binary the seed installs. Configuration first (an
  /// operator override must always win), then the environment seam tests use, then the two
  /// packaged locations `install.sh` writes.
  public static func resolveAgent(
    config: ImageBuildConfig, paths: RunnerPaths,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    executable: URL? = Bundle.main.executableURL
  ) throws -> URL {
    var tried: [String] = []
    for candidate in candidates(config: config, paths: paths, environment: environment, executable: executable) {
      let path = candidate.path(percentEncoded: false)
      if FileManager.default.isReadableFile(atPath: path) { return candidate }
      tried.append(path)
    }
    throw ImageBuildError.guestAgentMissing(tried: tried)
  }

  private static func candidates(
    config: ImageBuildConfig, paths: RunnerPaths, environment: [String: String], executable: URL?
  ) -> [URL] {
    var result: [URL] = []
    if let configured = config.guestAgentPath, !configured.isEmpty {
      result.append(URL(fileURLWithPath: configured))
    }
    if let override = environment["RUNNERVM_GUEST_AGENT"], !override.isEmpty {
      result.append(URL(fileURLWithPath: override))
    }
    result.append(paths.rootDir.appending(path: "guest-agent/linux-arm64/runnervm-guest-agent"))
    if let executable {
      result.append(
        executable.deletingLastPathComponent()
          .appending(path: "../share/runnervm/guest-agent/linux-arm64/runnervm-guest-agent")
          .standardizedFileURL)
    }
    return result
  }

  // MARK: - Rendering

  public static func metaData(buildId: ImageBuildID) -> String {
    """
    instance-id: runnervm-build-\(buildId.rawValue)
    local-hostname: runnervm-build

    """
  }

  /// `runnerSudo` maps the recipe's `RUNNER_SUDO` argument: passwordless sudo for the runner
  /// account is what a job needs to install packages, and exactly what a hardened image withholds.
  public static func userData(runnerSudo: Bool) -> String {
    let sudo = runnerSudo ? "sudo: 'ALL=(ALL) NOPASSWD:ALL'" : "sudo: false"
    return header + users(sudo: sudo) + writeFiles + runcmd
  }

  private static let header = """
    #cloud-config
    # Every cloud-init stage is mirrored onto the virtio console so the host can watch a bootstrap
    # build in serial.log without ever mounting the guest filesystem (spec §131).
    output:
      all: '| tee -a /var/log/cloud-init-output.log /dev/hvc0'

    hostname: runnervm-build
    preserve_hostname: false

    # systemd's getty on the virtio console calls vhangup(2), which invalidates every other
    # process's handle on /dev/hvc0 and silently truncates the build trace. bootcmd runs long
    # before multi-user.target, so the getty never starts.
    bootcmd:
      - [systemctl, mask, --now, 'serial-getty@hvc0.service']

    # docker must exist as a group before the runner account is created: users are configured in
    # the init stage, long before any recipe step installs docker.
    groups:
      - docker


    """

  private static func users(sudo: String) -> String {
    """
    users:
      - name: runner
        uid: 1001
        gecos: RunnerVM actions runner
        shell: /bin/bash
        groups: [docker]
        lock_passwd: true
        \(sudo)


    """
  }

  private static let writeFiles = """
    write_files:
      # console=hvc0 is what makes serial.log useful on Apple Virtualization: the stock cloud
      # cmdline names only tty1/ttyS0, neither of which exists here.
      - path: /etc/default/grub.d/99-runnervm.cfg
        permissions: '0644'
        content: |
          GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT console=hvc0"
          GRUB_TIMEOUT=0
          GRUB_RECORDFAIL_TIMEOUT=0

      # cloud-init pins 50-cloud-init.yaml to the builder VM's MAC; every instance cloned from the
      # sealed image gets a fresh one, so match the interface name family instead.
      - path: /etc/netplan/99-runnervm.yaml
        permissions: '0600'
        content: |
          network:
            version: 2
            renderer: networkd
            ethernets:
              runnervm-en:
                match:
                  name: "en*"
                dhcp4: true
                dhcp-identifier: mac

      # The agent unit is ordered After=network-online.target; an unbounded wait-online would
      # spend minutes of the build's boot budget doing nothing.
      - path: /etc/systemd/system/systemd-networkd-wait-online.service.d/10-runnervm.conf
        permissions: '0644'
        content: |
          [Service]
          ExecStart=
          ExecStart=/usr/lib/systemd/systemd-networkd-wait-online --any --timeout=20

      # SSH host keys are instance identity, not image content, so sealing removes them. cloud-init
      # is disabled on later boots, so a tiny early oneshot regenerates them.
      - path: /etc/systemd/system/runnervm-firstboot.service
        permissions: '0644'
        content: |
          [Unit]
          Description=RunnerVM first-boot instance identity
          DefaultDependencies=no
          After=local-fs.target
          Before=sysinit.target shutdown.target
          Conflicts=shutdown.target
          ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key

          [Service]
          Type=oneshot
          RemainAfterExit=yes
          ExecStart=/usr/bin/ssh-keygen -A

          [Install]
          WantedBy=sysinit.target


    """

  private static let runcmd = """
    runcmd:
      - |
        set -eux
        DEV=""
        i=0
        while [ "$i" -lt 30 ]; do
          DEV="$(lsblk -rno PATH,LABEL 2>/dev/null | awk 'tolower($2)=="cidata"{print $1; exit}')"
          if [ -n "$DEV" ]; then break; fi
          i=$((i + 1))
          sleep 1
        done
        if [ -z "$DEV" ]; then DEV=/dev/disk/by-label/cidata; fi
        mkdir -p /mnt/cidata
        mount -o ro "$DEV" /mnt/cidata
        install -m 0755 /mnt/cidata/runnervm/guest-agent /usr/local/bin/runnervm-guest-agent
        install -m 0644 /mnt/cidata/runnervm/runnervm-guest-agent.service \\
          /etc/systemd/system/runnervm-guest-agent.service
        install -d -m 0750 /var/lib/runnervm-guest-agent
        umount /mnt/cidata
        rmdir /mnt/cidata
        update-grub || true
        systemctl daemon-reload
        systemctl enable --now runnervm-guest-agent.service runnervm-firstboot.service

    """

  /// The unit text is inlined rather than read from `GuestAgent/packaging/systemd/` at runtime: the
  /// daemon ships as a signed binary with no source tree next to it, and a build must not depend on
  /// one being there. Kept byte-identical to that file.
  public static let guestAgentUnit = """
    [Unit]
    Description=RunnerVM guest agent (vsock control channel for the host)
    Documentation=file:///usr/share/doc/runnervm-guest-agent/guest_agent.md
    # The agent reports IP addresses and the docker version, so it starts after
    # both are meaningful. Neither is required: Requires= would make a guest
    # without docker fail to serve the host at all.
    After=network-online.target docker.service
    Wants=network-online.target

    [Service]
    Type=simple
    ExecStart=/usr/local/bin/runnervm-guest-agent --runner-dir /opt/actions-runner
    Restart=always
    RestartSec=2

    # Root is required: the agent switches identity to the runner account when
    # spawning the runner, and grows the root filesystem on request.
    User=root
    Group=root

    # Creates and owns /var/lib/runnervm-guest-agent, where the cleanup epoch
    # marker lives.
    StateDirectory=runnervm-guest-agent
    StateDirectoryMode=0750

    # The agent is the guest's control plane: if it dies the host loses its only
    # reliable channel, so systemd restarts it indefinitely rather than entering
    # a failed state after a burst.
    StartLimitIntervalSec=0

    StandardOutput=journal
    StandardError=journal
    SyslogIdentifier=runnervm-guest-agent

    [Install]
    WantedBy=multi-user.target

    """

  // MARK: - Write

  /// Lays the seed out under `staging` and turns it into `layout.seed`. `staging` is inside the
  /// build directory, so a failed build takes it with it.
  @discardableResult
  public static func write(
    into layout: VMBuildLayout, agent: URL, runnerSudo: Bool, staging: URL,
    runner: any ProcessRunner
  ) async throws -> URL {
    let manager = FileManager.default
    try? manager.removeItem(at: staging)
    let payload = staging.appending(path: "seed", directoryHint: .isDirectory)
    try manager.createDirectory(
      at: payload.appending(path: "runnervm", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    try manager.copyItem(at: agent, to: payload.appending(path: "runnervm/guest-agent"))
    try Data(guestAgentUnit.utf8).write(
      to: payload.appending(path: "runnervm/runnervm-guest-agent.service"))
    try Data(metaData(buildId: layout.buildId).utf8).write(to: payload.appending(path: "meta-data"))
    try Data(userData(runnerSudo: runnerSudo).utf8).write(to: payload.appending(path: "user-data"))

    let iso = staging.appending(path: "seed.iso")
    try await runner.runChecked(hdiutil, [
      "makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", volumeName,
      "-o", iso.path(percentEncoded: false), payload.path(percentEncoded: false),
    ])
    try? manager.removeItem(at: layout.seed)
    try manager.moveItem(at: iso, to: layout.seed)
    return layout.seed
  }
}
