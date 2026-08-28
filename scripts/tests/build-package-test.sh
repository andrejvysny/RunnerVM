#!/usr/bin/env bash
# Unit checks for scripts/build-package.sh that need no swift build, no guest-agent build and no
# pkgbuild/productbuild.
#
# Same two styles as scripts/tests/publish-images-test.sh: argument handling that exits is
# exercised as a real subprocess, and the pure helpers (parse_version_from_source, write_manifest)
# are exercised by `source`-ing the script, which guards its own `main` behind
# `[ "${BASH_SOURCE[0]}" = "${0}" ]` exactly so this file can call them directly.
#
# The staging layout (--stage-only --skip-build --skip-sign) is exercised as a real subprocess
# against fixture binaries swapped in at the exact paths build-package.sh reads under --skip-build
# (.build/release/{runnerd,runnerctl,vmworker}, GuestAgent/bin/{linux,darwin}-arm64/
# runnervm-guest-agent) -- both are gitignored build-artifact directories, never source, so this is
# safe to do against the real checkout. Anything already there (a developer's own prior release
# build) is backed up and restored, never lost.
#
# usage: scripts/tests/build-package-test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/build-package.sh"
TWORK="$(mktemp -d "${TMPDIR:-/tmp}/rvm-build-package-test-XXXXXX")"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }

expect_contains() {
    local haystack="$1" needle="$2" what="$3"
    case "$haystack" in
    *"$needle"*) ok "$what" ;;
    *) no "$what" "expected to find: $needle" ;;
    esac
}

expect_eq() {
    if [ "$1" = "$2" ]; then ok "$3"; else no "$3" "expected '$2', got '$1'"; fi
}

# --------------------------------------------------------------------------
# Fixture binaries at the real, fixed paths --skip-build reads (.build/release,
# GuestAgent/bin/*-arm64). Both are gitignored build-output dirs -- never source -- but may
# already hold a developer's real build, so back up/restore by position rather than assuming
# they were empty.
# --------------------------------------------------------------------------
FAKE_PATHS=(
    "$REPO_ROOT/.build/release/runnerd"
    "$REPO_ROOT/.build/release/runnerctl"
    "$REPO_ROOT/.build/release/vmworker"
    "$REPO_ROOT/GuestAgent/bin/linux-arm64/runnervm-guest-agent"
    "$REPO_ROOT/GuestAgent/bin/darwin-arm64/runnervm-guest-agent"
)
BACKUP_DIR="$TWORK/backup"

install_fake_binaries() {
    mkdir -p "$BACKUP_DIR"
    local p i=0
    for p in "${FAKE_PATHS[@]}"; do
        i=$((i + 1))
        if [ -e "$p" ]; then
            mv "$p" "$BACKUP_DIR/orig-$i"
        fi
        mkdir -p "$(dirname "$p")"
        printf '#!/bin/sh\necho stub\n' >"$p"
    done
}

restore_real_binaries() {
    local p i=0
    for p in "${FAKE_PATHS[@]}"; do
        i=$((i + 1))
        if [ -e "$BACKUP_DIR/orig-$i" ]; then
            mv "$BACKUP_DIR/orig-$i" "$p"
        else
            rm -f "$p"
        fi
    done
    # Best-effort: drop a .build/release we created from nothing. Never fatal, never touches
    # anything with content still in it.
    rmdir "$REPO_ROOT/.build/release" 2>/dev/null || true
}

trap 'restore_real_binaries; rm -rf "$TWORK"' EXIT

# --------------------------------------------------------------------------
# 1. Argument handling, as a subprocess (these paths exit before touching a build)
# --------------------------------------------------------------------------
if help_out="$("$SCRIPT" --help 2>&1)"; then
    expect_contains "$help_out" "usage: build-package.sh" "--help prints usage"
    expect_contains "$help_out" "--stage-only" "--help documents --stage-only"
    expect_contains "$help_out" "--skip-build" "--help documents --skip-build"
    expect_contains "$help_out" "--skip-sign" "--help documents --skip-sign"
    expect_contains "$help_out" "prebuilt-dir" "--help documents the --stage-only / install.sh --prebuilt-dir relationship"
else
    no "--help exits 0" "$help_out"
fi

set +e
out="$("$SCRIPT" --nonsense 2>&1)"
code=$?
set -e
expect_eq "$code" "2" "an unknown flag exits 2"
expect_contains "$out" "unknown option: --nonsense" "unknown-flag error names the flag"

if out="$("$SCRIPT" --skip-build --skip-sign --version 9.9.9 --stage-only "$TWORK/mismatch-stage" 2>&1)"; then
    no "--version mismatched with Version.swift exits non-zero" "$out"
else
    expect_contains "$out" "9.9.9" "version-mismatch error names the given version"
    expect_contains "$out" "Version.swift" "version-mismatch error names Version.swift"
fi

# --------------------------------------------------------------------------
# 2. Pure helpers, by sourcing (main() never runs: BASH_SOURCE guard)
# --------------------------------------------------------------------------
# shellcheck source=SCRIPTDIR/../build-package.sh
# shellcheck disable=SC1091 # dynamic path; run shellcheck -x to actually follow it
source "$SCRIPT"

expect_eq "$(parse_version_from_source)" "0.2.0" \
    "version parsed from Version.swift matches 0.2.0"

MANIFEST_OUT="$TWORK/release-manifest.json"
write_manifest "9.9.9" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "0" "$MANIFEST_OUT"
if [ -f "$MANIFEST_OUT" ]; then
    ok "write_manifest writes a file"
    manifest_err=""
    if manifest_err="$(python3 -c "
import json
with open('$MANIFEST_OUT') as f:
    data = json.load(f)
expected_keys = {'version', 'architecture', 'minimumMacOS', 'package', 'sha256', 'signed', 'license'}
assert set(data.keys()) == expected_keys, f'key set mismatch: {sorted(data.keys())}'
assert data['version'] == '9.9.9', data['version']
assert data['architecture'] == 'arm64', data['architecture']
assert data['minimumMacOS'] == '15.0', data['minimumMacOS']
assert data['package'] == 'RunnerVM-macos-arm64.pkg', data['package']
assert data['sha256'] == 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef', data['sha256']
assert data['signed'] is False, data['signed']
assert data['license'] == 'Apache-2.0', data['license']
" 2>&1)"; then
        ok "write_manifest produces the exact documented key set and values (signed: false)"
    else
        no "write_manifest produces the exact documented key set and values (signed: false)" "$manifest_err"
    fi
else
    no "write_manifest writes a file"
fi

write_manifest "9.9.9" "abc123" "1" "$MANIFEST_OUT"
manifest_err=""
if manifest_err="$(python3 -c "
import json
with open('$MANIFEST_OUT') as f:
    data = json.load(f)
assert data['signed'] is True, data['signed']
" 2>&1)"; then
    ok "write_manifest records signed: true when told so"
else
    no "write_manifest records signed: true when told so" "$manifest_err"
fi

# --------------------------------------------------------------------------
# 3. --stage-only against fixture binaries: verify the staged layout matches
#    docs/design/distribution.md exactly. No swift build, no guest-agent build, no pkgbuild.
# --------------------------------------------------------------------------
install_fake_binaries
STAGE="$TWORK/stage"
if stage_out="$("$SCRIPT" --skip-build --skip-sign --stage-only "$STAGE" 2>&1)"; then
    ok "--stage-only --skip-build --skip-sign exits 0 against fixture binaries"
else
    no "--stage-only --skip-build --skip-sign exits 0 against fixture binaries" "$stage_out"
fi

expect_path_exists() {
    local what="$1" path="$2"
    if [ -e "$path" ]; then ok "$what"; else no "$what" "missing: $path"; fi
}

USR_LOCAL="$STAGE/usr/local"
expect_path_exists "staged: bin/runnerctl" "$USR_LOCAL/bin/runnerctl"
expect_path_exists "staged: libexec/runnervm/runnerd" "$USR_LOCAL/libexec/runnervm/runnerd"
expect_path_exists "staged: libexec/runnervm/vmworker" "$USR_LOCAL/libexec/runnervm/vmworker"
expect_path_exists "staged: share/runnervm/VERSION" "$USR_LOCAL/share/runnervm/VERSION"
expect_path_exists "staged: share/runnervm/Resources/vmworker.entitlements" \
    "$USR_LOCAL/share/runnervm/Resources/vmworker.entitlements"
expect_path_exists "staged: share/runnervm/recipes/ubuntu-24/Runnerfile" \
    "$USR_LOCAL/share/runnervm/recipes/ubuntu-24/Runnerfile"
expect_path_exists "staged: share/runnervm/guest-agent/linux-arm64/runnervm-guest-agent" \
    "$USR_LOCAL/share/runnervm/guest-agent/linux-arm64/runnervm-guest-agent"
expect_path_exists "staged: share/runnervm/guest-agent/darwin-arm64/runnervm-guest-agent" \
    "$USR_LOCAL/share/runnervm/guest-agent/darwin-arm64/runnervm-guest-agent"
expect_path_exists "staged: share/runnervm/launchd/com.runnervm.runnerd.agent.plist" \
    "$USR_LOCAL/share/runnervm/launchd/com.runnervm.runnerd.agent.plist"
expect_path_exists "staged: share/runnervm/launchd/com.runnervm.runnerd.daemon.plist" \
    "$USR_LOCAL/share/runnervm/launchd/com.runnervm.runnerd.daemon.plist"
expect_path_exists "staged: share/runnervm/launchd/README.md" \
    "$USR_LOCAL/share/runnervm/launchd/README.md"
expect_path_exists "staged: share/runnervm/scripts/provision-macos-tart.sh" \
    "$USR_LOCAL/share/runnervm/scripts/provision-macos-tart.sh"
expect_path_exists "staged: share/runnervm/scripts/qualify-macos-image.sh" \
    "$USR_LOCAL/share/runnervm/scripts/qualify-macos-image.sh"
expect_path_exists "staged: share/runnervm/scripts/qualify-host.sh" \
    "$USR_LOCAL/share/runnervm/scripts/qualify-host.sh"
expect_path_exists "staged: share/runnervm/scripts/lib/macos-guest-provision.sh" \
    "$USR_LOCAL/share/runnervm/scripts/lib/macos-guest-provision.sh"
expect_path_exists "staged: share/runnervm/scripts/lib/live-common.sh" \
    "$USR_LOCAL/share/runnervm/scripts/lib/live-common.sh"
expect_path_exists "staged: share/runnervm/scripts/lib/macos-provision-vm.sh" \
    "$USR_LOCAL/share/runnervm/scripts/lib/macos-provision-vm.sh"
expect_path_exists "staged: share/runnervm/scripts/lib/live-macos.sh" \
    "$USR_LOCAL/share/runnervm/scripts/lib/live-macos.sh"
expect_path_exists "staged: share/runnervm/notices/LICENSE" "$USR_LOCAL/share/runnervm/notices/LICENSE"
expect_path_exists "staged: share/runnervm/notices/NOTICE" "$USR_LOCAL/share/runnervm/notices/NOTICE"
expect_path_exists "staged: share/runnervm/notices/PROVENANCE.md" \
    "$USR_LOCAL/share/runnervm/notices/PROVENANCE.md"

expect_eq "$(cat "$USR_LOCAL/share/runnervm/VERSION")" "0.2.0" "staged VERSION file contains 0.2.0"

# Mode spot-checks: binaries and guest agents are 0755, everything else 0644, dirs 0755.
mode_of() { stat -f '%Lp' "$1"; }
expect_eq "$(mode_of "$USR_LOCAL/bin/runnerctl")" "755" "runnerctl is 0755"
expect_eq "$(mode_of "$USR_LOCAL/libexec/runnervm/vmworker")" "755" "vmworker is 0755"
expect_eq "$(mode_of "$USR_LOCAL/share/runnervm/guest-agent/linux-arm64/runnervm-guest-agent")" "755" \
    "linux-arm64 guest agent is 0755"
expect_eq "$(mode_of "$USR_LOCAL/share/runnervm/guest-agent/darwin-arm64/runnervm-guest-agent")" "755" \
    "darwin-arm64 guest agent is 0755"
expect_eq "$(mode_of "$USR_LOCAL/share/runnervm/VERSION")" "644" "VERSION file is 0644"
expect_eq "$(mode_of "$USR_LOCAL/share/runnervm/notices/LICENSE")" "644" "LICENSE is 0644"
expect_eq "$(mode_of "$USR_LOCAL/share/runnervm/scripts/qualify-host.sh")" "644" \
    "staged scripts are 0644, not executable"
expect_eq "$(mode_of "$USR_LOCAL/share/runnervm")" "755" "share/runnervm dir is 0755"
expect_eq "$(mode_of "$USR_LOCAL/share/runnervm/scripts/lib")" "755" "scripts/lib dir is 0755"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
