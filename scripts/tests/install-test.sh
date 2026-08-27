#!/usr/bin/env bash
# Unit checks for scripts/install.sh's service-group defaulting and refusal logic: run entirely
# via --dry-run (no filesystem writes, no dscl/sudo mutation) against a throwaway prefix/state
# dir. Does not touch the real directory service beyond read-only `dscl . -read`/`-list` lookups,
# which install.sh performs on every invocation to plan its output.
#
# usage: scripts/tests/install-test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/install.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rvm-install-test-XXXXXX")"
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

# Fresh --prefix/--state-dir per call so no run's queued "create" plan is polluted by a prior
# call's leftovers; --runtime-dir is left at its short default (/var/run/runnervm) so the dry-run
# plan never trips the unrelated 100-byte socket path budget on a deep $TMPDIR.
dry_run() {
    local n="$1"
    shift
    "$SCRIPT" --dry-run --prefix "$WORK/$n/prefix" --state-dir "$WORK/$n/state" "$@" 2>&1
}

# --------------------------------------------------------------------------
# 1. Default plan uses the dedicated _runnervm group, not staff
# --------------------------------------------------------------------------
if out="$(dry_run default)"; then
    expect_contains "$out" "_runnervm:_runnervm" \
        "default plan chowns state to _runnervm:_runnervm"
    expect_contains "$out" "group _runnervm" \
        "default plan reports on the _runnervm group"
    case "$out" in
    *":staff"*) no "default plan never mentions :staff" "found a :staff reference: $out" ;;
    *) ok "default plan never mentions :staff" ;;
    esac
else
    no "default --dry-run run exits 0" "$out"
fi

# --------------------------------------------------------------------------
# 2. logs/ and logs/instances are explicitly 0750
# --------------------------------------------------------------------------
out="$(dry_run modes)"
expect_contains "$out" "chmod 0750 $WORK/modes/state/logs" \
    "logs/ is explicitly chmod 0750"
expect_contains "$out" "mkdir -p -m 0750 $WORK/modes/state/logs/instances" \
    "logs/instances is created 0750"

# --------------------------------------------------------------------------
# 3. --group staff without --allow-staff-group is refused
# --------------------------------------------------------------------------
if out="$(dry_run staff-refused --group staff)"; then
    no "--group staff without --allow-staff-group exits non-zero" "$out"
else
    ok "--group staff without --allow-staff-group exits non-zero"
    expect_contains "$out" "staff" "refusal message mentions staff"
    expect_contains "$out" "allow-staff-group" "refusal message names the escape hatch"
fi

# --------------------------------------------------------------------------
# 4. --group staff --allow-staff-group proceeds
# --------------------------------------------------------------------------
if out="$(dry_run staff-allowed --group staff --allow-staff-group)"; then
    expect_contains "$out" "_runnervm:staff" \
        "--group staff --allow-staff-group chowns state to _runnervm:staff"
    ok "--group staff --allow-staff-group exits 0"
else
    no "--group staff --allow-staff-group exits 0" "$out"
fi

# --------------------------------------------------------------------------
# 5. Default plan installs the image-builder assets (spec P6): guest agent binary + unit, the
#    shipped recipes (root:_runnervm, not the service user), and the builder's own directories.
#    Independent of whether GuestAgent/bin/linux-arm64/runnervm-guest-agent happens to exist on
#    this machine: either branch (found prebuilt vs. would build it) still queues the same
#    install/chown lines below it.
# --------------------------------------------------------------------------
out="$(dry_run assets)"
expect_contains "$out" "guest-agent/linux-arm64/runnervm-guest-agent" \
    "default plan installs the guest agent binary"
expect_contains "$out" "runnervm-guest-agent.service" \
    "default plan installs the guest agent systemd unit"
expect_contains "$out" "share/recipes" \
    "default plan installs the shipped recipes"
expect_contains "$out" "Runnerfile" \
    "default plan installs at least one Runnerfile"
expect_contains "$out" "chown root:_runnervm" \
    "recipes are chowned to root:_runnervm, not the service user"
expect_contains "$out" "state/builds" \
    "default plan creates the image-build state directory"
expect_contains "$out" "cache/base-images" \
    "default plan creates the base-image cache directory"
expect_contains "$out" "logs/builds" \
    "default plan creates the build logs directory"

# --------------------------------------------------------------------------
# 6. --skip-guest-agent warns instead of installing a guest agent, and touches nothing under
#    guest-agent/ -- recipes and the new directories are still installed either way.
# --------------------------------------------------------------------------
out="$(dry_run skip-agent --skip-guest-agent)"
expect_contains "$out" "skip-guest-agent" \
    "--skip-guest-agent warns that it is not installing a guest agent"
expect_contains "$out" "share/recipes" \
    "--skip-guest-agent still installs the shipped recipes"
# The warning text above names where the binary *would* go, so a plain substring check on the
# whole output would false-positive on it -- anchor to the actual `mkdir -p` action line instead.
if printf '%s\n' "$out" | grep -q '^+ mkdir -p .*guest-agent/linux-arm64$'; then
    no "--skip-guest-agent installs nothing under guest-agent/" "found a mkdir line: $out"
else
    ok "--skip-guest-agent installs nothing under guest-agent/"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
