#!/usr/bin/env bash
# Unit checks for scripts/live-gitlab-e2e.sh that need no daemon, no VM, no GitLab and no
# gitlab-runner: argument/env handling, the --dry-run plan, config rendering and token redaction.
#
# usage: scripts/tests/live-gitlab-e2e-test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/live-gitlab-e2e.sh"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }

expect_contains() {
    case "$1" in
    *"$2"*) ok "$3" ;;
    *) no "$3" "expected to find: $2" ;;
    esac
}

expect_lacks() {
    case "$1" in
    *"$2"*) no "$3" "did not expect: $2" ;;
    *) ok "$3" ;;
    esac
}

expect_eq() {
    if [ "$1" = "$2" ]; then ok "$3"; else no "$3" "expected '$2', got '$1'"; fi
}

# Subprocess with a clean slate of the RUNNERVM_E2E_* variables.
run() {
    env -u RUNNERVM_E2E_GITLAB_PROJECT -u RUNNERVM_E2E_GITLAB_PROFILE -u RUNNERVM_E2E_GITLAB_TOKEN \
        -u RUNNERVM_E2E_GITLAB_EXECUTOR -u RUNNERVM_E2E_SOCKET -u RUNNERVM_E2E_DRY_RUN \
        -u RUNNERVM_E2E_GITLAB_URL "$@"
}

# --------------------------------------------------------------------------
# 1. Argument and env handling
# --------------------------------------------------------------------------
if help_out="$("$SCRIPT" --help 2>&1)"; then
    expect_contains "$help_out" "usage: live-gitlab-e2e.sh" "--help prints usage"
    expect_contains "$help_out" "RUNNERVM_E2E_GITLAB_PROJECT" "--help documents the project variable"
    expect_contains "$help_out" "Exit codes" "--help documents exit codes"
else
    no "--help exits 0" "$help_out"
fi

rc_val=0
out="$(run "$SCRIPT" --bogus 2>&1)" || rc_val=$?
expect_eq "$rc_val" "2" "unknown option exits 2"
expect_contains "$out" "unknown option" "unknown option is named"

rc_val=0
out="$(run "$SCRIPT" 2>&1)" || rc_val=$?
expect_eq "$rc_val" "2" "missing project exits 2"
expect_contains "$out" "RUNNERVM_E2E_GITLAB_PROJECT is required" "missing project is named"

rc_val=0
out="$(run env RUNNERVM_E2E_GITLAB_PROJECT=g/p "$SCRIPT" 2>&1)" || rc_val=$?
expect_contains "$out" "RUNNERVM_E2E_GITLAB_PROFILE is required" "missing profile is named"

rc_val=0
out="$(run env RUNNERVM_E2E_GITLAB_PROJECT=g/p RUNNERVM_E2E_GITLAB_PROFILE=x "$SCRIPT" 2>&1)" || rc_val=$?
expect_contains "$out" "RUNNERVM_E2E_GITLAB_TOKEN is required" "live run without a token fails"

rc_val=0
out="$(run env RUNNERVM_E2E_GITLAB_PROJECT=g/p RUNNERVM_E2E_GITLAB_PROFILE=x \
    RUNNERVM_E2E_GITLAB_EXECUTOR=shell RUNNERVM_E2E_DRY_RUN=1 "$SCRIPT" 2>&1)" || rc_val=$?
expect_eq "$rc_val" "2" "unknown executor exits 2"
expect_contains "$out" "must be instance or docker-autoscaler" "unknown executor is explained"

# --------------------------------------------------------------------------
# 2. Dry run: no token, no tools, no network
# --------------------------------------------------------------------------
rc_val=0
out="$(run env RUNNERVM_E2E_GITLAB_PROJECT=grp/proj RUNNERVM_E2E_GITLAB_PROFILE=ubuntu-24-gitlab \
    RUNNERVM_E2E_DRY_RUN=1 "$SCRIPT" 2>&1)" || rc_val=$?
expect_eq "$rc_val" "0" "--dry-run via env exits 0"
expect_contains "$out" "api/v4/user/runners" "dry run plans runner creation"
expect_contains "$out" 'executor = "instance"' "dry run defaults to the instance executor"
expect_contains "$out" 'profile = "ubuntu-24-gitlab"' "dry run renders the profile"
expect_contains "$out" "max_use_count = 1" "one job per VM"
expect_contains "$out" "idle_count = 0" "scale to zero"
expect_contains "$out" "<runner-token>" "dry run never holds a real token"
expect_lacks "$out" "socket =" "no socket line unless one was given"

out="$(run env RUNNERVM_E2E_GITLAB_PROJECT=grp/proj RUNNERVM_E2E_GITLAB_PROFILE=p \
    RUNNERVM_E2E_GITLAB_EXECUTOR=docker-autoscaler RUNNERVM_E2E_SOCKET=/tmp/s.sock \
    "$SCRIPT" --dry-run 2>&1)"
expect_contains "$out" 'executor = "docker-autoscaler"' "docker-autoscaler executor"
expect_contains "$out" 'image = "alpine:3.20"' "docker image rendered"
expect_contains "$out" 'socket = "/tmp/s.sock"' "socket forwarded to the plugin"

# --------------------------------------------------------------------------
# 3. Sourced helpers
# --------------------------------------------------------------------------
# shellcheck source=SCRIPTDIR/../live-gitlab-e2e.sh
# shellcheck disable=SC1091
source "$SCRIPT"
PROFILE=mac-gitlab
EXECUTOR=instance
SOCKET=""
cfg="$(render_config "glrt-SECRET" macos)"
expect_contains "$cfg" 'os = "darwin"' "macOS guest renders os = darwin"
expect_contains "$cfg" 'shell = "bash"' "instance executor uses bash"
expect_contains "$cfg" "delete_instances_on_shutdown = true" "instances deleted on shutdown"

TOKEN="pat-12345"
scrubbed="$(printf 'Authorization pat-12345 and glrt-abc_DEF.9 here\n' | redact)"
expect_lacks "$scrubbed" "pat-12345" "redact removes the PAT"
expect_lacks "$scrubbed" "abc_DEF" "redact removes runner tokens"
expect_contains "$scrubbed" "glrt-<redacted>" "redact leaves a marker"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
