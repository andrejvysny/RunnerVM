#!/usr/bin/env bash
# Turn a pulled Tart macOS base VM into a RunnerVM-ready macOS image (docs/macos-guests.md, M8.3).
#
# There is no cloud-init for a macOS guest, so unlike scripts/build-ubuntu-image.sh this cannot
# drive the build from outside: the base image is provisioned once, over SSH, at build time. Clone
# the pulled base, boot it headless, push the payload in, run scripts/lib/macos-guest-provision.sh
# as root, halt, seal a metadata.json beside Tart's own disk.img/nvram.bin. SSH is a build-time
# channel only -- the finished image is managed over vsock by the guest agent.
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

TART_HOME="${TART_HOME:-$HOME/.tart}"
STAGE_DIR="/tmp/rvm-provision"
GUEST_SCRIPT_REMOTE="/tmp/rvm-provision.sh"
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
  --keep-vm-running        Do not halt the guest afterwards. Leaves disk.img inconsistent:
                           for debugging, never for importing.

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
    [ -f "$REPO_ROOT/GuestAgent/packaging/launchd/com.runnervm.guest-agent.plist" ] ||
        die "LaunchDaemon plist missing from the tree"
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
    guest_scp "$REPO_ROOT/GuestAgent/packaging/launchd/com.runnervm.guest-agent.plist" \
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
}

run_guest_provisioning() {
    local remote
    # SHUTDOWN=no: the halt is issued separately so this session's exit status and the
    # self-check block both survive the guest going down.
    remote="sudo -H env STAGE_DIR=$(shq "$STAGE_DIR") RUNNER_VERSION=$(shq "$RUNNER_VERSION")"
    remote="$remote RUNNER_SHA256=$(shq "$RUNNER_SHA256") RUNNER_SUDO=$(shq "$RUNNER_SUDO")"
    remote="$remote AGENT_VERSION=$(shq "$AGENT_VERSION") IMAGE_NAME=$(shq "$NAME") SHUTDOWN=no"
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
    # The guest script lives outside STAGE_DIR (which it deletes itself), so the host is what
    # keeps it out of the sealed image.
    guest_ssh "sudo rm -f $(shq "$GUEST_SCRIPT_REMOTE")" || warn "could not remove $GUEST_SCRIPT_REMOTE"
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
    [ "$loaded" = "yes" ] ||
        warn "the guest agent LaunchDaemon is not loaded (RunAtLoad still applies on the next boot)"
    [ -n "$GUEST_PRODUCT_VERSION" ] || warn "self-check reported no macOS product version"
    log "guest self-check: runner uid $uid, macOS $GUEST_PRODUCT_VERSION ($build), $git_version"
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
            docker: false, ssh: true, guestAgent: true,
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
        warn "--keep-vm-running: $NAME is still up, so disk.img is inconsistent -- do not import it"
        warn "halt it with: tart stop $NAME"
    else
        shutdown_guest
    fi
    seal
}

# Guarded so scripts/tests/provision-macos-tart-test.sh can source this file and exercise its
# pure helpers with no VM, no tart and no network.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
