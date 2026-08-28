#!/usr/bin/env bash
# Turn a pulled Tart macOS base VM into a RunnerVM-ready macOS image (docs/macos-guests.md, M8.3).
#
# There is no cloud-init for a macOS guest, so unlike scripts/build-ubuntu-image.sh this cannot
# drive the build from outside: the base image is provisioned once, over SSH, at build time. Clone
# the pulled base, boot it headless, push the payload in, run scripts/lib/macos-guest-provision.sh
# as root, lock the build-time SSH account down, halt, seal a metadata.json beside Tart's own
# disk.img/nvram.bin. SSH is a build-time channel only -- the finished image is managed over vsock
# by the guest agent, and the seal-time lockdown is what makes sure the *image* cannot be reached
# over SSH with the base image's well-known admin/admin credential.
#
# Output: <out>/<name>/metadata.json (+ selfcheck.txt) and the `runnerctl image import` command.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SOURCE="ghcr.io/cirruslabs/macos-tahoe-base:latest"
NAME="runnervm-macos-base"
RUNNER_VERSION="latest"
RUNNER_SHA256=""
RUNNER_URL=""
RUNNER_TARBALL=""
RUNNER_DIGEST_SOURCE=""
ALLOW_UNVERIFIED_RUNNER=0
AGENT_BINARY=""
AGENT_VERSION=""
RUNNER_SUDO="yes"
SSH_USER="admin"
SSH_PASSWORD="admin"
SSH_KEY=""
FORCE=0
IMPORT_NAME=""
OUT=""
KEEP_VM_RUNNING=0
DEBUG_SSH=0
ALLOW_DIRTY_SEAL=0
AGENT_SHA256=""
PLIST_SHA256=""
GUEST_SCRIPT_SHA256=""
HARDEN_REPORT=""
GRACEFUL_SHUTDOWN=0

TART_HOME="${TART_HOME:-$HOME/.tart}"
STAGE_DIR="/tmp/rvm-provision"
GUEST_SCRIPT_REMOTE="/tmp/rvm-provision.sh"
GUEST_PASSWORD_REMOTE="/tmp/rvm-harden-pw"
PLIST_SOURCE=""
PROVISION_TIMEOUT="${RVM_PROVISION_TIMEOUT:-3600}"

GUEST_IP=""
TART_PID=""
WORK=""
SELFCHECK=""
VIRTUAL_BYTES=0
CREATED_AT=""
GUEST_PRODUCT_VERSION=""
PROVISIONED=0

usage() {
    cat <<'USAGE'
usage: provision-macos-tart.sh [options]

Source and target VM:
  --source <ref>           Pulled Tart base image (default: ghcr.io/cirruslabs/macos-tahoe-base:latest).
  --name <name>            Local Tart VM to create (default: runnervm-macos-base).
  --force                  Delete an existing --name VM first. The only VM this script ever deletes.
  --keep-vm-running        Do not halt the guest, do not lock the SSH account down, and do not
                           seal. disk.img is inconsistent while the guest runs: for debugging only.
  --debug-ssh              Keep the base image's SSH access and its admin password in the sealed
                           image. Off by default; the image is then a debugging artifact, and its
                           metadata records capabilities.ssh: true.
  --allow-dirty-seal       Seal even when the guest had to be force-stopped. A forced stop leaves
                           APFS merely crash-consistent, so the default is to fail the build.

actions/runner (resolved and verified on the host, like build-ubuntu-image.sh):
  --runner-version <v>     Version, or "latest" (default: latest).
  --runner-sha256 <hex>    Pin the osx-arm64 tarball; must agree with GitHub's release asset digest.
  --allow-unverified-runner
                           Trust the host's own download hash when the release exposes no digest.

Guest agent:
  --agent-binary <path>    Prebuilt darwin/arm64 agent (default: GuestAgent/bin/darwin-arm64/,
                           built with `make -C GuestAgent build-darwin` when absent).

Guest configuration:
  --runner-sudo yes|no     Passwordless sudo for the runner account (default: yes).

SSH into the base VM (build-time only; Tart base images ship admin/admin):
  --ssh-user <name>        Default: admin.
  --ssh-password <pw>      Default: admin. Driven by /usr/bin/expect, since macOS has no sshpass.
  --ssh-key <path>         Use key authentication instead of a password.

Output:
  --out <dir>              Where the runner tarball is cached and metadata.json is written
                           (default: ~/Library/Caches/runnervm/macos-provision).
  --import <name>          Run `runnerctl image import` afterwards under this image name.

Environment: TART_HOME, RUNNERCTL, RVM_IP_TIMEOUT, RVM_SSH_TIMEOUT, RVM_PROVISION_TIMEOUT,
RVM_SHUTDOWN_TIMEOUT, RVM_RELEASE_JSON_FILE (test seam for the GitHub release JSON).
USAGE
}

log()  { printf '[macos-provision %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[macos-provision] warning: %s\n' "$*" >&2; }
die()  { printf '[macos-provision] error: %s\n' "$*" >&2; exit 1; }

# Tart lifecycle + the expect/ssh transport. Sourced before the argument parsing below so a test
# that sources this file gets both halves.
# shellcheck source=SCRIPTDIR/lib/macos-provision-vm.sh
# shellcheck disable=SC1091 # dynamic path; run shellcheck -x to actually follow it
source "$REPO_ROOT/scripts/lib/macos-provision-vm.sh"

# shellcheck disable=SC2034 # SSH_PASSWORD and FORCE are read by write_expect_helper/clone_vm in
# scripts/lib/macos-provision-vm.sh, which a per-file shellcheck pass cannot see.
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
        --source) SOURCE="$2"; shift 2 ;;
        --name) NAME="$2"; shift 2 ;;
        --runner-version) RUNNER_VERSION="$2"; shift 2 ;;
        --runner-sha256) RUNNER_SHA256="$2"; shift 2 ;;
        --allow-unverified-runner) ALLOW_UNVERIFIED_RUNNER=1; shift ;;
        --agent-binary) AGENT_BINARY="$2"; shift 2 ;;
        --runner-sudo) RUNNER_SUDO="$2"; shift 2 ;;
        --ssh-user) SSH_USER="$2"; shift 2 ;;
        --ssh-password) SSH_PASSWORD="$2"; shift 2 ;;
        --ssh-key) SSH_KEY="$2"; shift 2 ;;
        --force) FORCE=1; shift ;;
        --import) IMPORT_NAME="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --keep-vm-running) KEEP_VM_RUNNING=1; shift ;;
        --debug-ssh) DEBUG_SSH=1; shift ;;
        --allow-dirty-seal) ALLOW_DIRTY_SEAL=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
        esac
    done
    OUT="${OUT:-$HOME/Library/Caches/runnervm/macos-provision}"
    case "$RUNNER_SUDO" in yes | no) ;; *) die "--runner-sudo must be yes or no" ;; esac
    [ -n "$NAME" ] || die "--name must not be empty"
    [ -z "$RUNNER_SHA256" ] || expect_hex64 --runner-sha256 "$RUNNER_SHA256"
}

expect_hex64() {
    [[ "$2" =~ ^[0-9a-f]{64}$ ]] || die "$1 must be 64 lowercase hex characters, got: $2"
}

sha256_hex() { shasum -a 256 "$1" | awk '{print $1}'; }

# Single-quote a value for a remote /bin/sh command line.
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

check_preconditions() {
    local tool
    for tool in tart jq shasum curl awk ssh scp nc; do
        command -v "$tool" >/dev/null 2>&1 || die "required tool not on PATH: $tool"
    done
    if [ -n "$SSH_KEY" ]; then
        [ -f "$SSH_KEY" ] || die "--ssh-key not found: $SSH_KEY"
    else
        command -v expect >/dev/null 2>&1 || die \
            "password auth needs /usr/bin/expect (macOS ships no sshpass); pass --ssh-key instead"
    fi
    PLIST_SOURCE="$REPO_ROOT/GuestAgent/packaging/launchd/com.runnervm.guest-agent.plist"
    [ -f "$PLIST_SOURCE" ] || die "LaunchDaemon plist missing from the tree"
    if [ "$DEBUG_SSH" -eq 0 ] && [ -z "$SSH_KEY" ] && [ -z "$SSH_PASSWORD" ]; then
        die "the seal-time lockdown needs the build account's password to rotate and to prove the
old one no longer authenticates; pass --ssh-password, or --debug-ssh to skip the lockdown"
    fi
    vm_exists "$SOURCE" || die "source image not in \`tart list\`: $SOURCE
run: tart pull $SOURCE"
}

# --------------------------------------------------------------------------
# Guest agent
# --------------------------------------------------------------------------
resolve_guest_agent() {
    if [ -z "$AGENT_BINARY" ]; then
        AGENT_BINARY="$REPO_ROOT/GuestAgent/bin/darwin-arm64/runnervm-guest-agent"
        if [ ! -f "$AGENT_BINARY" ]; then
            log "building the guest agent (darwin/arm64)"
            make -C "$REPO_ROOT/GuestAgent" build-darwin >/dev/null
        fi
    fi
    [ -f "$AGENT_BINARY" ] || die "guest agent binary not found: $AGENT_BINARY"
    # The same provenance string build-ubuntu-image.sh seals, so a macOS and a Linux image built
    # from one tree report the same guestAgentVersion.
    AGENT_VERSION="$(git -C "$REPO_ROOT" describe --tags --always --dirty 2>/dev/null || echo dev)"
    log "guest agent: $AGENT_BINARY ($AGENT_VERSION, sha256 $(sha256_hex "$AGENT_BINARY" | cut -c1-16))"
}

# The payload manifest. `actions/runner` already gets this treatment against GitHub's own release
# digest; these are RunnerVM's own files, hashed on the host, verified by the host after the copy,
# and verified a third time inside the guest before anything is installed. The SSH transport into a
# throwaway NAT VM is deliberately not authenticated (see scripts/lib/macos-provision-vm.sh), so
# the content is what carries the trust, not the channel.
hash_payload() {
    AGENT_SHA256="$(sha256_hex "$AGENT_BINARY")"
    PLIST_SHA256="$(sha256_hex "$PLIST_SOURCE")"
    GUEST_SCRIPT_SHA256="$(sha256_hex "$REPO_ROOT/scripts/lib/macos-guest-provision.sh")"
}

# Reads every staged file back through the guest's own shasum and compares. Catches a truncated
# scp, a stale file left by an earlier run, and anything that rewrote the payload between the copy
# and the run.
verify_staged_payload() {
    local expected actual
    expected="$(printf '%s  %s\n' \
        "$AGENT_SHA256" "$STAGE_DIR/runnervm-guest-agent" \
        "$PLIST_SHA256" "$STAGE_DIR/com.runnervm.guest-agent.plist" \
        "$RUNNER_SHA256" "$STAGE_DIR/$(runner_asset_name "$RUNNER_VERSION")" \
        "$GUEST_SCRIPT_SHA256" "$GUEST_SCRIPT_REMOTE")"
    # Keep only shasum lines. Without a --ssh-key this runs through expect, and the pty echoes
    # ssh's own "admin@<ip>'s password:" prompt onto stdout, which is not part of the guest's
    # answer -- comparing raw output then fails with all four digests visibly identical.
    # Dropping non-digest lines cannot mask a real mismatch: the two sorted sets still have to
    # agree line for line, so a missing or altered digest still fails.
    actual="$(guest_ssh "shasum -a 256 $(shq "$STAGE_DIR")/runnervm-guest-agent \
$(shq "$STAGE_DIR")/com.runnervm.guest-agent.plist \
$(shq "$STAGE_DIR/$(runner_asset_name "$RUNNER_VERSION")") \
$(shq "$GUEST_SCRIPT_REMOTE")" | tr -d '\r' \
        | sed -E 's/^.*[Pp]assword: *//' | grep -E '^[0-9a-f]{64}  ' || true)"
    [ "$(printf '%s\n' "$actual" | sort)" = "$(printf '%s\n' "$expected" | sort)" ] || die \
        "the staged payload does not hash to what this host sent:
expected:
$expected
in the guest:
$actual"
    log "staged payload verified (4 files)"
}

# --------------------------------------------------------------------------
# actions/runner: resolved, pinned and verified on the host (mirrors build-ubuntu-image.sh; the
# only difference is the asset -- osx-arm64 instead of linux-arm64)
# --------------------------------------------------------------------------
runner_asset_name() { printf 'actions-runner-osx-arm64-%s.tar.gz' "$1"; }

runner_asset_url() {
    printf 'https://github.com/actions/runner/releases/download/v%s/%s' \
        "$1" "$(runner_asset_name "$1")"
}

latest_runner_version() {
    local resolved=""
    if command -v gh >/dev/null 2>&1; then
        resolved="$(gh api repos/actions/runner/releases/latest --jq .tag_name 2>/dev/null || true)"
    fi
    if [ -z "$resolved" ]; then
        resolved="$(curl -sSfL --max-time 30 \
            https://api.github.com/repos/actions/runner/releases/latest |
            sed -n 's/.*"tag_name" *: *"\([^"]*\)".*/\1/p' | head -1)"
    fi
    printf '%s' "${resolved#v}"
}

# RVM_RELEASE_JSON_FILE lets tests substitute a fixture -- the same seam name
# build-ubuntu-image.sh uses, so both test files can stub it identically.
fetch_release_json() {
    local version="$1" api_path token
    if [ -n "${RVM_RELEASE_JSON_FILE:-}" ]; then
        cat "$RVM_RELEASE_JSON_FILE"
        return 0
    fi
    api_path="repos/actions/runner/releases/tags/v$version"
    if command -v gh >/dev/null 2>&1 && gh api "$api_path" 2>/dev/null; then
        return 0
    fi
    token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    if [ -n "$token" ]; then
        curl -sSfL --max-time 30 -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" -H "Authorization: Bearer $token" \
            "https://api.github.com/$api_path"
    else
        curl -sSfL --max-time 30 -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" "https://api.github.com/$api_path"
    fi
}

# GitHub's own digest for the osx-arm64 asset ("sha256:<hex>"), or nothing plus rc 1.
resolve_runner_digest() {
    local version="$1" json digest
    json="$(fetch_release_json "$version")" || return 1
    digest="$(printf '%s' "$json" | jq -r --arg name "$(runner_asset_name "$version")" \
        '.assets[]? | select(.name == $name) | .digest // empty' 2>/dev/null)" || return 1
    [ -n "$digest" ] || return 1
    digest="${digest#sha256:}"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "$digest"
}

# Which digest this run trusts: --runner-sha256, else GitHub's own release asset metadata, else
# -- only with --allow-unverified-runner -- the host's own download hash.
select_runner_digest() {
    local asset_digest=""
    asset_digest="$(resolve_runner_digest "$RUNNER_VERSION")" || asset_digest=""
    if [ -n "$RUNNER_SHA256" ]; then
        if [ -n "$asset_digest" ] && [ "$asset_digest" != "$RUNNER_SHA256" ]; then
            die "runner digest mismatch for v$RUNNER_VERSION: --runner-sha256 $RUNNER_SHA256 \
disagrees with GitHub's release asset digest $asset_digest -- refusing to silently prefer either"
        fi
        RUNNER_DIGEST_SOURCE="operator"
        return 0
    fi
    if [ -n "$asset_digest" ]; then
        RUNNER_SHA256="$asset_digest"
        RUNNER_DIGEST_SOURCE="github-release-asset"
        log "runner digest from GitHub release asset metadata: $RUNNER_SHA256"
        return 0
    fi
    [ "$ALLOW_UNVERIFIED_RUNNER" -eq 1 ] || die \
        "could not read a release asset digest for actions/runner v$RUNNER_VERSION: pass
--runner-sha256 <hex> to pin it, or --allow-unverified-runner to hash whatever the host downloads"
    RUNNER_DIGEST_SOURCE="download"
    log "!!! WARNING: --allow-unverified-runner: no GitHub asset digest for v$RUNNER_VERSION"
}

resolve_runner() {
    if [ "$RUNNER_VERSION" = "latest" ]; then
        log "resolving the latest actions/runner release on the host"
        RUNNER_VERSION="$(latest_runner_version)"
        [ -n "$RUNNER_VERSION" ] ||
            die "could not resolve the latest actions/runner release; pass --runner-version <v>"
    fi
    RUNNER_VERSION="${RUNNER_VERSION#v}"
    RUNNER_URL="$(runner_asset_url "$RUNNER_VERSION")"
    select_runner_digest
    RUNNER_TARBALL="$OUT/downloads/$(runner_asset_name "$RUNNER_VERSION")"
    if [ ! -f "$RUNNER_TARBALL" ]; then
        log "downloading $RUNNER_URL"
        mkdir -p "$(dirname "$RUNNER_TARBALL")"
        # Atomic: an interrupted curl leaves a .part the next run overwrites, never a truncated
        # file that would then be hashed and cached under a name it does not have.
        curl -fL --retry 5 --retry-delay 3 --max-time 3600 -o "$RUNNER_TARBALL.part" "$RUNNER_URL"
        mv -f "$RUNNER_TARBALL.part" "$RUNNER_TARBALL"
    fi
    local actual
    actual="$(sha256_hex "$RUNNER_TARBALL")"
    if [ -n "$RUNNER_SHA256" ]; then
        [ "$actual" = "$RUNNER_SHA256" ] ||
            die "runner tarball sha256 mismatch: expected $RUNNER_SHA256, got $actual"
    else
        RUNNER_SHA256="$actual"
        log "!!! WARNING: recording observed runner sha256 $RUNNER_SHA256 (unverified against GitHub)"
    fi
    log "actions/runner $RUNNER_VERSION sha256 $RUNNER_SHA256 (source: $RUNNER_DIGEST_SOURCE)"
}

# --------------------------------------------------------------------------
# Provisioning
# --------------------------------------------------------------------------
stage_payload() {
    log "staging the payload in $STAGE_DIR"
    guest_ssh "rm -rf $(shq "$STAGE_DIR") && mkdir -p $(shq "$STAGE_DIR") && chmod 0755 $(shq "$STAGE_DIR")"
    guest_scp "$AGENT_BINARY" "$SSH_USER@$GUEST_IP:$STAGE_DIR/runnervm-guest-agent"
    guest_scp "$PLIST_SOURCE" \
        "$SSH_USER@$GUEST_IP:$STAGE_DIR/com.runnervm.guest-agent.plist"
    guest_scp "$RUNNER_TARBALL" \
        "$SSH_USER@$GUEST_IP:$STAGE_DIR/$(runner_asset_name "$RUNNER_VERSION")"
    # Deliberately outside STAGE_DIR: the guest script removes that directory as its last act and
    # must not unlink the file bash is still reading.
    guest_scp "$REPO_ROOT/scripts/lib/macos-guest-provision.sh" \
        "$SSH_USER@$GUEST_IP:$GUEST_SCRIPT_REMOTE"
    # World-readable staging: the unprivileged runner account has to read the tarball it unpacks,
    # and /Users/<admin> is not reliably traversable by another user.
    guest_ssh "chmod 0644 $(shq "$STAGE_DIR")/* && chmod 0755 $(shq "$GUEST_SCRIPT_REMOTE")"
    verify_staged_payload
}

run_guest_provisioning() {
    local remote
    # SHUTDOWN=no: the halt is issued separately so this session's exit status and the
    # self-check block both survive the guest going down.
    remote="sudo -H env STAGE_DIR=$(shq "$STAGE_DIR") RUNNER_VERSION=$(shq "$RUNNER_VERSION")"
    remote="$remote RUNNER_SHA256=$(shq "$RUNNER_SHA256") RUNNER_SUDO=$(shq "$RUNNER_SUDO")"
    remote="$remote AGENT_VERSION=$(shq "$AGENT_VERSION") IMAGE_NAME=$(shq "$NAME") SHUTDOWN=no"
    remote="$remote STAGE=all AGENT_SHA256=$(shq "$AGENT_SHA256") PLIST_SHA256=$(shq "$PLIST_SHA256")"
    remote="$remote bash $(shq "$GUEST_SCRIPT_REMOTE")"
    log "running the in-guest provisioner (installs Command Line Tools if absent; minutes)"
    SELFCHECK="$OUT/$NAME/selfcheck.txt"
    mkdir -p "$(dirname "$SELFCHECK")"
    # expect must be allowed the whole provisioning window, not its 600s default.
    export RVM_EXPECT_TIMEOUT="$PROVISION_TIMEOUT"
    guest_ssh "$remote" 2>&1 | tee "$SELFCHECK.raw"
    unset RVM_EXPECT_TIMEOUT
    # expect runs ssh on a pty, so lines arrive CRLF-terminated: strip the CRs *before* matching
    # the block delimiters, or the anchored range never matches.
    tr -d '\r' <"$SELFCHECK.raw" |
        sed -n '/^RVM-SELFCHECK-V1$/,/^RVM-SELFCHECK-END$/p' >"$SELFCHECK"
    [ -s "$SELFCHECK" ] || die "the guest printed no RVM-SELFCHECK block; see $SELFCHECK.raw"
    PROVISIONED=1
    check_selfcheck
}

# The guest script lives outside STAGE_DIR (which the guest deletes itself), so something has to
# keep it out of the sealed image. Not here, though: the lockdown stage runs the same file in a
# second ssh session, so on the normal path the guest removes it from its own detached shutdown
# tail. This is the `--debug-ssh` path, where there is no second stage.
remove_guest_script() {
    guest_ssh "sudo rm -f $(shq "$GUEST_SCRIPT_REMOTE")" ||
        warn "could not remove $GUEST_SCRIPT_REMOTE"
}

# Pure: value of key $2 in self-check file $1. Empty when the key is absent.
selfcheck_value() {
    sed -n "s/^$2=//p" "$1" | head -1
}

check_selfcheck() {
    local uid helper git_version loaded build
    GUEST_PRODUCT_VERSION="$(selfcheck_value "$SELFCHECK" sw_vers_product_version)"
    uid="$(selfcheck_value "$SELFCHECK" runner_uid)"
    helper="$(selfcheck_value "$SELFCHECK" credential_helper)"
    git_version="$(selfcheck_value "$SELFCHECK" git_version)"
    loaded="$(selfcheck_value "$SELFCHECK" launchd_loaded)"
    build="$(selfcheck_value "$SELFCHECK" sw_vers_build_version)"
    [ -n "$uid" ] || die "self-check reported no runner_uid"
    [ -n "$git_version" ] || die "self-check reported no git_version (Command Line Tools missing?)"
    # The one setting a macOS runner must not get wrong (docs/macos-guests.md): a Keychain-backed
    # helper on a headless guest blocks forever with no prompt anyone can answer.
    [ "$helper" = "<empty>" ] || die \
        "git credential.helper for the runner account is '$helper', not the required empty override"
    # Fatal, not a warning. "the agent cannot connect" is expected during provisioning (tart
    # attaches no virtio-socket device); "the LaunchDaemon did not load" means the one thing that
    # has to work on the first cold boot under RunnerVM is broken, and the image would look perfect
    # right up until a job was waiting on it.
    [ "$loaded" = "yes" ] || die \
        "the guest agent LaunchDaemon is not loaded; the image would boot with no control channel"
    [ -n "$GUEST_PRODUCT_VERSION" ] || warn "self-check reported no macOS product version"
    log "guest self-check: runner uid $uid, macOS $GUEST_PRODUCT_VERSION ($build), $git_version"
}

# --------------------------------------------------------------------------
# Seal-time lockdown
# --------------------------------------------------------------------------
# Runs in its own ssh session, after the self-check has been read, because it ends by disabling the
# very channel it arrives on and halting the guest. The guest writes its RVM-HARDEN-V1 block before
# any of that, so the evidence survives the session dying.
run_guest_hardening() {
    local remote
    remote="sudo -H env STAGE=harden HARDEN_USER=$(shq "$SSH_USER") SHUTDOWN=yes"
    if [ -z "$SSH_KEY" ]; then
        # Staged as a 0600 file rather than passed as an environment assignment: an `ssh
        # ... env HARDEN_OLD_PASSWORD=...` command line is visible in `ps` on *this* host, which is
        # not a throwaway VM. Same reasoning as the expect helper's password file.
        stage_old_password
        remote="$remote HARDEN_OLD_PASSWORD_FILE=$(shq "$GUEST_PASSWORD_REMOTE")"
    fi
    remote="$remote bash $(shq "$GUEST_SCRIPT_REMOTE")"
    log "locking the build-time SSH account down and halting the guest"
    HARDEN_REPORT="$OUT/$NAME/harden.txt"
    mkdir -p "$(dirname "$HARDEN_REPORT")"
    # The session may be cut short by the lockdown itself, so a non-zero status here is not by
    # itself a failure -- the parsed block below is what decides.
    guest_ssh "$remote" 2>&1 | tee "$HARDEN_REPORT.raw" || true
    tr -d '\r' <"$HARDEN_REPORT.raw" |
        sed -n '/^RVM-HARDEN-V1$/,/^RVM-HARDEN-END$/p' >"$HARDEN_REPORT"
    [ -s "$HARDEN_REPORT" ] ||
        die "the guest printed no RVM-HARDEN block; see $HARDEN_REPORT.raw"
    check_harden_report
    log "lockdown recorded in $HARDEN_REPORT"
}

# The guest reads the file once and unlinks it, so nothing is left for the seal.
stage_old_password() {
    local local_file="$WORK/harden-old-password"
    (umask 077; printf '%s' "$SSH_PASSWORD" >"$local_file")
    guest_scp "$local_file" "$SSH_USER@$GUEST_IP:$GUEST_PASSWORD_REMOTE"
    guest_ssh "chmod 600 $(shq "$GUEST_PASSWORD_REMOTE")"
    rm -f "$local_file"
}

check_harden_report() {
    local rotated rejected sshd keys
    rotated="$(selfcheck_value "$HARDEN_REPORT" password_rotated)"
    rejected="$(selfcheck_value "$HARDEN_REPORT" old_password_rejected)"
    sshd="$(selfcheck_value "$HARDEN_REPORT" sshd_disabled)"
    keys="$(selfcheck_value "$HARDEN_REPORT" authorized_keys_removed)"
    [ "$rotated" = "yes" ] || die "the guest did not rotate the $SSH_USER password"
    [ "$sshd" = "yes" ] || die "the guest did not disable com.openssh.sshd"
    case "$rejected" in
    yes) ;;
    no) die "the build-time password for $SSH_USER still authenticates after rotation" ;;
    *) warn "could not prove the old $SSH_USER password is rejected (key auth); \
scripts/qualify-macos-image.sh dials TCP/22 on a cold-booted clone instead" ;;
    esac
    log "lockdown: password rotated, old credential rejected=$rejected, sshd disabled, \
authorized_keys cleared from $keys home directories"
}

# --------------------------------------------------------------------------
# Sealing: metadata.json beside Tart's own disk.img/nvram.bin
# --------------------------------------------------------------------------

# Apple Virtualization boots the raw disk RunnerVM imports. Tart's newer "asif" container is a
# different format entirely, so refuse it here rather than importing bytes nothing can boot.
require_raw_disk_format() {
    local config="$1" format
    [ -f "$config" ] || die "tart config.json not found: $config"
    format="$(jq -r '.diskFormat // "raw"' "$config")"
    [ "$format" = "raw" ] || die "VM disk format is '$format', not raw: re-create the VM with a raw
disk (RunnerVM imports a raw disk image; tart's asif container cannot be imported)"
}

# Renders <dest> from a tart config.json plus the globals resolved above, in the shape
# Sources/RunnerCore/Models/ImageMetadata.swift decodes. Split out so
# scripts/tests/provision-macos-tart-test.sh can render it from a fixture with no VM.
write_metadata() {
    local config="$1" dest="$2" hardware_model min_cpu min_mem
    require_raw_disk_format "$config"
    hardware_model="$(jq -r '.hardwareModel // .platform.hardwareModel // empty' "$config")"
    [ -n "$hardware_model" ] || die \
        "tart config.json has no hardwareModel: $config (a macOS image cannot be imported without one)"
    # 0 means "the source never stated one"; ImageMetadata leaves those nil so a profile is
    # refused only when there is a real figure to compare against.
    min_cpu="$(jq -r '.cpuCountMin // 0' "$config")"
    min_mem="$(jq -r '.memorySizeMin // 0' "$config")"
    # Mandatory since the admission check stopped tolerating their absence: without them the first
    # real compatibility failure would land inside a worker, after a clone and a boot, as a bare
    # `VZVirtualMachineConfiguration validation failed`.
    { [ "$min_cpu" -gt 0 ] && [ "$min_mem" -gt 0 ]; } || die \
        "tart config.json states no cpuCountMin/memorySizeMin ($config); RunnerVM refuses a macOS
image that cannot say what it needs to boot -- add the values the source VM reports and re-run"
    mkdir -p "$(dirname "$dest")"
    jq -n --sort-keys \
        --argjson virtualBytes "$VIRTUAL_BYTES" \
        --argjson minCPU "$min_cpu" \
        --argjson minMem "$min_mem" \
        --arg hardwareModel "$hardware_model" \
        --arg sourceVersion "$GUEST_PRODUCT_VERSION" \
        --arg runnerVersion "$RUNNER_VERSION" \
        --arg agentVersion "$AGENT_VERSION" \
        --arg createdAt "$CREATED_AT" \
        --arg tartImage "$SOURCE" \
        --argjson ssh "$([ "$DEBUG_SSH" -eq 1 ] && echo true || echo false)" \
        '{
          schemaVersion: 1,
          os: "macos",
          architecture: "arm64",
          diskFormat: "raw",
          virtualDiskSizeBytes: $virtualBytes,
          runnerVersion: $runnerVersion,
          guestAgentVersion: $agentVersion,
          minimumHostOS: "15.0",
          createdAt: $createdAt,
          boot: { type: "macos" },
          macos: ({ hardwareModel: $hardwareModel }
            + (if $sourceVersion == "" then {} else { sourceVersion: $sourceVersion } end)
            + (if $minCPU > 0 then { minimumCPUCount: $minCPU } else {} end)
            + (if $minMem > 0 then { minimumMemoryBytes: $minMem } else {} end)),
          capabilities: {
            docker: false, ssh: $ssh, guestAgent: true,
            labels: { "runnervm.source": "tart", "runnervm.tart.image": $tartImage }
          }
        }' >"$dest"
}

seal() {
    local dir disk metadata
    dir="$(vm_dir "$NAME")"
    disk="$dir/disk.img"
    [ -f "$disk" ] || die "no disk.img in $dir"
    [ -f "$dir/nvram.bin" ] || die "no nvram.bin in $dir"
    # The daemon overwrites this with the real file size on import; recorded so the sealed file
    # is still honest for anything reading it before then.
    VIRTUAL_BYTES="$(stat -f %z "$disk")"
    CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    metadata="$OUT/$NAME/metadata.json"
    write_metadata "$dir/config.json" "$metadata"
    log "sealed $metadata"
    printf '\nImport it with:\n\n  runnerctl image import %s \\\n    --os macos --nvram %s \\\n    --metadata %s \\\n    --name %s\n\n' \
        "$disk" "$dir/nvram.bin" "$metadata" "${IMPORT_NAME:-$NAME}"
    [ -z "$IMPORT_NAME" ] || run_import "$disk" "$dir/nvram.bin" "$metadata"
}

# A forced `tart stop` is a power cut. APFS is then merely crash-consistent, and the keychain,
# launchd state and Spotlight metadata may all have been mid-write -- fine for a disposable
# development VM, not for bytes every future CI guest is cloned from.
require_clean_shutdown() {
    [ "$GRACEFUL_SHUTDOWN" -eq 1 ] && return 0
    [ "$ALLOW_DIRTY_SEAL" -eq 1 ] || die \
        "the guest did not shut down gracefully, so disk.img is only crash-consistent: refusing to
seal it. Re-run the build, or pass --allow-dirty-seal if you are debugging and accept the risk"
    warn "--allow-dirty-seal: sealing after a forced stop; this image is a debugging artifact"
}

find_runnerctl() {
    # The order scripts/lib/live-common.sh uses, re-stated rather than sourced: that file also
    # defines log/warn/die with the e2e drivers' own prefixes and would shadow the ones above.
    if [ -n "${RUNNERCTL:-}" ]; then printf '%s' "$RUNNERCTL"; return 0; fi
    local candidate
    for candidate in "$REPO_ROOT/.build/debug/runnerctl" "$REPO_ROOT/.build/release/runnerctl"; do
        if [ -x "$candidate" ]; then printf '%s' "$candidate"; return 0; fi
    done
    command -v runnerctl 2>/dev/null || true
}

run_import() {
    local bin
    bin="$(find_runnerctl)"
    [ -n "$bin" ] || die "--import needs runnerctl (build it, or set RUNNERCTL); requires a reachable daemon"
    log "importing as '$IMPORT_NAME' with $bin"
    "$bin" image import "$1" --os macos --nvram "$2" --metadata "$3" --name "$IMPORT_NAME"
}

cleanup() {
    local rc=$?
    if [ -n "$TART_PID" ] && kill -0 "$TART_PID" 2>/dev/null; then
        if [ "$PROVISIONED" -eq 1 ] && [ "$KEEP_VM_RUNNING" -eq 1 ]; then
            log "leaving $NAME running (--keep-vm-running); stop it with: tart stop $NAME"
        else
            warn "stopping $NAME after an incomplete run"
            tart stop "$NAME" >/dev/null 2>&1 || true
            kill "$TART_PID" 2>/dev/null || true
        fi
    fi
    [ -z "$WORK" ] || rm -rf "$WORK"
    return "$rc"
}

main() {
    parse_args "$@"
    check_preconditions
    resolve_guest_agent
    resolve_runner
    hash_payload
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/rvm-macos-provision-XXXXXX")"
    chmod 700 "$WORK"
    trap cleanup EXIT
    init_ssh_opts
    write_expect_helper
    clone_vm
    start_vm
    stage_payload
    run_guest_provisioning
    if [ "$KEEP_VM_RUNNING" -eq 1 ]; then
        warn "--keep-vm-running: $NAME is still up, so disk.img is inconsistent"
        warn "nothing was sealed and the build-time SSH account was left as it is"
        warn "halt it with: tart stop $NAME"
        return 0
    fi
    if [ "$DEBUG_SSH" -eq 1 ]; then
        warn "--debug-ssh: the sealed image keeps SSH and the base image's admin credential"
        remove_guest_script
        shutdown_guest
    else
        # The guest halts itself at the end of the lockdown, so there is no session left to issue
        # `shutdown` from.
        run_guest_hardening
        wait_for_guest_down
    fi
    require_clean_shutdown
    seal
}

# Guarded so scripts/tests/provision-macos-tart-test.sh can source this file and exercise its
# pure helpers with no VM, no tart and no network.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
