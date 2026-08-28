#!/usr/bin/env bash
# Build the unsigned (or Developer-ID-signed installer) RunnerVM macOS package: a swift release
# build, the Linux+macOS guest agents, an ad-hoc-signed vmworker, a staged payload root matching
# docs/design/distribution.md's package layout exactly, then `pkgbuild`/`productbuild` into
# dist/RunnerVM-macos-arm64.pkg plus its sha256 and release-manifest.json.
#
# See docs/design/distribution.md ("Package layout", "Release artifacts and manifest", "Unsigned
# phase") for the contract this script implements. Read that first if anything here looks
# arbitrary -- it mostly isn't.
#
# usage:
#   scripts/build-package.sh [--version X] [--out dist] [--sign-identity -] \
#     [--installer-identity <id>] [--skip-build] [--stage-only <dir>]
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

log()  { printf '[build-package] %s\n' "$*"; }
warn() { printf '[build-package] warning: %s\n' "$*" >&2; }
die()  { printf '[build-package] error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
usage: build-package.sh [options]

Builds the RunnerVM macOS installer package: swift release binaries, the Linux+macOS guest
agents, a signed vmworker, a staged payload root, then pkgbuild/productbuild into
<out>/$PKG_NAME plus <out>/$PKG_NAME.sha256 and <out>/release-manifest.json.

options:
  --version <X>             Version to build. Default: parsed from
                             Sources/RunnerCore/Version.swift. If both this flag and Version.swift
                             are present, they must agree -- this flag can only confirm the
                             version, never override it (the version bump is authored in exactly
                             one place; see docs/design/distribution.md "Version source of truth").
  --out <dir>                Output directory for the pkg, checksum and manifest. Default: dist/
  --sign-identity <id>        codesign identity for vmworker. Default: "-" (ad-hoc). Pass a
                             Developer ID Application identity for a signed vmworker.
  --installer-identity <id>  productbuild identity for the distribution pkg itself. Default:
                             empty, which produces an unsigned pkg (release-manifest.json's
                             "signed" is false). Pass a Developer ID Installer identity to sign
                             the pkg and record "signed": true.
  --skip-build                Skip \`swift build -c release\` and \`make -C GuestAgent
                             build-linux build-darwin\`; reuse whatever is already at
                             .build/release and GuestAgent/bin. For iterating on packaging without
                             paying for a full rebuild every time.
  --skip-sign                 Skip codesigning/verifying/probing vmworker entirely. Test-only: lets
                             --stage-only exercise the staging layout against non-Mach-O stub
                             binaries. Never use this for a real release -- an unverified vmworker
                             in the pkg means postinstall's signature check (which never re-signs)
                             fails on the installed host.
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
        --skip-build) SKIP_BUILD=1; shift ;;
        --skip-sign) SKIP_SIGN=1; shift ;;
        --stage-only) STAGE_ONLY_DIR="$2"; shift 2 ;;
        -h | --help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
        esac
    done
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

# Fail-closed signature check, reused (same shape) from scripts/install.sh's
# sign_and_verify_vmworker: force-sign, strict verify, entitlement grep, then a real `probe --json`
# that exercises Virtualization.framework without creating a VM. Every failure is fatal -- there is
# no useful vmworker without this, and postinstall on the target host only ever verifies, never
# re-signs.
sign_and_verify_vmworker() {
    local bin="$1"
    codesign --force --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS_PATH" "$bin" \
        || die "codesign failed for $bin"
    codesign --verify --strict "$bin" \
        || die "signature verification failed for $bin"
    if ! codesign -d --entitlements :- "$bin" 2>&1 | grep -q com.apple.security.virtualization; then
        die "$bin is missing com.apple.security.virtualization"
    fi
    "$bin" probe --json >/dev/null \
        || die "$bin probe failed (entitlement not honoured or binary broken)"
}

# Pretty-printed, stable key order -- exactly docs/design/distribution.md's
# release-manifest.json shape. $3 is "0" or "1"; everything else is a plain string.
write_manifest() {
    local version="$1" sha="$2" signed="$3" out="$4" signed_json="false"
    [ "$signed" = "1" ] && signed_json="true"
    command -v jq >/dev/null 2>&1 || die "jq is required to write release-manifest.json"
    jq -n \
        --arg version "$version" \
        --arg architecture "$PKG_ARCH" \
        --arg minimumMacOS "$PKG_MIN_MACOS" \
        --arg package "$PKG_NAME" \
        --arg sha256 "$sha" \
        --argjson signed "$signed_json" \
        --arg license "$PKG_LICENSE" \
        '{version:$version,architecture:$architecture,minimumMacOS:$minimumMacOS,
          package:$package,sha256:$sha256,signed:$signed,license:$license}' \
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
    local stage="$1" component_dir="$2"

    log "pkgbuild --root $stage"
    pkgbuild --root "$stage" \
        --identifier "$PKG_IDENTIFIER" \
        --version "$VERSION" \
        --install-location / \
        --scripts "$REPO_ROOT/packaging/pkg/scripts" \
        "$component_dir/RunnerVM-component.pkg" \
        || die "pkgbuild failed"

    mkdir -p "$OUT_DIR"
    local -a productbuild_args
    productbuild_args=(
        --distribution "$REPO_ROOT/packaging/pkg/distribution.xml"
        --package-path "$component_dir"
    )
    if [ -n "$INSTALLER_IDENTITY" ]; then
        productbuild_args+=(--sign "$INSTALLER_IDENTITY")
    fi
    log "productbuild -> $OUT_DIR/$PKG_NAME"
    productbuild "${productbuild_args[@]}" "$OUT_DIR/$PKG_NAME" \
        || die "productbuild failed"

    local sha_line sha signed
    sha_line="$(cd "$OUT_DIR" && shasum -a 256 "$PKG_NAME" | tee "$PKG_NAME.sha256")"
    sha="${sha_line%% *}"

    signed=0
    [ -n "$INSTALLER_IDENTITY" ] && signed=1
    write_manifest "$VERSION" "$sha" "$signed" "$OUT_DIR/release-manifest.json"

    log "wrote $OUT_DIR/$PKG_NAME"
    log "wrote $OUT_DIR/$PKG_NAME.sha256"
    log "wrote $OUT_DIR/release-manifest.json"
}

# --------------------------------------------------------------------------
main() {
    parse_args "$@"
    resolve_version

    build_swift
    build_guest_agents

    if [ "$SKIP_SIGN" -eq 1 ]; then
        warn "--skip-sign: vmworker will not be codesigned, verified or probed"
    else
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

    # `install`/`cp` can strip a code signature on some toolchains (see install.sh); re-assert it
    # on the staged copy so what actually lands in the pkg is proven signed, not just the source
    # binary before it moved.
    if [ "$SKIP_SIGN" -ne 1 ]; then
        sign_and_verify_vmworker "$stage/usr/local/libexec/runnervm/vmworker"
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
# helpers (parse_version_from_source, write_manifest, stage_payload) with no swift build, no
# guest-agent build and no pkgbuild.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
