#!/usr/bin/env bash
# Build a RunnerVM Ubuntu 24.04 arm64 runner image (spec §18, §19, §60, §62).
#
# The whole build runs *inside* a throwaway VM driven by `vmworker run`: a copy
# of an Ubuntu cloud disk plus a read-only cloud-init NoCloud seed. The host
# never mounts the guest filesystem; it only watches serial.log, which the guest
# feeds by teeing cloud-init output to /dev/hvc0 (spec §131).
#
# Every downloaded input is pinned and checksum-verified before it reaches the
# guest, and the sealed metadata.json records the full provenance plus the
# installed package manifest the guest reports back over the console.
#
# Output: <out>/disk.img, <out>/nvram.bin, <out>/metadata.json.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_REL="scripts/build-ubuntu-image.sh"

# --------------------------------------------------------------------------
# Options
# --------------------------------------------------------------------------
BASE=""
BASE_URL=""
BASE_SHA256=""
BASE_SOURCE=""
ALLOW_UNVERIFIED_BASE=0
OUT=""
RUNNER_VERSION="latest"
RUNNER_SHA256=""
RUNNER_URL=""
RUNNER_DIGEST_SOURCE=""
ALLOW_UNVERIFIED_RUNNER=0
ALLOW_PARTIAL_PROVENANCE=0
PARTIAL_REASON=""
PACKAGE_UPGRADE="yes"
DOCKER_REPO_URL="https://download.docker.com/linux/ubuntu"
DOCKER_SUITE="noble"
DOCKER_COMPONENT="stable"
GUEST_AGENT_BIN=""
PRINT_SEED=0
DISK_GIB=16
CPUS=4
MEMORY_GIB=4
SOCKET_DIR=""
NO_SUDO=0
KEEP_BUILD_DIR=0
TIMEOUT_MIN="${BUILD_TIMEOUT_MIN:-40}"
VMWORKER="${VMWORKER:-$REPO_ROOT/.build/debug/vmworker}"
CACHE_DIR="${RUNNERVM_BUILD_CACHE:-$HOME/.cache/runnervm-build}"

usage() {
    cat <<'USAGE'
usage: build-ubuntu-image.sh --base <raw.img> --out <dir> [options]

Inputs (every download is pinned and verified before the guest sees it):
  --base <path>            Raw Ubuntu 24.04 arm64 cloud disk (never modified).
  --base-url <url>         Download the base image into the cache instead; requires --base-sha256.
  --base-sha256 <hex>      Expected sha256 of the base image. Required unless --allow-unverified-base.
  --allow-unverified-base  Build from an unverified base image. Loud, and recorded as such.
  --runner-version <v>     actions/runner version, or "latest" (default: latest, resolved on the host).
  --runner-sha256 <hex>    Pin the runner tarball; must match GitHub's release asset digest,
                           if one could be read, or the build stops.
  --allow-unverified-runner
                           Trust the host's own download hash when GitHub's release asset has
                           no digest and no --runner-sha256 was given. Loud, and recorded as such.
  --package-upgrade yes|no Run a full apt upgrade during the build (default: yes).
  --docker-suite <name>    Docker apt repository suite (default: noble).
  --guest-agent <path>     Use a prebuilt linux/arm64 guest agent instead of building one.

Output and builder VM:
  --out <dir>              Directory to write disk.img/nvram.bin/metadata.json into.
  --disk-gib <n>           Virtual size of the built image (default: 16).
  --cpus <n>               Builder VM vCPUs (default: 4).
  --memory-gib <n>         Builder VM memory (default: 4).
  --socket-dir <dir>       Where vmworker publishes its sockets (default: /tmp/rvm-build-<id>).
  --no-sudo                Do not grant the runner account passwordless sudo.
  --keep-build-dir         Keep the builder VM directory (disk, seed, serial.log) after sealing.
  --print-seed             Resolve every input, render the cloud-init user-data, print both, exit.
  --allow-partial-provenance
                           Seal the image even if the guest's RVM-MANIFEST block could not be
                           recovered from serial.log. Loud, and recorded as such.

Environment: VMWORKER (path to a signed vmworker), BUILD_TIMEOUT_MIN (default 40),
RUNNERVM_BUILD_CACHE (download cache, default ~/.cache/runnervm-build).
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
    --base) BASE="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --base-sha256) BASE_SHA256="$2"; shift 2 ;;
    --allow-unverified-base) ALLOW_UNVERIFIED_BASE=1; shift ;;
    --out) OUT="$2"; shift 2 ;;
    --runner-version) RUNNER_VERSION="$2"; shift 2 ;;
    --runner-sha256) RUNNER_SHA256="$2"; shift 2 ;;
    --allow-unverified-runner) ALLOW_UNVERIFIED_RUNNER=1; shift ;;
    --package-upgrade) PACKAGE_UPGRADE="$2"; shift 2 ;;
    --docker-suite) DOCKER_SUITE="$2"; shift 2 ;;
    --guest-agent) GUEST_AGENT_BIN="$2"; shift 2 ;;
    --print-seed) PRINT_SEED=1; shift ;;
    --disk-gib) DISK_GIB="$2"; shift 2 ;;
    --cpus) CPUS="$2"; shift 2 ;;
    --memory-gib) MEMORY_GIB="$2"; shift 2 ;;
    --socket-dir) SOCKET_DIR="$2"; shift 2 ;;
    --no-sudo) NO_SUDO=1; shift ;;
    --keep-build-dir) KEEP_BUILD_DIR=1; shift ;;
    --allow-partial-provenance) ALLOW_PARTIAL_PROVENANCE=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

log() { printf '[build %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { echo "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
# Option validation
# --------------------------------------------------------------------------
check_options() {
    [ -n "$BASE" ] || [ -n "$BASE_URL" ] || die "--base or --base-url is required"
    [ -n "$OUT" ] || [ "$PRINT_SEED" -eq 1 ] || die "--out is required"
    case "$PACKAGE_UPGRADE" in
    yes | no) ;;
    *) die "--package-upgrade must be yes or no" ;;
    esac
    [ -z "$BASE_SHA256" ] || expect_hex64 --base-sha256 "$BASE_SHA256"
    [ -z "$RUNNER_SHA256" ] || expect_hex64 --runner-sha256 "$RUNNER_SHA256"
    for tool in shasum curl jq awk; do
        command -v "$tool" >/dev/null 2>&1 || die "required tool not on PATH: $tool"
    done
    [ "$PRINT_SEED" -eq 1 ] && return 0
    [ -x "$VMWORKER" ] || die "vmworker not found or not executable: $VMWORKER
run scripts/sign-dev.sh first"
    codesign -d --entitlements - "$VMWORKER" 2>&1 |
        grep -q com.apple.security.virtualization ||
        die "vmworker lacks the virtualization entitlement; run scripts/sign-dev.sh"
}

expect_hex64() {
    [[ "$2" =~ ^[0-9a-f]{64}$ ]] || die "$1 must be 64 lowercase hex characters, got: $2"
}

sha256_hex() { shasum -a 256 "$1" | awk '{print $1}'; }

verify_sha256() {
    local path="$1" expected="$2" label="$3" actual
    actual="$(sha256_hex "$path")"
    [ "$actual" = "$expected" ] ||
        die "$label sha256 mismatch: expected $expected, got $actual"
    log "$label sha256 verified ($expected)"
}

# Atomic: a killed curl leaves a .part file the next run overwrites, never a
# truncated file that would then be hashed and cached under a name it isn't.
download_to() {
    local url="$1" dest="$2"
    mkdir -p "$(dirname "$dest")"
    curl -fL --retry 5 --retry-delay 3 --max-time 3600 -o "$dest.part" "$url"
    mv -f "$dest.part" "$dest"
}

# --------------------------------------------------------------------------
# 1. Base image: fetched if asked, verified before anything else runs
# --------------------------------------------------------------------------
resolve_base() {
    if [ -n "$BASE_URL" ]; then
        [ -n "$BASE_SHA256" ] || die "--base-url requires --base-sha256"
        BASE="$CACHE_DIR/base-$BASE_SHA256.img"
        BASE_SOURCE="$BASE_URL"
        if [ -f "$BASE" ]; then
            log "base image already cached: $BASE"
        else
            log "downloading base image from $BASE_URL"
            download_to "$BASE_URL" "$BASE"
        fi
    else
        BASE_SOURCE="$BASE"
    fi
    [ -f "$BASE" ] || die "base image not found: $BASE"
    require_partition_table "$BASE"
    if [ -n "$BASE_SHA256" ]; then
        verify_sha256 "$BASE" "$BASE_SHA256" "base image"
        return 0
    fi
    [ "$ALLOW_UNVERIFIED_BASE" -eq 1 ] || die \
        "refusing to build from an unverified base image: pass --base-sha256 <hex>
(or --allow-unverified-base to accept whatever $BASE happens to contain)"
    log "!!! WARNING: --allow-unverified-base: $BASE is NOT checked against a known digest"
    log "!!! the image this build produces is only as trustworthy as that file"
    BASE_SHA256="$(sha256_hex "$BASE")"
    log "recording observed base sha256 $BASE_SHA256"
}

# EFI can only boot a partitioned disk. Ubuntu's `*-cloudimg-arm64.tar.gz` unpacks to a bare ext4
# root filesystem (no GPT, no ESP) and a qcow2 `.img` is not raw either; both make the guest stop
# within a second of `running` with nothing on serial. Catch that here instead of after a download.
require_partition_table() {
    local base="$1" magic sector1
    magic="$(head -c 3 "$base")"
    [ "$magic" != "QFI" ] || die "base image $base is qcow2; convert it to raw first (docs/images.md)"
    sector1="$(tail -c +513 "$base" | head -c 8)"
    [ "$sector1" = "EFI PART" ] || die \
        "base image $base has no GPT (sector 1 is not 'EFI PART'); it must be a raw whole-disk image
with an EFI system partition -- the Ubuntu cloud .tar.gz is a bare rootfs and cannot boot"
}

# --------------------------------------------------------------------------
# 2. Guest agent (linux/arm64)
# --------------------------------------------------------------------------
resolve_guest_agent() {
    if [ -n "$GUEST_AGENT_BIN" ]; then
        [ -f "$GUEST_AGENT_BIN" ] || die "guest agent not found: $GUEST_AGENT_BIN"
        AGENT_BIN="$GUEST_AGENT_BIN"
        log "using prebuilt guest agent: $AGENT_BIN"
    else
        log "building guest agent (linux/arm64)"
        make -C "$REPO_ROOT/GuestAgent" build-linux >/dev/null
        AGENT_BIN="$REPO_ROOT/GuestAgent/bin/linux-arm64/runnervm-guest-agent"
        [ -f "$AGENT_BIN" ] || die "guest agent build produced nothing"
    fi
    AGENT_SHA256="$(sha256_hex "$AGENT_BIN")"
    AGENT_VERSION="$(git -C "$REPO_ROOT" describe --tags --always --dirty 2>/dev/null || echo dev)"
    AGENT_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
    log "guest agent $AGENT_VERSION (commit ${AGENT_COMMIT:0:12}, sha256 ${AGENT_SHA256:0:16})"
}

# --------------------------------------------------------------------------
# 3. actions/runner: resolved and hashed on the host, never "latest" in the guest
# --------------------------------------------------------------------------
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

# Prints the release JSON for `v<version>` of actions/runner. RVM_RELEASE_JSON_FILE
# lets tests substitute a fixture, so this never has to touch the network under test.
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
        curl -sSfL --max-time 30 \
            -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
            -H "Authorization: Bearer $token" "https://api.github.com/$api_path"
    else
        curl -sSfL --max-time 30 \
            -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
            "https://api.github.com/$api_path"
    fi
}

# Resolves the sha256 GitHub itself recorded for the arm64 runner tarball asset of
# release v<version> (assets[].digest, "sha256:<hex>") -- the trust anchor, rather than
# hashing whatever an unauthenticated first download happens to contain. Prints the bare
# hex on success; prints nothing and returns 1 if the release, the asset, or its digest
# field is unavailable.
resolve_runner_digest() {
    local version="$1" json digest
    json="$(fetch_release_json "$version")" || return 1
    digest="$(printf '%s' "$json" | jq -r \
        --arg name "actions-runner-linux-arm64-$version.tar.gz" \
        '.assets[]? | select(.name == $name) | .digest // empty' 2>/dev/null)" || return 1
    [ -n "$digest" ] || return 1
    digest="${digest#sha256:}"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "$digest"
}

# Decides which digest the build trusts, in order: an operator's --runner-sha256 pin,
# then GitHub's own release asset metadata, then -- only with --allow-unverified-runner
# -- the hash of whatever the host ends up downloading. Sets RUNNER_SHA256 and
# RUNNER_DIGEST_SOURCE; RUNNER_SHA256 is left empty only in the last case, where it is
# not known until resolve_runner hashes the download itself.
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
    log "!!! WARNING: --allow-unverified-runner: no GitHub asset digest for v$RUNNER_VERSION, \
will hash the host's own download instead"
}

resolve_runner() {
    if [ "$RUNNER_VERSION" = "latest" ]; then
        log "resolving the latest actions/runner release on the host"
        RUNNER_VERSION="$(latest_runner_version)"
        [ -n "$RUNNER_VERSION" ] ||
            die "could not resolve the latest actions/runner release; pass --runner-version <v>"
    fi
    RUNNER_VERSION="${RUNNER_VERSION#v}"
    RUNNER_URL="https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-linux-arm64-$RUNNER_VERSION.tar.gz"
    select_runner_digest

    local cached="$CACHE_DIR/actions-runner-linux-arm64-$RUNNER_VERSION.tar.gz"
    if [ ! -f "$cached" ] && [ "$PRINT_SEED" -eq 1 ]; then
        [ -n "$RUNNER_SHA256" ] || die \
            "--print-seed cannot hash an unverified runner tarball without downloading it:
run a real build once so $cached is cached, or pin --runner-sha256"
        log "print-seed: trusting the resolved runner digest for $RUNNER_VERSION ($RUNNER_DIGEST_SOURCE), nothing downloaded"
        return 0
    fi
    if [ ! -f "$cached" ]; then
        log "downloading $RUNNER_URL"
        download_to "$RUNNER_URL" "$cached"
    fi
    if [ -n "$RUNNER_SHA256" ]; then
        verify_sha256 "$cached" "$RUNNER_SHA256" "runner tarball"
    else
        RUNNER_SHA256="$(sha256_hex "$cached")"
        log "!!! WARNING: recording observed runner sha256 $RUNNER_SHA256 (download, unverified against GitHub)"
    fi
    log "actions runner $RUNNER_VERSION sha256 $RUNNER_SHA256 (source: $RUNNER_DIGEST_SOURCE)"
}

# --------------------------------------------------------------------------
# 4. Builder VM directory
# --------------------------------------------------------------------------
prepare_build_dir() {
    BUILD_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    if [ -n "$OUT" ]; then
        mkdir -p "$OUT"
        OUT="$(cd "$OUT" && pwd)"
        BUILD_DIR="$OUT/.build/$BUILD_ID"
    else
        BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rvm-seed-XXXXXX")"
    fi
    mkdir -p "$BUILD_DIR"
    # AF_UNIX paths cap at 104 bytes, which a build directory nested under a long
    # --out easily blows past, so the sockets live in a short path by default.
    [ -n "$SOCKET_DIR" ] || SOCKET_DIR="/tmp/rvm-build-${BUILD_ID:0:8}"
    log "build dir: $BUILD_DIR"
}

stage_builder_disk() {
    mkdir -p "$SOCKET_DIR"
    SOCKET_DIR="$(cd "$SOCKET_DIR" && pwd)"
    # clonefile(2): a copy-on-write clone, so the base image is never touched and the
    # copy costs no space until the guest writes to it.
    cp -c "$BASE" "$BUILD_DIR/disk.img" 2>/dev/null || cp "$BASE" "$BUILD_DIR/disk.img"
    truncate -s "${DISK_GIB}G" "$BUILD_DIR/disk.img"
    "$VMWORKER" prepare-nvram "$BUILD_DIR/nvram.bin" >/dev/null
    local mac
    mac="$(printf '02:%02x:%02x:%02x:%02x:%02x' \
        $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))"
    # Mirrors VirtualizationCore.VMInstanceSpec; vmworker decodes it with .iso8601.
    cat >"$BUILD_DIR/spec.json" <<SPEC
{
  "cpuCount": $CPUS,
  "diskBytes": $((DISK_GIB * 1024 * 1024 * 1024)),
  "id": "$BUILD_ID",
  "imageDigest": "sha256:build",
  "macAddress": "$mac",
  "memoryBytes": $((MEMORY_GIB * 1024 * 1024 * 1024)),
  "os": "linux",
  "serialConsole": true
}
SPEC
}

# --------------------------------------------------------------------------
# 5. cloud-init NoCloud seed
# --------------------------------------------------------------------------
stage_seed_files() {
    SEED_SRC="$BUILD_DIR/seed"
    mkdir -p "$SEED_SRC/runnervm"
    cp "$AGENT_BIN" "$SEED_SRC/runnervm/guest-agent"
    cp "$REPO_ROOT/GuestAgent/packaging/systemd/runnervm-guest-agent.service" \
        "$SEED_SRC/runnervm/runnervm-guest-agent.service"
    cat >"$SEED_SRC/meta-data" <<META
instance-id: runnervm-build-$BUILD_ID
local-hostname: runnervm-build
META
}

# sed's replacement text treats \ & and the delimiter specially, so every host
# value is escaped before it is substituted into the template.
sed_escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

render_user_data() {
    local sudo_line="sudo: 'ALL=(ALL) NOPASSWD:ALL'"
    [ "$NO_SUDO" -eq 0 ] || sudo_line="sudo: false"
    local upgrade="true"
    [ "$PACKAGE_UPGRADE" = "yes" ] || upgrade="false"
    sed \
        -e "s|@RUNNER_SUDO@|$(sed_escape "$sudo_line")|g" \
        -e "s|@RUNNER_VERSION@|$(sed_escape "$RUNNER_VERSION")|g" \
        -e "s|@RUNNER_SHA256@|$(sed_escape "$RUNNER_SHA256")|g" \
        -e "s|@RUNNER_URL@|$(sed_escape "$RUNNER_URL")|g" \
        -e "s|@AGENT_VERSION@|$(sed_escape "$AGENT_VERSION")|g" \
        -e "s|@BUILT_AT@|$(sed_escape "$BUILT_AT")|g" \
        -e "s|@PACKAGE_UPGRADE@|$upgrade|g" \
        -e "s|@DOCKER_REPO_URL@|$(sed_escape "$DOCKER_REPO_URL")|g" \
        -e "s|@DOCKER_SUITE@|$(sed_escape "$DOCKER_SUITE")|g" \
        -e "s|@DOCKER_COMPONENT@|$(sed_escape "$DOCKER_COMPONENT")|g" \
        "$SEED_SRC/user-data.tmpl" >"$SEED_SRC/user-data"
    rm -f "$SEED_SRC/user-data.tmpl"
    grep -q '@[A-Z_]\{3,\}@' "$SEED_SRC/user-data" &&
        die "unsubstituted placeholder left in user-data"
    return 0
}

build_seed_image() {
    log "building NoCloud seed"
    rm -f "$BUILD_DIR/seed.iso" "$BUILD_DIR/seed.img"
    hdiutil makehybrid -quiet -iso -joliet -default-volume-name cidata \
        -o "$BUILD_DIR/seed.iso" "$SEED_SRC"
    mv "$BUILD_DIR/seed.iso" "$BUILD_DIR/seed.img"
}

# --------------------------------------------------------------------------
# 6. Builder VM
# --------------------------------------------------------------------------
shutdown_worker() {
    [ -n "$WORKER_PID" ] || return 0
    kill -0 "$WORKER_PID" 2>/dev/null || return 0
    "$VMWORKER" debug-call --socket "$WORKER_SOCK" --method worker.shutdown \
        --payload '{"reason":"stop","gracefulTimeoutMs":30000}' >/dev/null 2>&1 || true
    for _ in $(seq 1 60); do
        kill -0 "$WORKER_PID" 2>/dev/null || return 0
        sleep 1
    done
    kill -TERM "$WORKER_PID" 2>/dev/null || true
}

cleanup() {
    local code=$?
    if [ -n "$WORKER_PID" ] && kill -0 "$WORKER_PID" 2>/dev/null; then
        log "stopping builder worker (pid $WORKER_PID)"
        shutdown_worker
    fi
    return $code
}

start_worker() {
    log "starting builder VM (${CPUS} vCPU, ${MEMORY_GIB} GiB RAM, ${DISK_GIB} GiB disk)"
    "$VMWORKER" run \
        --instance "$BUILD_ID" \
        --spec "$BUILD_DIR/spec.json" \
        --socket-dir "$SOCKET_DIR" \
        --generation 1 \
        --nonce build \
        --lease-ttl-ms 86400000 \
        --orphan-idle-ms 86400000 \
        >"$WORKER_LOG" 2>&1 &
    WORKER_PID=$!
    for _ in $(seq 1 60); do
        [ -S "$WORKER_SOCK" ] && break
        kill -0 "$WORKER_PID" 2>/dev/null || {
            echo "vmworker exited early:" >&2
            tail -20 "$WORKER_LOG" >&2
            exit 1
        }
        sleep 1
    done
    [ -S "$WORKER_SOCK" ] || {
        echo "worker socket never appeared: $WORKER_SOCK" >&2
        tail -20 "$WORKER_LOG" >&2
        exit 1
    }
    log "worker socket up: $WORKER_SOCK"
}

await_guest() {
    local deadline=$((BUILD_START + TIMEOUT_MIN * 60)) state="unknown"
    while :; do
        if ! kill -0 "$WORKER_PID" 2>/dev/null; then
            state="stopped"
            break
        fi
        state="$("$VMWORKER" debug-call --socket "$WORKER_SOCK" --method vm.state 2>/dev/null |
            sed -n 's/.*"vmState" *: *"\([a-z]*\)".*/\1/p' | head -1)"
        [ -n "$state" ] || state="unknown"
        case "$state" in
        stopped | error) break ;;
        esac
        if [ "$(date +%s)" -ge "$deadline" ]; then
            echo "timeout after ${TIMEOUT_MIN} min; vmState=$state" >&2
            echo "--- tail of $SERIAL_LOG ---" >&2
            tail -80 "$SERIAL_LOG" >&2 || true
            exit 1
        fi
        printf '[build %s] guest %s, %sm elapsed | %s\n' \
            "$(date +%H:%M:%S)" "$state" \
            "$((($(date +%s) - BUILD_START) / 60))" \
            "$(tr -d '\r' <"$SERIAL_LOG" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-110)"
        sleep 5
    done
    printf '%s' "$state"
}

# --------------------------------------------------------------------------
# 7. Manifest + sealed metadata
# --------------------------------------------------------------------------
# Takes the *last* marker pair and keeps only base64-alphabet lines, so a noisy
# console (kernel messages interleaved mid-block) cannot corrupt the decode.
extract_manifest() {
    local serial="$1" dest="$2"
    awk '
      /RVM-MANIFEST-BEGIN/ { buf = ""; capture = 1; next }
      /RVM-MANIFEST-END/   { if (capture) last = buf; capture = 0; next }
      capture              { buf = buf $0 "\n" }
      END                  { printf "%s", last }
    ' "$serial" |
        tr -d '\r' |
        grep -E '^[A-Za-z0-9+/=]+$' |
        tr -d '\n' |
        base64 -d >"$dest" 2>/dev/null || return 1
    jq -e . "$dest" >/dev/null 2>&1 || return 1
}

# Fails closed: a build the guest never reported a usable manifest for (or reported one
# with no `packages`) has no way to know what actually landed on disk, so it must not
# seal silently. Writes the manifest (or '{}') to `dest` either way and sets the global
# PARTIAL_REASON; returns 1 -- the caller is expected to die -- unless allow_partial is 1.
check_guest_manifest() {
    local serial="$1" dest="$2" allow_partial="$3"
    PARTIAL_REASON=""
    if extract_manifest "$serial" "$dest"; then
        jq -e '.packages != null' "$dest" >/dev/null 2>&1 ||
            PARTIAL_REASON="guest manifest decoded but has no packages field"
    else
        PARTIAL_REASON="no usable RVM-MANIFEST block in $serial"
        echo '{}' >"$dest"
    fi
    [ -z "$PARTIAL_REASON" ] || [ "$allow_partial" -eq 1 ] || return 1
    return 0
}

write_metadata() {
    local guest="$1" dest="$2" upgrade="false" partial="false"
    [ "$PACKAGE_UPGRADE" != "yes" ] || upgrade="true"
    [ -z "${PARTIAL_REASON:-}" ] || partial="true"
    jq -n --sort-keys \
        --argjson virtualBytes "$VIRTUAL_BYTES" \
        --argjson packageUpgrade "$upgrade" \
        --argjson partial "$partial" \
        --arg runnerVersion "$RUNNER_VERSION" \
        --arg runnerSha "sha256:$RUNNER_SHA256" \
        --arg runnerUrl "$RUNNER_URL" \
        --arg runnerDigestSource "${RUNNER_DIGEST_SOURCE:-}" \
        --arg agentVersion "$AGENT_VERSION" \
        --arg agentCommit "$AGENT_COMMIT" \
        --arg agentSha "sha256:$AGENT_SHA256" \
        --arg baseSource "$BASE_SOURCE" \
        --arg baseSha "sha256:$BASE_SHA256" \
        --arg builderCommit "$BUILDER_COMMIT" \
        --arg script "$SCRIPT_REL" \
        --arg hostOS "$HOST_OS_VERSION" \
        --arg builtAt "$BUILT_AT" \
        --arg dockerRepo "$DOCKER_REPO_URL $DOCKER_SUITE $DOCKER_COMPONENT" \
        --arg diskSha "sha256:$DISK_SHA256" \
        --arg partialReason "${PARTIAL_REASON:-}" \
        --slurpfile guest "$guest" \
        "$(metadata_filter)" >"$dest"
}

# Shape of the sealed metadata.json (RunnerCore.ImageMetadata + .provenance). Kept out of
# write_metadata so that function stays readable; every value it reads is a jq --arg above.
metadata_filter() {
    cat <<'JQ'
{
  schemaVersion: 1,
  os: "linux",
  architecture: "arm64",
  diskFormat: "raw",
  virtualDiskSizeBytes: $virtualBytes,
  runnerVersion: ($guest[0].runnerVersion // $runnerVersion),
  guestAgentVersion: $agentVersion,
  minimumHostOS: "15.0",
  createdAt: $builtAt,
  boot: { type: "efi" },
  capabilities: { docker: true, ssh: true },
  provenance: {
    baseImage: { source: $baseSource, sha256: $baseSha },
    actionsRunner: {
      version: $runnerVersion, sha256: $runnerSha, url: $runnerUrl,
      digestSource: ($runnerDigestSource | select(length > 0) // null)
    },
    guestAgent: {
      gitCommit: $agentCommit, sha256: $agentSha,
      reportedVersion: ($guest[0].guestAgentVersion // null)
    },
    builder: {
      gitCommit: $builderCommit, script: $script,
      hostOSVersion: $hostOS, builtAt: $builtAt
    },
    docker: {
      repository: $dockerRepo, version: ($guest[0].dockerVersion // null)
    },
    packageUpgrade: $packageUpgrade,
    packages: ($guest[0].packages // null),
    kernelVersion: ($guest[0].kernelVersion // null),
    diskSHA256: $diskSha,
    partial: $partial,
    partialReason: ($partialReason | select(length > 0) // null)
  }
}
JQ
}

# --------------------------------------------------------------------------
# Main flow
# --------------------------------------------------------------------------
# Sourced rather than executed: stop here, so scripts/tests/ can exercise the helpers
# above -- manifest extraction, metadata rendering -- without launching a builder VM.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; fi

check_options
resolve_base
resolve_guest_agent
resolve_runner

BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BUILDER_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
git -C "$REPO_ROOT" diff --quiet 2>/dev/null || BUILDER_COMMIT="$BUILDER_COMMIT-dirty"
HOST_OS_VERSION="$(sw_vers -productVersion 2>/dev/null || uname -r)"

prepare_build_dir
stage_seed_files

# The template is a *quoted* heredoc so nothing here is expanded by this shell:
# every `$` below belongs to the guest. Host values arrive as @PLACEHOLDER@.
cat >"$SEED_SRC/user-data.tmpl" <<'CLOUDCONFIG'
#cloud-config
# Mirror every cloud-init stage onto the virtio console so the host can watch the
# build in serial.log without ever mounting the guest filesystem (spec §131).
output:
  all: '| tee -a /var/log/cloud-init-output.log /dev/hvc0'

hostname: runnervm-build
preserve_hostname: false

# systemd puts a login getty on the virtio console. Its vhangup(2) at session
# setup invalidates every *other* process's open handle on /dev/hvc0 -- which
# silently truncates cloud-init's build trace in serial.log the moment the login
# banner appears. A CI guest has no use for a console login, so stop it from ever
# starting; bootcmd runs long before multi-user.target. This keeps serial.log a
# pure boot/diagnostic channel in built instances too (spec §131).
bootcmd:
  - [systemctl, mask, --now, 'serial-getty@hvc0.service']

# docker must exist as a group before the runner account is created: users are
# configured in the init stage, long before the docker package is installed.
groups:
  - docker

users:
  - name: runner
    uid: 1001
    gecos: RunnerVM actions runner
    shell: /bin/bash
    groups: [docker]
    lock_passwd: true
    @RUNNER_SUDO@

package_update: true
package_upgrade: @PACKAGE_UPGRADE@
packages:
  - git
  - curl
  - wget
  - ca-certificates
  - jq
  - tar
  - gzip
  - xz-utils
  - zstd
  - unzip
  - zip
  - rsync
  - openssh-server
  - build-essential
  - python3
  - python3-pip
  - pipx
  - dnsutils
  - iproute2
  - netcat-openbsd
  - cloud-guest-utils

write_files:
  # console=hvc0 is what makes serial.log useful on Apple Virtualization: the
  # stock Ubuntu cloud cmdline names only tty1/ttyS0, neither of which exists here.
  - path: /etc/default/grub.d/99-runnervm.cfg
    permissions: '0644'
    content: |
      GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT console=hvc0"
      GRUB_TIMEOUT=0
      GRUB_RECORDFAIL_TIMEOUT=0

  # cloud-init writes 50-cloud-init.yaml pinned to the *builder* VM's MAC. Every
  # instance cloned from this image gets a fresh MAC, so match on the interface
  # name family instead; the pinned file is deleted during sealing.
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

  # The guest agent unit is ordered After=network-online.target; unbounded
  # wait-online would spend two minutes of the profile's agentReady budget.
  - path: /etc/systemd/system/systemd-networkd-wait-online.service.d/10-runnervm.conf
    permissions: '0644'
    content: |
      [Service]
      ExecStart=
      ExecStart=/usr/lib/systemd/systemd-networkd-wait-online --any --timeout=20

  - path: /etc/ssh/sshd_config.d/99-runnervm.conf
    permissions: '0644'
    content: |
      PasswordAuthentication no
      PermitRootLogin no

  # SSH host keys are instance identity, not image content, so sealing removes
  # them (spec §62). cloud-init is disabled on later boots, so a tiny early
  # oneshot regenerates them before anything can want sshd.
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

  # Everything imperative lives in one script: a failure then shows a `set -x`
  # trace on the serial console instead of an opaque runcmd index.
  - path: /usr/local/sbin/runnervm-build.sh
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      set -Eeuxo pipefail
      export DEBIAN_FRONTEND=noninteractive
      APT="apt-get -y -o DPkg::Lock::Timeout=900 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

      marker() { echo "$1" >/dev/hvc0 2>/dev/null || echo "$1"; }
      trap 'marker RUNNERVM-BUILD-FAILED' ERR

      # Background apt jobs fight the build for the dpkg lock. This image is
      # rebuilt, not patched in place, so they have no job here.
      systemctl stop unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer || true
      systemctl disable unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer || true

      # ---- guest agent, from the read-only NoCloud seed ----
      # hdiutil's volume label case is not guaranteed, so match case-insensitively.
      CIDATA=""
      for _ in $(seq 1 30); do
        CIDATA="$(lsblk -rno PATH,LABEL 2>/dev/null | awk 'tolower($2)=="cidata"{print $1; exit}')"
        if [ -n "$CIDATA" ]; then break; fi
        sleep 1
      done
      if [ -z "$CIDATA" ]; then CIDATA=/dev/disk/by-label/cidata; fi
      mkdir -p /mnt/cidata
      mount -o ro "$CIDATA" /mnt/cidata
      install -m 0755 /mnt/cidata/runnervm/guest-agent /usr/local/bin/runnervm-guest-agent
      install -m 0644 /mnt/cidata/runnervm/runnervm-guest-agent.service \
        /etc/systemd/system/runnervm-guest-agent.service
      install -d -m 0750 /var/lib/runnervm-guest-agent
      umount /mnt/cidata
      rmdir /mnt/cidata
      systemctl daemon-reload
      systemctl enable runnervm-guest-agent.service
      systemctl enable runnervm-firstboot.service

      # ---- docker engine, official repo (spec §19) ----
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL --retry 5 --retry-delay 3 @DOCKER_REPO_URL@/gpg \
        -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
      echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.asc] @DOCKER_REPO_URL@ @DOCKER_SUITE@ @DOCKER_COMPONENT@" \
        >/etc/apt/sources.list.d/docker.list
      $APT update
      $APT install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      systemctl enable docker.service containerd.service

      # ---- actions runner (spec §36) ----
      # The host resolved this version and hashed this exact tarball; a mismatch
      # here means the bytes changed between the two downloads, so the build dies
      # rather than baking in something nobody verified.
      install -d -o runner -g runner -m 0755 /opt/actions-runner
      curl -fsSL --retry 5 --retry-delay 3 "@RUNNER_URL@" -o /tmp/actions-runner.tar.gz
      echo "@RUNNER_SHA256@  /tmp/actions-runner.tar.gz" | sha256sum -c -
      tar -xzf /tmp/actions-runner.tar.gz -C /opt/actions-runner
      rm -f /tmp/actions-runner.tar.gz
      chown -R runner:runner /opt/actions-runner
      chmod +x /opt/actions-runner/run.sh /opt/actions-runner/config.sh
      /opt/actions-runner/bin/installdependencies.sh

      update-grub

      cat >/etc/runnervm-image.json <<'JSON'
      {
        "runnerVersion": "@RUNNER_VERSION@",
        "guestAgentVersion": "@AGENT_VERSION@",
        "builtAt": "@BUILT_AT@"
      }
      JSON
      chmod 0644 /etc/runnervm-image.json

      # ---- machine-readable build manifest, emitted over the console ----
      # Everything the host cannot see from outside the guest: what apt actually
      # installed, which kernel booted, what the agent binary reports about itself.
      DOCKER_VERSION="$(dpkg-query -W -f='${Version}' docker-ce 2>/dev/null || echo unknown)"
      AGENT_REPORTED="$(/usr/local/bin/runnervm-guest-agent -version 2>/dev/null | head -1 || echo unknown)"
      AGENT_SHA="$(sha256sum /usr/local/bin/runnervm-guest-agent | awk '{print $1}')"
      dpkg-query -W -f='${Package}=${Version}\n' | sort >/tmp/rvm-packages.txt
      jq -R -s 'split("\n") | map(select(length > 0))' </tmp/rvm-packages.txt >/tmp/rvm-packages.json
      jq -n \
        --arg runnerVersion "@RUNNER_VERSION@" \
        --arg runnerSHA256 "@RUNNER_SHA256@" \
        --arg dockerVersion "$DOCKER_VERSION" \
        --arg dockerRepository "@DOCKER_REPO_URL@ @DOCKER_SUITE@ @DOCKER_COMPONENT@" \
        --arg kernelVersion "$(uname -r)" \
        --arg guestAgentVersion "$AGENT_REPORTED" \
        --arg guestAgentSHA256 "$AGENT_SHA" \
        --slurpfile packages /tmp/rvm-packages.json \
        '{runnerVersion: $runnerVersion, runnerSHA256: $runnerSHA256,
          dockerVersion: $dockerVersion, dockerRepository: $dockerRepository,
          kernelVersion: $kernelVersion, guestAgentVersion: $guestAgentVersion,
          guestAgentSHA256: $guestAgentSHA256, packages: $packages[0]}' \
        >/tmp/rvm-manifest.json
      # Tracing off across the emission: a `set -x` line quoting the markers would
      # otherwise land in serial.log and fool the host's extractor.
      set +x
      { echo RVM-MANIFEST-BEGIN
        base64 -w 100 </tmp/rvm-manifest.json
        echo RVM-MANIFEST-END
      } >/dev/hvc0 2>/dev/null || {
        echo RVM-MANIFEST-BEGIN
        base64 -w 100 </tmp/rvm-manifest.json
        echo RVM-MANIFEST-END
      }
      set -x
      rm -f /tmp/rvm-packages.txt /tmp/rvm-packages.json /tmp/rvm-manifest.json

      # ---- seal: drop everything instance-specific (spec §62) ----
      # The builder's hostname is build-time identity, not image content.
      echo runnervm >/etc/hostname
      sed -i 's/runnervm-build/runnervm/g' /etc/hosts
      rm -f /etc/netplan/50-cloud-init.yaml
      netplan generate
      rm -f /etc/ssh/ssh_host_*
      touch /etc/cloud/cloud-init.disabled
      $APT clean
      rm -rf /var/lib/apt/lists/*
      rm -rf /var/log/journal/* /tmp/* /var/tmp/*
      : >/etc/machine-id
      if [ -d /var/lib/dbus ]; then ln -sf /etc/machine-id /var/lib/dbus/machine-id; fi
      sync
      fstrim -av || true
      marker RUNNERVM-BUILD-OK

runcmd:
  - [bash, /usr/local/sbin/runnervm-build.sh]

power_state:
  mode: poweroff
  message: runnervm image build complete
  timeout: 120
  condition: true
CLOUDCONFIG

render_user_data

if [ "$PRINT_SEED" -eq 1 ]; then
    jq -n --sort-keys \
        --arg base "$BASE" --arg baseSource "$BASE_SOURCE" --arg baseSha "$BASE_SHA256" \
        --arg runnerVersion "$RUNNER_VERSION" --arg runnerSha "$RUNNER_SHA256" \
        --arg runnerDigestSource "$RUNNER_DIGEST_SOURCE" \
        --arg runnerUrl "$RUNNER_URL" --arg agentVersion "$AGENT_VERSION" \
        --arg agentSha "$AGENT_SHA256" --arg agentCommit "$AGENT_COMMIT" \
        --arg builderCommit "$BUILDER_COMMIT" --arg builtAt "$BUILT_AT" \
        --arg dockerRepo "$DOCKER_REPO_URL $DOCKER_SUITE $DOCKER_COMPONENT" \
        --arg packageUpgrade "$PACKAGE_UPGRADE" \
        '$ARGS.named' >"$BUILD_DIR/inputs.json"
    echo "RVM-SEED-INPUTS-BEGIN"
    cat "$BUILD_DIR/inputs.json"
    echo "RVM-SEED-INPUTS-END"
    echo "RVM-SEED-USER-DATA-BEGIN"
    cat "$SEED_SRC/user-data"
    echo "RVM-SEED-USER-DATA-END"
    [ -n "$OUT" ] || rm -rf "$BUILD_DIR"
    exit 0
fi

stage_builder_disk
build_seed_image

SHORT_ID="${BUILD_ID:0:8}"
WORKER_SOCK="$SOCKET_DIR/vm-$SHORT_ID.sock"
SERIAL_LOG="$BUILD_DIR/serial.log"
WORKER_LOG="$BUILD_DIR/worker.log"
WORKER_PID=""
trap cleanup EXIT

BUILD_START=$(date +%s)
start_worker
STATE="$(await_guest)"
BUILD_ELAPSED=$(($(date +%s) - BUILD_START))
log "guest stopped after ${BUILD_ELAPSED}s (vmState=$STATE)"

if ! grep -q 'RUNNERVM-BUILD-OK' "$SERIAL_LOG"; then
    echo "guest never reported RUNNERVM-BUILD-OK; provisioning failed" >&2
    echo "--- tail of $SERIAL_LOG ---" >&2
    tail -120 "$SERIAL_LOG" >&2 || true
    exit 1
fi

# The worker holds worker.lock until it exits; sealing a disk underneath a live
# vmworker would hash torn bytes.
shutdown_worker
wait "$WORKER_PID" 2>/dev/null || true
WORKER_PID=""

# --------------------------------------------------------------------------
# Seal
# --------------------------------------------------------------------------
GUEST_MANIFEST="$BUILD_DIR/guest-manifest.json"
if ! check_guest_manifest "$SERIAL_LOG" "$GUEST_MANIFEST" "$ALLOW_PARTIAL_PROVENANCE"; then
    echo "guest manifest could not be recovered: $PARTIAL_REASON" >&2
    echo "serial log: $SERIAL_LOG" >&2
    echo "pass --allow-partial-provenance to seal anyway with degraded provenance" >&2
    exit 1
fi
if [ -n "$PARTIAL_REASON" ]; then
    log "!!! WARNING: $PARTIAL_REASON"
    log "!!! metadata.json will carry no package manifest for this image (--allow-partial-provenance)"
else
    log "guest manifest: $(jq -r '.packages | length' "$GUEST_MANIFEST") packages, \
docker $(jq -r .dockerVersion "$GUEST_MANIFEST"), kernel $(jq -r .kernelVersion "$GUEST_MANIFEST")"
fi

log "sealing image into $OUT"
VIRTUAL_BYTES="$(stat -f %z "$BUILD_DIR/disk.img")"
mv -f "$BUILD_DIR/disk.img" "$OUT/disk.img"
mv -f "$BUILD_DIR/nvram.bin" "$OUT/nvram.bin"
cp -f "$SERIAL_LOG" "$OUT/build-serial.log"
cp -f "$GUEST_MANIFEST" "$OUT/build-manifest.json"

# Hashing the whole virtual size costs a full read of a sparse file; it is what
# makes the image referable by content outside the daemon's own catalogue.
log "hashing sealed disk (${DISK_GIB} GiB virtual)"
DISK_SHA256="$(sha256_hex "$OUT/disk.img")"
log "disk sha256 $DISK_SHA256"
write_metadata "$GUEST_MANIFEST" "$OUT/metadata.json"

case "$SOCKET_DIR" in
/tmp/rvm-build-*) rm -rf "$SOCKET_DIR" ;;
esac

if [ "$KEEP_BUILD_DIR" -eq 0 ]; then
    rm -rf "$BUILD_DIR"
    rmdir "$OUT/.build" 2>/dev/null || true
else
    log "build dir kept: $BUILD_DIR"
fi

ALLOCATED="$(du -h "$OUT/disk.img" | awk '{print $1}')"
log "done in ${BUILD_ELAPSED}s — virtual ${DISK_GIB} GiB, allocated ${ALLOCATED}"
cat <<IMPORT

Import it with (the sealed metadata.json is picked up automatically):

  runnerctl image import "$OUT/disk.img" \\
    --nvram "$OUT/nvram.bin" \\
    --os linux \\
    --name ubuntu-24
IMPORT
