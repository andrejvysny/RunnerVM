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
    expect_contains "$help_out" "--notarize-key " "--help documents --notarize-key"
    expect_contains "$help_out" "--notarize-key-id" "--help documents --notarize-key-id"
    expect_contains "$help_out" "--notarize-issuer" "--help documents --notarize-issuer"
    expect_contains "$help_out" "--notarize-timeout" "--help documents --notarize-timeout"
    expect_contains "$help_out" "--keychain" "--help documents --keychain"
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
# 1b. Notarization option validation, as a subprocess. Every one of these refuses BEFORE any build
#     step runs: an invocation that cannot produce a notarized release must not burn a release
#     build first, and must never quietly produce an unnotarized pkg instead.
# --------------------------------------------------------------------------
NOTARY_KEY_FIXTURE="$TWORK/notary.p8"
: >"$NOTARY_KEY_FIXTURE"

if out="$("$SCRIPT" --notarize-key "$NOTARY_KEY_FIXTURE" 2>&1)"; then
    no "--notarize-key alone exits non-zero" "$out"
else
    expect_contains "$out" "required together" "partial notarize flags name the constraint"
    expect_contains "$out" "--notarize-key-id" "partial notarize flags name the missing key id"
    expect_contains "$out" "--notarize-issuer" "partial notarize flags name the missing issuer"
fi

if out="$("$SCRIPT" --notarize-timeout 5m 2>&1)"; then
    no "--notarize-timeout alone exits non-zero" "$out"
else
    expect_contains "$out" "required together" \
        "--notarize-timeout alone is refused like any other partial notarize flag"
fi

if out="$("$SCRIPT" --sign-identity "Developer ID Application: X" \
    --notarize-key "$NOTARY_KEY_FIXTURE" --notarize-key-id K --notarize-issuer I 2>&1)"; then
    no "--notarize-* without --installer-identity exits non-zero" "$out"
else
    expect_contains "$out" "--installer-identity" \
        "notarize-without-installer-identity error names the missing flag"
fi

if out="$("$SCRIPT" --installer-identity "Developer ID Installer: X" \
    --notarize-key "$NOTARY_KEY_FIXTURE" --notarize-key-id K --notarize-issuer I 2>&1)"; then
    no "--notarize-* with the default ad-hoc --sign-identity exits non-zero" "$out"
else
    expect_contains "$out" "ad-hoc" "notarize-with-ad-hoc error explains why ad-hoc cannot work"
fi

if out="$("$SCRIPT" --sign-identity - --installer-identity "Developer ID Installer: X" \
    --notarize-key "$NOTARY_KEY_FIXTURE" --notarize-key-id K --notarize-issuer I 2>&1)"; then
    no "--notarize-* with an explicit --sign-identity - exits non-zero" "$out"
else
    expect_contains "$out" "ad-hoc" \
        "explicit --sign-identity - is refused for notarization too"
fi

# --------------------------------------------------------------------------
# 2. Pure helpers, by sourcing (main() never runs: BASH_SOURCE guard)
# --------------------------------------------------------------------------
# shellcheck source=SCRIPTDIR/../build-package.sh
# shellcheck disable=SC1091 # dynamic path; run shellcheck -x to actually follow it
source "$SCRIPT"

# Derived from Version.swift itself, never hardcoded: a version bump must not break this suite.
EXPECTED_VERSION="$(sed -nE 's/.*public static let current = "([^"]+)".*/\1/p' "$REPO_ROOT/Sources/RunnerCore/Version.swift")"
[ -n "$EXPECTED_VERSION" ] || { echo "could not read RunnerVMVersion.current from Version.swift" >&2; exit 1; }
expect_eq "$(parse_version_from_source)" "$EXPECTED_VERSION" \
    "version parsed from Version.swift matches RunnerVMVersion.current ($EXPECTED_VERSION)"

MANIFEST_OUT="$TWORK/release-manifest.json"
write_manifest "9.9.9" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "0" "" "0" \
    "$MANIFEST_OUT"
if [ -f "$MANIFEST_OUT" ]; then
    ok "write_manifest writes a file"
    manifest_err=""
    if manifest_err="$(python3 -c "
import json
with open('$MANIFEST_OUT') as f:
    data = json.load(f)
expected_keys = {'version', 'architecture', 'minimumMacOS', 'package', 'sha256', 'signed',
                 'teamId', 'notarized', 'license'}
assert set(data.keys()) == expected_keys, f'key set mismatch: {sorted(data.keys())}'
assert data['version'] == '9.9.9', data['version']
assert data['architecture'] == 'arm64', data['architecture']
assert data['minimumMacOS'] == '15.0', data['minimumMacOS']
assert data['package'] == 'RunnerVM-macos-arm64.pkg', data['package']
assert data['sha256'] == 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef', data['sha256']
assert data['signed'] is False, data['signed']
assert data['teamId'] == '', repr(data['teamId'])
assert data['notarized'] is False, data['notarized']
assert data['license'] == 'Apache-2.0', data['license']
" 2>&1)"; then
        ok "write_manifest produces the exact 9-key set and values (unsigned: teamId '', notarized false)"
    else
        no "write_manifest produces the exact 9-key set and values (unsigned: teamId '', notarized false)" "$manifest_err"
    fi
else
    no "write_manifest writes a file"
fi

# A release build: the key set is identical, only the values differ. Anything that decodes one
# manifest must decode the other.
write_manifest "9.9.9" "abc123" "1" "ABCDE12345" "1" "$MANIFEST_OUT"
manifest_err=""
if manifest_err="$(python3 -c "
import json
with open('$MANIFEST_OUT') as f:
    data = json.load(f)
expected_keys = {'version', 'architecture', 'minimumMacOS', 'package', 'sha256', 'signed',
                 'teamId', 'notarized', 'license'}
assert set(data.keys()) == expected_keys, f'key set mismatch: {sorted(data.keys())}'
assert data['signed'] is True, data['signed']
assert data['teamId'] == 'ABCDE12345', data['teamId']
assert data['notarized'] is True, data['notarized']
" 2>&1)"; then
    ok "write_manifest records signed/teamId/notarized for a release build, same key set"
else
    no "write_manifest records signed/teamId/notarized for a release build, same key set" "$manifest_err"
fi

# signed and notarized are independent: a signed-but-not-notarized pkg is a real (if rejected)
# state, and the manifest must be able to say so.
write_manifest "9.9.9" "abc123" "1" "ABCDE12345" "0" "$MANIFEST_OUT"
manifest_err=""
if manifest_err="$(python3 -c "
import json
with open('$MANIFEST_OUT') as f:
    data = json.load(f)
assert data['signed'] is True, data['signed']
assert data['notarized'] is False, data['notarized']
" 2>&1)"; then
    ok "write_manifest can record signed: true with notarized: false"
else
    no "write_manifest can record signed: true with notarized: false" "$manifest_err"
fi

# A caller stuck on the old 4-argument form must fail loudly, not write the output path into
# "teamId".
if out="$(write_manifest "9.9.9" "abc123" "0" "$MANIFEST_OUT" 2>&1)"; then
    no "write_manifest rejects the old 4-argument form" "$out"
else
    expect_contains "$out" "6 arguments" "the arity error says how many arguments are expected"
fi

# --------------------------------------------------------------------------
# 2b. codesign_common_flags: the hardened runtime and a timestamp are requested on EVERY build,
#     ad-hoc dev builds included, so a release is not the first time that configuration runs.
# --------------------------------------------------------------------------
flags_out="$(codesign_common_flags | tr '\n' ' ')"
expect_contains "$flags_out" "--options runtime" "codesign_common_flags always requests the hardened runtime"
expect_contains "$flags_out" "--timestamp" "codesign_common_flags always requests a timestamp"
expect_contains "$flags_out" "--force" "codesign_common_flags replaces an existing signature"
case "$flags_out" in
*--keychain*) no "codesign_common_flags omits --keychain when none was given" "got: $flags_out" ;;
*) ok "codesign_common_flags omits --keychain when none was given" ;;
esac

KEYCHAIN="$TWORK/some path/build.keychain"
flags_out="$(codesign_common_flags | tr '\n' '|')"
expect_contains "$flags_out" "--keychain|$TWORK/some path/build.keychain" \
    "codesign_common_flags passes --keychain as one argument, spaces and all"
# shellcheck disable=SC2034 # read by codesign_common_flags, which lives in the sourced script
KEYCHAIN=""

# --------------------------------------------------------------------------
# 2c. stage_pkg_scripts: postinstall is templated into a COPY. The checked-in file is the
#     template and must survive untouched; an empty team id must render as empty, never as the
#     literal placeholder (which postinstall refuses to run with).
# --------------------------------------------------------------------------
SOURCE_POSTINSTALL="$REPO_ROOT/packaging/pkg/scripts/postinstall"

rendered_dir="$(stage_pkg_scripts "")"
if [ -f "$rendered_dir/postinstall" ]; then
    ok "stage_pkg_scripts copies postinstall"
else
    no "stage_pkg_scripts copies postinstall" "missing: $rendered_dir/postinstall"
fi
expect_contains "$(cat "$rendered_dir/postinstall")" 'TEAM_ID=""' \
    "an empty team id renders as an empty TEAM_ID"
case "$(cat "$rendered_dir/postinstall")" in
*"$TEAM_ID_PLACEHOLDER"*)
    no "an empty team id leaves no placeholder behind" "placeholder still present"
    ;;
*) ok "an empty team id leaves no placeholder behind" ;;
esac
expect_eq "$(stat -f '%Lp' "$rendered_dir/postinstall")" "755" "the rendered postinstall is 0755"
rm -rf "$rendered_dir"

rendered_dir="$(stage_pkg_scripts "ABCDE12345")"
expect_contains "$(cat "$rendered_dir/postinstall")" 'TEAM_ID="ABCDE12345"' \
    "a real team id is substituted into the copy"
expect_eq "$(stat -f '%Lp' "$rendered_dir/postinstall")" "755" \
    "the rendered postinstall is 0755 with a team id too"
TEMPLATED_POSTINSTALL="$TWORK/postinstall-teamed"
cp "$rendered_dir/postinstall" "$TEMPLATED_POSTINSTALL"
UNTEMPLATED_POSTINSTALL="$TWORK/postinstall-untemplated"
cp "$SOURCE_POSTINSTALL" "$UNTEMPLATED_POSTINSTALL"
EMPTY_TEAM_POSTINSTALL="$TWORK/postinstall-empty-team"
rm -rf "$rendered_dir"
rendered_dir="$(stage_pkg_scripts "")"
cp "$rendered_dir/postinstall" "$EMPTY_TEAM_POSTINSTALL"
rm -rf "$rendered_dir"

expect_contains "$(cat "$SOURCE_POSTINSTALL")" "$TEAM_ID_PLACEHOLDER" \
    "the checked-in postinstall still holds the placeholder (rendering never edits it)"

# --------------------------------------------------------------------------
# 2d. resolve_team_id: derived from the signature, never from a flag. `codesign` is shadowed by a
#     shell function for these -- the values are real codesign output shapes.
# --------------------------------------------------------------------------
MOCK_CODESIGN_OUT=""
# shellcheck disable=SC2329 # invoked by resolve_team_id in the sourced script, not from here
codesign() { printf '%s\n' "$MOCK_CODESIGN_OUT"; }

MOCK_CODESIGN_OUT="Identifier=com.runnervm.vmworker
Signature=adhoc
TeamIdentifier=not set"
expect_eq "$(resolve_team_id /nonexistent)" "" "an ad-hoc signature (TeamIdentifier=not set) yields no team id"

MOCK_CODESIGN_OUT="Identifier=com.runnervm.vmworker
Authority=Developer ID Application: RunnerVM (ABCDE12345)
TeamIdentifier=ABCDE12345"
expect_eq "$(resolve_team_id /nonexistent)" "ABCDE12345" "a Developer ID signature yields its team id"

MOCK_CODESIGN_OUT="Identifier=com.runnervm.vmworker"
expect_eq "$(resolve_team_id /nonexistent)" "" "an unsigned binary yields no team id"

# A team id that is not exactly [A-Z0-9]{10} is fatal: it would be substituted into postinstall's
# `codesign -R` requirement and into a `sed` expression.
MOCK_CODESIGN_OUT="TeamIdentifier=ABCDE1234"
if out="$(resolve_team_id /nonexistent 2>&1)"; then
    no "a too-short team id is fatal" "got: $out"
else
    expect_contains "$out" "10 characters" "the too-short team id error says what was expected"
fi
MOCK_CODESIGN_OUT='TeamIdentifier=A|BCDE1234$'
if out="$(resolve_team_id /nonexistent 2>&1)"; then
    no "a team id with metacharacters is fatal" "got: $out"
else
    expect_contains "$out" "[A-Z0-9]" "the bad-charset team id error says what was expected"
fi
unset -f codesign

# --------------------------------------------------------------------------
# 2e. notarize_and_staple control flow, with `xcrun` shadowed by a shell function. No submission
#     is ever made: what is under test is that a non-Accepted verdict fails the build loudly and
#     prints the notary log, and that an accepted one staples AND validates.
# --------------------------------------------------------------------------
NOTARY_CALLS="$TWORK/notary-calls"
NOTARY_STATUS="Accepted"
NOTARY_RAW=""
# shellcheck disable=SC2329 # invoked by notarize_and_staple in the sourced script
xcrun() {
    printf '%s\n' "$*" >>"$NOTARY_CALLS"
    if [ "$1" = "notarytool" ] && [ "$2" = "submit" ]; then
        if [ -n "$NOTARY_RAW" ]; then
            printf '%s\n' "$NOTARY_RAW"
        else
            printf '{"id":"sub-1","status":"%s"}\n' "$NOTARY_STATUS"
        fi
    elif [ "$1" = "notarytool" ] && [ "$2" = "log" ]; then
        printf 'mock notary log body\n'
    fi
    return 0
}
NOTARY_KEY="$NOTARY_KEY_FIXTURE"
NOTARY_KEY_ID="KEYID"
NOTARY_ISSUER="ISSUER"

: >"$NOTARY_CALLS"
NOTARY_STATUS="Accepted"
if out="$(notarize_and_staple "$TWORK/fake.pkg" 2>&1)"; then
    ok "an Accepted verdict completes"
else
    no "an Accepted verdict completes" "$out"
fi
expect_contains "$(cat "$NOTARY_CALLS")" "stapler staple" "an Accepted verdict staples the ticket"
expect_contains "$(cat "$NOTARY_CALLS")" "stapler validate" "stapling is validated, not assumed"

: >"$NOTARY_CALLS"
NOTARY_STATUS="Invalid"
if out="$(notarize_and_staple "$TWORK/fake.pkg" 2>&1)"; then
    no "a non-Accepted verdict is fatal" "$out"
else
    expect_contains "$out" "not accepted" "the rejection error says the verdict was not accepted"
    expect_contains "$out" "mock notary log body" "a rejection prints the notary log"
fi
expect_contains "$(cat "$NOTARY_CALLS")" "notarytool log sub-1" \
    "a rejection fetches the log for the submission id it got back"
case "$(cat "$NOTARY_CALLS")" in
*stapler*) no "a rejected submission is never stapled" "found a stapler call" ;;
*) ok "a rejected submission is never stapled" ;;
esac
# Output that is not the JSON document this parses at all (a notarytool that changed its format,
# or progress text folded into stdout) must fail the build, not be read as an acceptance.
: >"$NOTARY_CALLS"
NOTARY_RAW="Conducting pre-submission checks..."
if out="$(notarize_and_staple "$TWORK/fake.pkg" 2>&1)"; then
    no "unparseable notarytool output is fatal" "$out"
else
    expect_contains "$out" "status: unknown" "unparseable notarytool output reports an unknown verdict"
fi
case "$(cat "$NOTARY_CALLS")" in
*stapler*) no "unparseable notarytool output never staples" "found a stapler call" ;;
*) ok "unparseable notarytool output never staples" ;;
esac
NOTARY_RAW=""

unset -f xcrun
# shellcheck disable=SC2034 # read by notarize_and_staple, which lives in the sourced script
NOTARY_KEY=""
# shellcheck disable=SC2034
NOTARY_KEY_ID=""
# shellcheck disable=SC2034
NOTARY_ISSUER=""

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
expect_path_exists "staged: share/runnervm/guest-agent/launchd/com.runnervm.guest-agent.plist" \
    "$USR_LOCAL/share/runnervm/guest-agent/launchd/com.runnervm.guest-agent.plist"
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

expect_eq "$(cat "$USR_LOCAL/share/runnervm/VERSION")" "$EXPECTED_VERSION" \
    "staged VERSION file contains RunnerVMVersion.current ($EXPECTED_VERSION)"

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

# --------------------------------------------------------------------------
# 4. A REAL pkgbuild + productbuild run (still --skip-build --skip-sign, still fixture binaries;
#    both tools take about a second). Asserts the three published artifacts agree with each other
#    and that the postinstall actually embedded in the pkg went through the team-id templating.
# --------------------------------------------------------------------------
OUT="$TWORK/out"
if pkg_out="$("$SCRIPT" --skip-build --skip-sign --out "$OUT" 2>&1)"; then
    ok "--skip-build --skip-sign builds a pkg end to end"
else
    no "--skip-build --skip-sign builds a pkg end to end" "$pkg_out"
fi

expect_path_exists "built: $PKG_NAME" "$OUT/$PKG_NAME"
expect_path_exists "built: $PKG_NAME.sha256" "$OUT/$PKG_NAME.sha256"
expect_path_exists "built: release-manifest.json" "$OUT/release-manifest.json"

if [ -f "$OUT/$PKG_NAME" ]; then
    actual_sha="$(shasum -a 256 "$OUT/$PKG_NAME" | cut -d' ' -f1)"
    recorded_sha="$(cut -d' ' -f1 <"$OUT/$PKG_NAME.sha256")"
    expect_eq "$recorded_sha" "$actual_sha" "the .sha256 sidecar matches the pkg on disk"

    manifest_err=""
    if manifest_err="$(python3 -c "
import json, hashlib
with open('$OUT/release-manifest.json') as f:
    data = json.load(f)
expected_keys = {'version', 'architecture', 'minimumMacOS', 'package', 'sha256', 'signed',
                 'teamId', 'notarized', 'license'}
assert set(data.keys()) == expected_keys, f'key set mismatch: {sorted(data.keys())}'
assert data['version'] == '$EXPECTED_VERSION', data['version']
assert data['package'] == '$PKG_NAME', data['package']
assert data['signed'] is False, data['signed']
assert data['teamId'] == '', repr(data['teamId'])
assert data['notarized'] is False, data['notarized']
digest = hashlib.sha256(open('$OUT/$PKG_NAME', 'rb').read()).hexdigest()
assert data['sha256'] == digest, f\"manifest {data['sha256']} != file {digest}\"
" 2>&1)"; then
        ok "the manifest has the 9 keys and its sha256 is the built pkg's own digest"
    else
        no "the manifest has the 9 keys and its sha256 is the built pkg's own digest" "$manifest_err"
    fi

    # The postinstall the pkg will actually run, read back out of the pkg itself.
    EXPAND="$TWORK/expanded"
    rm -rf "$EXPAND"
    if pkgutil --expand "$OUT/$PKG_NAME" "$EXPAND" >/dev/null 2>&1; then
        embedded="$(find "$EXPAND" -name postinstall -type f | head -1)"
        if [ -z "$embedded" ]; then
            # Older layouts keep Scripts as an archive; --expand-full unpacks it.
            rm -rf "$EXPAND"
            pkgutil --expand-full "$OUT/$PKG_NAME" "$EXPAND" >/dev/null 2>&1 || true
            embedded="$(find "$EXPAND" -name postinstall -type f | head -1)"
        fi
        if [ -n "$embedded" ]; then
            ok "the pkg embeds a postinstall script"
            expect_contains "$(cat "$embedded")" 'TEAM_ID=""' \
                "the embedded postinstall was templated (empty team id on an unsigned build)"
            case "$(cat "$embedded")" in
            *"$TEAM_ID_PLACEHOLDER"*)
                no "the embedded postinstall carries no untemplated placeholder" "placeholder found"
                ;;
            *) ok "the embedded postinstall carries no untemplated placeholder" ;;
            esac
            expect_eq "$(stat -f '%Lp' "$embedded")" "755" "the embedded postinstall is executable"
        else
            no "the pkg embeds a postinstall script" "no postinstall found under $EXPAND"
        fi
    else
        no "pkgutil --expand can read the built pkg" "pkgutil --expand failed"
    fi
fi

# --------------------------------------------------------------------------
# 5. postinstall's two branches, run for real against a throwaway root (the installer passes the
#    destination volume as $3). `codesign` is mocked on PATH; the mock records every call so the
#    test can prove which checks ran, not just that the script exited.
# --------------------------------------------------------------------------
POST_ROOT="$TWORK/postroot"
mkdir -p "$POST_ROOT/usr/local/bin" \
    "$POST_ROOT/usr/local/libexec/runnervm" \
    "$POST_ROOT/usr/local/share/runnervm/guest-agent/darwin-arm64"
: >"$POST_ROOT/usr/local/bin/runnerctl"
: >"$POST_ROOT/usr/local/libexec/runnervm/runnerd"
: >"$POST_ROOT/usr/local/libexec/runnervm/vmworker"
: >"$POST_ROOT/usr/local/share/runnervm/guest-agent/darwin-arm64/runnervm-guest-agent"

POST_MOCKBIN="$TWORK/postbin"
mkdir -p "$POST_MOCKBIN"
cat >"$POST_MOCKBIN/codesign" <<'MOCK'
#!/bin/sh
# Test double for codesign. RVM_MOCK_R=fail rejects the -R requirement check; RVM_MOCK_RUNTIME=0
# reports a signature without the hardened runtime flag. Every call is appended to RVM_MOCK_LOG.
if [ -n "${RVM_MOCK_LOG:-}" ]; then
    echo "$*" >>"$RVM_MOCK_LOG"
fi
mode=verify
for arg in "$@"; do
    case "$arg" in
    -R) mode=requirement ;;
    --entitlements) mode=entitlements ;;
    --verbose=2) mode=flags ;;
    esac
done
case "$mode" in
requirement)
    [ "${RVM_MOCK_R:-ok}" = "ok" ] || exit 3
    ;;
entitlements)
    echo '<key>com.apple.security.virtualization</key><true/>'
    ;;
flags)
    if [ "${RVM_MOCK_RUNTIME:-1}" = "1" ]; then
        echo 'CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+2' >&2
    else
        echo 'CodeDirectory v=20500 size=1 flags=0x0(none) hashes=1+2' >&2
    fi
    ;;
esac
exit 0
MOCK
chmod 0755 "$POST_MOCKBIN/codesign"

run_postinstall() {
    local script="$1"
    shift
    env PATH="$POST_MOCKBIN:$PATH" RVM_MOCK_LOG="$TWORK/postinstall-calls" "$@" \
        bash "$script" /dev/null / "$POST_ROOT" 2>&1
}

# Empty team id (dev/unsigned build): no publisher requirement is checked at all, even when the
# requirement check would fail. This is the branch that keeps ad-hoc installs working.
: >"$TWORK/postinstall-calls"
if out="$(run_postinstall "$EMPTY_TEAM_POSTINSTALL" RVM_MOCK_R=fail)"; then
    ok "an empty team id accepts an install that could not satisfy a publisher requirement"
else
    no "an empty team id accepts an install that could not satisfy a publisher requirement" "$out"
fi
case "$(cat "$TWORK/postinstall-calls")" in
*" -R "*) no "an empty team id runs no -R requirement check" "found an -R call" ;;
*) ok "an empty team id runs no -R requirement check" ;;
esac
expect_contains "$(cat "$TWORK/postinstall-calls")" "--verify --strict" \
    "an empty team id still verifies every signature"

# Templated team id, everything as a real signed release: passes, and the requirement it checked
# names our team and covers all four Mach-O files.
: >"$TWORK/postinstall-calls"
if out="$(run_postinstall "$TEMPLATED_POSTINSTALL")"; then
    ok "a templated team id accepts a correctly signed install"
else
    no "a templated team id accepts a correctly signed install" "$out"
fi
calls="$(cat "$TWORK/postinstall-calls")"
expect_contains "$calls" 'leaf[subject.OU] = "ABCDE12345"' \
    "the requirement check pins the templated team id"
for checked in libexec/runnervm/runnerd bin/runnerctl libexec/runnervm/vmworker \
    guest-agent/darwin-arm64/runnervm-guest-agent; do
    if printf '%s\n' "$calls" | grep -F -- "-R " | grep -qF "$checked"; then
        ok "the publisher requirement is checked on $checked"
    else
        no "the publisher requirement is checked on $checked" "no -R call for it: $calls"
    fi
done

# Same pkg, wrong publisher: hard failure naming the team.
: >"$TWORK/postinstall-calls"
if out="$(run_postinstall "$TEMPLATED_POSTINSTALL" RVM_MOCK_R=fail)"; then
    no "a signature from another team fails the install" "$out"
else
    expect_contains "$out" "ABCDE12345" "the wrong-publisher error names the expected team"
    expect_contains "$out" "not built by the RunnerVM publisher" \
        "the wrong-publisher error says what it means"
fi

# Right publisher, no hardened runtime: also a failure -- notarization required it, so its absence
# means these are not the bits we shipped.
: >"$TWORK/postinstall-calls"
if out="$(run_postinstall "$TEMPLATED_POSTINSTALL" RVM_MOCK_RUNTIME=0)"; then
    no "a signature without the hardened runtime fails the install" "$out"
else
    expect_contains "$out" "hardened runtime" "the hardened-runtime error names the problem"
fi

# The checked-in template itself must refuse to run: an unsubstituted placeholder means the
# packaging step was bypassed, and falling back to the weaker check would hide exactly that.
if out="$(run_postinstall "$UNTEMPLATED_POSTINSTALL")"; then
    no "an untemplated postinstall refuses to run" "$out"
else
    expect_contains "$out" "not templated" "the untemplated-postinstall error names the problem"
fi

# A missing binary is still a failed install.
: >"$TWORK/postinstall-calls"
mv "$POST_ROOT/usr/local/share/runnervm/guest-agent/darwin-arm64/runnervm-guest-agent" \
    "$TWORK/agent-away"
if out="$(run_postinstall "$TEMPLATED_POSTINSTALL")"; then
    no "a missing binary fails the install" "$out"
else
    expect_contains "$out" "not found after install" "the missing-binary error names the problem"
fi
mv "$TWORK/agent-away" \
    "$POST_ROOT/usr/local/share/runnervm/guest-agent/darwin-arm64/runnervm-guest-agent"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
