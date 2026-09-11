#!/usr/bin/env bash
# Build the RunnerVM macOS package: a swift release build, the Linux+macOS guest agents, all four
# shipped Mach-O files signed with the hardened runtime, a staged payload root matching
# docs/design/distribution.md's package layout exactly, then `pkgbuild`/`productbuild` into
# dist/RunnerVM-macos-arm64.pkg plus its sha256 and release-manifest.json.
#
# Two modes, same code path: a dev build signs ad-hoc ("-") and produces an unsigned pkg; a release
# build passes Developer ID identities plus the four --notarize-* flags and additionally notarizes
# and staples. Everything else -- hardened runtime, timestamps, stable code-signing identifiers,
# the postinstall templating -- is identical in both, so a dev build exercises the release
# configuration.
#
# See docs/design/distribution.md ("Package layout", "Release artifacts and manifest", "Signing and
# notarization") for the contract this script implements. Read that first if anything here looks
# arbitrary -- it mostly isn't.
#
# usage:
#   scripts/build-package.sh [--version X] [--out dist] [--sign-identity -] \
#     [--installer-identity <id>] [--skip-build] [--stage-only <dir>] \
#     [--notarize-key <p8> --notarize-key-id <id> --notarize-issuer <uuid>] \
#     [--notarize-timeout 30m] [--keychain <path>]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --------------------------------------------------------------------------
# Constants (the pkg's identity; not overridable -- distribution.xml's pkg-ref hardcodes the
# same identifier, and the manifest/release asset names are part of the install.sh contract)
# --------------------------------------------------------------------------
PKG_IDENTIFIER="com.runnervm.pkg"
PKG_NAME="RunnerVM-macos-arm64.pkg"
PKG_ARCH="arm64"
PKG_MIN_MACOS="15.0"
PKG_LICENSE="Apache-2.0"

# Code-signing identifiers, one per shipped Mach-O. Passed to codesign explicitly because without
# --identifier codesign derives one from the file name plus a per-build hash, which is unstable
# across builds -- and any `codesign -R` requirement or Gatekeeper rule that pins an identifier
# would then break on the next release for no reason.
CODESIGN_ID_RUNNERD="com.runnervm.runnerd"
CODESIGN_ID_RUNNERCTL="com.runnervm.runnerctl"
CODESIGN_ID_VMWORKER="com.runnervm.vmworker"
CODESIGN_ID_GUEST_AGENT="com.runnervm.guest-agent"

# Substituted into the copy of packaging/pkg/scripts that pkgbuild consumes (stage_pkg_scripts).
TEAM_ID_PLACEHOLDER="@RUNNERVM_TEAM_ID@"

VERSION_SOURCE="$REPO_ROOT/Sources/RunnerCore/Version.swift"
ENTITLEMENTS_PATH="$REPO_ROOT/Resources/vmworker.entitlements"
RUNNERD_BUILT="$REPO_ROOT/.build/release/runnerd"
RUNNERCTL_BUILT="$REPO_ROOT/.build/release/runnerctl"
VMWORKER_BUILT="$REPO_ROOT/.build/release/vmworker"
GUEST_AGENT_LINUX_ARM64="$REPO_ROOT/GuestAgent/bin/linux-arm64/runnervm-guest-agent"
GUEST_AGENT_DARWIN_ARM64="$REPO_ROOT/GuestAgent/bin/darwin-arm64/runnervm-guest-agent"

# --------------------------------------------------------------------------
# Options, defaults
# --------------------------------------------------------------------------
VERSION_FLAG=""
OUT_DIR="dist"
SIGN_IDENTITY="-"
INSTALLER_IDENTITY=""
SKIP_BUILD=0
SKIP_SIGN=0
STAGE_ONLY_DIR=""
NOTARY_KEY=""
NOTARY_KEY_ID=""
NOTARY_ISSUER=""
NOTARY_TIMEOUT="30m"
KEYCHAIN=""
# Set by any --notarize-* flag, including --notarize-timeout: passing one of the four alone is a
# mistake worth failing on, not a silently unnotarized release.
NOTARIZE_REQUESTED=0

# Derived while building, recorded in release-manifest.json: the Apple Team ID the shipped Mach-O
# files are actually signed by ("" for an ad-hoc/dev build) and whether a notarization ticket was
# stapled and validated onto the pkg.
TEAM_ID=""
NOTARIZED=0

log()  { printf '[build-package] %s\n' "$*"; }
warn() { printf '[build-package] warning: %s\n' "$*" >&2; }
die()  { printf '[build-package] error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
usage: build-package.sh [options]

Builds the RunnerVM macOS installer package: swift release binaries, the Linux+macOS guest
agents, four hardened-runtime-signed Mach-O files, a staged payload root, then
pkgbuild/productbuild (optionally notarize + staple) into <out>/$PKG_NAME plus
<out>/$PKG_NAME.sha256 and <out>/release-manifest.json.

options:
  --version <X>             Version to build. Default: parsed from
                             Sources/RunnerCore/Version.swift. If both this flag and Version.swift
                             are present, they must agree -- this flag can only confirm the
                             version, never override it (the version bump is authored in exactly
                             one place; see docs/design/distribution.md "Version source of truth").
  --out <dir>                Output directory for the pkg, checksum and manifest. Default: dist/
  --sign-identity <id>        codesign identity for all four shipped Mach-O files (runnerd,
                             runnerctl, vmworker, the darwin guest agent). Default: "-" (ad-hoc).
                             Pass a Developer ID Application identity for a release build. The
                             hardened runtime and a timestamp are requested either way.
  --installer-identity <id>  productbuild identity for the distribution pkg itself. Default:
                             empty, which produces an unsigned pkg (release-manifest.json's
                             "signed" is false). Pass a Developer ID Installer identity to sign
                             the pkg and record "signed": true.
  --notarize-key <p8>        App Store Connect API key file used to notarize the built pkg.
  --notarize-key-id <id>     Key ID for --notarize-key.
  --notarize-issuer <uuid>   Issuer ID for --notarize-key.
                             The three flags above are required together, require
                             --installer-identity, and are refused with --sign-identity "-"
                             (Apple only notarizes Developer ID signed code). When given, the pkg
                             is submitted to the notary service, stapled, re-verified with
                             \`pkgutil --check-signature\` and \`spctl --assess --type install\`,
                             and only then checksummed -- stapling rewrites the pkg.
  --notarize-timeout <dur>   Timeout passed to \`notarytool submit --wait\`. Default: 30m.
  --keychain <path>          Keychain searched for the signing identities (codesign,
                             productbuild). Default: the user's search list.
  --skip-build                Skip \`swift build -c release\` and \`make -C GuestAgent
                             build-linux build-darwin\`; reuse whatever is already at
                             .build/release and GuestAgent/bin. For iterating on packaging without
                             paying for a full rebuild every time.
  --skip-sign                 Skip codesigning/verifying/probing every Mach-O entirely (and with
                             it the team-id derivation, so the manifest records an empty teamId).
                             Test-only: lets --stage-only and the packaging steps run against
                             non-Mach-O stub binaries. Never use this for a real release -- an
                             unverified vmworker in the pkg means postinstall's signature check
                             (which never re-signs) fails on the installed host.
  --stage-only <dir>          Stage the payload root into <dir> and stop before pkgbuild/
                             productbuild. <dir>/usr/local is exactly the layout
                             \`install.sh --prebuilt-dir\` expects (<prebuilt-dir>/bin,
                             <prebuilt-dir>/libexec, <prebuilt-dir>/share/runnervm) -- pass
                             "<dir>/usr/local" as --prebuilt-dir to install from a staged tree
                             without building a pkg at all.
  -h, --help                  Show this help.
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
        --version) VERSION_FLAG="$2"; shift 2 ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        --sign-identity) SIGN_IDENTITY="$2"; shift 2 ;;
        --installer-identity) INSTALLER_IDENTITY="$2"; shift 2 ;;
        --notarize-key) NOTARY_KEY="$2"; NOTARIZE_REQUESTED=1; shift 2 ;;
        --notarize-key-id) NOTARY_KEY_ID="$2"; NOTARIZE_REQUESTED=1; shift 2 ;;
        --notarize-issuer) NOTARY_ISSUER="$2"; NOTARIZE_REQUESTED=1; shift 2 ;;
        --notarize-timeout) NOTARY_TIMEOUT="$2"; NOTARIZE_REQUESTED=1; shift 2 ;;
        --keychain) KEYCHAIN="$2"; shift 2 ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        --skip-sign) SKIP_SIGN=1; shift ;;
        --stage-only) STAGE_ONLY_DIR="$2"; shift 2 ;;
        -h | --help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
        esac
    done
}

# Refuse option combinations that would silently produce a release-shaped artifact that is not
# actually a release artifact. Runs before anything is built, so a bad invocation costs no time.
validate_options() {
    if [ "$NOTARIZE_REQUESTED" -eq 0 ]; then
        return 0
    fi
    local missing=""
    [ -n "$NOTARY_KEY" ] || missing="$missing --notarize-key"
    [ -n "$NOTARY_KEY_ID" ] || missing="$missing --notarize-key-id"
    [ -n "$NOTARY_ISSUER" ] || missing="$missing --notarize-issuer"
    if [ -n "$missing" ]; then
        die "the notarization flags are required together; missing:$missing"
    fi
    [ -f "$NOTARY_KEY" ] || die "--notarize-key file not found: $NOTARY_KEY"
    if [ -z "$INSTALLER_IDENTITY" ]; then
        die "--notarize-* requires --installer-identity: Apple only notarizes a pkg that is" \
            "already signed with a Developer ID Installer certificate"
    fi
    if [ "$SIGN_IDENTITY" = "-" ]; then
        die "--notarize-* refused with --sign-identity '-': an ad-hoc signed Mach-O is never" \
            "accepted by the notary service; pass a Developer ID Application identity"
    fi
}

# --------------------------------------------------------------------------
# Pure helpers (sourced and exercised directly by scripts/tests/build-package-test.sh)
# --------------------------------------------------------------------------

# Extracts RunnerVMVersion.current's literal value from Version.swift. The single place a version
# bump is authored (docs/design/distribution.md "Version source of truth") -- this script only
# ever reads it, never writes it.
parse_version_from_source() {
    [ -f "$VERSION_SOURCE" ] || die "version source not found: $VERSION_SOURCE"
    local v
    v="$(grep -E 'public static let current' "$VERSION_SOURCE" | sed -E 's/.*"([^"]*)".*/\1/')"
    [ -n "$v" ] || die "could not parse RunnerVMVersion.current from $VERSION_SOURCE"
    printf '%s' "$v"
}

# Sets $VERSION. --version is a confirmation, not an override: it exists so a release workflow can
# assert "the tag I'm about to build matches Version.swift" in one place instead of two.
resolve_version() {
    local parsed
    parsed="$(parse_version_from_source)"
    if [ -n "$VERSION_FLAG" ] && [ "$VERSION_FLAG" != "$parsed" ]; then
        die "--version $VERSION_FLAG does not match Sources/RunnerCore/Version.swift ($parsed);" \
            "bump Version.swift instead of overriding it here"
    fi
    VERSION="${VERSION_FLAG:-$parsed}"
}

# The codesign flags every shipped Mach-O gets, ad-hoc and Developer ID alike -- one flag per
# line so a --keychain path with spaces survives the round trip into an array.
#
# --options runtime and --timestamp are UNCONDITIONAL on purpose: ad-hoc signing accepts both
# (an ad-hoc signature simply carries no timestamp), so dev and CI builds run the exact hardened
# runtime configuration a release does. Notarization requires the hardened runtime; discovering
# that it breaks a binary at release time, on a configuration nothing else ever exercised, is the
# failure mode this avoids.
codesign_common_flags() {
    printf '%s\n' --force --options runtime --timestamp
    if [ -n "$KEYCHAIN" ]; then
        printf '%s\n' --keychain "$KEYCHAIN"
    fi
}

# Sign one Mach-O with a stable identifier and prove the signature verifies. $3, when given, is an
# entitlements plist. Fatal on any failure: an unsigned or unverifiable file in the payload fails
# notarization later, or postinstall on the target host, and neither re-signs.
sign_mach_o() {
    local path="$1" identifier="$2" entitlements="${3:-}"
    local -a args
    args=()
    local flag
    while IFS= read -r flag; do
        args+=("$flag")
    done < <(codesign_common_flags)
    args+=(--sign "$SIGN_IDENTITY" --identifier "$identifier")
    if [ -n "$entitlements" ]; then
        args+=(--entitlements "$entitlements")
    fi
    codesign "${args[@]}" "$path" || die "codesign failed for $path"
    # --deep is a no-op on a bare executable (no nested code); --strict is what actually rejects a
    # damaged or partially written signature.
    codesign --verify --strict "$path" || die "signature verification failed for $path"
}

# Fail-closed signature check, same shape as scripts/install.sh's sign_and_verify_vmworker: sign,
# strict verify, entitlement grep, then a real `probe --json` that exercises
# Virtualization.framework without creating a VM. Every failure is fatal -- there is no useful
# vmworker without this, and postinstall on the target host only ever verifies, never re-signs.
sign_and_verify_vmworker() {
    local bin="$1"
    sign_mach_o "$bin" "$CODESIGN_ID_VMWORKER" "$ENTITLEMENTS_PATH"
    if ! codesign -d --entitlements :- "$bin" 2>&1 | grep -q com.apple.security.virtualization; then
        die "$bin is missing com.apple.security.virtualization"
    fi
    "$bin" probe --json >/dev/null \
        || die "$bin probe failed (entitlement not honoured or binary broken)"
}

# Sign every Mach-O the package ships, on the STAGED copies -- `cp`/`install` can drop a signature
# on some toolchains, so the staged file is the one that must be proven signed, not its source.
#
# All four, not just vmworker: the notary service scans every Mach-O in the payload, and the Go
# guest agent for darwin arrives linker-ad-hoc signed (Identifier=a.out), which notarization
# rejects. The linux guest agent is an ELF and is deliberately not signed.
sign_staged_mach_o() {
    local stage="$1" share="$1/usr/local/share/runnervm"
    sign_mach_o "$stage/usr/local/libexec/runnervm/runnerd" "$CODESIGN_ID_RUNNERD"
    sign_mach_o "$stage/usr/local/bin/runnerctl" "$CODESIGN_ID_RUNNERCTL"
    sign_and_verify_vmworker "$stage/usr/local/libexec/runnervm/vmworker"
    sign_mach_o "$share/guest-agent/darwin-arm64/runnervm-guest-agent" "$CODESIGN_ID_GUEST_AGENT"
}

# Prints the Apple Team ID the given signed binary carries, or nothing for an ad-hoc signature
# (codesign reports "TeamIdentifier=not set") or an unsigned file. The team id is DERIVED from the
# signature, never taken from a flag: what the manifest records has to be what the bits say.
#
# The charset check is also what makes stage_pkg_scripts' `sed s|...|$TEAM|` safe -- a team id can
# never contain the delimiter, a shell metacharacter, or a newline.
resolve_team_id() {
    local bin="$1" team
    team="$(codesign -dv --verbose=4 "$bin" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')"
    if [ "$team" = "not set" ]; then
        team=""
    fi
    case "$team" in
    '') ;;
    *[!A-Z0-9]*)
        die "team identifier '$team' from $bin is not of the form [A-Z0-9]{10}"
        ;;
    *)
        [ "${#team}" -eq 10 ] \
            || die "team identifier '$team' from $bin is not 10 characters"
        ;;
    esac
    printf '%s' "$team"
}

# Renders packaging/pkg/scripts into a throwaway copy with the team id substituted and prints the
# copy's path. The checked-in postinstall is never modified: it is the template, and a build must
# not leave the working tree dirty. An empty team id is legitimate (dev/unsigned build) and makes
# postinstall fall back to its signature-only check.
stage_pkg_scripts() {
    local team="$1" dir f
    dir="$(mktemp -d "${TMPDIR:-/tmp}/rvm-pkg-scripts-XXXXXX")"
    cp "$REPO_ROOT/packaging/pkg/scripts/"* "$dir/"
    for f in "$dir"/*; do
        sed -e "s|$TEAM_ID_PLACEHOLDER|$team|g" "$f" >"$f.rendered"
        mv "$f.rendered" "$f"
        chmod 0755 "$f"
    done
    printf '%s' "$dir"
}

# Submit the built pkg to Apple's notary service, wait for the verdict, then staple the ticket into
# the pkg so an offline host can still verify it. Any verdict other than Accepted prints the notary
# log (the only place that says *why*) and fails the build -- there is no unsigned/unnotarized
# fallback publish.
notarize_and_staple() {
    local pkg="$1" out status submission_id
    log "notarytool submit --wait (timeout $NOTARY_TIMEOUT); this is a round trip to Apple"
    # stdout only: it is the JSON document jq parses. notarytool's progress and error text goes to
    # stderr, which is left alone so it lands in the build log -- folding it into $out would put
    # non-JSON lines in front of the document and turn every submission into a parse failure.
    if ! out="$(xcrun notarytool submit "$pkg" --wait --timeout "$NOTARY_TIMEOUT" \
        --output-format json -k "$NOTARY_KEY" -d "$NOTARY_KEY_ID" -i "$NOTARY_ISSUER")"; then
        printf '%s\n' "$out" >&2
        die "notarytool submit failed (its own output is above)"
    fi
    status="$(printf '%s' "$out" | jq -r '.status // empty' 2>/dev/null || true)"
    submission_id="$(printf '%s' "$out" | jq -r '.id // empty' 2>/dev/null || true)"
    if [ "$status" != "Accepted" ]; then
        printf '%s\n' "$out" >&2
        if [ -n "$submission_id" ]; then
            xcrun notarytool log "$submission_id" \
                -k "$NOTARY_KEY" -d "$NOTARY_KEY_ID" -i "$NOTARY_ISSUER" >&2 \
                || warn "could not fetch the notarization log for submission $submission_id"
        fi
        die "notarization was not accepted (status: ${status:-unknown})"
    fi
    log "notarization accepted (submission ${submission_id:-unknown}); stapling"
    xcrun stapler staple "$pkg" || die "stapler staple failed for $pkg"
    xcrun stapler validate "$pkg" || die "stapler validate failed for $pkg"
}

# True when pkgutil sees a Developer ID Installer certificate in the pkg's chain. This -- not "the
# --installer-identity flag was passed" -- is what release-manifest.json's "signed" records.
pkg_is_developer_id_signed() {
    local pkg="$1" out
    out="$(pkgutil --check-signature "$pkg" 2>&1 || true)"
    case "$out" in
    *"Developer ID Installer"*) return 0 ;;
    esac
    return 1
}

# Re-verify the pkg AFTER stapling, with the same two tools a target host has (both live in
# /usr/sbin, no Xcode): stapling rewrites the file, so a signature or assessment checked before it
# proves nothing about the artifact that actually ships.
verify_stapled_pkg() {
    local pkg="$1" out
    out="$(pkgutil --check-signature "$pkg" 2>&1 || true)"
    if ! pkg_is_developer_id_signed "$pkg"; then
        printf '%s\n' "$out" >&2
        die "$pkg carries no Developer ID Installer signature after stapling"
    fi
    spctl --assess --type install "$pkg" \
        || die "spctl --assess --type install rejected $pkg after stapling"
    printf '%s\n' "$out"
    log "verified after stapling: Developer ID Installer signature + spctl install assessment"
}

# Defensive: the produced pkg's name must satisfy the same constraint bootstrap.sh's
# verify_pkg_name enforces on release-manifest.json's "package" field (docs/design/distribution.md
# "Release artifacts and manifest") -- no "/", no leading "-", charset [A-Za-z0-9._-], must end
# ".pkg", non-empty. $PKG_NAME is a hardcoded constant today, but this still catches a future
# change to it before a bad name ever reaches the manifest.
assert_pkg_name_valid() {
    local pkg_name="$1"
    case "$pkg_name" in
    '')
        die "PKG_NAME is empty -- refusing to write release-manifest.json"
        ;;
    */*)
        die "PKG_NAME '$pkg_name' must not contain '/' -- refusing to write release-manifest.json"
        ;;
    -*)
        die "PKG_NAME '$pkg_name' must not start with '-' -- refusing to write release-manifest.json"
        ;;
    esac
    case "$pkg_name" in
    *[!A-Za-z0-9._-]*)
        die "PKG_NAME '$pkg_name' contains characters outside [A-Za-z0-9._-] -- refusing to write release-manifest.json"
        ;;
    esac
    case "$pkg_name" in
    *.pkg) ;;
    *)
        die "PKG_NAME '$pkg_name' does not end in .pkg -- refusing to write release-manifest.json"
        ;;
    esac
}

# Pretty-printed, stable key order -- exactly docs/design/distribution.md's
# release-manifest.json shape. The key set is constant: "teamId" is "" and "notarized" is false on
# a dev build rather than absent, so every consumer parses one shape.
# $3 and $5 are "0" or "1"; everything else is a plain string.
write_manifest() {
    # Explicit, because a caller left on the old 4-argument form would otherwise write the output
    # path into "teamId" before failing on an unbound $6.
    [ $# -eq 6 ] \
        || die "write_manifest takes 6 arguments (version sha signed teamId notarized out), got $#"
    local version="$1" sha="$2" signed="$3" team="$4" notarized="$5" out="$6"
    local signed_json="false" notarized_json="false"
    [ "$signed" = "1" ] && signed_json="true"
    [ "$notarized" = "1" ] && notarized_json="true"
    command -v jq >/dev/null 2>&1 || die "jq is required to write release-manifest.json"
    jq -n \
        --arg version "$version" \
        --arg architecture "$PKG_ARCH" \
        --arg minimumMacOS "$PKG_MIN_MACOS" \
        --arg package "$PKG_NAME" \
        --arg sha256 "$sha" \
        --argjson signed "$signed_json" \
        --arg teamId "$team" \
        --argjson notarized "$notarized_json" \
        --arg license "$PKG_LICENSE" \
        '{version:$version,architecture:$architecture,minimumMacOS:$minimumMacOS,
          package:$package,sha256:$sha256,signed:$signed,teamId:$teamId,
          notarized:$notarized,license:$license}' \
        >"$out"
}

# --------------------------------------------------------------------------
# Build steps
# --------------------------------------------------------------------------
build_swift() {
    if [ "$SKIP_BUILD" -eq 1 ]; then
        log "--skip-build: reusing $REPO_ROOT/.build/release"
        return 0
    fi
    log "swift build -c release (runnerd, runnerctl, vmworker)"
    # One invocation per product, not `--product a --product b --product c`: SwiftPM's argument
    # parser keeps only the last --product given rather than building their union (verified
    # locally -- a single multi-flag release build only links the last product named, silently;
    # nothing about the command's exit status says so). scripts/install.sh and ci.yml's "Build
    # (release config)" step share this same multi-flag invocation and are equally affected, but
    # fixing those is out of scope here (see CONSTRAINTS in this change's task).
    local product
    for product in runnerd runnerctl vmworker; do
        env -C "$REPO_ROOT" swift build -c release --product "$product"
    done
}

build_guest_agents() {
    if [ "$SKIP_BUILD" -eq 1 ]; then
        log "--skip-build: reusing $REPO_ROOT/GuestAgent/bin"
        return 0
    fi
    log "make -C GuestAgent build-linux build-darwin (VERSION=$VERSION)"
    make -C "$REPO_ROOT/GuestAgent" VERSION="$VERSION" build-linux build-darwin
}

# --------------------------------------------------------------------------
# Stage the payload root exactly per docs/design/distribution.md's "Package layout":
#   <stage>/usr/local/bin/runnerctl
#   <stage>/usr/local/libexec/runnervm/{runnerd,vmworker}
#   <stage>/usr/local/share/runnervm/{VERSION,Resources/,recipes/,guest-agent/{linux,darwin}-arm64/,
#                                      launchd/,scripts/{,lib/},notices/}
# <stage>/usr/local is exactly what `install.sh --prebuilt-dir` expects.
# --------------------------------------------------------------------------
stage_payload() {
    local stage="$1" share="$1/usr/local/share/runnervm"

    rm -rf "$stage"
    mkdir -p \
        "$stage/usr/local/bin" \
        "$stage/usr/local/libexec/runnervm" \
        "$share/Resources" \
        "$share/recipes" \
        "$share/guest-agent/linux-arm64" \
        "$share/guest-agent/darwin-arm64" \
        "$share/launchd" \
        "$share/scripts/lib" \
        "$share/notices"

    cp "$RUNNERCTL_BUILT" "$stage/usr/local/bin/runnerctl"
    cp "$RUNNERD_BUILT" "$stage/usr/local/libexec/runnervm/runnerd"
    cp "$VMWORKER_BUILT" "$stage/usr/local/libexec/runnervm/vmworker"

    printf '%s\n' "$VERSION" >"$share/VERSION"

    cp -R "$REPO_ROOT/Resources/." "$share/Resources/"
    cp -R "$REPO_ROOT/images/recipes/." "$share/recipes/"

    cp "$GUEST_AGENT_LINUX_ARM64" "$share/guest-agent/linux-arm64/runnervm-guest-agent"
    cp "$GUEST_AGENT_DARWIN_ARM64" "$share/guest-agent/darwin-arm64/runnervm-guest-agent"
    # The in-guest LaunchDaemon plist the macOS provisioning script stages into every image;
    # provision-macos-tart.sh resolves it relative to the agent binary on packaged hosts.
    mkdir -p "$share/guest-agent/launchd"
    cp "$REPO_ROOT/GuestAgent/packaging/launchd/com.runnervm.guest-agent.plist" \
        "$share/guest-agent/launchd/com.runnervm.guest-agent.plist"

    cp "$REPO_ROOT/packaging/launchd/com.runnervm.runnerd.agent.plist" \
        "$REPO_ROOT/packaging/launchd/com.runnervm.runnerd.daemon.plist" \
        "$REPO_ROOT/packaging/launchd/README.md" \
        "$share/launchd/"

    cp "$REPO_ROOT/scripts/provision-macos-tart.sh" \
        "$REPO_ROOT/scripts/qualify-macos-image.sh" \
        "$REPO_ROOT/scripts/qualify-host.sh" \
        "$share/scripts/"
    cp "$REPO_ROOT"/scripts/lib/*.sh "$share/scripts/lib/"

    cp "$REPO_ROOT/LICENSE" "$REPO_ROOT/NOTICE" "$REPO_ROOT/PROVENANCE.md" "$share/notices/"

    # Normalize modes: dirs 0755, files 0644, except the compiled binaries and guest agents (0755)
    # -- fixed after copying rather than per-source-file, so a source file's on-disk mode (git
    # checkout, umask, a stub built by a test) never leaks into the shipped package.
    find "$stage" -type d -exec chmod 0755 {} +
    find "$stage" -type f -exec chmod 0644 {} +
    chmod 0755 \
        "$stage/usr/local/bin/runnerctl" \
        "$stage/usr/local/libexec/runnervm/runnerd" \
        "$stage/usr/local/libexec/runnervm/vmworker" \
        "$share/guest-agent/linux-arm64/runnervm-guest-agent" \
        "$share/guest-agent/darwin-arm64/runnervm-guest-agent"
}

# --------------------------------------------------------------------------
# pkgbuild (component) -> productbuild (distribution) -> checksum -> manifest
# --------------------------------------------------------------------------
build_pkg() {
    local stage="$1" component_dir="$2" scripts_dir

    # postinstall is templated with the team id derived above, into a copy -- pkgbuild embeds
    # whatever it is handed, and the checked-in file stays the template.
    scripts_dir="$(stage_pkg_scripts "$TEAM_ID")"
    log "pkgbuild --root $stage (postinstall team id: '${TEAM_ID}')"
    pkgbuild --root "$stage" \
        --identifier "$PKG_IDENTIFIER" \
        --version "$VERSION" \
        --install-location / \
        --scripts "$scripts_dir" \
        "$component_dir/RunnerVM-component.pkg" \
        || { rm -rf "$scripts_dir"; die "pkgbuild failed"; }
    rm -rf "$scripts_dir"

    mkdir -p "$OUT_DIR"
    local -a productbuild_args
    productbuild_args=(
        --distribution "$REPO_ROOT/packaging/pkg/distribution.xml"
        --package-path "$component_dir"
    )
    if [ -n "$INSTALLER_IDENTITY" ]; then
        productbuild_args+=(--sign "$INSTALLER_IDENTITY")
    fi
    if [ -n "$KEYCHAIN" ]; then
        productbuild_args+=(--keychain "$KEYCHAIN")
    fi
    log "productbuild -> $OUT_DIR/$PKG_NAME"
    productbuild "${productbuild_args[@]}" "$OUT_DIR/$PKG_NAME" \
        || die "productbuild failed"

    local signed=0
    if pkg_is_developer_id_signed "$OUT_DIR/$PKG_NAME"; then
        signed=1
    elif [ -n "$INSTALLER_IDENTITY" ]; then
        die "--installer-identity was given but $OUT_DIR/$PKG_NAME carries no Developer ID" \
            "Installer signature"
    fi

    # Notarize, staple and re-verify BEFORE the checksum: `stapler staple` rewrites the pkg in
    # place, so a sha256 taken any earlier describes a file nobody will ever download.
    if [ "$NOTARIZE_REQUESTED" -eq 1 ]; then
        notarize_and_staple "$OUT_DIR/$PKG_NAME"
        NOTARIZED=1
        verify_stapled_pkg "$OUT_DIR/$PKG_NAME"
    fi

    local sha_line sha
    sha_line="$(cd "$OUT_DIR" && shasum -a 256 "$PKG_NAME" | tee "$PKG_NAME.sha256")"
    sha="${sha_line%% *}"

    assert_pkg_name_valid "$PKG_NAME"
    write_manifest "$VERSION" "$sha" "$signed" "$TEAM_ID" "$NOTARIZED" \
        "$OUT_DIR/release-manifest.json"

    log "wrote $OUT_DIR/$PKG_NAME"
    log "wrote $OUT_DIR/$PKG_NAME.sha256"
    log "wrote $OUT_DIR/release-manifest.json"
}

# --------------------------------------------------------------------------
main() {
    parse_args "$@"
    validate_options
    resolve_version

    build_swift
    build_guest_agents

    if [ "$SKIP_SIGN" -eq 1 ]; then
        warn "--skip-sign: no Mach-O will be codesigned, verified or probed"
    else
        # Early detection: sign and probe the built vmworker before anything is staged, so a
        # broken identity, an unreachable timestamp server or a hardened runtime that the binary
        # cannot start under fails here rather than after a full staging pass.
        log "codesign vmworker (identity: $SIGN_IDENTITY)"
        sign_and_verify_vmworker "$VMWORKER_BUILT"
    fi

    local stage cleanup_stage=0
    if [ -n "$STAGE_ONLY_DIR" ]; then
        stage="$STAGE_ONLY_DIR"
    else
        stage="$(mktemp -d "${TMPDIR:-/tmp}/rvm-build-package-stage-XXXXXX")"
        cleanup_stage=1
    fi
    stage_payload "$stage"

    if [ "$SKIP_SIGN" -ne 1 ]; then
        sign_staged_mach_o "$stage"
        TEAM_ID="$(resolve_team_id "$stage/usr/local/libexec/runnervm/vmworker")" \
            || die "could not resolve the signing team id from the staged vmworker"
        if [ -n "$TEAM_ID" ]; then
            log "signed by team $TEAM_ID"
        else
            log "ad-hoc signature: no team id (release-manifest.json records \"teamId\": \"\")"
        fi
    fi

    if [ -n "$STAGE_ONLY_DIR" ]; then
        log "--stage-only: staged payload at $stage; stopping before pkgbuild"
        return 0
    fi

    local component_dir
    component_dir="$(mktemp -d "${TMPDIR:-/tmp}/rvm-build-package-component-XXXXXX")"
    build_pkg "$stage" "$component_dir"
    rm -rf "$component_dir"
    [ "$cleanup_stage" -eq 1 ] && rm -rf "$stage"
}

# Guarded so scripts/tests/build-package-test.sh can source this file and exercise its pure
# helpers (parse_version_from_source, write_manifest, codesign_common_flags, stage_pkg_scripts,
# resolve_team_id, stage_payload) with no swift build, no guest-agent build and no pkgbuild.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
