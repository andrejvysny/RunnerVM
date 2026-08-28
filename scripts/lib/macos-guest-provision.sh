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
#   AGENT_SHA256     expected sha256 of the staged guest agent binary, re-verified here
#   PLIST_SHA256     expected sha256 of the staged LaunchDaemon plist, re-verified here
#   SHUTDOWN         yes|no -- halt the guest when done (default yes; the host passes no so it can
#                    read the self-check off a still-live ssh session first)
#   STAGE            all|harden -- `all` provisions (default); `harden` runs only the seal-time
#                    lockdown below, which the host invokes in its own ssh session
#   HARDEN_USER      the build-time SSH account to lock down (default admin)
#   HARDEN_OLD_PASSWORD_FILE
#                    path to a 0600 file holding that account's current password, so the rotation
#                    can be done with `dscl . -passwd` and *proved* by re-authenticating with the
#                    old one afterwards. A file rather than a value: the host stages it with `scp`,
#                    so the secret never appears in any argv, on either side. Read and unlinked
#                    before anything else in the harden stage.
#   HARDEN_OLD_PASSWORD
#                    the same value inline, for a manual run. Prefer the file.
#
# Output: a `RVM-SELFCHECK-V1` (STAGE=all) or `RVM-HARDEN-V1` (STAGE=harden) block of KEY=value
# lines on stdout, which the host parses and refuses to seal without.
set -euo pipefail

STAGE_DIR="${STAGE_DIR:-/tmp/rvm-provision}"
RUNNER_VERSION="${RUNNER_VERSION:-}"
RUNNER_SHA256="${RUNNER_SHA256:-}"
RUNNER_SUDO="${RUNNER_SUDO:-yes}"
RUNNER_USER="${RUNNER_USER:-runner}"
AGENT_VERSION="${AGENT_VERSION:-dev}"
IMAGE_NAME="${IMAGE_NAME:-runnervm-macos-base}"
AGENT_SHA256="${AGENT_SHA256:-}"
PLIST_SHA256="${PLIST_SHA256:-}"
SHUTDOWN="${SHUTDOWN:-yes}"
STAGE="${STAGE:-all}"
HARDEN_USER="${HARDEN_USER:-admin}"
HARDEN_OLD_PASSWORD="${HARDEN_OLD_PASSWORD:-}"
HARDEN_OLD_PASSWORD_FILE="${HARDEN_OLD_PASSWORD_FILE:-}"

RUNNER_HOME="/Users/$RUNNER_USER"
RUNNER_DIR="$RUNNER_HOME/actions-runner"
AGENT_BIN="/usr/local/bin/runnervm-guest-agent"
AGENT_STATE_DIR="/var/lib/runnervm-guest-agent"
PLIST_LABEL="com.runnervm.guest-agent"
PLIST_PATH="/Library/LaunchDaemons/$PLIST_LABEL.plist"
SELFCHECK_LOG="/var/log/runnervm-provision-selfcheck.txt"
HARDEN_LOG="/var/log/runnervm-harden.txt"
SSHD_SERVICE="system/com.openssh.sshd"
NEWSYSLOG_CONF="/etc/newsyslog.d/runnervm-guest-agent.conf"

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

# `harden` needs neither the staged payload nor the runner inputs -- it runs after all of that,
# in its own ssh session, against a guest that is already provisioned.
check_harden_inputs() {
    [ "$(id -u)" = "0" ] || die "must run as root (sudo bash $0)"
    [ -n "$HARDEN_USER" ] || die "HARDEN_USER is required"
    case "$SHUTDOWN" in yes | no) ;; *) die "SHUTDOWN must be yes or no" ;; esac
    read_old_password
}

# Consumes HARDEN_OLD_PASSWORD_FILE: read once, unlinked immediately. The file is how the host
# gets the credential in without putting it in an ssh command line, and the unlink is what keeps it
# out of the sealed image if the run stops early.
read_old_password() {
    [ -n "$HARDEN_OLD_PASSWORD_FILE" ] || return 0
    if [ -r "$HARDEN_OLD_PASSWORD_FILE" ]; then
        HARDEN_OLD_PASSWORD="$(cat "$HARDEN_OLD_PASSWORD_FILE")"
    else
        warn "HARDEN_OLD_PASSWORD_FILE is not readable: $HARDEN_OLD_PASSWORD_FILE"
    fi
    rm -f "$HARDEN_OLD_PASSWORD_FILE"
}

# Fails unless the file hashes to the expected value. An empty expectation is itself a failure:
# the host always computes one, so a missing value means the payload was staged by something that
# did not, and installing it unverified is exactly what this exists to prevent.
verify_sha256() {
    local file="$1" expected="$2" what="$3" actual
    [ -n "$expected" ] || die "no expected sha256 for $what; re-run scripts/provision-macos-tart.sh"
    [ -f "$file" ] || die "$what is missing: $file"
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    [ "$actual" = "$expected" ] ||
        die "$what sha256 mismatch: expected $expected, got $actual"
    log "$what verified (sha256 ${expected:0:16})"
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
# Fail-closed, with one deliberate exception.
#
# "the agent cannot *connect*" is fine here -- tart attaches no virtio-socket device, so the agent
# has no vsock peer during provisioning and restarts in a loop. "the LaunchDaemon cannot *load*" is
# not fine: it is the single thing that has to work on the first cold boot under RunnerVM, and an
# image that seals with a broken daemon looks perfect until a job is waiting on it.
install_agent() {
    verify_sha256 "$STAGE_DIR/runnervm-guest-agent" "$AGENT_SHA256" "guest agent binary"
    verify_sha256 "$STAGE_DIR/$PLIST_LABEL.plist" "$PLIST_SHA256" "LaunchDaemon plist"
    install -d -m 0755 /usr/local/bin
    install -m 0755 "$STAGE_DIR/runnervm-guest-agent" "$AGENT_BIN"
    # --state-dir's default; the agent does not create it itself.
    install -d -o root -g wheel -m 0755 "$AGENT_STATE_DIR"
    # arm64 macOS refuses to exec an unsigned Mach-O. `go build` ad-hoc signs darwin/arm64 output,
    # so this only fires for a binary that lost its signature in transit or was cross-built by a
    # toolchain that does not sign -- fail here, with the fix, rather than at first boot.
    "$AGENT_BIN" --version >/dev/null 2>&1 ||
        die "$AGENT_BIN will not execute; if it is unsigned, run: codesign -s - --force $AGENT_BIN"
    # launchd silently ignores a plist it cannot parse, so lint before installing it.
    plutil -lint "$STAGE_DIR/$PLIST_LABEL.plist" >/dev/null ||
        die "$PLIST_LABEL.plist is not a valid property list"
    install -o root -g wheel -m 0644 "$STAGE_DIR/$PLIST_LABEL.plist" "$PLIST_PATH"
    # launchd refuses a LaunchDaemon that is not root-owned and not group-writable-free.
    local owner
    owner="$(stat -f '%Su:%Sg:%Lp' "$PLIST_PATH")"
    [ "$owner" = "root:wheel:644" ] ||
        die "$PLIST_PATH is $owner, not root:wheel:644 -- launchd would refuse to load it"
    # bootout first so a re-run picks up the binary just installed instead of leaving the old one
    # running. Only *this* call is tolerant: "not loaded" is a fine state to boot out of.
    launchctl bootout "system/$PLIST_LABEL" >/dev/null 2>&1 || true
    launchctl bootstrap system "$PLIST_PATH" 2>&1 | sed 's/^/[launchctl] /' ||
        die "launchctl bootstrap system $PLIST_PATH failed"
    launchctl enable "system/$PLIST_LABEL" || die "launchctl enable system/$PLIST_LABEL failed"
    launchctl print "system/$PLIST_LABEL" >/dev/null 2>&1 ||
        die "$PLIST_LABEL bootstrapped but does not appear in \`launchctl print\`"
    log "LaunchDaemon $PLIST_LABEL loaded"
    install_log_rotation
}

# The agent appends to /var/log/runnervm-guest-agent.log for the life of the guest. An ephemeral
# VM never lives long enough for that to matter; a reusable or long-lived debugging guest does, and
# an unbounded log on a disk that cannot grow (macOS guests do not resize) is a real failure mode.
install_log_rotation() {
    install -d -m 0755 /etc/newsyslog.d
    cat >"$NEWSYSLOG_CONF" <<'CONF'
# logfilename                        [owner:group]  mode count size(KB) when  flags
/var/log/runnervm-guest-agent.log    root:wheel     640  5     8192     *     GJ
CONF
    chmod 0644 "$NEWSYSLOG_CONF"
    # `-n` is a dry run: it parses the file and prints what it would do, without rotating anything.
    newsyslog -nvv -f "$NEWSYSLOG_CONF" >/dev/null 2>&1 ||
        warn "newsyslog did not accept $NEWSYSLOG_CONF"
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
    verify_sha256 "$tarball" "$RUNNER_SHA256" "actions/runner tarball"
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

# --------------------------------------------------------------------------
# 8. Seal-time lockdown (STAGE=harden)
# --------------------------------------------------------------------------
# The Tart base image ships a well-known `admin`/`admin` administrator with Remote Login on. That
# is fine for a disposable build VM and unacceptable in an image cloned for untrusted CI: every
# clone would carry the same working credential, reachable on the guest's NAT address.
#
# The account is *not* deleted -- it is the first administrator and the Secure Token owner, and
# removing it breaks more than it fixes. Instead its password becomes a value nobody knows, its
# authorized keys go, and sshd is disabled persistently. RunnerVM manages the finished guest over
# vsock, so nothing here costs any capability the daemon actually uses.

# 64 characters of base64 with the shell-hostile bytes dropped, generated in the guest and never
# printed, logged or returned. Reaches `dscl` through argv, briefly visible to `ps` inside this
# throwaway build VM, which is acceptable precisely because nothing ever needs the value again.
random_password() {
    openssl rand -base64 96 | tr -d '/+=\n' | cut -c1-64
}

rotate_build_account_password() {
    local new
    new="$(random_password)"
    [ "${#new}" -ge 32 ] || die "could not generate a replacement password"
    if [ -n "$HARDEN_OLD_PASSWORD" ]; then
        # `dscl . -passwd` with the old password is the path that works on a SecureToken account
        # without prompting; `sysadminctl -resetPasswordFor` as root does not, on a FileVault or
        # SecureToken guest.
        dscl . -passwd "/Users/$HARDEN_USER" "$HARDEN_OLD_PASSWORD" "$new" ||
            die "could not rotate the password for $HARDEN_USER"
    else
        sysadminctl -resetPasswordFor "$HARDEN_USER" -newPassword "$new" 2>&1 |
            sed 's/^/[sysadminctl] /' ||
            die "could not rotate the password for $HARDEN_USER (no old password was supplied)"
    fi
    unset new
    log "rotated the password for $HARDEN_USER to a discarded random value"
}

# The proof, not the intent: the credential the host authenticated with must no longer work.
# `dscl . -authonly` is the local-directory authentication check, so this holds whether or not
# sshd is still listening.
old_password_rejected() {
    [ -n "$HARDEN_OLD_PASSWORD" ] || { echo unknown; return 0; }
    if dscl . -authonly "$HARDEN_USER" "$HARDEN_OLD_PASSWORD" >/dev/null 2>&1; then
        echo no
    else
        echo yes
    fi
}

# Sets AUTHORIZED_KEYS_REMOVED rather than printing it: `log` writes to stdout, so a command
# substitution around this would capture the log lines too.
AUTHORIZED_KEYS_REMOVED=0
remove_authorized_keys() {
    local home
    AUTHORIZED_KEYS_REMOVED=0
    while IFS= read -r home; do
        [ -n "$home" ] || continue
        case "$home" in /Users/* | /var/root) ;; *) continue ;; esac
        [ -f "$home/.ssh/authorized_keys" ] || [ -f "$home/.ssh/authorized_keys2" ] || continue
        rm -f "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2"
        AUTHORIZED_KEYS_REMOVED=$((AUTHORIZED_KEYS_REMOVED + 1))
    done <<EOF
$(dscl . -list /Users NFSHomeDirectory | awk '{print $2}')
EOF
    rm -f /etc/ssh/authorized_keys 2>/dev/null || true
    log "removed authorized_keys from $AUTHORIZED_KEYS_REMOVED home directories"
}

# `launchctl disable` writes the persistent override database, so the service stays disabled across
# reboots -- unlike `bootout`, which only affects this boot. The bootout that would actually close
# the port right now is deferred to `finish_harden`, because it kills the ssh session running this
# script.
#
# Sets SSHD_DISABLED_READBACK. The readback is advisory: `launchctl print-disabled` has spelled the
# value `true`, `disabled` and `1` across macOS releases, so an unrecognized line is reported as
# `unknown` rather than failing a correct lockdown. The authoritative proof is the cold-boot check
# in scripts/qualify-macos-image.sh, which dials TCP/22 on a clone.
SSHD_DISABLED_READBACK=unknown
disable_remote_login() {
    local line
    launchctl disable "$SSHD_SERVICE" ||
        die "could not disable $SSHD_SERVICE; the sealed image would still accept SSH"
    line="$(launchctl print-disabled system 2>/dev/null | grep -F '"com.openssh.sshd"' || true)"
    case "$line" in
    *"=> false"* | *"=> enabled"* | *"=> 0"*)
        die "$SSHD_SERVICE reads back as still enabled: $line"
        ;;
    "")
        SSHD_DISABLED_READBACK=unknown
        warn "com.openssh.sshd is not listed by launchctl print-disabled system"
        ;;
    *)
        SSHD_DISABLED_READBACK=yes
        log "$SSHD_SERVICE is disabled for every future boot"
        ;;
    esac
}

harden_guest() {
    local rejected
    rotate_build_account_password
    remove_authorized_keys
    disable_remote_login
    rejected="$(old_password_rejected)"
    [ "$rejected" != "no" ] ||
        die "the build-time password for $HARDEN_USER still authenticates after rotation"
    # Written before anything that can drop this ssh session, so the host has the evidence even if
    # the connection dies during the shutdown below.
    {
        echo "RVM-HARDEN-V1"
        echo "harden_user=$HARDEN_USER"
        echo "password_rotated=yes"
        echo "old_password_rejected=$rejected"
        echo "authorized_keys_removed=$AUTHORIZED_KEYS_REMOVED"
        echo "sshd_disabled=yes"
        echo "sshd_disabled_readback=$SSHD_DISABLED_READBACK"
        echo "remote_login_off_at=next-boot"
        echo "RVM-HARDEN-END"
    } | tee "$HARDEN_LOG"
    chmod 0644 "$HARDEN_LOG"
}

# Everything that can kill the session, detached so it cannot: remove this script (the host staged
# it outside STAGE_DIR precisely so the provisioning stage could not unlink the file bash was still
# reading, and it must not reach the sealed image), turn Remote Login off for this boot too, then
# halt gracefully. A forced `tart stop` is what the host refuses to seal after, so the guest is the
# thing that has to bring itself down cleanly.
finish_harden() {
    [ "$SHUTDOWN" = "yes" ] || return 0
    local self
    self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    log "removing $self, disabling Remote Login and halting the guest"
    nohup /bin/sh -c "rm -f '$self'
systemsetup -f -setremotelogin off >/dev/null 2>&1
sleep 3
/sbin/shutdown -h now" >/dev/null 2>&1 </dev/null &
    disown 2>/dev/null || true
}

main() {
    case "$STAGE" in
    harden)
        check_harden_inputs
        harden_guest
        finish_harden
        return 0
        ;;
    all) ;;
    *) die "STAGE must be all or harden" ;;
    esac
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
