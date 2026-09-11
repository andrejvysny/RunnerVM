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
#   - `pkgutil` and `spctl`, the two tools verify_package_signature reads its evidence from, are
#     faked as executables on a PATH prepended inside the scenario subshell rather than as shell
#     functions -- see the shim helpers below. No scenario in this file ever runs the real ones.
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

expect_not_contains() {
    local haystack="$1" needle="$2" what="$3"
    case "$haystack" in
    *"$needle"*) no "$what" "did not expect to find: $needle" ;;
    *) ok "$what" ;;
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
    local notarized="${5:-false}" team_id="${6:-}"
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
  "notarized": $notarized,
  "teamId": "$team_id",
  "license": "Apache-2.0"
}
EOF
}

# --------------------------------------------------------------------------
# PATH shims for the two signature tools. bootstrap.sh runs `pkgutil` and `spctl` by name, so a
# directory prepended to PATH inside a scenario's subshell replaces them for that scenario only --
# no real package is ever assessed, and the canned output stays byte-shaped like Apple's (the
# parser is keyed on the certificate-chain line and the exit status, so a fixture that drifts from
# the real shape is the point of failure these shims exist to catch).
#
# Written as executables rather than shell functions (what `id`/`installer`/`codesign` use above)
# because the multi-line output is easier to keep verbatim in a file, and because `command -v
# spctl` -- bootstrap.sh's "is there an assessor at all" probe -- only sees $PATH entries.
# --------------------------------------------------------------------------
write_shim() {
    local path="$1" preamble="$2"
    mkdir -p "$(dirname "$path")"
    printf '#!/bin/sh\n%s\n' "$preamble" >"$path"
    cat >>"$path"
    chmod +x "$path"
}

fake_pkgutil_unsigned() {
    write_shim "$1/pkgutil" ':' <<'SHIM'
# `pkgutil --check-signature <pkg>` on a pkg with no signature at all (exits 1).
echo "Package \"$2\":"
echo "   Status: no signature"
exit 1
SHIM
}

# $2 goes inside the chain line's parentheses (a real team id, or something that is not one); $3
# is the wording after "Notarization:", empty for a pkg with no ticket at all; $4 is anything the
# chain line carries after the parentheses, e.g. " [expired]". The Status line never varies on
# purpose: only the chain line and the "Notarization:" wording may decide anything.
write_pkgutil_signed_shim() {
    write_shim "$1/pkgutil" "TEAM=$2; NOTARIZATION=\"${3:-}\"; SUFFIX=\"${4:-}\"" <<'SHIM'
echo "Package \"$2\":"
echo "   Status: signed by a developer certificate issued by Apple for distribution"
[ -n "$NOTARIZATION" ] && echo "   Notarization: $NOTARIZATION"
echo "   Signed with a trusted timestamp on: 2026-01-02 03:04:05 +0000"
echo "   Certificate Chain:"
echo "    1. Developer ID Installer: RunnerVM Test ($TEAM)$SUFFIX"
echo "       Expires: 2030-01-01 00:00:00 +0000"
echo "       ------------------------------------------------------------------------"
echo "    2. Developer ID Certification Authority"
echo "    3. Apple Root CA"
exit 0
SHIM
}

fake_pkgutil_signed_unnotarized() { write_pkgutil_signed_shim "$1" "$2" "" ""; }
fake_pkgutil_notarized() { write_pkgutil_signed_shim "$1" "$2" "trusted by the Apple notary service" ""; }

# spctl writes its assessment to stderr, hence the >&2 -- bootstrap.sh has to capture it with 2>&1.
fake_spctl_notarized() {
    write_shim "$1/spctl" "TEAM=$2" <<'SHIM'
case "$1" in
--status) echo "assessments enabled"; exit 0 ;;
esac
for a in "$@"; do pkg="$a"; done
echo "$pkg: accepted" >&2
echo "source=Notarized Developer ID" >&2
echo "origin=Developer ID Installer: RunnerVM Test ($TEAM)" >&2
exit 0
SHIM
}

fake_spctl_rejected() {
    write_shim "$1/spctl" ':' <<'SHIM'
case "$1" in
--status) echo "assessments enabled"; exit 0 ;;
esac
for a in "$@"; do pkg="$a"; done
echo "$pkg: rejected" >&2
echo "source=no usable signature" >&2
exit 3
SHIM
}

# No live assessor: `spctl --assess` would accept anything, so bootstrap.sh must not ask. $2 is a
# marker file this shim touches if it is asked anyway; $3 is the `--status` wording, defaulting to
# the switched-off one (pass something else to stand in for a status bootstrap.sh cannot read).
fake_spctl_status_disabled() {
    write_shim "$1/spctl" "MARKER=$2; STATUS=\"${3:-assessments disabled}\"" <<'SHIM'
case "$1" in
--status) echo "$STATUS"; exit 0 ;;
esac
: >"$MARKER"
for a in "$@"; do pkg="$a"; done
echo "$pkg: accepted" >&2
echo "source=Notarized Developer ID" >&2
exit 0
SHIM
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

RUNNERVM_VERSION="0.3.0-rc.1"
expect_eq "$(resolve_base_url)" \
    "https://github.com/andrejvysny/RunnerVM/releases/download/v0.3.0-rc.1" \
    "resolve_base_url adds the leading 'v' RUNNERVM_VERSION was missing"

RUNNERVM_VERSION="v0.3.0-rc.1"
expect_eq "$(resolve_base_url)" \
    "https://github.com/andrejvysny/RunnerVM/releases/download/v0.3.0-rc.1" \
    "resolve_base_url leaves an already-prefixed RUNNERVM_VERSION alone"

RUNNERVM_VERSION="v0.2.0"
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
expect_eq "$(manifest_field "$MANIFEST" notarized)" "false" "manifest_field reads notarized: false as the string 'false'"
expect_eq "$(manifest_field "$MANIFEST" teamId)" "" "manifest_field reads an empty teamId"
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
HAPPY_SHIMS="$WORK/happy/shims"
make_fixture_release "$HAPPY_RELEASE" "0.2.0" "false"
make_fake_prefix "$HAPPY_PREFIX"
fake_pkgutil_unsigned "$HAPPY_SHIMS"
fake_spctl_rejected "$HAPPY_SHIMS"

case_happy_path() {
    id() { fake_id_root "$@"; }
    installer() { printf '%s\n' "$*" >>"$HAPPY_INSTALLER_LOG"; }
    codesign() { fake_codesign_ok "$@"; }
    export PATH="$HAPPY_SHIMS:$PATH"
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
UNSIGNED_SHIMS="$WORK/unsigned/shims"
make_fixture_release "$UNSIGNED_RELEASE" "0.2.0" "false"
make_fake_prefix "$UNSIGNED_PREFIX"
fake_pkgutil_unsigned "$UNSIGNED_SHIMS"
fake_spctl_rejected "$UNSIGNED_SHIMS"

case_unsigned_no_tty() {
    id() { fake_id_root "$@"; }
    installer() { printf '%s\n' "$*" >>"$UNSIGNED_INSTALLER_LOG"; }
    export PATH="$UNSIGNED_SHIMS:$PATH"
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
BROKEN_SHIMS="$WORK/broken/shims"
make_fixture_release "$BROKEN_RELEASE" "0.2.0" "true" "" "true" "ABCDE12345"
make_fake_prefix "$BROKEN_PREFIX"
fake_pkgutil_notarized "$BROKEN_SHIMS" "ABCDE12345"
fake_spctl_notarized "$BROKEN_SHIMS" "ABCDE12345"

case_broken_install() {
    id() { fake_id_root "$@"; }
    installer() { :; }
    export PATH="$BROKEN_SHIMS:$PATH"
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
NOTTY_SHIMS="$WORK/notty/shims"
make_fixture_release "$NOTTY_RELEASE" "0.2.0" "true" "" "true" "ABCDE12345"
make_fake_prefix "$NOTTY_PREFIX"
fake_pkgutil_notarized "$NOTTY_SHIMS" "ABCDE12345"
fake_spctl_notarized "$NOTTY_SHIMS" "ABCDE12345"

case_no_setup_no_tty() {
    id() { fake_id_root "$@"; }
    installer() { :; }
    codesign() { fake_codesign_ok "$@"; }
    export PATH="$NOTTY_SHIMS:$PATH"
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

# --------------------------------------------------------------------------
# 13. verify_pkg_name is a pure check (case globs, no I/O): ten scenarios exercised directly, each
#     in its own subshell via run_case since die() calls exit. Sourcing $SCRIPT never runs main
#     (the "am I sourced" guard at the bottom of bootstrap.sh), so this calls verify_pkg_name
#     straight after sourcing, same as the case_* scenarios above call main.
# --------------------------------------------------------------------------
check_pkg_name() {
    local name="$1"
    # shellcheck disable=SC1090,SC1091 # dynamic path; run shellcheck -x to actually follow it
    source "$SCRIPT"
    verify_pkg_name "$name"
    printf 'accepted: %s\n' "$name"
}

# --------------------------------------------------------------------------
# 13b. verify_manifest_version: MAJOR.MINOR.PATCH plus an optional [0-9A-Za-z.-] prerelease suffix,
#     checked before any download because the value names the cache directory and rides on argv.
# --------------------------------------------------------------------------
check_manifest_version() {
    local version="$1"
    # shellcheck disable=SC1090,SC1091 # dynamic path; run shellcheck -x to actually follow it
    source "$SCRIPT"
    verify_manifest_version "$version"
    printf 'accepted: %s\n' "$version"
}
for v in "0.3.0" "0.3.0-rc.1" "10.20.30-beta-2"; do
    version_case_ok() { check_manifest_version "$v"; }
    run_case version_case_ok
    if [ "$CASE_CODE" -eq 0 ]; then ok "manifest version '$v' accepted"; else no "manifest version '$v' accepted" "$CASE_OUT"; fi
done
for v in "" "0.3" "v0.3.0" "0.3.0-" "../0.3.0" "0.3.0/.." "0.3.0-rc 1" "0.3.0.1" "0.3.0-rc;id"; do
    version_case_bad() { check_manifest_version "$v"; }
    run_case version_case_bad
    if [ "$CASE_CODE" -eq 0 ]; then no "manifest version '$v' rejected" "$CASE_OUT"; else ok "manifest version '$v' rejected"; fi
done

pkgname_case_empty() { check_pkg_name ""; }
run_case pkgname_case_empty
if [ "$CASE_CODE" -eq 0 ]; then
    no "pkg_name: empty rejected" "$CASE_OUT"
else
    expect_contains "$CASE_OUT" "is empty" "pkg_name: empty error names the problem"
fi

pkgname_case_leading_dash() { check_pkg_name "-rf.pkg"; }
run_case pkgname_case_leading_dash
if [ "$CASE_CODE" -eq 0 ]; then
    no "pkg_name: leading dash rejected" "$CASE_OUT"
else
    expect_contains "$CASE_OUT" "must not start with '-'" "pkg_name: leading-dash error names the problem"
fi

pkgname_case_relative_slash() { check_pkg_name "sub/RunnerVM.pkg"; }
run_case pkgname_case_relative_slash
if [ "$CASE_CODE" -eq 0 ]; then
    no "pkg_name: relative path rejected" "$CASE_OUT"
else
    expect_contains "$CASE_OUT" "must not contain '/'" "pkg_name: relative-path error names the problem"
fi

pkgname_case_absolute_slash() { check_pkg_name "/etc/RunnerVM.pkg"; }
run_case pkgname_case_absolute_slash
if [ "$CASE_CODE" -eq 0 ]; then
    no "pkg_name: absolute path rejected" "$CASE_OUT"
else
    expect_contains "$CASE_OUT" "must not contain '/'" "pkg_name: absolute-path error names the problem"
fi

pkgname_case_traversal() { check_pkg_name "../../etc/RunnerVM.pkg"; }
run_case pkgname_case_traversal
if [ "$CASE_CODE" -eq 0 ]; then
    no "pkg_name: directory traversal rejected" "$CASE_OUT"
else
    expect_contains "$CASE_OUT" "must not contain '/'" "pkg_name: traversal error names the problem"
fi

pkgname_case_space() { check_pkg_name "Runner VM.pkg"; }
run_case pkgname_case_space
if [ "$CASE_CODE" -eq 0 ]; then
    no "pkg_name: embedded space rejected" "$CASE_OUT"
else
    expect_contains "$CASE_OUT" "outside [A-Za-z0-9._-]" "pkg_name: space error names the problem"
fi

pkgname_case_shell_metachar() { check_pkg_name 'RunnerVM;rm -rf ~.pkg'; }
run_case pkgname_case_shell_metachar
if [ "$CASE_CODE" -eq 0 ]; then
    no "pkg_name: shell metacharacter rejected" "$CASE_OUT"
else
    expect_contains "$CASE_OUT" "outside [A-Za-z0-9._-]" "pkg_name: metacharacter error names the problem"
fi

pkgname_case_wrong_suffix() { check_pkg_name "RunnerVM-macos-arm64.tar.gz"; }
run_case pkgname_case_wrong_suffix
if [ "$CASE_CODE" -eq 0 ]; then
    no "pkg_name: non-.pkg suffix rejected" "$CASE_OUT"
else
    expect_contains "$CASE_OUT" "does not end in .pkg" "pkg_name: bad-suffix error names the problem"
fi

pkgname_case_valid_plain() { check_pkg_name "RunnerVM-macos-arm64.pkg"; }
run_case pkgname_case_valid_plain
expect_eq "$CASE_CODE" "0" "pkg_name: plain release filename accepted"
expect_contains "$CASE_OUT" "accepted: RunnerVM-macos-arm64.pkg" "pkg_name: plain release filename echoed back"

pkgname_case_valid_dotted() { check_pkg_name "Runner_VM.1.2.3.pkg"; }
run_case pkgname_case_valid_dotted
expect_eq "$CASE_CODE" "0" "pkg_name: dotted/underscored filename accepted"
expect_contains "$CASE_OUT" "accepted: Runner_VM.1.2.3.pkg" "pkg_name: dotted/underscored filename echoed back"

# --------------------------------------------------------------------------
# 14. Full-flow scenario: a manifest whose "package" field attempts directory traversal aborts
#     before download_pkg -- the installer stub never runs and nothing is written outside WORKDIR
#     (in particular, the traversal target is never created). Modeled on case_bad_manifest_arch.
# --------------------------------------------------------------------------
TRAVERSAL_RELEASE="$WORK/traversal/release"
TRAVERSAL_PREFIX="$WORK/traversal/prefix"
TRAVERSAL_INSTALLER_LOG="$WORK/traversal/installer.log"
TRAVERSAL_ESCAPE_TARGET="$WORK/traversal-escape-marker.pkg"
make_fixture_release "$TRAVERSAL_RELEASE" "0.2.0" "true"
sed -i '' 's#"package": "RunnerVM-macos-arm64.pkg"#"package": "../traversal-escape-marker.pkg"#' \
    "$TRAVERSAL_RELEASE/release-manifest.json"
make_fake_prefix "$TRAVERSAL_PREFIX"

case_bad_manifest_pkg_name() {
    id() { fake_id_root "$@"; }
    installer() { printf '%s\n' "$*" >>"$TRAVERSAL_INSTALLER_LOG"; }
    export RUNNERVM_PKG_URL="file://$TRAVERSAL_RELEASE"
    export RUNNERVM_PREFIX="$TRAVERSAL_PREFIX"
    export RUNNERVM_ALLOW_UNSIGNED=1
    export RUNNERVM_NO_SETUP=1
    # shellcheck disable=SC1090,SC1091 # dynamic path; run shellcheck -x to actually follow it
    source "$SCRIPT"
    main
}
run_case case_bad_manifest_pkg_name
if [ "$CASE_CODE" -eq 0 ]; then
    no "manifest package-name traversal aborts" "$CASE_OUT"
else
    expect_contains "$CASE_OUT" "must not contain '/'" \
        "manifest-package-traversal error names the problem"
fi
if [ -f "$TRAVERSAL_INSTALLER_LOG" ]; then
    no "manifest package-name traversal never invokes installer" \
        "installer ran: $(cat "$TRAVERSAL_INSTALLER_LOG")"
else
    ok "manifest package-name traversal never invokes installer"
fi
if [ -e "$TRAVERSAL_ESCAPE_TARGET" ]; then
    no "manifest package-name traversal writes nothing outside WORKDIR" \
        "traversal target was created: $TRAVERSAL_ESCAPE_TARGET"
else
    ok "manifest package-name traversal writes nothing outside WORKDIR"
fi


# ==========================================================================
# 15-21. verify_package_signature: the install-side publisher gate. `curl` sets no quarantine flag
# and `installer` runs no Gatekeeper assessment, so these scenarios cover the only thing standing
# between a downloaded pkg and a root install. Every one of them fakes both tools (see the shim
# helpers near the top) -- the real /usr/sbin/pkgutil and /usr/sbin/spctl are never consulted.
#
# RUNNERVM_EXPECTED_TEAM_ID is a constant in bootstrap.sh, not an env var (that is the point: the
# environment must not be able to unpin the publisher), so a scenario that needs it pinned assigns
# it after sourcing the script -- the same place the script's own default assignment ran.
# ==========================================================================

# --------------------------------------------------------------------------
# 15. Notarized pkg whose leaf team matches the pinned one: installs with no prompt at all.
#     RUNNERVM_TTY points at a path that cannot be opened and RUNNERVM_ALLOW_UNSIGNED is unset, so
#     any confirmation path would abort the run instead of silently passing.
# --------------------------------------------------------------------------
GOODSIG_RELEASE="$WORK/goodsig/release"
GOODSIG_PREFIX="$WORK/goodsig/prefix"
GOODSIG_SHIMS="$WORK/goodsig/shims"
GOODSIG_INSTALLER_LOG="$WORK/goodsig/installer.log"
make_fixture_release "$GOODSIG_RELEASE" "0.3.0" "true" "" "true" "ABCDE12345"
make_fake_prefix "$GOODSIG_PREFIX"
fake_pkgutil_notarized "$GOODSIG_SHIMS" "ABCDE12345"
fake_spctl_notarized "$GOODSIG_SHIMS" "ABCDE12345"

case_notarized_team_match() {
    id() { fake_id_root "$@"; }
    installer() { printf '%s\n' "$*" >>"$GOODSIG_INSTALLER_LOG"; }
    codesign() { fake_codesign_ok "$@"; }
    export PATH="$GOODSIG_SHIMS:$PATH"
    export RUNNERVM_PKG_URL="file://$GOODSIG_RELEASE"
    export RUNNERVM_PREFIX="$GOODSIG_PREFIX"
    export RUNNERVM_STATE_ROOT="$WORK/goodsig/state"
    export RUNNERVM_TTY="$WORK/goodsig/no-such-tty"
    export RUNNERVM_NO_SETUP=1
    # shellcheck disable=SC1090,SC1091 # dynamic path; run shellcheck -x to actually follow it
    source "$SCRIPT"
    # shellcheck disable=SC2034 # read by the sourced bootstrap.sh, not by this file
    RUNNERVM_EXPECTED_TEAM_ID="ABCDE12345"
    main
}
run_case case_notarized_team_match
expect_eq "$CASE_CODE" "0" "notarized + matching team exits 0"
expect_contains "$CASE_OUT" "publisher verified: Developer ID Installer, team ABCDE12345" \
    "notarized + matching team names the verified publisher"
expect_contains "$CASE_OUT" "notarization verified" "notarized + matching team says notarization was verified"
expect_not_contains "$CASE_OUT" "WARNING" "notarized + matching team prints no warning banner"
expect_not_contains "$CASE_OUT" "Continue?" "notarized + matching team never prompts"
if [ -f "$GOODSIG_INSTALLER_LOG" ]; then
    ok "notarized + matching team runs the installer"
else
    no "notarized + matching team runs the installer" "no installer log at $GOODSIG_INSTALLER_LOG"
fi

# --------------------------------------------------------------------------
# 16. A perfectly notarized pkg signed by SOMEBODY ELSE's Developer ID is a hard failure with no
#     escape hatch: RUNNERVM_ALLOW_UNSIGNED=1 is set here and must not rescue it.
# --------------------------------------------------------------------------
WRONGTEAM_RELEASE="$WORK/wrongteam/release"
WRONGTEAM_PREFIX="$WORK/wrongteam/prefix"
WRONGTEAM_SHIMS="$WORK/wrongteam/shims"
WRONGTEAM_INSTALLER_LOG="$WORK/wrongteam/installer.log"
make_fixture_release "$WRONGTEAM_RELEASE" "0.3.0" "true" "" "true" "ABCDE12345"
make_fake_prefix "$WRONGTEAM_PREFIX"
fake_pkgutil_notarized "$WRONGTEAM_SHIMS" "F00DFACE99"
fake_spctl_notarized "$WRONGTEAM_SHIMS" "F00DFACE99"

case_notarized_team_mismatch() {
    id() { fake_id_root "$@"; }
    installer() { printf '%s\n' "$*" >>"$WRONGTEAM_INSTALLER_LOG"; }
    codesign() { fake_codesign_ok "$@"; }
    export PATH="$WRONGTEAM_SHIMS:$PATH"
    export RUNNERVM_PKG_URL="file://$WRONGTEAM_RELEASE"
    export RUNNERVM_PREFIX="$WRONGTEAM_PREFIX"
    export RUNNERVM_ALLOW_UNSIGNED=1
    export RUNNERVM_NO_SETUP=1
    # shellcheck disable=SC1090,SC1091 # dynamic path; run shellcheck -x to actually follow it
    source "$SCRIPT"
    # shellcheck disable=SC2034 # read by the sourced bootstrap.sh, not by this file
    RUNNERVM_EXPECTED_TEAM_ID="ABCDE12345"
    main
}
run_case case_notarized_team_mismatch
if [ "$CASE_CODE" -eq 0 ]; then
    no "a different signing team aborts even with RUNNERVM_ALLOW_UNSIGNED=1" "$CASE_OUT"
else
    expect_contains "$CASE_OUT" "signed by Developer ID team 'F00DFACE99'" \
        "wrong-team error names the team that actually signed the pkg"
    expect_contains "$CASE_OUT" "not RunnerVM's 'ABCDE12345'" \
        "wrong-team error names the team it expected"
    expect_contains "$CASE_OUT" "no override" "wrong-team error says there is no override"
fi
if [ -f "$WRONGTEAM_INSTALLER_LOG" ]; then
    no "a different signing team never invokes installer" "installer ran: $(cat "$WRONGTEAM_INSTALLER_LOG")"
else
    ok "a different signing team never invokes installer"
fi

# --------------------------------------------------------------------------
# 17. Signed by us but NOT notarized: a prompt, not a lockout. RUNNERVM_ALLOW_UNSIGNED=1 accepts it
#     (same escape hatch as the unsigned path) and the install proceeds.
# --------------------------------------------------------------------------
UNNOTARIZED_RELEASE="$WORK/unnotarized/release"
UNNOTARIZED_PREFIX="$WORK/unnotarized/prefix"
UNNOTARIZED_SHIMS="$WORK/unnotarized/shims"
UNNOTARIZED_INSTALLER_LOG="$WORK/unnotarized/installer.log"
make_fixture_release "$UNNOTARIZED_RELEASE" "0.3.0" "true" "" "false" "ABCDE12345"
make_fake_prefix "$UNNOTARIZED_PREFIX"
fake_pkgutil_signed_unnotarized "$UNNOTARIZED_SHIMS" "ABCDE12345"
fake_spctl_rejected "$UNNOTARIZED_SHIMS"

case_unnotarized_allowed() {
    id() { fake_id_root "$@"; }
    installer() { printf '%s\n' "$*" >>"$UNNOTARIZED_INSTALLER_LOG"; }
    codesign() { fake_codesign_ok "$@"; }
    export PATH="$UNNOTARIZED_SHIMS:$PATH"
    export RUNNERVM_PKG_URL="file://$UNNOTARIZED_RELEASE"
    export RUNNERVM_PREFIX="$UNNOTARIZED_PREFIX"
    export RUNNERVM_STATE_ROOT="$WORK/unnotarized/state"
    export RUNNERVM_TTY="$WORK/unnotarized/no-such-tty"
    export RUNNERVM_ALLOW_UNSIGNED=1
    export RUNNERVM_NO_SETUP=1
    # shellcheck disable=SC1090,SC1091 # dynamic path; run shellcheck -x to actually follow it
    source "$SCRIPT"
    # shellcheck disable=SC2034 # read by the sourced bootstrap.sh, not by this file
    RUNNERVM_EXPECTED_TEAM_ID="ABCDE12345"
    main
}
run_case case_unnotarized_allowed
expect_eq "$CASE_CODE" "0" "signed-but-unnotarized + RUNNERVM_ALLOW_UNSIGNED=1 exits 0"
expect_contains "$CASE_OUT" "does not vouch for this package" \
    "signed-but-unnotarized run says the notary does not vouch for the pkg"
expect_contains "$CASE_OUT" "skipping not-notarized-package confirmation" \
    "signed-but-unnotarized run names the env var that skipped the prompt"
if [ -f "$UNNOTARIZED_INSTALLER_LOG" ]; then
    ok "signed-but-unnotarized + RUNNERVM_ALLOW_UNSIGNED=1 runs the installer"
else
    no "signed-but-unnotarized + RUNNERVM_ALLOW_UNSIGNED=1 runs the installer" \
        "no installer log at $UNNOTARIZED_INSTALLER_LOG"
fi

# --------------------------------------------------------------------------
# 18. Same signed-but-unnotarized pkg, no RUNNERVM_ALLOW_UNSIGNED and no controlling terminal to
#     prompt on: aborts before the installer, and says which env var accepts the risk. This
#     fixture's manifest claims notarized:true, which changes nothing except a line saying the
#     manifest overstated itself -- a manifest cannot notarize a package by asserting that it is.
# --------------------------------------------------------------------------
UNNOTARIZED2_RELEASE="$WORK/unnotarized2/release"
UNNOTARIZED2_PREFIX="$WORK/unnotarized2/prefix"
UNNOTARIZED2_INSTALLER_LOG="$WORK/unnotarized2/installer.log"
make_fixture_release "$UNNOTARIZED2_RELEASE" "0.3.0" "true" "" "true" "ABCDE12345"
make_fake_prefix "$UNNOTARIZED2_PREFIX"

case_unnotarized_no_tty() {
    id() { fake_id_root "$@"; }
    installer() { printf '%s\n' "$*" >>"$UNNOTARIZED2_INSTALLER_LOG"; }
    export PATH="$UNNOTARIZED_SHIMS:$PATH"
    export RUNNERVM_PKG_URL="file://$UNNOTARIZED2_RELEASE"
    export RUNNERVM_PREFIX="$UNNOTARIZED2_PREFIX"
    export RUNNERVM_TTY="$WORK/unnotarized2/no-such-tty"
    export RUNNERVM_NO_SETUP=1
    # shellcheck disable=SC1090,SC1091 # dynamic path; run shellcheck -x to actually follow it
    source "$SCRIPT"
    # shellcheck disable=SC2034 # read by the sourced bootstrap.sh, not by this file
    RUNNERVM_EXPECTED_TEAM_ID="ABCDE12345"
    main
}
run_case case_unnotarized_no_tty
if [ "$CASE_CODE" -eq 0 ]; then
    no "signed-but-unnotarized + no tty + no RUNNERVM_ALLOW_UNSIGNED aborts" "$CASE_OUT"
else
    expect_contains "$CASE_OUT" "refusing to install a package that is not notarized non-interactively" \
        "unnotarized/no-tty refusal names the problem"
    expect_contains "$CASE_OUT" "RUNNERVM_ALLOW_UNSIGNED=1" \
        "unnotarized/no-tty refusal names the escape hatch"
    expect_contains "$CASE_OUT" "overstated this package" \
        "a manifest claiming notarized:true over an unnotarized pkg is called out, not believed"
fi
if [ -f "$UNNOTARIZED2_INSTALLER_LOG" ]; then
    no "unnotarized/no-tty abort never invokes installer" "installer ran: $(cat "$UNNOTARIZED2_INSTALLER_LOG")"
else
    ok "unnotarized/no-tty abort never invokes installer"
fi

# --------------------------------------------------------------------------
# 19. A manifest that claims signed:true + notarized:true over a pkg carrying no signature at all
#     (a tampered or mis-built release): the pkg decides, so this is the ordinary unsigned path,
#     plus a line recording that the manifest overstated itself. Never a hard failure -- a manifest
#     must not be able to lock an operator out of an install they can still confirm by hand.
# --------------------------------------------------------------------------
OVERSTATED_RELEASE="$WORK/overstated/release"
OVERSTATED_PREFIX="$WORK/overstated/prefix"
OVERSTATED_SHIMS="$WORK/overstated/shims"
OVERSTATED_INSTALLER_LOG="$WORK/overstated/installer.log"
make_fixture_release "$OVERSTATED_RELEASE" "0.3.0" "true" "" "true" "ABCDE12345"
make_fake_prefix "$OVERSTATED_PREFIX"
fake_pkgutil_unsigned "$OVERSTATED_SHIMS"
fake_spctl_rejected "$OVERSTATED_SHIMS"

case_manifest_overstated() {
    id() { fake_id_root "$@"; }
    installer() { printf '%s\n' "$*" >>"$OVERSTATED_INSTALLER_LOG"; }
    export PATH="$OVERSTATED_SHIMS:$PATH"
    export RUNNERVM_PKG_URL="file://$OVERSTATED_RELEASE"
    export RUNNERVM_PREFIX="$OVERSTATED_PREFIX"
    export RUNNERVM_TTY="$WORK/overstated/no-such-tty"
    export RUNNERVM_NO_SETUP=1
    # shellcheck disable=SC1090,SC1091 # dynamic path; run shellcheck -x to actually follow it
    source "$SCRIPT"
    # shellcheck disable=SC2034 # read by the sourced bootstrap.sh, not by this file
    RUNNERVM_EXPECTED_TEAM_ID="ABCDE12345"
    main
}
run_case case_manifest_overstated
if [ "$CASE_CODE" -eq 0 ]; then
    no "manifest claiming a signature it does not have falls back to the unsigned path" "$CASE_OUT"
else
    expect_contains "$CASE_OUT" "carries no Developer ID Installer signature" \
        "overstated manifest is judged on the pkg, not the manifest"
    expect_contains "$CASE_OUT" "overstated this package" \
        "overstated manifest is called out as overstating"
    expect_contains "$CASE_OUT" "refusing to install an unsigned package non-interactively" \
        "overstated manifest takes the unsigned path, not a hard failure"
fi
if [ -f "$OVERSTATED_INSTALLER_LOG" ]; then
    no "overstated manifest never invokes installer" "installer ran: $(cat "$OVERSTATED_INSTALLER_LOG")"
else
    ok "overstated manifest never invokes installer"
fi

# --------------------------------------------------------------------------
# 20. Gatekeeper assessments disabled on the host: `spctl --assess` would accept anything, so it is
#     not asked at all (the shim touches a marker file if it is) and pkgutil's stapled-ticket line
#     becomes the fallback evidence -- proceeding, but saying so loudly.
# --------------------------------------------------------------------------
SPCTLOFF_RELEASE="$WORK/spctloff/release"
SPCTLOFF_PREFIX="$WORK/spctloff/prefix"
SPCTLOFF_SHIMS="$WORK/spctloff/shims"
SPCTLOFF_INSTALLER_LOG="$WORK/spctloff/installer.log"
SPCTLOFF_ASSESS_MARKER="$WORK/spctloff/assess-was-called"
make_fixture_release "$SPCTLOFF_RELEASE" "0.3.0" "true" "" "true" "ABCDE12345"
make_fake_prefix "$SPCTLOFF_PREFIX"
fake_pkgutil_notarized "$SPCTLOFF_SHIMS" "ABCDE12345"
fake_spctl_status_disabled "$SPCTLOFF_SHIMS" "$SPCTLOFF_ASSESS_MARKER"

case_spctl_disabled() {
    id() { fake_id_root "$@"; }
    installer() { printf '%s\n' "$*" >>"$SPCTLOFF_INSTALLER_LOG"; }
    codesign() { fake_codesign_ok "$@"; }
    export PATH="$SPCTLOFF_SHIMS:$PATH"
    export RUNNERVM_PKG_URL="file://$SPCTLOFF_RELEASE"
    export RUNNERVM_PREFIX="$SPCTLOFF_PREFIX"
    export RUNNERVM_STATE_ROOT="$WORK/spctloff/state"
    export RUNNERVM_TTY="$WORK/spctloff/no-such-tty"
    export RUNNERVM_NO_SETUP=1
    # shellcheck disable=SC1090,SC1091 # dynamic path; run shellcheck -x to actually follow it
    source "$SCRIPT"
    # shellcheck disable=SC2034 # read by the sourced bootstrap.sh, not by this file
    RUNNERVM_EXPECTED_TEAM_ID="ABCDE12345"
    main
}
run_case case_spctl_disabled
expect_eq "$CASE_CODE" "0" "spctl disabled + pkgutil notarization proceeds"
expect_contains "$CASE_OUT" "notarization unverified on this host" \
    "spctl-disabled run says notarization is unverified, loudly"
if [ -e "$SPCTLOFF_ASSESS_MARKER" ]; then
    no "a disabled spctl is never asked to assess" "the assess marker was created"
else
    ok "a disabled spctl is never asked to assess"
fi
if [ -f "$SPCTLOFF_INSTALLER_LOG" ]; then
    ok "spctl disabled + pkgutil notarization runs the installer"
else
    no "spctl disabled + pkgutil notarization runs the installer" \
        "no installer log at $SPCTLOFF_INSTALLER_LOG"
fi

# --------------------------------------------------------------------------
# 21. RUNNERVM_EXPECTED_TEAM_ID left at its shipped default (empty, until the operator's Developer
#     ID certificates exist): the team comparison is skipped and the installer says so, but the
#     signature and notarization requirements still hold.
# --------------------------------------------------------------------------
UNPINNED_RELEASE="$WORK/unpinned/release"
UNPINNED_PREFIX="$WORK/unpinned/prefix"
UNPINNED_SHIMS="$WORK/unpinned/shims"
UNPINNED_INSTALLER_LOG="$WORK/unpinned/installer.log"
make_fixture_release "$UNPINNED_RELEASE" "0.3.0" "true" "" "true" "F00DFACE99"
make_fake_prefix "$UNPINNED_PREFIX"
fake_pkgutil_notarized "$UNPINNED_SHIMS" "F00DFACE99"
fake_spctl_notarized "$UNPINNED_SHIMS" "F00DFACE99"

case_team_not_pinned() {
    id() { fake_id_root "$@"; }
    installer() { printf '%s\n' "$*" >>"$UNPINNED_INSTALLER_LOG"; }
    codesign() { fake_codesign_ok "$@"; }
    export PATH="$UNPINNED_SHIMS:$PATH"
    export RUNNERVM_PKG_URL="file://$UNPINNED_RELEASE"
    export RUNNERVM_PREFIX="$UNPINNED_PREFIX"
    export RUNNERVM_STATE_ROOT="$WORK/unpinned/state"
    export RUNNERVM_TTY="$WORK/unpinned/no-such-tty"
    export RUNNERVM_NO_SETUP=1
    # shellcheck disable=SC1090,SC1091 # dynamic path; run shellcheck -x to actually follow it
    source "$SCRIPT"
    main
}
run_case case_team_not_pinned
expect_eq "$CASE_CODE" "0" "an unpinned publisher team still installs a notarized pkg"
expect_contains "$CASE_OUT" "publisher team not pinned in this installer" \
    "an unpinned publisher team is announced, not hidden"
expect_contains "$CASE_OUT" "F00DFACE99" "the unpinned run still reports the pkg's own team"
if [ -f "$UNPINNED_INSTALLER_LOG" ]; then
    ok "an unpinned publisher team runs the installer"
else
    no "an unpinned publisher team runs the installer" "no installer log at $UNPINNED_INSTALLER_LOG"
fi

# --------------------------------------------------------------------------
# 22. The evidence must come from the tools, not from text they echo back. pkgutil's first line
#     repeats the package path, and the package lives under $TMPDIR, so a directory named like a
#     certificate-chain entry is a forged-signature attempt: here TMPDIR spells out both a
#     "Developer ID Installer:" chain line and a "Notarization: trusted ..." line, with the team
#     unpinned and assessments disabled so nothing else can catch it. The line-anchored parse is
#     what makes this an ordinary unsigned install instead of a silent one.
# --------------------------------------------------------------------------
INJECT_RELEASE="$WORK/inject/release"
INJECT_PREFIX="$WORK/inject/prefix"
INJECT_SHIMS="$WORK/inject/shims"
INJECT_INSTALLER_LOG="$WORK/inject/installer.log"
INJECT_TMPDIR="$WORK/inject/1. Developer ID Installer: RunnerVM (F00DFACE99) Notarization: trusted by the Apple notary service"
make_fixture_release "$INJECT_RELEASE" "0.3.0" "false"
make_fake_prefix "$INJECT_PREFIX"
mkdir -p "$INJECT_TMPDIR"
fake_pkgutil_unsigned "$INJECT_SHIMS"
fake_spctl_status_disabled "$INJECT_SHIMS" "$WORK/inject/assess-was-called"

case_forged_path_signature() {
    id() { fake_id_root "$@"; }
    installer() { printf '%s\n' "$*" >>"$INJECT_INSTALLER_LOG"; }
    codesign() { fake_codesign_ok "$@"; }
    export PATH="$INJECT_SHIMS:$PATH"
    export TMPDIR="$INJECT_TMPDIR"
    export RUNNERVM_PKG_URL="file://$INJECT_RELEASE"
    export RUNNERVM_PREFIX="$INJECT_PREFIX"
    export RUNNERVM_TTY="$WORK/inject/no-such-tty"
    export RUNNERVM_NO_SETUP=1
    # shellcheck disable=SC1090,SC1091 # dynamic path; run shellcheck -x to actually follow it
    source "$SCRIPT"
    main
}
run_case case_forged_path_signature
if [ "$CASE_CODE" -eq 0 ]; then
    no "a package path shaped like pkgutil's own output cannot forge a signature" "$CASE_OUT"
else
    expect_contains "$CASE_OUT" "carries no Developer ID Installer signature" \
        "a forged-looking package path is still read as unsigned"
    expect_contains "$CASE_OUT" "refusing to install an unsigned package non-interactively" \
        "a forged-looking package path takes the unsigned path"
fi
if [ -f "$INJECT_INSTALLER_LOG" ]; then
    no "a forged-looking package path never invokes installer" \
        "installer ran: $(cat "$INJECT_INSTALLER_LOG")"
else
    ok "a forged-looking package path never invokes installer"
fi

# --------------------------------------------------------------------------
# 23. "Notarization:" is judged on the first word of its value, not on the presence of the string
#     "trusted" anywhere in the line -- Apple's negative wordings contain it too. Both of them must
#     leave the package unnotarized. The assessor is switched off in these runs so that pkgutil's
#     line is the only notarization evidence there is, which also pins item 4: the
#     "notarization unverified" notice is printed on a run that ends in a refusal, not just on the
#     accept path.
# --------------------------------------------------------------------------
WORDING_RELEASE="$WORK/wording/release"
WORDING_PREFIX="$WORK/wording/prefix"
WORDING_SHIMS="$WORK/wording/shims"
WORDING_INSTALLER_LOG="$WORK/wording/installer.log"
make_fixture_release "$WORDING_RELEASE" "0.3.0" "true" "" "false" "ABCDE12345"
make_fake_prefix "$WORDING_PREFIX"
fake_spctl_status_disabled "$WORDING_SHIMS" "$WORK/wording/assess-was-called"

case_notarization_wording() {
    id() { fake_id_root "$@"; }
    installer() { printf '%s\n' "$*" >>"$WORDING_INSTALLER_LOG"; }
    codesign() { fake_codesign_ok "$@"; }
    export PATH="$WORDING_SHIMS:$PATH"
    export RUNNERVM_PKG_URL="file://$WORDING_RELEASE"
    export RUNNERVM_PREFIX="$WORDING_PREFIX"
    export RUNNERVM_TTY="$WORK/wording/no-such-tty"
    export RUNNERVM_NO_SETUP=1
    # shellcheck disable=SC1090,SC1091 # dynamic path; run shellcheck -x to actually follow it
    source "$SCRIPT"
    # shellcheck disable=SC2034 # read by the sourced bootstrap.sh, not by this file
    RUNNERVM_EXPECTED_TEAM_ID="ABCDE12345"
    main
}

for wording in "not trusted by the Apple notary service" "untrusted by the Apple notary service"; do
    write_pkgutil_signed_shim "$WORDING_SHIMS" "ABCDE12345" "$wording" ""
    rm -f "$WORDING_INSTALLER_LOG"
    run_case case_notarization_wording
    if [ "$CASE_CODE" -eq 0 ]; then
        no "'Notarization: $wording' is not notarized" "$CASE_OUT"
    else
        expect_contains "$CASE_OUT" "refusing to install a package that is not notarized" \
            "'Notarization: $wording' takes the not-notarized path"
        expect_contains "$CASE_OUT" "notarization unverified on this host" \
            "'Notarization: $wording' still gets the disabled-assessor notice, on a refusal"
    fi
    if [ -f "$WORDING_INSTALLER_LOG" ]; then
        no "'Notarization: $wording' never invokes installer" "installer ran"
    else
        ok "'Notarization: $wording' never invokes installer"
    fi
done

# --------------------------------------------------------------------------
# 24. A real chain line can carry a suffix after the parentheses -- "(TEAMID) [expired]" is the one
#     to expect. The team id must still be read out of it: anchoring the match to the end of the
#     line would yield no team, and with a pin set that is a hard failure on a package that is
#     actually ours.
# --------------------------------------------------------------------------
SUFFIX_RELEASE="$WORK/suffix/release"
SUFFIX_PREFIX="$WORK/suffix/prefix"
SUFFIX_SHIMS="$WORK/suffix/shims"
SUFFIX_INSTALLER_LOG="$WORK/suffix/installer.log"
make_fixture_release "$SUFFIX_RELEASE" "0.3.0" "true" "" "true" "ABCDE12345"
make_fake_prefix "$SUFFIX_PREFIX"
write_pkgutil_signed_shim "$SUFFIX_SHIMS" "ABCDE12345" "trusted by the Apple notary service" " [expired]"
fake_spctl_notarized "$SUFFIX_SHIMS" "ABCDE12345"

case_chain_line_suffix() {
    id() { fake_id_root "$@"; }
    installer() { printf '%s\n' "$*" >>"$SUFFIX_INSTALLER_LOG"; }
    codesign() { fake_codesign_ok "$@"; }
    export PATH="$SUFFIX_SHIMS:$PATH"
    export RUNNERVM_PKG_URL="file://$SUFFIX_RELEASE"
    export RUNNERVM_PREFIX="$SUFFIX_PREFIX"
    export RUNNERVM_STATE_ROOT="$WORK/suffix/state"
    export RUNNERVM_TTY="$WORK/suffix/no-such-tty"
    export RUNNERVM_NO_SETUP=1
    # shellcheck disable=SC1090,SC1091 # dynamic path; run shellcheck -x to actually follow it
    source "$SCRIPT"
    # shellcheck disable=SC2034 # read by the sourced bootstrap.sh, not by this file
    RUNNERVM_EXPECTED_TEAM_ID="ABCDE12345"
    main
}
run_case case_chain_line_suffix
expect_eq "$CASE_CODE" "0" "a chain line with a trailing '[expired]' still yields the team id"
expect_contains "$CASE_OUT" "publisher verified: Developer ID Installer, team ABCDE12345" \
    "the team id is read from a chain line that does not end at the parentheses"
if [ -f "$SUFFIX_INSTALLER_LOG" ]; then
    ok "a chain line with a trailing suffix runs the installer"
else
    no "a chain line with a trailing suffix runs the installer" "no installer log"
fi

# --------------------------------------------------------------------------
# 25. Parentheses holding something that is not a ten-character team id are not a team id this
#     installer can compare, so the package is UNSIGNED -- the warn-and-confirm path, never the
#     wrong-team hard failure. bash and Swift have to return the same verdict for the same bytes,
#     and "signed by somebody unreadable" is not one of the verdicts either of them has.
# --------------------------------------------------------------------------
BADTEAM_RELEASE="$WORK/badteam/release"
BADTEAM_PREFIX="$WORK/badteam/prefix"
BADTEAM_SHIMS="$WORK/badteam/shims"
BADTEAM_INSTALLER_LOG="$WORK/badteam/installer.log"
make_fixture_release "$BADTEAM_RELEASE" "0.3.0" "true" "" "true" "ABCDE12345"
make_fake_prefix "$BADTEAM_PREFIX"
write_pkgutil_signed_shim "$BADTEAM_SHIMS" "SHORT9" "trusted by the Apple notary service" ""
fake_spctl_notarized "$BADTEAM_SHIMS" "SHORT9"

case_unreadable_team() {
    id() { fake_id_root "$@"; }
    installer() { printf '%s\n' "$*" >>"$BADTEAM_INSTALLER_LOG"; }
    codesign() { fake_codesign_ok "$@"; }
    export PATH="$BADTEAM_SHIMS:$PATH"
    export RUNNERVM_PKG_URL="file://$BADTEAM_RELEASE"
    export RUNNERVM_PREFIX="$BADTEAM_PREFIX"
    export RUNNERVM_TTY="$WORK/badteam/no-such-tty"
    export RUNNERVM_NO_SETUP=1
    # shellcheck disable=SC1090,SC1091 # dynamic path; run shellcheck -x to actually follow it
    source "$SCRIPT"
    # shellcheck disable=SC2034 # read by the sourced bootstrap.sh, not by this file
    RUNNERVM_EXPECTED_TEAM_ID="ABCDE12345"
    main
}
run_case case_unreadable_team
if [ "$CASE_CODE" -eq 0 ]; then
    no "a team id that is not ten characters is treated as unsigned" "$CASE_OUT"
else
    expect_contains "$CASE_OUT" "no readable ten-character team id" \
        "an unreadable team id is named as the reason the pkg counts as unsigned"
    expect_contains "$CASE_OUT" "refusing to install an unsigned package non-interactively" \
        "an unreadable team id takes the unsigned path"
    expect_not_contains "$CASE_OUT" "not RunnerVM's" \
        "an unreadable team id is never the no-override wrong-team failure"
fi
if [ -f "$BADTEAM_INSTALLER_LOG" ]; then
    no "an unreadable team id never invokes installer" "installer ran"
else
    ok "an unreadable team id never invokes installer"
fi

# --------------------------------------------------------------------------
# 26. `spctl --status` is believed only when it positively says assessments are enabled. A wording
#     this installer cannot read is not evidence that the assessor works, so it is treated exactly
#     like a switched-off one: never asked to assess, stapled ticket as the fallback, notice
#     printed.
# --------------------------------------------------------------------------
UNKNOWNSTATUS_RELEASE="$WORK/unknownstatus/release"
UNKNOWNSTATUS_PREFIX="$WORK/unknownstatus/prefix"
UNKNOWNSTATUS_SHIMS="$WORK/unknownstatus/shims"
UNKNOWNSTATUS_INSTALLER_LOG="$WORK/unknownstatus/installer.log"
UNKNOWNSTATUS_MARKER="$WORK/unknownstatus/assess-was-called"
make_fixture_release "$UNKNOWNSTATUS_RELEASE" "0.3.0" "true" "" "true" "ABCDE12345"
make_fake_prefix "$UNKNOWNSTATUS_PREFIX"
fake_pkgutil_notarized "$UNKNOWNSTATUS_SHIMS" "ABCDE12345"
fake_spctl_status_disabled "$UNKNOWNSTATUS_SHIMS" "$UNKNOWNSTATUS_MARKER" "assessments status unknown"

case_spctl_status_unknown() {
    id() { fake_id_root "$@"; }
    installer() { printf '%s\n' "$*" >>"$UNKNOWNSTATUS_INSTALLER_LOG"; }
    codesign() { fake_codesign_ok "$@"; }
    export PATH="$UNKNOWNSTATUS_SHIMS:$PATH"
    export RUNNERVM_PKG_URL="file://$UNKNOWNSTATUS_RELEASE"
    export RUNNERVM_PREFIX="$UNKNOWNSTATUS_PREFIX"
    export RUNNERVM_STATE_ROOT="$WORK/unknownstatus/state"
    export RUNNERVM_TTY="$WORK/unknownstatus/no-such-tty"
    export RUNNERVM_NO_SETUP=1
    # shellcheck disable=SC1090,SC1091 # dynamic path; run shellcheck -x to actually follow it
    source "$SCRIPT"
    # shellcheck disable=SC2034 # read by the sourced bootstrap.sh, not by this file
    RUNNERVM_EXPECTED_TEAM_ID="ABCDE12345"
    main
}
run_case case_spctl_status_unknown
expect_eq "$CASE_CODE" "0" "an unreadable spctl --status falls back to the stapled ticket"
expect_contains "$CASE_OUT" "notarization unverified on this host" \
    "an unreadable spctl --status gets the same loud notice as a disabled one"
if [ -e "$UNKNOWNSTATUS_MARKER" ]; then
    no "an assessor whose status cannot be read is never asked to assess" "the assess marker was created"
else
    ok "an assessor whose status cannot be read is never asked to assess"
fi
if [ -f "$UNKNOWNSTATUS_INSTALLER_LOG" ]; then
    ok "an unreadable spctl --status still runs the installer"
else
    no "an unreadable spctl --status still runs the installer" "no installer log"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
