#!/usr/bin/env bash
# In-guest half of scripts/provision-macos-tart.sh: turns a stock Tart macOS base VM into a
# RunnerVM guest. Runs as root inside the guest (`sudo bash macos-guest-provision.sh`), reads its
# inputs from the environment, and is idempotent -- a second run over a half-provisioned guest
# finishes the job instead of failing.
#
# Mirrors the Linux contract in images/recipes/ubuntu-24-minimal/Runnerfile: a `runner` account, a
# sha256-verified actions/runner unpacked as that account, an empty git credential helper, optional
# passwordless sudo -- plus the macOS-only pieces (LaunchDaemon, Command Line Tools).
#
# Inputs (environment):
#   STAGE_DIR        where the host scp'd the payload (default /tmp/rvm-provision). The script
#                    itself lives *outside* it, so the cleanup below can remove it whole.
#   RUNNER_VERSION   actions/runner version, resolved and pinned on the host
#   RUNNER_SHA256    expected sha256 of the osx-arm64 tarball, re-verified here
#   RUNNER_SUDO      yes|no -- passwordless sudo for the runner account (default yes)
#   AGENT_VERSION    guest agent version string the host recorded (informational)
#   IMAGE_NAME       image name written into /etc/runnervm-image.json
#   SHUTDOWN         yes|no -- halt the guest when done (default yes; the host passes no so it can
#                    read the self-check off a still-live ssh session first)
#
# Output: a `RVM-SELFCHECK-V1` block of KEY=value lines on stdout, which the host parses.
set -euo pipefail

STAGE_DIR="${STAGE_DIR:-/tmp/rvm-provision}"
RUNNER_VERSION="${RUNNER_VERSION:-}"
RUNNER_SHA256="${RUNNER_SHA256:-}"
RUNNER_SUDO="${RUNNER_SUDO:-yes}"
RUNNER_USER="${RUNNER_USER:-runner}"
AGENT_VERSION="${AGENT_VERSION:-dev}"
IMAGE_NAME="${IMAGE_NAME:-runnervm-macos-base}"
SHUTDOWN="${SHUTDOWN:-yes}"

RUNNER_HOME="/Users/$RUNNER_USER"
RUNNER_DIR="$RUNNER_HOME/actions-runner"
AGENT_BIN="/usr/local/bin/runnervm-guest-agent"
AGENT_STATE_DIR="/var/lib/runnervm-guest-agent"
PLIST_LABEL="com.runnervm.guest-agent"
PLIST_PATH="/Library/LaunchDaemons/$PLIST_LABEL.plist"
SELFCHECK_LOG="/var/log/runnervm-provision-selfcheck.txt"

log()  { printf '[guest %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[guest] warning: %s\n' "$*" >&2; }
die()  { printf '[guest] error: %s\n' "$*" >&2; exit 1; }

check_inputs() {
    [ "$(id -u)" = "0" ] || die "must run as root (sudo bash $0)"
    [ -d "$STAGE_DIR" ] || die "stage directory not found: $STAGE_DIR"
    [ -n "$RUNNER_VERSION" ] || die "RUNNER_VERSION is required"
    [ -n "$RUNNER_SHA256" ] || die "RUNNER_SHA256 is required"
    case "$RUNNER_SUDO" in yes | no) ;; *) die "RUNNER_SUDO must be yes or no" ;; esac
    case "$SHUTDOWN" in yes | no) ;; *) die "SHUTDOWN must be yes or no" ;; esac
}

# --------------------------------------------------------------------------
# 1. The runner account
# --------------------------------------------------------------------------

# First uid >= 501 no local record already claims. 501 is the first "human" uid on macOS and is
# normally the Tart base image's own `admin`, so this almost always lands on 502.
next_free_uid() {
    local uid=501
    while [ -n "$(dscl . -search /Users UniqueID "$uid" 2>/dev/null)" ]; do
        uid=$((uid + 1))
    done
    printf '%s' "$uid"
}

create_runner_account() {
    # Tart base images ship /Users/runner as a symlink to /Users/admin (GitHub-hosted-runner path
    # compatibility). A symlinked home would put the runner's state inside admin's account, and the
    # guest agent refuses to snapshot a symlinked HOME -- so the link goes before the account exists.
    if [ -L "$RUNNER_HOME" ]; then
        log "removing symlink $RUNNER_HOME -> $(readlink "$RUNNER_HOME") shipped by the base image"
        rm "$RUNNER_HOME"
    fi
    if dscl . -read "/Users/$RUNNER_USER" >/dev/null 2>&1; then
        log "account $RUNNER_USER already exists (uid $(runner_uid))"
    else
        local uid password
        uid="$(next_free_uid)"
        # The account password is random and deliberately discarded: nothing ever logs in as
        # `runner`. The agent starts the runner from a root LaunchDaemon and sudo is NOPASSWD, so a
        # known password would only be an attack surface. It reaches sysadminctl through argv --
        # briefly visible to `ps` inside this throwaway build VM, which is acceptable precisely
        # because the value is never used again and never leaves the guest.
        password="$(openssl rand -base64 48 | tr -d '/+=\n' | cut -c1-32)"
        log "creating account $RUNNER_USER (uid $uid)"
        sysadminctl -addUser "$RUNNER_USER" -fullName "RunnerVM runner" -UID "$uid" \
            -password "$password" -home "$RUNNER_HOME" -shell /bin/zsh 2>&1 |
            sed 's/^/[sysadminctl] /'
        unset password
    fi
    # Keep the account out of the login window: this guest cold-boots with no operator.
    dscl . -create "/Users/$RUNNER_USER" IsHidden 1 || warn "could not set IsHidden on $RUNNER_USER"
    if [ ! -d "$RUNNER_HOME" ]; then
        log "creating $RUNNER_HOME"
        createhomedir -c -u "$RUNNER_USER" >/dev/null 2>&1 ||
            die "createhomedir failed for $RUNNER_USER"
    fi
    [ -d "$RUNNER_HOME" ] || die "$RUNNER_HOME still does not exist"
    chown "$RUNNER_USER":staff "$RUNNER_HOME"
}

runner_uid() { dscl . -read "/Users/$RUNNER_USER" UniqueID 2>/dev/null | awk '{print $2}'; }

# --------------------------------------------------------------------------
# 2. Guest agent + LaunchDaemon
# --------------------------------------------------------------------------
install_agent() {
    [ -f "$STAGE_DIR/runnervm-guest-agent" ] || die "staged agent binary missing"
    [ -f "$STAGE_DIR/$PLIST_LABEL.plist" ] || die "staged LaunchDaemon plist missing"
    install -d -m 0755 /usr/local/bin
    install -m 0755 "$STAGE_DIR/runnervm-guest-agent" "$AGENT_BIN"
    # --state-dir's default; the agent does not create it itself.
    install -d -o root -g wheel -m 0755 "$AGENT_STATE_DIR"
    # arm64 macOS refuses to exec an unsigned Mach-O. `go build` ad-hoc signs darwin/arm64 output,
    # so this only fires for a binary that lost its signature in transit or was cross-built by a
    # toolchain that does not sign -- fail here, with the fix, rather than at first boot.
    "$AGENT_BIN" --version >/dev/null 2>&1 ||
        die "$AGENT_BIN will not execute; if it is unsigned, run: codesign -s - --force $AGENT_BIN"
    install -o root -g wheel -m 0644 "$STAGE_DIR/$PLIST_LABEL.plist" "$PLIST_PATH"
    # bootout first so a re-run picks up the binary just installed instead of leaving the old one
    # running; both calls are tolerant because "not loaded"/"already loaded" are both fine states.
    launchctl bootout "system/$PLIST_LABEL" >/dev/null 2>&1 || true
    launchctl bootstrap system "$PLIST_PATH" 2>&1 | sed 's/^/[launchctl] /' || true
    launchctl enable "system/$PLIST_LABEL" || warn "launchctl enable failed"
    if launchctl print "system/$PLIST_LABEL" >/dev/null 2>&1; then
        log "LaunchDaemon $PLIST_LABEL loaded"
    else
        # Not fatal: RunAtLoad in the plist starts it on the next boot regardless, and the agent
        # cannot reach a vsock peer during provisioning anyway.
        warn "LaunchDaemon $PLIST_LABEL is not loaded right now"
    fi
}

launchd_loaded() {
    if launchctl print "system/$PLIST_LABEL" >/dev/null 2>&1; then echo yes; else echo no; fi
}

# --------------------------------------------------------------------------
# 3. actions/runner (osx-arm64)
# --------------------------------------------------------------------------
install_runner() {
    local tarball="$STAGE_DIR/actions-runner-osx-arm64-$RUNNER_VERSION.tar.gz"
    [ -f "$tarball" ] || die "staged runner tarball missing: $tarball"
    # Verified on the host before the copy and again here: a mismatch means the bytes changed in
    # transit, so nothing unverified is ever unpacked.
    echo "$RUNNER_SHA256  $tarball" | shasum -a 256 -c - >/dev/null ||
        die "runner tarball sha256 mismatch in the guest (expected $RUNNER_SHA256)"
    # The image may already carry a runner under this path (Tart base images pre-install one,
    # owned by admin); it is replaced wholesale so the tree is exactly the verified tarball.
    [ -e "$RUNNER_DIR" ] && rm -rf "$RUNNER_DIR"
    install -d -o "$RUNNER_USER" -g staff -m 0755 "$RUNNER_DIR"
    # Unpacked as the runner account so every file lands with its ownership; a non-root tar cannot
    # restore foreign uids, which is exactly what we want here.
    sudo -u "$RUNNER_USER" tar -xzf "$tarball" -C "$RUNNER_DIR"
    chown -R "$RUNNER_USER":staff "$RUNNER_DIR"
    # runner.Manager.SelfCheck refuses to start a job unless run.sh is executable.
    chmod +x "$RUNNER_DIR/run.sh" "$RUNNER_DIR/config.sh"
    # No bin/installdependencies.sh on macOS: that script is Linux-only (apt/yum ICU + libssl).
    log "actions/runner $RUNNER_VERSION unpacked into $RUNNER_DIR"
}

# --------------------------------------------------------------------------
# 4. Xcode Command Line Tools (git, and every toolchain a job expects)
# --------------------------------------------------------------------------
install_command_line_tools() {
    if /usr/bin/xcode-select -p >/dev/null 2>&1 && /usr/bin/git --version >/dev/null 2>&1; then
        log "Command Line Tools already installed ($(/usr/bin/xcode-select -p))"
        return 0
    fi
    local marker="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress" label=""
    # softwareupdate only advertises the CLT packages while this marker exists.
    : >"$marker"
    label="$(softwareupdate -l 2>/dev/null |
        sed -n 's/^[[:space:]]*\*[[:space:]]*Label:[[:space:]]*//p' |
        grep '^Command Line Tools for Xcode' | sed 's/[[:space:]]*$//' |
        sort -V | tail -1)" || label=""
    if [ -n "$label" ]; then
        log "installing '$label'"
        softwareupdate -i "$label" --verbose 2>&1 | sed 's/^/[softwareupdate] /' ||
            warn "softwareupdate -i '$label' failed"
    else
        warn "softwareupdate advertised no Command Line Tools label"
    fi
    rm -f "$marker"
    /usr/bin/git --version >/dev/null 2>&1 ||
        die "git is still unavailable after the Command Line Tools install"
}

# --------------------------------------------------------------------------
# 5. git credential helper -- the one setting a macOS runner must not get wrong
# --------------------------------------------------------------------------
# actions/checkout injects the job token via http.extraheader, so no helper is ever needed. An
# empty override (not --unset-all) also stops anything installed later from reintroducing a
# Keychain-backed helper underneath it: on a headless, never-logged-in guest that helper blocks
# forever with no prompt anyone can answer. It must be written as the runner account with
# HOME=/Users/runner -- a root-owned ~/.gitconfig would not be read by the job.
reset_credential_helper() {
    sudo -H -u "$RUNNER_USER" git config --global credential.helper ""
    local helpers
    helpers="$(sudo -H -u "$RUNNER_USER" git config --global --get-all credential.helper)" || helpers=""
    log "credential.helper for $RUNNER_USER: [${helpers}]"
}

# "<empty>" (the override is present and empty -- what the host demands), "<unset>" (no helper
# configured at all, which is *not* the same thing: nothing then stops a later install from adding
# one), or the comma-joined helpers actually configured. A bare `credential_helper=` line could
# not tell the first two apart, and only git's exit status can.
credential_helper_value() {
    local helpers rc=0
    helpers="$(sudo -H -u "$RUNNER_USER" git config --global --get-all credential.helper 2>/dev/null)" ||
        rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "<unset>"
    elif [ -z "$helpers" ]; then
        echo "<empty>"
    else
        echo "$helpers" | tr '\n' ',' | sed 's/,$//'
    fi
}

# --------------------------------------------------------------------------
# 6. Passwordless sudo, power/indexing, guest info file
# --------------------------------------------------------------------------
configure_sudo() {
    if [ "$RUNNER_SUDO" != "yes" ]; then
        rm -f /etc/sudoers.d/90-runner
        log "passwordless sudo for $RUNNER_USER: disabled"
        return 0
    fi
    install -d -m 0750 /etc/sudoers.d
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$RUNNER_USER" >/etc/sudoers.d/90-runner
    chmod 0440 /etc/sudoers.d/90-runner
    visudo -cf /etc/sudoers.d/90-runner ||
        die "/etc/sudoers.d/90-runner did not pass visudo -c"
    grep -qE '^[[:space:]]*#includedir[[:space:]]+/private/etc/sudoers\.d' /etc/sudoers ||
        warn "/etc/sudoers has no #includedir for sudoers.d; 90-runner will be ignored"
    log "passwordless sudo for $RUNNER_USER: enabled"
}

# Best-effort only: a guest that still sleeps or still indexes is slower, not broken.
tune_host_behaviour() {
    pmset -a sleep 0 displaysleep 0 disksleep 0 2>&1 | sed 's/^/[pmset] /' ||
        warn "pmset failed; the guest may sleep mid-job"
    mdutil -a -i off 2>&1 | sed 's/^/[mdutil] /' || warn "mdutil failed; Spotlight may index jobs"
    systemsetup -setcomputersleep Never >/dev/null 2>&1 || true
}

# Same file images/recipes/ubuntu-24-minimal ships at /etc/runnervm-image.json. The guest agent
# itself does not read it (it takes the runner version from <runner-dir>/bin/runnerversion); the
# build probe in Sources/ImageBuild/BuildScripts.swift does, so keep the shape identical.
write_image_info() {
    cat >/etc/runnervm-image.json <<JSON
{
  "family": "macos",
  "variant": "$IMAGE_NAME",
  "runnerVersion": "$RUNNER_VERSION",
  "guestAgentVersion": "$AGENT_VERSION"
}
JSON
    chmod 0644 /etc/runnervm-image.json
}

# --------------------------------------------------------------------------
# 7. Self-check -- the host parses these lines and seals them into metadata.json
# --------------------------------------------------------------------------
self_check() {
    local agent_version git_version
    agent_version="$("$AGENT_BIN" --version 2>/dev/null | head -1)" || agent_version=""
    git_version="$(/usr/bin/git --version 2>/dev/null | head -1)" || git_version=""
    [ -x "$RUNNER_DIR/run.sh" ] || die "$RUNNER_DIR/run.sh is not executable (agent SelfCheck would fail)"
    {
        echo "RVM-SELFCHECK-V1"
        echo "runner_uid=$(runner_uid)"
        echo "runner_home=$RUNNER_HOME"
        echo "runner_dir=$RUNNER_DIR"
        echo "runner_version=$RUNNER_VERSION"
        echo "agent_version=$agent_version"
        echo "agent_version_host=$AGENT_VERSION"
        echo "launchd_loaded=$(launchd_loaded)"
        echo "git_version=$git_version"
        echo "credential_helper=$(credential_helper_value)"
        echo "runner_sudo=$RUNNER_SUDO"
        echo "sw_vers_product_version=$(sw_vers -productVersion)"
        echo "sw_vers_build_version=$(sw_vers -buildVersion)"
        echo "RVM-SELFCHECK-END"
    } | tee "$SELFCHECK_LOG"
}

main() {
    check_inputs
    create_runner_account
    install_agent
    install_runner
    install_command_line_tools
    reset_credential_helper
    configure_sudo
    tune_host_behaviour
    write_image_info
    self_check
    rm -rf "$STAGE_DIR"
    # The daemon has been restarting since install_agent with no vsock peer to talk to (Tart
    # attaches no virtio-socket device). Ship the image with an empty log rather than that noise.
    : >/var/log/runnervm-guest-agent.log
    if [ "$SHUTDOWN" = "yes" ]; then
        log "halting the guest"
        shutdown -h now
    fi
}

main "$@"
