#!/usr/bin/env bash
# RunnerVM bootstrap installer. Published, byte-for-byte, as the "install.sh" asset on every
# GitHub release (see .github/workflows/release.yml), so the one-liner in
# docs/design/distribution.md's "Goal" section works:
#
#   curl -fsSL https://github.com/andrejvysny/RunnerVM/releases/latest/download/install.sh \
#     | sudo bash
#
# Self-contained on purpose: the target host has no RunnerVM checkout, so this script assumes
# nothing beyond stock macOS tools -- bash 3.2, curl, shasum, installer, sw_vers, uname, mktemp,
# python3 (present on every shipping macOS; a sed/grep fallback covers its absence). It never
# clones this repo, never runs swift/go, never builds anything: it downloads the prebuilt pkg from
# a GitHub release, verifies it, installs it, and hands off to `runnerctl setup`.
#
# See docs/design/distribution.md ("Release artifacts and manifest", "Unsigned phase", "Failure
# semantics") for the contract this implements. Every failure here must leave the host exactly as
# it was before this script ran, up to and including a successful `installer -pkg` -- see
# verify_install() below for what happens if the pkg installs but is broken.
#
# Test seams (never part of the public curl-one-liner contract; scripts/tests/bootstrap-test.sh
# uses them to point this script at fixtures instead of the real network/filesystem):
#   RUNNERVM_PREFIX      default /usr/local -- where the pkg is expected to have installed
#                        runnerctl/vmworker; only the *verification* and *handoff* steps read it.
#   RUNNERVM_STATE_ROOT  default "/Library/Application Support/RunnerVM" -- where the pkg cache
#                        (used later by `runnerctl upgrade`) is written.
#   RUNNERVM_TTY         default /dev/tty -- the device the unsigned-package prompt reads/writes.
# Operator-facing env vars (part of the real contract):
#   RUNNERVM_PKG_URL         a file:// or https:// directory containing release-manifest.json,
#                            the pkg and its .sha256. Overrides RUNNERVM_VERSION and the default.
#   RUNNERVM_VERSION         vX.Y.Z -- install a specific tagged release instead of latest.
#   RUNNERVM_ALLOW_UNSIGNED  "1" skips the unsigned-package confirmation prompt.
#   RUNNERVM_NO_SETUP        "1" skips the `runnerctl setup` handoff at the end.
set -euo pipefail

RUNNERVM_REPO_SLUG="andrejvysny/RunnerVM"
RUNNERVM_INSTALL_URL="https://github.com/$RUNNERVM_REPO_SLUG/releases/latest/download/install.sh"

PREFIX="${RUNNERVM_PREFIX:-/usr/local}"
STATE_ROOT="${RUNNERVM_STATE_ROOT:-/Library/Application Support/RunnerVM}"
TTY_DEVICE="${RUNNERVM_TTY:-/dev/tty}"

WORKDIR=""

log() { printf '[runnervm-install] %s\n' "$*"; }
die() { printf '[runnervm-install] error: %s\n' "$*" >&2; exit 1; }

cleanup() {
    if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
        rm -rf "$WORKDIR"
    fi
}

# --------------------------------------------------------------------------
# 1. Must run as root
# --------------------------------------------------------------------------
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        printf '[runnervm-install] error: this script must run as root.\n' >&2
        printf '[runnervm-install] run via: curl -fsSL %s | sudo bash\n' "$RUNNERVM_INSTALL_URL" >&2
        exit 2
    fi
}

# --------------------------------------------------------------------------
# 2. Platform: Apple Silicon, macOS 15+
# --------------------------------------------------------------------------
HOST_MACOS_VERSION=""
HOST_MACOS_MAJOR=""

check_platform() {
    local machine
    machine="$(uname -m)"
    if [ "$machine" != "arm64" ]; then
        die "unsupported architecture: $machine (RunnerVM requires Apple Silicon / arm64)"
    fi

    HOST_MACOS_VERSION="$(sw_vers -productVersion)"
    HOST_MACOS_MAJOR="${HOST_MACOS_VERSION%%.*}"
    case "$HOST_MACOS_MAJOR" in
    '' | *[!0-9]*)
        die "could not parse macOS major version from sw_vers -productVersion: $HOST_MACOS_VERSION"
        ;;
    esac
    if [ "$HOST_MACOS_MAJOR" -lt 15 ]; then
        die "unsupported macOS version: $HOST_MACOS_VERSION (RunnerVM requires macOS 15 or later)"
    fi
    log "platform OK: arm64, macOS $HOST_MACOS_VERSION"
}

# --------------------------------------------------------------------------
# 3. Resolve the release asset directory
# --------------------------------------------------------------------------
# RUNNERVM_PKG_URL > RUNNERVM_VERSION > releases/latest/download. RUNNERVM_PKG_URL is a directory
# (file:// or https://) holding all three release assets -- used by CI's install smoke test and by
# scripts/tests/bootstrap-test.sh's fixtures. No trailing slash on the result.
resolve_base_url() {
    if [ -n "${RUNNERVM_PKG_URL:-}" ]; then
        printf '%s' "${RUNNERVM_PKG_URL%/}"
    elif [ -n "${RUNNERVM_VERSION:-}" ]; then
        printf '%s' "https://github.com/$RUNNERVM_REPO_SLUG/releases/download/${RUNNERVM_VERSION}"
    else
        printf '%s' "https://github.com/$RUNNERVM_REPO_SLUG/releases/latest/download"
    fi
}

# --------------------------------------------------------------------------
# 4. release-manifest.json field access: python3 first (present on every shipping macOS), a
#    grep/sed fallback for the (unsupported, but not worth hard-failing over) case it is missing.
# --------------------------------------------------------------------------
manifest_field_fallback() {
    local file="$1" field="$2" line value
    line="$(grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"\|\"${field}\"[[:space:]]*:[[:space:]]*[a-zA-Z0-9._-]*" "$file" | head -n1)"
    [ -n "$line" ] || return 1
    value="${line#*:}"
    value="$(printf '%s' "$value" | sed -E 's/^[[:space:]]*"?//; s/"?[[:space:]]*$//')"
    [ -n "$value" ] || return 1
    printf '%s' "$value"
}

manifest_field() {
    local file="$1" field="$2"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$file" "$field" <<'PY'
import json, sys
path, field = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
if field not in data:
    sys.exit(1)
value = data[field]
print("true" if value is True else "false" if value is False else value)
PY
    else
        manifest_field_fallback "$file" "$field"
    fi
}

# --------------------------------------------------------------------------
# 5. Download manifest + pkg + checksum into a scratch dir
# --------------------------------------------------------------------------
download_release() {
    local base="$1"
    WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/runnervm-install.XXXXXX")"
    trap cleanup EXIT INT TERM

    log "downloading release-manifest.json from $base"
    curl -fsSL "$base/release-manifest.json" -o "$WORKDIR/release-manifest.json" \
        || die "failed to download release-manifest.json from $base -- nothing installed"
}

# --------------------------------------------------------------------------
# 6. release-manifest.json's architecture/minimumMacOS must match this host before anything else
#    is downloaded (docs/design/distribution.md "Release artifacts and manifest").
# --------------------------------------------------------------------------
verify_manifest_platform() {
    local manifest_arch="$1" manifest_min_macos="$2" min_major
    if [ "$manifest_arch" != "arm64" ]; then
        die "release-manifest.json architecture is '$manifest_arch', not arm64 -- refusing to install (nothing installed)"
    fi
    min_major="${manifest_min_macos%%.*}"
    case "$min_major" in
    '' | *[!0-9]*)
        die "could not parse minimumMacOS from release-manifest.json: $manifest_min_macos"
        ;;
    esac
    if [ "$HOST_MACOS_MAJOR" -lt "$min_major" ]; then
        die "release-manifest.json requires macOS $manifest_min_macos or later; this host is $HOST_MACOS_VERSION -- refusing to install (nothing installed)"
    fi
}

# --------------------------------------------------------------------------
# 7. Download the pkg + its detached checksum, named per the manifest's "package" field
# --------------------------------------------------------------------------
download_pkg() {
    local base="$1" pkg_name="$2"
    curl -fsSL "$base/$pkg_name" -o "$WORKDIR/$pkg_name" \
        || die "failed to download $pkg_name from $base -- nothing installed"
    curl -fsSL "$base/$pkg_name.sha256" -o "$WORKDIR/$pkg_name.sha256" \
        || die "failed to download $pkg_name.sha256 from $base -- nothing installed"
}

# --------------------------------------------------------------------------
# 8. Checksum: shasum -c the detached file, then cross-check the hex against the manifest's own
#    "sha256" field -- two independent sources have to agree before installer ever runs.
# --------------------------------------------------------------------------
verify_checksum() {
    local pkg_name="$1" manifest_sha="$2" actual
    (cd "$WORKDIR" && shasum -a 256 -c "$pkg_name.sha256") \
        || die "checksum verification failed for $pkg_name (download corrupted or tampered) -- nothing installed"
    actual="$(shasum -a 256 "$WORKDIR/$pkg_name" | awk '{print $1}')"
    if [ "$actual" != "$manifest_sha" ]; then
        die "$pkg_name's sha256 ($actual) does not match release-manifest.json's sha256 ($manifest_sha) -- nothing installed"
    fi
    log "checksum verified: $pkg_name matches $pkg_name.sha256 and release-manifest.json"
}

# --------------------------------------------------------------------------
# 9. Unsigned-package warning + confirmation (docs/design/distribution.md "Unsigned phase").
#    RUNNERVM_ALLOW_UNSIGNED=1 skips the prompt for non-interactive use (CI, scripted installs).
# --------------------------------------------------------------------------
print_unsigned_warning() {
    local version="$1" sha="$2"
    cat <<EOF

================================================================================
WARNING: RunnerVM $version is UNSIGNED
================================================================================
This package has not been signed with an Apple Developer ID and is not
notarized -- Gatekeeper will not vouch for it.

Its sha256 ($sha) has been verified against release-manifest.json. That only
protects the download against corruption and tampering in transit (a
truncated download, a bit-flipped mirror); it does NOT prove who built this
package -- anyone who can edit the release can regenerate a matching
checksum. Verifying publisher identity requires code signing, which this
phase does not yet provide.

Apple Developer ID signing and notarization are planned for a later
milestone; this warning goes away once they land.
================================================================================

EOF
}

confirm_unsigned() {
    local version="$1" sha="$2" answer=""

    if [ "${RUNNERVM_ALLOW_UNSIGNED:-}" = "1" ]; then
        log "RUNNERVM_ALLOW_UNSIGNED=1: skipping unsigned-package confirmation"
        return 0
    fi

    if ! : <"$TTY_DEVICE" 2>/dev/null; then
        die "refusing to install an unsigned package non-interactively (no controlling terminal at $TTY_DEVICE) -- re-run with RUNNERVM_ALLOW_UNSIGNED=1 to accept the risk described above"
    fi

    print_unsigned_warning "$version" "$sha" >"$TTY_DEVICE"
    printf 'Continue? [y/N] ' >"$TTY_DEVICE"
    read -r answer <"$TTY_DEVICE" || true
    case "$answer" in
    y | Y | yes | YES) log "continuing with unsigned install" ;;
    *) die "aborted: unsigned-package install was not confirmed -- re-run with RUNNERVM_ALLOW_UNSIGNED=1 to skip this prompt" ;;
    esac
}

# --------------------------------------------------------------------------
# 10. installer -pkg ... -target /
# --------------------------------------------------------------------------
run_installer() {
    local pkg_path="$1"
    log "installing $pkg_path"
    installer -pkg "$pkg_path" -target / \
        || die "installer failed -- pkg install did not complete (see output above)"
}

# --------------------------------------------------------------------------
# 11. Verify the install actually works before touching anything else. Failure here means the pkg
#     stayed installed (postinstall already ran) but is broken -- nothing else was touched, so the
#     fix is to re-run this script or investigate, not to roll anything back.
# --------------------------------------------------------------------------
verify_install() {
    local vmworker="$PREFIX/libexec/runnervm/vmworker"
    log "verifying install"
    if ! codesign --verify --strict "$vmworker" >/dev/null 2>&1; then
        die "install verification failed: codesign --verify --strict $vmworker did not pass -- the pkg is installed but broken; nothing else was touched"
    fi
    if ! codesign -d --entitlements :- "$vmworker" 2>&1 | grep -q com.apple.security.virtualization; then
        die "install verification failed: $vmworker is missing com.apple.security.virtualization -- the pkg is installed but broken; nothing else was touched"
    fi
    if ! "$vmworker" probe --json >/dev/null; then
        die "install verification failed: $vmworker probe --json did not succeed -- the pkg is installed but broken; nothing else was touched"
    fi
    log "install verified: vmworker signature, entitlement and probe OK"
}

# --------------------------------------------------------------------------
# 12. Cache the pkg + manifest for `runnerctl upgrade`'s rollback path.
# --------------------------------------------------------------------------
cache_release() {
    local version="$1" pkg_name="$2"
    local cache_dir="$STATE_ROOT/upgrades/$version"
    log "caching pkg + manifest at $cache_dir"
    mkdir -p "$STATE_ROOT" "$STATE_ROOT/upgrades" "$cache_dir" || die "failed to create $cache_dir"
    chmod 0755 "$STATE_ROOT" "$STATE_ROOT/upgrades" "$cache_dir"
    cp "$WORKDIR/$pkg_name" "$cache_dir/" || die "failed to cache $pkg_name"
    cp "$WORKDIR/$pkg_name.sha256" "$cache_dir/" || die "failed to cache $pkg_name.sha256"
    cp "$WORKDIR/release-manifest.json" "$cache_dir/" || die "failed to cache release-manifest.json"
    chmod 0644 "$cache_dir/$pkg_name" "$cache_dir/$pkg_name.sha256" "$cache_dir/release-manifest.json"
}

# --------------------------------------------------------------------------
# 13. Hand off to the setup wizard, unless RUNNERVM_NO_SETUP=1 or there is no controlling terminal
#     to run it interactively over.
# --------------------------------------------------------------------------
run_setup() {
    if [ "${RUNNERVM_NO_SETUP:-}" = "1" ]; then
        log "RUNNERVM_NO_SETUP=1: skipping runnerctl setup"
        log "next step: sudo $PREFIX/bin/runnerctl setup"
        exit 0
    fi
    if ! : <"$TTY_DEVICE" 2>/dev/null; then
        log "no controlling terminal available to run the setup wizard"
        log "next step: sudo $PREFIX/bin/runnerctl setup"
        exit 0
    fi
    log "launching runnerctl setup"
    # shellcheck disable=SC2094 # $TTY_DEVICE is a character device (/dev/tty or a test seam
    # pointing at one) -- opening it for stdin/stdout/stderr in the same exec is safe, unlike a
    # regular file opened for simultaneous read and write.
    exec "$PREFIX/bin/runnerctl" setup <"$TTY_DEVICE" >"$TTY_DEVICE" 2>"$TTY_DEVICE"
}

# --------------------------------------------------------------------------
main() {
    require_root
    check_platform

    local base pkg_name manifest_sha manifest_signed manifest_version manifest_arch manifest_min_macos
    base="$(resolve_base_url)"

    download_release "$base"

    manifest_arch="$(manifest_field "$WORKDIR/release-manifest.json" architecture)" \
        || die "release-manifest.json missing 'architecture'"
    manifest_min_macos="$(manifest_field "$WORKDIR/release-manifest.json" minimumMacOS)" \
        || die "release-manifest.json missing 'minimumMacOS'"
    verify_manifest_platform "$manifest_arch" "$manifest_min_macos"

    pkg_name="$(manifest_field "$WORKDIR/release-manifest.json" package)" \
        || die "release-manifest.json missing 'package'"
    manifest_sha="$(manifest_field "$WORKDIR/release-manifest.json" sha256)" \
        || die "release-manifest.json missing 'sha256'"
    manifest_signed="$(manifest_field "$WORKDIR/release-manifest.json" signed)" \
        || die "release-manifest.json missing 'signed'"
    manifest_version="$(manifest_field "$WORKDIR/release-manifest.json" version)" \
        || die "release-manifest.json missing 'version'"

    log "release-manifest.json: version $manifest_version, package $pkg_name, signed=$manifest_signed"

    download_pkg "$base" "$pkg_name"
    verify_checksum "$pkg_name" "$manifest_sha"

    if [ "$manifest_signed" != "true" ]; then
        confirm_unsigned "$manifest_version" "$manifest_sha"
    fi

    run_installer "$WORKDIR/$pkg_name"
    verify_install
    cache_release "$manifest_version" "$pkg_name"

    run_setup
}

# Guarded with the "am I sourced" idiom, not a BASH_SOURCE/$0 comparison: this script is normally
# read from stdin by `curl -fsSL ... | sudo bash`, where BASH_SOURCE is empty and would never equal
# $0 anyway. `(return 0 2>/dev/null)` succeeds only when sourced (by scripts/tests/bootstrap-test.sh,
# to exercise the functions above directly), so it is the one check that works in every invocation
# style.
if ! (return 0 2>/dev/null); then
    main "$@"
fi
