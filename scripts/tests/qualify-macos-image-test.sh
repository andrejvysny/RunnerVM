#!/usr/bin/env bash
# Unit checks for scripts/qualify-macos-image.sh that need no daemon, no VM and no macOS guest:
# argument handling, the report shape, and the pass/fail bookkeeping every check goes through.
#
# Same two styles as scripts/tests/provision-macos-tart-test.sh: the paths that exit are exercised
# as a real subprocess, and the pure helpers are exercised by `source`-ing the script, which guards
# its own `main` behind `[ "${BASH_SOURCE[0]}" = "${0}" ]` exactly so this file can call them.
#
# usage: scripts/tests/qualify-macos-image-test.sh
#
# shellcheck disable=SC2034
# SC2034 (appears unused): PROFILE, IMAGE_DIGEST_BEFORE, INSTANCE_ID, JSON_REPORT and friends are
# read by scripts/qualify-macos-image.sh's own functions after this file sources it -- invisible to
# a standalone shellcheck pass over just this file.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/qualify-macos-image.sh"
TWORK="$(mktemp -d "${TMPDIR:-/tmp}/rvm-qualify-macos-test-XXXXXX")"
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
# 1. Argument handling, as a subprocess (these paths exit before touching a daemon)
# --------------------------------------------------------------------------
if help_out="$("$SCRIPT" --help 2>&1)"; then
    expect_contains "$help_out" "usage: qualify-macos-image.sh" "--help prints usage"
    expect_contains "$help_out" "--allow-ssh" "--help documents --allow-ssh"
    expect_contains "$help_out" "--boot-timeout" "--help documents --boot-timeout"
else
    no "--help exits 0" "$help_out"
fi

if out="$("$SCRIPT" 2>&1)"; then
    no "a missing --profile fails" "exited 0"
else
    expect_contains "$out" "--profile is required" "a missing --profile fails"
fi

if out="$("$SCRIPT" --profile p --nonsense 2>&1)"; then
    no "an unknown option fails" "exited 0"
else
    rc=$?
    expect_eq "$rc" "2" "an unknown option exits 2"
    expect_contains "$out" "unknown option: --nonsense" "an unknown option names itself"
fi

# --dry-run must not need a daemon: it is what an operator runs first.
if plan="$("$SCRIPT" --profile rvm-macos-26 --dry-run 2>&1)"; then
    expect_contains "$plan" "rvm-macos-26" "--dry-run names the profile"
    expect_contains "$plan" "admin/admin rejected" "--dry-run states the SSH lockdown checks"
    expect_contains "$plan" "enforced" "the SSH checks are enforced by default"
else
    no "--dry-run exits 0 with no daemon" "$plan"
fi

if plan="$("$SCRIPT" --profile p --allow-ssh --dry-run 2>&1)"; then
    expect_contains "$plan" "skipped (--allow-ssh)" "--allow-ssh is reflected in the plan"
else
    no "--allow-ssh --dry-run exits 0" "$plan"
fi

# --------------------------------------------------------------------------
# Source the script so the pure helpers can be called directly. Guarded in the script itself, so
# nothing is created, booted or deleted.
# --------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$SCRIPT"

# --------------------------------------------------------------------------
# 2. Pass/fail bookkeeping
# --------------------------------------------------------------------------
report_init
CHECKS_RUN=0
CHECKS_FAILED=0

assert first_check 0 "all good" >/dev/null 2>&1
expect_eq "$CHECKS_RUN" "1" "a passing check is counted"
expect_eq "$CHECKS_FAILED" "0" "a passing check does not fail the run"

assert second_check 1 "something is wrong" >/dev/null 2>&1
expect_eq "$CHECKS_RUN" "2" "a failing check is counted"
expect_eq "$CHECKS_FAILED" "1" "a failing check fails the run"

# A guest command that never ran yields an empty string, not a number. That must fail rather than
# blowing up the arithmetic or silently passing.
assert third_check "" "the guest returned nothing" >/dev/null 2>&1
expect_eq "$CHECKS_FAILED" "2" "a non-numeric status fails rather than erroring"

# A skip is neither: it is recorded, but it neither counts towards nor against qualification.
skip fourth_check "not applicable" >/dev/null 2>&1
expect_eq "$CHECKS_RUN" "3" "a skip is not counted as a check"
expect_eq "$CHECKS_FAILED" "2" "a skip does not fail the run"

# --------------------------------------------------------------------------
# 3. The JSON report
# --------------------------------------------------------------------------
PROFILE="rvm-macos-26"
IMAGE_DIGEST_BEFORE="sha256:abc"
INSTANCE_ID="11111111-2222-3333-4444-555555555555"
JSON_REPORT="$TWORK/report.json"
write_report >/dev/null

expect_eq "$(jq -r .profile "$JSON_REPORT")" "rvm-macos-26" "the report names the profile"
expect_eq "$(jq -r .imageDigest "$JSON_REPORT")" "sha256:abc" "the report names the image digest"
expect_eq "$(jq -r .instanceId "$JSON_REPORT")" "$INSTANCE_ID" "the report names the instance"
expect_eq "$(jq -r .checksRun "$JSON_REPORT")" "3" "the report counts the checks that ran"
expect_eq "$(jq -r .checksFailed "$JSON_REPORT")" "2" "the report counts the failures"
expect_eq "$(jq -r .qualified "$JSON_REPORT")" "false" "a run with failures is not qualified"
expect_eq "$(jq -r '[.checks[] | select(.status=="skip")] | length' "$JSON_REPORT")" "1" \
    "a skipped check is recorded as a skip"
expect_eq "$(jq -r '.checks[0].name' "$JSON_REPORT")" "first_check" "checks keep their order"

# Nothing to qualify is not the same as qualified: a report with no checks must not read as a pass.
report_init
CHECKS_RUN=0
CHECKS_FAILED=0
JSON_REPORT="$TWORK/empty.json"
write_report >/dev/null
expect_eq "$(jq -r .qualified "$TWORK/empty.json")" "false" \
    "a report with no checks is not qualified"

report_init
CHECKS_RUN=0
CHECKS_FAILED=0
assert only_check 0 >/dev/null 2>&1
JSON_REPORT="$TWORK/pass.json"
write_report >/dev/null
expect_eq "$(jq -r .qualified "$TWORK/pass.json")" "true" \
    "a report whose checks all passed is qualified"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
