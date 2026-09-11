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
# See docs/design/distribution.md ("Release artifacts and manifest", "Signing and notarization", "Failure
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
#   RUNNERVM_TTY         default /dev/tty -- the device the unsigned / not-notarized package
#                        prompts read and write.
# Operator-facing env vars (part of the real contract):
#   RUNNERVM_PKG_URL         a file:// or https:// directory containing release-manifest.json,
#                            the pkg and its .sha256. Takes precedence over RUNNERVM_VERSION when
#                            both are set, and over the default (the Swift-side resolver in
#                            ReleaseManifest.swift follows the same order).
#   RUNNERVM_VERSION         vX.Y.Z -- install a specific tagged release instead of latest. Used
#                            only when RUNNERVM_PKG_URL is unset. A missing leading "v" is added,
#                            so 0.3.0-rc.1 and v0.3.0-rc.1 name the same tag.
#   RUNNERVM_ALLOW_UNSIGNED  "1" skips the confirmation prompt for a package that is unsigned, and
#                            for one that is signed but not notarized. It never bypasses the
#                            publisher check: a package signed by a Developer ID team other than
#                            the pinned one is refused outright, with no override.
#   RUNNERVM_NO_SETUP        "1" skips the `runnerctl setup` handoff at the end.
set -euo pipefail

RUNNERVM_REPO_SLUG="andrejvysny/RunnerVM"
RUNNERVM_INSTALL_URL="https://github.com/$RUNNERVM_REPO_SLUG/releases/latest/download/install.sh"

# The Apple Developer ID team that RunnerVM releases are signed by -- a constant compiled into this
# installer, deliberately NOT read from the environment or from release-manifest.json: the manifest
# is written by whoever produced the release, so its own `teamId`/`signed`/`notarized` fields can
# never be the reference for judging it. Must stay equal to `RunnerVMSigning.teamID` on the Swift
# side (Sources/RunnerCore), which gates `runnerctl upgrade` the same way.
#
# Empty until the operator's Developer ID certificates exist (PLAN 4.1 / docs/design/
# distribution.md). While empty, this installer still requires a Developer ID Installer signature
# and notarization, but cannot tell one publisher from another -- it says so, out loud, per install.
RUNNERVM_EXPECTED_TEAM_ID=""

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
# RUNNERVM_PKG_URL > RUNNERVM_VERSION > releases/latest/download -- an explicit directory always
# wins over a version, because an operator who names a directory has already decided which bits to
# install. `ReleaseManifest.swift`'s resolver implements this same order for `runnerctl upgrade`.
# RUNNERVM_PKG_URL is a directory (file:// or https://) holding all three release assets -- used by
# CI's install smoke test and by scripts/tests/bootstrap-test.sh's fixtures. No trailing slash.
resolve_base_url() {
    local tag
    if [ -n "${RUNNERVM_PKG_URL:-}" ]; then
        printf '%s' "${RUNNERVM_PKG_URL%/}"
    elif [ -n "${RUNNERVM_VERSION:-}" ]; then
        # Release tags carry a leading "v"; an operator who types the bare version means the same
        # tag, and without this it would 404. `ReleaseSource.tagged` normalises identically.
        tag="$RUNNERVM_VERSION"
        case "$tag" in
        v*) ;;
        *) tag="v$tag" ;;
        esac
        printf '%s' "https://github.com/$RUNNERVM_REPO_SLUG/releases/download/$tag"
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
# 7. release-manifest.json's "package" field must be a plain filename -- not a path, not a
#    flag-like string, nothing that could escape $WORKDIR when interpolated into curl/cp/installer
#    argv below (docs/design/distribution.md "Release artifacts and manifest"). Checked before
#    anything is downloaded.
# --------------------------------------------------------------------------
# The manifest's "version" names the cache directory (upgrades/<version>/) and rides on the
# curl -o and spctl command lines, so it is held to the same plain-token rule as the package
# name: MAJOR.MINOR.PATCH with an optional dot/dash/alphanumeric prerelease suffix.
verify_manifest_version() {
    local version="$1" core suffix
    case "$version" in
    '') die "release-manifest.json's 'version' field is empty -- refusing to install (nothing installed)" ;;
    *-*) core="${version%%-*}"; suffix="${version#*-}" ;;
    *) core="$version"; suffix="" ;;
    esac
    case "$core" in
    *[!0-9.]* | .* | *. | *..*) die "release-manifest.json's 'version' '$version' is not MAJOR.MINOR.PATCH -- refusing to install (nothing installed)" ;;
    esac
    case "$core" in
    *.*.*) : ;;
    *) die "release-manifest.json's 'version' '$version' is not MAJOR.MINOR.PATCH -- refusing to install (nothing installed)" ;;
    esac
    case "$core" in
    *.*.*.*) die "release-manifest.json's 'version' '$version' is not MAJOR.MINOR.PATCH -- refusing to install (nothing installed)" ;;
    esac
    case "$version" in
    *-)
        die "release-manifest.json's 'version' '$version' has an empty prerelease suffix -- refusing to install (nothing installed)" ;;
    esac
    if [ -n "$suffix" ]; then
        case "$suffix" in
        *[!A-Za-z0-9.-]*) die "release-manifest.json's 'version' '$version' has a prerelease suffix outside [0-9A-Za-z.-] -- refusing to install (nothing installed)" ;;
        esac
    fi
}

verify_pkg_name() {
    local pkg_name="$1"
    case "$pkg_name" in
    '')
        die "release-manifest.json's 'package' field is empty -- refusing to install (nothing installed)"
        ;;
    */*)
        die "release-manifest.json's 'package' field '$pkg_name' must not contain '/' -- refusing to install (nothing installed)"
        ;;
    -*)
        die "release-manifest.json's 'package' field '$pkg_name' must not start with '-' -- refusing to install (nothing installed)"
        ;;
    esac
    case "$pkg_name" in
    *[!A-Za-z0-9._-]*)
        die "release-manifest.json's 'package' field '$pkg_name' contains characters outside [A-Za-z0-9._-] -- refusing to install (nothing installed)"
        ;;
    esac
    case "$pkg_name" in
    *.pkg) ;;
    *)
        die "release-manifest.json's 'package' field '$pkg_name' does not end in .pkg -- refusing to install (nothing installed)"
        ;;
    esac
}

# --------------------------------------------------------------------------
# 8. Download the pkg + its detached checksum, named per the manifest's "package" field
# --------------------------------------------------------------------------
download_pkg() {
    local base="$1" pkg_name="$2"
    curl -fsSL "$base/$pkg_name" -o "$WORKDIR/$pkg_name" \
        || die "failed to download $pkg_name from $base -- nothing installed"
    curl -fsSL "$base/$pkg_name.sha256" -o "$WORKDIR/$pkg_name.sha256" \
        || die "failed to download $pkg_name.sha256 from $base -- nothing installed"
}

# --------------------------------------------------------------------------
# 9. Checksum: shasum -c the detached file, then cross-check the hex against the manifest's own
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
# 10. Publisher identity: Developer ID signature + notarization, verified HERE rather than trusted
#     from release-manifest.json. `curl` attaches no quarantine attribute and `installer` performs
#     no Gatekeeper assessment, so this function is the only gate between a downloaded pkg and a
#     root-level install; the manifest's own `signed`/`notarized`/`teamId` fields are self-attested
#     by whoever produced the release and are used for nothing but detecting that they overstated.
#
#     Evidence (target hosts have /usr/sbin/pkgutil and /usr/sbin/spctl; `stapler`/`notarytool` are
#     Xcode-only and absent here):
#       pkgutil --check-signature  proves a Developer ID Installer certificate chain and yields the
#                                  leaf's team id from "1. Developer ID Installer: Name (TEAMID)".
#       spctl --assess -t install  the only real notarization evidence on a stock host, and only
#                                  when `spctl --status` positively reports assessments enabled --
#                                  a disabled assessor accepts anything, so it counts as no
#                                  evidence at all and pkgutil's "Notarization:" line becomes the
#                                  fallback, announced loudly whether or not it ends up accepting.
#     Parsing is structural -- the certificate-chain line, the team id in parentheses, the exit
#     status -- never keyed on Apple's English status prose.
#
#     Outcomes: notarized + team match (or no pin) => silent proceed; signed by another team =>
#     hard fail, no override; signed by us but not notarized => warn + confirm; unsigned => the
#     unsigned warning + confirm. A manifest that overstated its own signing state changes nothing
#     but adds a line saying so: this gate never turns into a lockout on manifest content.
# --------------------------------------------------------------------------
verify_package_signature() {
    local pkg="$1" version="$2" sha="$3" manifest_signed="$4" manifest_notarized="$5"
    local pkgutil_out="" sig_line="" notarization_line="" notarization_word="" leaf_team=""
    local status_out="" assess_out=""
    local signed=0 notarized_pkgutil=0 notarized=0 spctl_available=0

    # Both greps are anchored to the start of a line: pkgutil echoes the package path back in its
    # first line ('Package "<path>":'), so an unanchored match would let a crafted path -- or a
    # crafted TMPDIR, which is where $pkg lives -- forge the very evidence being collected. The
    # entry number pkgutil prints ("    1. Developer ID Installer: Name (TEAMID)") is optional in
    # the pattern but ordering is not: `head -n 1` takes the first chain entry, which is the leaf.
    pkgutil_out="$(pkgutil --check-signature "$pkg" 2>&1)" || true
    sig_line="$(printf '%s\n' "$pkgutil_out" |
        grep '^[[:space:]]*\([0-9][0-9]*\. \)\{0,1\}Developer ID Installer:' | head -n 1)" || true
    notarization_line="$(printf '%s\n' "$pkgutil_out" |
        grep '^[[:space:]]*Notarization:' | head -n 1)" || true

    # A Developer ID team id is exactly ten ASCII alphanumerics. Anything else in the parentheses
    # is not a team id this installer can compare, so the package counts as UNSIGNED and takes the
    # warn-and-confirm path -- there is no "signed by somebody unreadable" verdict, because bash
    # and Swift have to reach the same conclusion from the same bytes. No end-of-line anchor: a
    # real chain line can carry a suffix ("(TEAMID) [expired]") after the parentheses.
    if [ -n "$sig_line" ]; then
        leaf_team="$(printf '%s\n' "$sig_line" |
            sed -n 's/.*(\([A-Za-z0-9]\{10\}\)).*/\1/p')" || true
        if [ -n "$leaf_team" ]; then
            signed=1
        fi
    fi

    # The value after "Notarization:" is judged on its first word only: "trusted by the Apple
    # notary service" is the accepting wording, and a substring test for "trusted" would also
    # accept "not trusted ..." and "untrusted ...", which mean the opposite.
    notarization_word="$(printf '%s\n' "$notarization_line" |
        sed -n 's/^[[:space:]]*Notarization:[[:space:]]*\([^[:space:]][^[:space:]]*\).*$/\1/p')" || true
    if [ "$notarization_word" = "trusted" ]; then
        notarized_pkgutil=1
    fi

    # Positive match only: an assessor is trusted to answer only when it says, in so many words,
    # that assessments are enabled. Anything else -- disabled, an unrecognised wording, an error,
    # no spctl at all -- is "no live assessor" and falls back to the stapled ticket.
    spctl_available=0
    if command -v spctl >/dev/null 2>&1; then
        status_out="$(spctl --status 2>&1)" || true
        case "$status_out" in
        *"assessments enabled"*) spctl_available=1 ;;
        esac
    fi
    if [ "$spctl_available" -eq 1 ]; then
        # Accepted AND notarized: spctl also exits 0 for a merely-signed package accepted under a
        # local rule, so the exit status alone is not the evidence. `source=` is anchored to the
        # start of its line for the same reason the pkgutil greps are: spctl echoes the path too.
        if assess_out="$(spctl --assess --type install -vv "$pkg" 2>&1)"; then
            if printf '%s\n' "$assess_out" | grep -q '^source=Notarized Developer ID'; then
                notarized=1
            fi
        fi
    else
        # Unconditional, and before any verdict: on a host with no live assessor the operator is
        # told that this install's notarization evidence is weaker, whatever the outcome turns out
        # to be. `Upgrader.signatureStep` prints its equivalent the same way.
        notarized="$notarized_pkgutil"
        print_unverified_notarization_warning
    fi

    if [ "$signed" -eq 0 ]; then
        if [ -n "$sig_line" ]; then
            log "signature check: $pkg has a Developer ID Installer chain line with no readable ten-character team id -- treating it as unsigned"
        else
            log "signature check: $pkg carries no Developer ID Installer signature"
        fi
        if [ "$manifest_signed" = "true" ] || [ "$manifest_notarized" = "true" ]; then
            log "NOTE: release-manifest.json overstated this package (it claims signed=$manifest_signed, notarized=$manifest_notarized); the package itself is what decides"
        fi
        confirm_unsigned "$version" "$sha"
        return 0
    fi

    if [ -n "$RUNNERVM_EXPECTED_TEAM_ID" ]; then
        if [ "$leaf_team" != "$RUNNERVM_EXPECTED_TEAM_ID" ]; then
            die "package is signed by Developer ID team '$leaf_team', not RunnerVM's '$RUNNERVM_EXPECTED_TEAM_ID' -- refusing to install (nothing installed). This is not a RunnerVM release and there is no override for it"
        fi
        log "publisher verified: Developer ID Installer, team $leaf_team"
    else
        log "publisher team not pinned in this installer -- accepting any Developer ID Installer signature (this package's team: $leaf_team)"
    fi

    if [ "$notarized" -eq 1 ]; then
        if [ "$spctl_available" -eq 1 ]; then
            log "notarization verified: spctl assesses $pkg as a notarized Developer ID package"
        else
            log "notarization accepted on this package's stapled ticket alone -- see the warning above"
        fi
        return 0
    fi

    log "notarization check: Apple's notary service does not vouch for this package"
    if [ "$manifest_notarized" = "true" ]; then
        log "NOTE: release-manifest.json overstated this package (it claims notarized=true); the package itself is what decides"
    fi
    confirm_unnotarized "$version" "$leaf_team"
}

# Printed on every run where no live assessor answered, before the verdict rather than only on the
# accept path: pkgutil's stapled-ticket line is weaker evidence than spctl (it is a property of the
# file, not a live check), so the operator is told rather than quietly reassured.
print_unverified_notarization_warning() {
    cat <<EOF

================================================================================
WARNING: notarization unverified on this host
================================================================================
Gatekeeper assessments are disabled on this host ('spctl --status' did not
report them as enabled), and a disabled assessor accepts every package, so its
verdict proves nothing and was not asked for.

Notarization is being judged on the weaker evidence in 'pkgutil
--check-signature' instead: whether this package carries a stapled
notarization ticket that this host recognizes. That is a property of the file,
not a live check with Apple.

To get a real assessment, re-enable it ('sudo spctl --master-enable') and
re-run this installer.
================================================================================

EOF
}

# --------------------------------------------------------------------------
# 11. Unsigned / not-notarized warnings + confirmation (docs/design/distribution.md).
#    RUNNERVM_ALLOW_UNSIGNED=1 skips both prompts for non-interactive use (CI, scripted installs).
#    Neither prompt is reachable for a package signed by the wrong team -- that one just fails.
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
checksum. Verifying publisher identity requires code signing.

Official RunnerVM releases are signed with a Developer ID and notarized; an
unsigned package is a development build, a local rebuild, or a download that
did not come from the project's releases. Continue only if you know which.
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

print_unnotarized_warning() {
    local version="$1" team="$2"
    cat <<EOF

================================================================================
WARNING: RunnerVM $version is SIGNED but NOT NOTARIZED
================================================================================
The package carries a Developer ID Installer signature (team
${team:-unreadable}), so its publisher is identified and its contents have not
changed since it was signed.

Apple's notary service has not vouched for it. Notarization is what proves the
package was scanned for known malware, and that the signing key was still
trusted -- not revoked -- when the package was submitted. Without it, a
signature made with a stolen or since-revoked key still looks fine here.

Every published RunnerVM release is notarized. A signed but unnotarized
package is a locally built one, a release from a broken pipeline, or a
package you should not be installing.
================================================================================

EOF
}

confirm_unnotarized() {
    local version="$1" team="$2" answer=""

    if [ "${RUNNERVM_ALLOW_UNSIGNED:-}" = "1" ]; then
        log "RUNNERVM_ALLOW_UNSIGNED=1: skipping not-notarized-package confirmation"
        return 0
    fi

    if ! : <"$TTY_DEVICE" 2>/dev/null; then
        die "refusing to install a package that is not notarized non-interactively (no controlling terminal at $TTY_DEVICE) -- re-run with RUNNERVM_ALLOW_UNSIGNED=1 to accept the risk described above"
    fi

    print_unnotarized_warning "$version" "$team" >"$TTY_DEVICE"
    printf 'Continue? [y/N] ' >"$TTY_DEVICE"
    read -r answer <"$TTY_DEVICE" || true
    case "$answer" in
    y | Y | yes | YES) log "continuing with a signed but unnotarized install" ;;
    *) die "aborted: not-notarized-package install was not confirmed -- re-run with RUNNERVM_ALLOW_UNSIGNED=1 to skip this prompt" ;;
    esac
}

# --------------------------------------------------------------------------
# 12. installer -pkg ... -target /
# --------------------------------------------------------------------------
run_installer() {
    local pkg_path="$1"
    log "installing $pkg_path"
    installer -pkg "$pkg_path" -target / \
        || die "installer failed -- pkg install did not complete (see output above)"
}

# --------------------------------------------------------------------------
# 13. Verify the install actually works before touching anything else. Failure here means the pkg
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
# 14. Cache the pkg + manifest for `runnerctl upgrade`'s rollback path.
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
# 15. Hand off to the setup wizard, unless RUNNERVM_NO_SETUP=1 or there is no controlling terminal
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

    local base pkg_name manifest_sha manifest_signed manifest_notarized manifest_version
    local manifest_arch manifest_min_macos
    base="$(resolve_base_url)"

    download_release "$base"

    manifest_arch="$(manifest_field "$WORKDIR/release-manifest.json" architecture)" \
        || die "release-manifest.json missing 'architecture'"
    manifest_min_macos="$(manifest_field "$WORKDIR/release-manifest.json" minimumMacOS)" \
        || die "release-manifest.json missing 'minimumMacOS'"
    verify_manifest_platform "$manifest_arch" "$manifest_min_macos"

    pkg_name="$(manifest_field "$WORKDIR/release-manifest.json" package)" \
        || die "release-manifest.json missing 'package'"
    verify_pkg_name "$pkg_name"
    manifest_sha="$(manifest_field "$WORKDIR/release-manifest.json" sha256)" \
        || die "release-manifest.json missing 'sha256'"
    manifest_signed="$(manifest_field "$WORKDIR/release-manifest.json" signed)" \
        || die "release-manifest.json missing 'signed'"
    # `notarized` post-dates the first releases, so an absent one reads as false rather than
    # aborting an install of an older tag. Both fields are claims, never evidence -- see
    # verify_package_signature. The manifest's `teamId` is deliberately not read at all: the only
    # team id this installer compares against is RUNNERVM_EXPECTED_TEAM_ID.
    manifest_notarized="$(manifest_field "$WORKDIR/release-manifest.json" notarized)" \
        || manifest_notarized="false"
    manifest_version="$(manifest_field "$WORKDIR/release-manifest.json" version)" \
        || die "release-manifest.json missing 'version'"
    verify_manifest_version "$manifest_version"

    log "release-manifest.json: version $manifest_version, package $pkg_name, signed=$manifest_signed, notarized=$manifest_notarized"

    download_pkg "$base" "$pkg_name"
    verify_checksum "$pkg_name" "$manifest_sha"
    verify_package_signature "$WORKDIR/$pkg_name" "$manifest_version" "$manifest_sha" \
        "$manifest_signed" "$manifest_notarized"

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
