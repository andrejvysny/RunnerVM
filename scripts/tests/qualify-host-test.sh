#!/usr/bin/env bash
# Unit checks for scripts/qualify-host.sh's argument parsing and pure bash helpers -- the parts
# that can be verified without a real RunnerVM install, a running daemon, or a service account.
# Two styles, matched to what each check needs:
#   - Argument-validation failures (`validate_args`'s `exit 2` paths) are invoked as a real
#     subprocess, mirroring scripts/tests/install-test.sh: `validate_args` runs and exits before
#     `resolve_defaults`/any host check, so the process never touches the host.
#   - Pure helpers (json_escape, byte_size_to_bytes, parse_reserve_disk, bytes_human, jf_str/
#     jf_raw, doctor_check_block/record_from_doctor, resolve_service_user, as_service_user,
#     resolve_defaults's --build-recipe default) are exercised by `source`-ing the script, which
#     scripts/qualify-host.sh guards behind a `[ "${BASH_SOURCE[0]}" = "${0}" ]` check specifically
#     so this file can call its functions directly without running the check suite.
#
# usage: scripts/tests/qualify-host-test.sh
#
# shellcheck disable=SC2034,SC2329
# SC2034 (appears unused): several globals below (DOCTOR_JSON, RUN_AS_USER, STATE_DIR,
# RUNTIME_DIR, SOCKET, RUNNERCTL_BIN, VMWORKER_BIN, CONFIG_PATH, ...) are read by
# scripts/qualify-host.sh's own functions after this file `source`s it -- invisible to a
# standalone shellcheck pass over just this file.
# SC2329 (never invoked): the `id` shadow functions below are called indirectly, as a plain `id`
# command, from inside resolve_service_user() (also only visible once qualify-host.sh is sourced).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/qualify-host.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rvm-qualify-test-XXXXXX")"
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

# ==========================================================================
# Part 1: argument validation (subprocess -- see header). Every case here must fail before
# resolve_defaults/any host check runs, so no PATH/state-dir/socket setup is needed.
# ==========================================================================

out="$("$SCRIPT" --help 2>&1)" || true
expect_contains "$out" "--skip-build" "usage documents --skip-build"
expect_contains "$out" "--build-recipe" "usage documents --build-recipe"
expect_contains "$out" "check_build_as_service" "usage explains --user also drives check_build_as_service"

if out="$("$SCRIPT" 2>&1)"; then
    no "missing --profile without --skip-vm exits non-zero" "$out"
else
    ok "missing --profile without --skip-vm exits non-zero"
    expect_contains "$out" "--profile" "missing-profile message mentions --profile"
fi

if out="$("$SCRIPT" --skip-vm --github-job 2>&1)"; then
    no "--github-job without --profile exits non-zero" "$out"
else
    ok "--github-job without --profile exits non-zero"
    expect_contains "$out" "--github-job requires --profile" "message names the actual requirement"
fi

if out="$("$SCRIPT" --skip-vm --require-filevault-off --allow-filevault 2>&1)"; then
    no "--require-filevault-off + --allow-filevault exits non-zero" "$out"
else
    ok "--require-filevault-off + --allow-filevault exits non-zero"
    expect_contains "$out" "mutually exclusive" "message says the two flags are mutually exclusive"
fi

if out="$("$SCRIPT" --skip-vm --launchd bogus 2>&1)"; then
    no "--launchd bogus exits non-zero" "$out"
else
    ok "--launchd bogus exits non-zero"
fi

if out="$("$SCRIPT" --nonsense-flag 2>&1)"; then
    no "an unknown flag exits non-zero" "$out"
else
    ok "an unknown flag exits non-zero"
fi

# ==========================================================================
# Part 2: pure helpers (sourced -- see header).
# ==========================================================================
# shellcheck source=/dev/null
source "$SCRIPT"

# --- json_escape ----------------------------------------------------------
expect_eq "$(json_escape 'a"b')" 'a\"b' "json_escape escapes a double quote"
expect_eq "$(json_escape 'a\b')" 'a\\b' "json_escape escapes a backslash"
expect_eq "$(json_escape "$(printf 'a\nb')")" 'a\nb' "json_escape escapes a newline"
expect_eq "$(json_escape "$(printf 'a\tb')")" 'a\tb' "json_escape escapes a tab"

# --- byte_size_to_bytes ----------------------------------------------------
expect_eq "$(byte_size_to_bytes 8GiB)" "$((8 * 1024 * 1024 * 1024))" "byte_size_to_bytes parses GiB"
expect_eq "$(byte_size_to_bytes 512MiB)" "$((512 * 1024 * 1024))" "byte_size_to_bytes parses MiB"
expect_eq "$(byte_size_to_bytes 1KiB)" "1024" "byte_size_to_bytes parses KiB"
expect_eq "$(byte_size_to_bytes 2TiB)" "$((2 * 1024 * 1024 * 1024 * 1024))" "byte_size_to_bytes parses TiB"
expect_eq "$(byte_size_to_bytes 1GB)" "1000000000" "byte_size_to_bytes parses decimal GB"
expect_eq "$(byte_size_to_bytes 4096)" "4096" "byte_size_to_bytes parses a bare byte count"
expect_eq "$(byte_size_to_bytes 4096B)" "4096" "byte_size_to_bytes parses an explicit B suffix"
if byte_size_to_bytes 8XiB >/dev/null 2>&1; then
    no "byte_size_to_bytes rejects an unknown unit"
else
    ok "byte_size_to_bytes rejects an unknown unit"
fi

# --- parse_reserve_disk -----------------------------------------------------
yaml_with_reserve="$(cat <<'YAML'
version: 1
host:
  reserve:
    cpu: 2
    disk: 75GiB
  overcommit:
    cpu: 1.0
YAML
)"
expect_eq "$(parse_reserve_disk "$yaml_with_reserve")" "75GiB" "parse_reserve_disk reads host.reserve.disk"
expect_eq "$(parse_reserve_disk 'version: 1')" "" "parse_reserve_disk is empty with no host section"

# --- bytes_human ------------------------------------------------------------
expect_eq "$(bytes_human $((8 * 1024 * 1024 * 1024)))" "8.0GiB" "bytes_human renders whole GiB"
expect_eq "$(bytes_human 0)" "0.0B" "bytes_human renders zero"

# --- jf_str / jf_raw ---------------------------------------------------------
sample_json='{
  "id" : "example",
  "state" : "idle",
  "count" : 3
}'
expect_eq "$(jf_str "$sample_json" id)" "example" "jf_str extracts a quoted string field"
expect_eq "$(jf_str "$sample_json" state)" "idle" "jf_str extracts a second quoted field"
expect_eq "$(jf_raw "$sample_json" count)" "3" "jf_raw extracts an unquoted numeric field"

# --- doctor_check_block / record_from_doctor --------------------------------
# Shape mirrors `runnerctl doctor --output json`'s actual encoder settings (JSONEncoder,
# prettyPrinted, sortedKeys): each check is exactly {"detail","id","status","title"}, in that
# alphabetical order -- verified against a real `.build/debug/runnerctl doctor --output json` run.
DOCTOR_FIXTURE='{
  "checks" : [
    {
      "detail" : "hw.machine=arm64",
      "id" : "apple_silicon",
      "status" : "ok",
      "title" : "Apple Silicon"
    },
    {
      "detail" : "/state is mode 0755; must be 0750 or stricter",
      "id" : "service_user_ownership",
      "status" : "fail",
      "title" : "Service account ownership"
    },
    {
      "detail" : "no --config given; skipped",
      "id" : "free_memory",
      "status" : "warn",
      "title" : "Free memory"
    }
  ]
}'

block="$(doctor_check_block "$DOCTOR_FIXTURE" service_user_ownership)"
expect_eq "$(jf_str "$block" status)" "fail" "doctor_check_block isolates the right check's status"
expect_contains "$(jf_str "$block" detail)" "0750" "doctor_check_block isolates the right check's detail"

block="$(doctor_check_block "$DOCTOR_FIXTURE" apple_silicon)"
expect_eq "$(jf_str "$block" status)" "ok" "doctor_check_block does not bleed into an adjacent check"

DOCTOR_JSON="$DOCTOR_FIXTURE"
CHECK_JSON=()
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

# `out=$(record_from_doctor ...)` would fork a subshell for the command substitution, so the
# PASS_COUNT/WARN_COUNT/FAIL_COUNT/CHECK_JSON mutations `record()` makes would be lost the moment
# it returns. Redirecting a single command's stdout to a file does not fork -- this preserves the
# side effects the counter/array assertions below depend on.
capture() {
    "$@" >"$WORK/capture.out"
    CAPTURED="$(cat "$WORK/capture.out")"
}

capture record_from_doctor service_user_ownership "State ownership (service_user_ownership)"
expect_contains "$CAPTURED" "FAIL" "record_from_doctor prints FAIL for a fail-status doctor check"
expect_eq "$FAIL_COUNT" "1" "record_from_doctor increments FAIL_COUNT"
last="${CHECK_JSON[${#CHECK_JSON[@]} - 1]}"
expect_contains "$last" '"id":"service_user_ownership"' "record_from_doctor's JSON row carries the doctor check id"
expect_contains "$last" '"status":"FAIL"' "record_from_doctor's JSON row carries the mapped FAIL status"

capture record_from_doctor free_memory "Free memory (free_memory)"
expect_contains "$CAPTURED" "WARN" "record_from_doctor prints WARN for a warn-status doctor check"
expect_eq "$WARN_COUNT" "1" "record_from_doctor increments WARN_COUNT"

capture record_from_doctor apple_silicon "Apple Silicon"
expect_contains "$CAPTURED" "PASS" "record_from_doctor maps doctor's ok status to PASS"
expect_eq "$PASS_COUNT" "1" "record_from_doctor increments PASS_COUNT"

capture record_from_doctor no_such_check "Nonexistent check"
expect_contains "$CAPTURED" "WARN" "record_from_doctor WARNs when the doctor report has no such check id"
expect_eq "$WARN_COUNT" "2" "the not-found path still increments WARN_COUNT (not a silent no-op)"

# --- resolve_service_user ----------------------------------------------------
RUN_AS_USER="alice"
resolve_service_user
expect_eq "$SERVICE_USER" "alice" "resolve_service_user honors an explicit --user"
expect_eq "$SERVICE_USER_NOTE" "" "an explicit --user carries no caveat note"

RUN_AS_USER=""
id() { case "$1" in -u) echo 0 ;; -un) echo root ;; esac; }
resolve_service_user
unset -f id
expect_eq "$SERVICE_USER" "_runnervm" "resolve_service_user defaults to _runnervm when running as root"
expect_eq "$SERVICE_USER_NOTE" "" "the root/_runnervm default carries no caveat note"

RUN_AS_USER=""
id() { case "$1" in -u) echo 501 ;; -un) echo devuser ;; esac; }
resolve_service_user
unset -f id
expect_eq "$SERVICE_USER" "devuser" "resolve_service_user falls back to the caller when not root and no --user"
expect_contains "$SERVICE_USER_NOTE" "_runnervm" "the caller-fallback note points at the real service account"

# --- as_service_user ---------------------------------------------------------
SERVICE_USER="$(id -un)"
out="$(as_service_user echo hello-service-user)"
expect_eq "$out" "hello-service-user" "as_service_user runs directly (no sudo) when already the service user"

# --- resolve_defaults's --build-recipe default -------------------------------
STATE_DIR="$WORK/installed-state"
mkdir -p "$STATE_DIR/share/recipes/ubuntu-24-minimal"
: >"$STATE_DIR/share/recipes/ubuntu-24-minimal/Runnerfile"
RUNTIME_DIR="$WORK/installed-runtime"
BUILD_RECIPE=""
SOCKET=""
RUNNERCTL_BIN=""
VMWORKER_BIN=""
CONFIG_PATH=""
resolve_defaults
expect_eq "$BUILD_RECIPE" "$STATE_DIR/share/recipes/ubuntu-24-minimal" \
    "resolve_defaults prefers the installed recipe under --state-dir when present"

STATE_DIR="$WORK/bare-state"
mkdir -p "$STATE_DIR"
RUNTIME_DIR="$WORK/bare-runtime"
BUILD_RECIPE=""
SOCKET=""
RUNNERCTL_BIN=""
VMWORKER_BIN=""
CONFIG_PATH=""
resolve_defaults
expect_eq "$BUILD_RECIPE" "$REPO_ROOT/images/recipes/ubuntu-24-minimal" \
    "resolve_defaults falls back to the repo's shipped recipe when none is installed"

# An explicit --build-recipe always wins over either default.
STATE_DIR="$WORK/installed-state"
RUNTIME_DIR="$WORK/installed-runtime"
BUILD_RECIPE="/custom/recipe/dir"
SOCKET=""
RUNNERCTL_BIN=""
VMWORKER_BIN=""
CONFIG_PATH=""
resolve_defaults
expect_eq "$BUILD_RECIPE" "/custom/recipe/dir" "resolve_defaults never overrides an explicit --build-recipe"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
