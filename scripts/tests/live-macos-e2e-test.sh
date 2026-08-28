#!/usr/bin/env bash
# Unit checks for scripts/live-macos-e2e.sh and scripts/lib/live-macos.sh that need no daemon, no
# VM, no macOS guest and no GitHub: argument handling, scenario selection, and the identity /
# leak assertions run against a fake state directory.
#
# usage: scripts/tests/live-macos-e2e-test.sh
#
# shellcheck disable=SC2034
# SC2034 (appears unused): PROFILE, STATE_DIR, SOCKET and friends are read by the sourced driver's
# own functions -- invisible to a standalone shellcheck pass over just this file.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/live-macos-e2e.sh"
TWORK="$(mktemp -d "${TMPDIR:-/tmp}/rvm-live-macos-test-XXXXXX")"
trap 'rm -rf "$TWORK"' EXIT

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
# 1. Argument handling, as a subprocess
# --------------------------------------------------------------------------
if help_out="$("$SCRIPT" --help 2>&1)"; then
    expect_contains "$help_out" "usage: live-macos-e2e.sh" "--help prints usage"
    expect_contains "$help_out" "concurrency" "--help documents the concurrency scenario"
    expect_contains "$help_out" "--soak-jobs" "--help documents --soak-jobs"
else
    no "--help exits 0" "$help_out"
fi

if out="$("$SCRIPT" --repo acme/app 2>&1)"; then
    no "a missing --profile fails" "exited 0"
else
    expect_contains "$out" "--profile is required" "a missing --profile fails"
fi

if out="$("$SCRIPT" --profile p 2>&1)"; then
    no "a missing --repo fails" "exited 0"
else
    expect_contains "$out" "RUNNERVM_E2E_REPO is required" "a missing --repo fails"
fi

if out="$("$SCRIPT" --profile p --repo acme/app --scenario nope 2>&1)"; then
    no "an unknown scenario fails" "exited 0"
else
    expect_contains "$out" "unknown scenario: nope" "an unknown scenario names itself"
fi

# --------------------------------------------------------------------------
# Source the driver (and, through it, both libs) so the pure helpers can be called directly.
# --------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$SCRIPT"

# --------------------------------------------------------------------------
# 2. Scenario selection
# --------------------------------------------------------------------------
SCENARIOS="all"
expect_eq "$(scenario_list)" "concurrency recovery soak" "\"all\" expands to every scenario"
SCENARIOS="soak"
expect_eq "$(scenario_list)" "soak" "a single scenario is passed through"
SCENARIOS="concurrency,soak"
expect_eq "$(scenario_list)" "concurrency soak" "a comma-separated list becomes a space list"
SCENARIOS="all"

# --------------------------------------------------------------------------
# 3. Per-instance identity, against a fake state directory
# --------------------------------------------------------------------------
# `macos_identity_snapshot` reads instance directories directly (the identity is a file vmworker
# mints; no DTO carries it), so a fake tree is enough to exercise the uniqueness rules.
PROFILE="rvm-macos-26"
STATE_DIR="$TWORK/state"

make_instance() {
    local id="$1" machine="$2" mac="$3" directory="$STATE_DIR/instances/$1"
    mkdir -p "$directory"
    printf '%s' "$machine" >"$directory/machine-identifier.bin"
    printf '{"macAddress":"%s"}' "$mac" >"$directory/spec.json"
    # Distinct files, so distinct inodes: an APFS clone shares blocks, never an inode.
    printf 'nvram-%s' "$id" >"$directory/nvram.bin"
}

# Stub the daemon: the helpers only need the list of live instance ids.
LIVE_IDS=""
# Deliberately unquoted: LIVE_IDS is a space-separated list this test splits into one id per line,
# which is the shape the real helper produces from `runnerctl vm list`.
# shellcheck disable=SC2086
macos_live_instance_ids() { printf '%s\n' $LIVE_IDS; }

make_instance a AAAA 02:00:00:00:00:01
make_instance b BBBB 02:00:00:00:00:02
LIVE_IDS="a b"

if macos_assert_identity_unique >/dev/null 2>&1; then
    ok "two guests with distinct identity pass"
else
    no "two guests with distinct identity pass" "$(macos_assert_identity_unique 2>&1)"
fi

expect_eq "$(macos_identity_snapshot | wc -l | tr -d ' ')" "2" \
    "the snapshot has one line per live instance"

# Apple's actual rule: two concurrently running macOS VMs must not share a machine identifier.
make_instance b AAAA 02:00:00:00:00:02
if macos_assert_identity_unique >/dev/null 2>&1; then
    no "a shared machine identifier fails" "reported unique"
else
    ok "a shared machine identifier fails"
fi

make_instance b BBBB 02:00:00:00:00:01
if macos_assert_identity_unique >/dev/null 2>&1; then
    no "a shared MAC address fails" "reported unique"
else
    ok "a shared MAC address fails"
fi

# A missing identity file is not silently "unique": it reads as `-` and fails the count.
make_instance b BBBB 02:00:00:00:00:02
rm "$STATE_DIR/instances/b/machine-identifier.bin"
if macos_assert_identity_unique >/dev/null 2>&1; then
    no "an unreadable machine identifier fails" "reported unique"
else
    ok "an unreadable machine identifier fails"
fi

# One instance cannot collide with anything, and zero is vacuously fine.
make_instance b BBBB 02:00:00:00:00:02
LIVE_IDS="a"
if macos_assert_identity_unique >/dev/null 2>&1; then ok "a single guest passes"; else no "a single guest passes"; fi
LIVE_IDS=""
if macos_assert_identity_unique >/dev/null 2>&1; then
    ok "no live guests is vacuously unique"
else
    no "no live guests is vacuously unique"
fi

expect_eq "$(macos_machine_identifier a)" \
    "$(printf 'AAAA' | shasum -a 256 | awk '{print $1}')" \
    "the restart check reads the identifier's own hash"

# --------------------------------------------------------------------------
# 4. The instance-directory leak invariant
# --------------------------------------------------------------------------
if macos_assert_no_directory_leak >/dev/null 2>&1; then
    no "leftover instance directories fail the invariant" "reported clean"
else
    ok "leftover instance directories fail the invariant"
fi

rm -rf "$STATE_DIR/instances"
mkdir -p "$STATE_DIR/instances"
if macos_assert_no_directory_leak >/dev/null 2>&1; then
    ok "an empty instances directory passes"
else
    no "an empty instances directory passes"
fi

# The staging root is a dot-directory and is not an instance.
mkdir -p "$STATE_DIR/instances/.tmp"
if macos_assert_no_directory_leak >/dev/null 2>&1; then
    ok "the .tmp staging root is not counted as a leak"
else
    no "the .tmp staging root is not counted as a leak"
fi

STATE_DIR=""
if macos_assert_no_directory_leak >/dev/null 2>&1; then
    ok "with no state directory the check is skipped, not failed"
else
    no "with no state directory the check is skipped, not failed"
fi

# --------------------------------------------------------------------------
# 5. macOS slot locks
# --------------------------------------------------------------------------
SOCKET="$TWORK/runtime/runnerd.sock"
mkdir -p "$TWORK/runtime"
expect_eq "$(macos_slot_dir)" "$TWORK/runtime" "the slot directory is the socket's directory"

if command -v python3 >/dev/null 2>&1; then
    : >"$TWORK/runtime/macos-slot-0.lock"
    : >"$TWORK/runtime/macos-slot-1.lock"
    expect_eq "$(macos_slots_held)" "0" "unheld slot locks count as free"
    if macos_assert_slots_free >/dev/null 2>&1; then
        ok "free slots pass the invariant"
    else
        no "free slots pass the invariant"
    fi
else
    ok "slot-lock checks skipped (no python3)"
    ok "slot-lock invariant skipped (no python3)"
fi

SOCKET=""
RUNNERVM_RUNTIME_DIR=""
expect_eq "$(macos_slots_held)" "-1" "an unknown runtime directory reports -1, not 0"
if macos_assert_slots_free >/dev/null 2>&1; then
    ok "an undeterminable slot count is skipped, not failed"
else
    no "an undeterminable slot count is skipped, not failed"
fi

# --------------------------------------------------------------------------
# 6. The helpers this driver calls but does not define itself (start_peak_monitor,
# stop_peak_monitor, read_peak, wait_for_instance_state, restart_runnerd, runnerd_pid,
# kill_runnerd, wait_for_daemon_up) must actually come from sourcing the driver -- which sources
# scripts/lib/live-common.sh. They used to live only in scripts/live-github-e2e.sh, which this
# driver never sources: every one of these calls was "command not found" at runtime.
# --------------------------------------------------------------------------
for helper in start_peak_monitor stop_peak_monitor read_peak wait_for_instance_state \
    restart_runnerd runnerd_pid kill_runnerd wait_for_daemon_up; do
    if [ "$(type -t "$helper" 2>/dev/null)" = "function" ]; then
        ok "$helper is defined after sourcing the driver"
    else
        no "$helper is defined after sourcing the driver" "not found"
    fi
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
