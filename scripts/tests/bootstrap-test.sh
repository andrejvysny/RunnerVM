#!/usr/bin/env bash
# Unit checks for scripts/bootstrap.sh, the script published as the "install.sh" release asset
# (see .github/workflows/release.yml and docs/design/distribution.md "Goal").
#
# Two styles:
#   - The root-refusal check is the one thing that must be true of the *real*, unmodified script
#     with nothing faked: this test process never runs as root, so invoking the script as a plain
#     subprocess and expecting the refusal is the natural, honest way to exercise it (mirrors
#     scripts/tests/install-test.sh's use of real subprocesses for exit-before-any-work paths).
#   - Everything past the root check needs `id`, `uname`, `sw_vers`, `installer` and `codesign`
#     faked, and env vars (RUNNERVM_*) scoped to one scenario at a time. bootstrap.sh guards its
#     own `main` behind the "am I sourced" idiom `(return 0 2>/dev/null)` specifically so this file
#     can `source` it and call its functions directly -- same technique
#     scripts/tests/qualify-host-test.sh uses for shadowing `id` via a same-named shell function,
#     which wins over the real command because shell functions take priority over $PATH lookups.
#
#     Each such scenario is a named `case_*` function (defined below, at this file's own scope)
#     that fakes what it needs, `source`s bootstrap.sh, and calls `main`. `run_case` executes it in
#     a real `( subshell )` -- not `$(...)` command substitution -- so its `export`s and fake
#     functions never leak to other scenarios, and `main`'s `exit`/`die` calls only terminate that
#     subshell. Deliberately NOT `$(...)`: bash 3.2 (what /usr/bin/bash actually is on the macOS
#     boxes this targets, /usr/bin/env bash included) cannot parse a `case` pattern's terminating
#     `)` -- e.g. `-u)` -- when that text sits directly inside `$(...)`; it reports a bogus "syntax
#     error near unexpected token `newline'". A plain `( ... )` subshell has no such bug, so
#     run_case redirects the subshell's combined output to a file and reads that back separately.
#
# Test seams documented at the top of scripts/bootstrap.sh: RUNNERVM_PREFIX, RUNNERVM_STATE_ROOT,
# RUNNERVM_TTY. RUNNERVM_PKG_URL, RUNNERVM_VERSION, RUNNERVM_ALLOW_UNSIGNED and RUNNERVM_NO_SETUP
# are the real, documented, operator-facing env vars.
#
# usage: scripts/tests/bootstrap-test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/bootstrap.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rvm-bootstrap-test-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

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

# See header: a real subshell, combined output captured via a file (never `$(...)`), exit status
# via `if` so a non-zero result never trips this file's own `set -e`.
CASE_OUT=""
CASE_CODE=0
run_case() {
    if ("$1") >"$WORK/case.out" 2>&1; then
        CASE_CODE=0
    else
        CASE_CODE=$?
    fi
    CASE_OUT="$(cat "$WORK/case.out")"
}

# A fixture release directory: a real fixture "pkg" file, a real `shasum -a 256` over it (so the
# happy path exercises the actual checksum machinery, not a stub), and a manifest whose "sha256"
# agrees with it unless the caller wants to test disagreement.
make_fixture_release() {
    local dir="$1" version="${2:-0.2.0}" signed="${3:-false}" sha_override="${4:-}"
    local pkg="$dir/RunnerVM-macos-arm64.pkg" sha
    mkdir -p "$dir"
    printf 'fixture pkg contents for %s\n' "$version" >"$pkg"
    (cd "$dir" && shasum -a 256 RunnerVM-macos-arm64.pkg >RunnerVM-macos-arm64.pkg.sha256)
    sha="$(shasum -a 256 "$pkg" | awk '{print $1}')"
    [ -n "$sha_override" ] && sha="$sha_override"
    cat >"$dir/release-manifest.json" <<EOF
{
  "version": "$version",
  "architecture": "arm64",
  "minimumMacOS": "15.0",
  "package": "RunnerVM-macos-arm64.pkg",
  "sha256": "$sha",
  "signed": $signed,
  "license": "Apache-2.0"
}
EOF
}

# A fake installed vmworker at <prefix>/libexec/runnervm/vmworker, standing in for what a real
# `installer -pkg` run would have placed there -- fine to pre-create since `installer` itself is
# always faked in these tests (never runs for real).
make_fake_prefix() {
    local prefix="$1"
    mkdir -p "$prefix/libexec/runnervm" "$prefix/bin"
    printf '#!/bin/sh\nexit 0\n' >"$prefix/libexec/runnervm/vmworker"
    chmod +x "$prefix/libexec/runnervm/vmworker"
}

fake_id_root() { case "$1" in -u) echo 0 ;; esac; }

fake_codesign_ok() {
    case "$1" in
    --verify) return 0 ;;
    -d) printf 'com.apple.security.virtualization\n' ;;
    esac
}

# --------------------------------------------------------------------------
# 1. Refuses non-root -- the one case exercised as a real, unmodified subprocess (see header).
# --------------------------------------------------------------------------
if out="$(bash "$SCRIPT" 2>&1)"; then
    no "refuses to run as non-root" "$out"
else
    code=$?
    expect_eq "$code" "2" "non-root run exits 2"
    expect_contains "$out" "must run as root" "non-root refusal names the problem"
    expect_contains "$out" "curl -fsSL" "non-root refusal prints the curl | sudo bash hint"
    expect_contains "$out" "sudo bash" "non-root refusal's hint actually says sudo bash"
fi

# --------------------------------------------------------------------------
# Pure helpers: sourced once, exercised directly. bootstrap.sh's own `main` never runs on source
# (its guard is `(return 0 2>/dev/null)`, true here), so this is safe at the top level of this file
# even though bootstrap.sh carries `set -euo pipefail` too (nothing below calls a function in a way
# that returns non-zero unguarded).
# --------------------------------------------------------------------------
# shellcheck source=SCRIPTDIR/../bootstrap.sh
# shellcheck disable=SC1091 # dynamic path; run shellcheck -x to actually follow it
source "$SCRIPT"

# --------------------------------------------------------------------------
# 2. resolve_base_url: RUNNERVM_PKG_URL > RUNNERVM_VERSION > releases/latest/download
# --------------------------------------------------------------------------
unset RUNNERVM_PKG_URL RUNNERVM_VERSION 2>/dev/null || true
expect_eq "$(resolve_base_url)" \
    "https://github.com/andrejvysny/RunnerVM/releases/latest/download" \
    "resolve_base_url defaults to releases/latest/download"

RUNNERVM_VERSION="v0.2.0"
expect_eq "$(resolve_base_url)" \
    "https://github.com/andrejvysny/RunnerVM/releases/download/v0.2.0" \
    "resolve_base_url builds the tagged-release URL from RUNNERVM_VERSION"

RUNNERVM_PKG_URL="file:///tmp/some/fixture/"
expect_eq "$(resolve_base_url)" "file:///tmp/some/fixture" \
    "resolve_base_url prefers RUNNERVM_PKG_URL over RUNNERVM_VERSION, and strips a trailing slash"
unset RUNNERVM_PKG_URL RUNNERVM_VERSION

# --------------------------------------------------------------------------
# 3. manifest_field: parses every documented key, and fails closed on a missing one.
# --------------------------------------------------------------------------
FIXTURE_DIR="$WORK/manifest-fixture"
make_fixture_release "$FIXTURE_DIR" "0.2.0" "false"
MANIFEST="$FIXTURE_DIR/release-manifest.json"

expect_eq "$(manifest_field "$MANIFEST" version)" "0.2.0" "manifest_field reads version"
expect_eq "$(manifest_field "$MANIFEST" architecture)" "arm64" "manifest_field reads architecture"
expect_eq "$(manifest_field "$MANIFEST" minimumMacOS)" "15.0" "manifest_field reads minimumMacOS"
expect_eq "$(manifest_field "$MANIFEST" package)" "RunnerVM-macos-arm64.pkg" "manifest_field reads package"
expect_eq "$(manifest_field "$MANIFEST" signed)" "false" "manifest_field reads signed: false as the string 'false'"
expect_eq "$(manifest_field "$MANIFEST" license)" "Apache-2.0" "manifest_field reads license"

if manifest_field "$MANIFEST" no_such_field >/dev/null 2>&1; then
    no "manifest_field fails on a missing field"
else
    ok "manifest_field fails on a missing field"
fi

# ==========================================================================
# Full-flow scenarios (see run_case in the header for why these are subshells, not $(...)).
# None of these touch a real network, a real installer, or a real codesign identity.
# ==========================================================================

# --------------------------------------------------------------------------
# 4. Refuses x86_64
# --------------------------------------------------------------------------
case_x86_64() {
    id() { fake_id_root "$@"; }
    uname() { echo x86_64; }
    # shellcheck disable=SC1090,SC1091 # dynamic path; run shellcheck -x to actually follow it
    source "$SCRIPT"
    main
}
run_case case_x86_64
if [ "$CASE_CODE" -eq 0 ]; then
    no "refuses x86_64" "$CASE_OUT"
else
    expect_contains "$CASE_OUT" "unsupported architecture" "x86_64 refusal names the problem"
    expect_contains "$CASE_OUT" "x86_64" "x86_64 refusal echoes the actual arch"
fi

# --------------------------------------------------------------------------
# 5. Refuses macOS 14
# --------------------------------------------------------------------------
case_macos14() {
    id() { fake_id_root "$@"; }
    sw_vers() { echo 14.6.1; }
    # shellcheck disable=SC1090,SC1091 # dynamic path; run shellcheck -x to actually follow it
    source "$SCRIPT"
    main
}
run_case case_macos14
if [ "$CASE_CODE" -eq 0 ]; then
    no "refuses macOS 14" "$CASE_OUT"
else
    expect_contains "$CASE_OUT" "unsupported macOS version" "macOS-14 refusal names the problem"
    expect_contains "$CASE_OUT" "14.6.1" "macOS-14 refusal echoes the actual version"
fi

# --------------------------------------------------------------------------
# 6. Happy path: file:// RUNNERVM_PKG_URL, unsigned+allowed, setup skipped.
# --------------------------------------------------------------------------
HAPPY_RELEASE="$WORK/happy/release"
HAPPY_PREFIX="$WORK/happy/prefix"
HAPPY_STATE="$WORK/happy/state"
HAPPY_INSTALLER_LOG="$WORK/happy/installer.log"
make_fixture_release "$HAPPY_RELEASE" "0.2.0" "false"
make_fake_prefix "$HAPPY_PREFIX"

case_happy_path() {
    id() { fake_id_root "$@"; }
    installer() { printf '%s\n' "$*" >>"$HAPPY_INSTALLER_LOG"; }
    codesign() { fake_codesign_ok "$@"; }
    export RUNNERVM_PKG_URL="file://$HAPPY_RELEASE"
    export RUNNERVM_PREFIX="$HAPPY_PREFIX"
    export RUNNERVM_STATE_ROOT="$HAPPY_STATE"
    export RUNNERVM_ALLOW_UNSIGNED=1
    export RUNNERVM_NO_SETUP=1
    # shellcheck disable=SC1090,SC1091 # dynamic path; run shellcheck -x to actually follow it
    source "$SCRIPT"
    main
}
run_case case_happy_path
expect_eq "$CASE_CODE" "0" "happy path exits 0"
expect_contains "$CASE_OUT" "RUNNERVM_NO_SETUP=1" "happy path logs that setup was skipped"
expect_contains "$CASE_OUT" "$HAPPY_PREFIX/bin/runnerctl setup" \
    "happy path's next-step line names the real setup command"

if [ -f "$HAPPY_INSTALLER_LOG" ]; then
    ok "installer was invoked"
    expect_contains "$(cat "$HAPPY_INSTALLER_LOG")" "RunnerVM-macos-arm64.pkg" \
        "installer was invoked with the downloaded pkg"
else
    no "installer was invoked" "no installer log at $HAPPY_INSTALLER_LOG"
fi

CACHE_DIR="$HAPPY_STATE/upgrades/0.2.0"
if [ -d "$CACHE_DIR" ]; then
    ok "cache dir created"
    for f in RunnerVM-macos-arm64.pkg RunnerVM-macos-arm64.pkg.sha256 release-manifest.json; do
        if [ -f "$CACHE_DIR/$f" ]; then
            ok "cache dir contains $f"
        else
            no "cache dir contains $f" "missing: $CACHE_DIR/$f"
        fi
    done
else
    no "cache dir created" "missing: $CACHE_DIR"
fi

# --------------------------------------------------------------------------
# 7. Checksum mismatch (against the manifest's own sha256 field) aborts before installer runs.
# --------------------------------------------------------------------------
MISMATCH_RELEASE="$WORK/mismatch/release"
MISMATCH_PREFIX="$WORK/mismatch/prefix"
MISMATCH_INSTALLER_LOG="$WORK/mismatch/installer.log"
make_fixture_release "$MISMATCH_RELEASE" "0.2.0" "false" \
    "0000000000000000000000000000000000000000000000000000000000000000"
make_fake_prefix "$MISMATCH_PREFIX"

case_checksum_mismatch() {
    id() { fake_id_root "$@"; }
    installer() { printf '%s\n' "$*" >>"$MISMATCH_INSTALLER_LOG"; }
    export RUNNERVM_PKG_URL="file://$MISMATCH_RELEASE"
    export RUNNERVM_PREFIX="$MISMATCH_PREFIX"
    export RUNNERVM_ALLOW_UNSIGNED=1
    export RUNNERVM_NO_SETUP=1
    # shellcheck disable=SC1090,SC1091 # dynamic path; run shellcheck -x to actually follow it
    source "$SCRIPT"
    main
}
run_case case_checksum_mismatch
if [ "$CASE_CODE" -eq 0 ]; then
    no "checksum mismatch aborts" "$CASE_OUT"
else
    expect_contains "$CASE_OUT" "does not match release-manifest.json" \
        "checksum-mismatch error names the problem"
fi
if [ -f "$MISMATCH_INSTALLER_LOG" ]; then
    no "checksum mismatch never invokes installer" "installer ran: $(cat "$MISMATCH_INSTALLER_LOG")"
else
    ok "checksum mismatch never invokes installer"
fi

# --------------------------------------------------------------------------
# 8. Missing manifest aborts (nothing downloaded, nothing to checksum against).
# --------------------------------------------------------------------------
EMPTY_RELEASE="$WORK/empty-release"
mkdir -p "$EMPTY_RELEASE"
case_missing_manifest() {
    id() { fake_id_root "$@"; }
    export RUNNERVM_PKG_URL="file://$EMPTY_RELEASE"
    export RUNNERVM_ALLOW_UNSIGNED=1
    export RUNNERVM_NO_SETUP=1
    # shellcheck disable=SC1090,SC1091 # dynamic path; run shellcheck -x to actually follow it
    source "$SCRIPT"
    main
}
run_case case_missing_manifest
if [ "$CASE_CODE" -eq 0 ]; then
    no "missing manifest aborts" "$CASE_OUT"
else
    expect_contains "$CASE_OUT" "failed to download release-manifest.json" \
        "missing-manifest error names the problem"
fi

# --------------------------------------------------------------------------
# 9. signed:false, no RUNNERVM_ALLOW_UNSIGNED, no controlling terminal -> aborts after download,
#    before installer. RUNNERVM_TTY points at a path that cannot be opened, deterministically
#    standing in for "no controlling terminal" regardless of whether this test happens to run
#    attached to a real tty.
# --------------------------------------------------------------------------
UNSIGNED_RELEASE="$WORK/unsigned/release"
UNSIGNED_PREFIX="$WORK/unsigned/prefix"
UNSIGNED_INSTALLER_LOG="$WORK/unsigned/installer.log"
make_fixture_release "$UNSIGNED_RELEASE" "0.2.0" "false"
make_fake_prefix "$UNSIGNED_PREFIX"

case_unsigned_no_tty() {
    id() { fake_id_root "$@"; }
    installer() { printf '%s\n' "$*" >>"$UNSIGNED_INSTALLER_LOG"; }
    export RUNNERVM_PKG_URL="file://$UNSIGNED_RELEASE"
    export RUNNERVM_PREFIX="$UNSIGNED_PREFIX"
    export RUNNERVM_TTY="$WORK/unsigned/no-such-tty"
    export RUNNERVM_NO_SETUP=1
    # shellcheck disable=SC1090,SC1091 # dynamic path; run shellcheck -x to actually follow it
    source "$SCRIPT"
    main
}
run_case case_unsigned_no_tty
if [ "$CASE_CODE" -eq 0 ]; then
    no "unsigned + no tty + no RUNNERVM_ALLOW_UNSIGNED aborts" "$CASE_OUT"
else
    expect_contains "$CASE_OUT" "refusing to install an unsigned package non-interactively" \
        "unsigned/no-tty refusal names the problem"
    expect_contains "$CASE_OUT" "RUNNERVM_ALLOW_UNSIGNED=1" \
        "unsigned/no-tty refusal names the escape hatch"
fi
if [ -f "$UNSIGNED_INSTALLER_LOG" ]; then
    no "unsigned/no-tty abort never invokes installer" "installer ran: $(cat "$UNSIGNED_INSTALLER_LOG")"
else
    ok "unsigned/no-tty abort never invokes installer"
fi

# --------------------------------------------------------------------------
# 10. release-manifest.json's own architecture/minimumMacOS are checked against this host, not
#     just against the downloaded pkg's checksum -- an architecture mismatch aborts before the pkg
#     is even downloaded.
# --------------------------------------------------------------------------
BADARCH_RELEASE="$WORK/badarch/release"
make_fixture_release "$BADARCH_RELEASE" "0.2.0" "true"
sed -i '' 's/"architecture": "arm64"/"architecture": "x86_64"/' "$BADARCH_RELEASE/release-manifest.json"

case_bad_manifest_arch() {
    id() { fake_id_root "$@"; }
    export RUNNERVM_PKG_URL="file://$BADARCH_RELEASE"
    export RUNNERVM_NO_SETUP=1
    # shellcheck disable=SC1090,SC1091 # dynamic path; run shellcheck -x to actually follow it
    source "$SCRIPT"
    main
}
run_case case_bad_manifest_arch
if [ "$CASE_CODE" -eq 0 ]; then
    no "manifest architecture mismatch aborts" "$CASE_OUT"
else
    expect_contains "$CASE_OUT" "architecture is 'x86_64', not arm64" \
        "manifest-architecture-mismatch error names the problem"
fi

# --------------------------------------------------------------------------
# 11. Install verification failure (broken codesign/entitlement) exits non-zero and says the pkg
#     is installed but broken -- it must not claim nothing was installed at this point.
# --------------------------------------------------------------------------
BROKEN_RELEASE="$WORK/broken/release"
BROKEN_PREFIX="$WORK/broken/prefix"
make_fixture_release "$BROKEN_RELEASE" "0.2.0" "true"
make_fake_prefix "$BROKEN_PREFIX"

case_broken_install() {
    id() { fake_id_root "$@"; }
    installer() { :; }
    codesign() {
        case "$1" in
        --verify) return 1 ;;
        -d) printf 'com.apple.security.virtualization\n' ;;
        esac
    }
    export RUNNERVM_PKG_URL="file://$BROKEN_RELEASE"
    export RUNNERVM_PREFIX="$BROKEN_PREFIX"
    export RUNNERVM_NO_SETUP=1
    # shellcheck disable=SC1090,SC1091 # dynamic path; run shellcheck -x to actually follow it
    source "$SCRIPT"
    main
}
run_case case_broken_install
if [ "$CASE_CODE" -eq 0 ]; then
    no "broken install (codesign --verify fails) exits non-zero" "$CASE_OUT"
else
    expect_contains "$CASE_OUT" "installed but broken" \
        "broken-install error says the pkg is installed but broken"
fi

# --------------------------------------------------------------------------
# 12. No RUNNERVM_NO_SETUP and no controlling terminal -> graceful degrade: tells the operator to
#     run setup themselves and exits 0 (does not exec into a wizard with nowhere to read/write).
# --------------------------------------------------------------------------
NOTTY_RELEASE="$WORK/notty/release"
NOTTY_PREFIX="$WORK/notty/prefix"
make_fixture_release "$NOTTY_RELEASE" "0.2.0" "true"
make_fake_prefix "$NOTTY_PREFIX"

case_no_setup_no_tty() {
    id() { fake_id_root "$@"; }
    installer() { :; }
    codesign() { fake_codesign_ok "$@"; }
    export RUNNERVM_PKG_URL="file://$NOTTY_RELEASE"
    export RUNNERVM_PREFIX="$NOTTY_PREFIX"
    export RUNNERVM_STATE_ROOT="$WORK/notty/state"
    export RUNNERVM_TTY="$WORK/notty/no-such-tty"
    # shellcheck disable=SC1090,SC1091 # dynamic path; run shellcheck -x to actually follow it
    source "$SCRIPT"
    main
}
run_case case_no_setup_no_tty
expect_eq "$CASE_CODE" "0" "no RUNNERVM_NO_SETUP + no tty still exits 0"
expect_contains "$CASE_OUT" "no controlling terminal available" \
    "no-tty setup handoff explains why it did not launch the wizard"
expect_contains "$CASE_OUT" "$NOTTY_PREFIX/bin/runnerctl setup" \
    "no-tty setup handoff tells the operator the exact command to run"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
