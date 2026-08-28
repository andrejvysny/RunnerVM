#!/usr/bin/env bash
# macOS concurrency, recovery and soak driver (docs/macos-guests.md, H3-H5).
#
# Complements scripts/live-github-e2e.sh rather than replacing it: that driver proves the *GitHub*
# lifecycle against a Linux profile and is guest-agnostic. This one proves the three things that
# are only true of a macOS host -- the two-guest ceiling, the per-instance Apple identity, and the
# fact that both survive crashes and a long run.
#
# The principle behind every scenario here:
#
#   A soak that reports "100 of 100 workflows succeeded" and leaves two orphaned guests behind is
#   a failed soak. Every scenario ends in the same invariant check (scripts/lib/live-macos.sh):
#   GitHub lists no runner, no non-terminal session, no capacity-consuming instance, no instance
#   directory, no vmworker, both macOS slots free, and the image digest unchanged.
#
# Needs a real host: a macOS profile whose image is qualified (scripts/qualify-macos-image.sh), a
# running runnerd, `gh` authenticated against $RUNNERVM_E2E_REPO, and enough free disk for two
# concurrent macOS guests. See docs/live-integration.md.
#
# usage: scripts/live-macos-e2e.sh --profile rvm-macos-26 [--scenario concurrency|recovery|soak|all]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

PROFILE=""
SCENARIOS="all"
SOAK_JOBS=100
SOAK_CONCURRENCY=1
BOOT_TIMEOUT=900
RUN_TIMEOUT=2700
LEFTOVER_TIMEOUT=600
# shellcheck disable=SC2034 # read by wait_for_run_conclusion (live-common.sh)
RUN_POLL_INTERVAL=10
WORKFLOW_FILE="e2e.yml"
JSON_REPORT=""
SOCKET="${RUNNERVM_SOCKET:-}"
STATE_DIR="${RUNNERVM_STATE_DIR:-}"
RESTART_CMD=""
KILL_CMD=""
DRY_RUN=0

OWNER=""
REPO="${RUNNERVM_E2E_REPO:-}"
RUNNERCTL_BIN=""
IMAGE_REF=""
IMAGE_DIGEST=""
REPORT_TMP=""
FAILURES=0

KNOWN_SCENARIOS="concurrency recovery soak"
# The states worth interrupting a macOS guest in. Deliberately the same ladder the Linux recovery
# matrix uses (`InstanceState`), because the recovery logic is shared -- what is being proven here
# is that a macOS guest converges through it too, not that macOS needs its own logic.
RECOVERY_STATES="startingVM waitingForAgent idle configuringRunner runnerOnline busy"

# shellcheck source=SCRIPTDIR/lib/live-common.sh
# shellcheck disable=SC1091 # dynamic path; run shellcheck -x to actually follow it
source "$REPO_ROOT/scripts/lib/live-common.sh"
# shellcheck source=SCRIPTDIR/lib/live-macos.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/lib/live-macos.sh"

usage() {
    cat <<'USAGE'
usage: live-macos-e2e.sh --profile <name> [options]

Scenarios (--scenario, comma-separated, or "all"):
  concurrency  two guests run at once, a third job waits for a slot, each guest has its own
               machine identifier / MAC / auxiliary storage, and the third starts only when one
               of the first two is gone.
  recovery     runnerd and vmworker are interrupted (graceful restart and SIGKILL) at each state
               of the ladder; every scenario must converge to the same terminal invariants.
  soak         --soak-jobs short jobs at --soak-concurrency, then the invariants.

Options:
  --profile <name>          macOS profile under test (required).
  --repo <owner/name>       Test repository (default: $RUNNERVM_E2E_REPO).
  --scenario <list>         Default: all.
  --soak-jobs <n>           Default: 100.
  --soak-concurrency <n>    Default: 1. Use 2 for the second soak pass.
  --socket <path>           runnerd.sock (default: $RUNNERVM_SOCKET).
  --state-dir <path>        RunnerVM state directory; needed for the identity and directory-leak
                            checks (default: $RUNNERVM_STATE_DIR).
  --restart-cmd <cmd>       How to restart runnerd (default: launchctl kickstart of the user job).
  --kill-cmd <cmd>          How to SIGKILL runnerd (default: signal the pid runnerctl reports).
  --boot-timeout <s>        Seconds a guest may take to reach idle (default: 900).
  --run-timeout <s>         Seconds a workflow run may take (default: 2700).
  --json <path>             Write the JSON report here.
  --dry-run                 Print the plan and exit.
  -h, --help                This text.
USAGE
}

# SOCKET, STATE_DIR, RESTART_CMD and KILL_CMD are read by scripts/lib/live-common.sh and
# scripts/lib/live-macos.sh, which a per-file lint pass over this file alone cannot see.
# shellcheck disable=SC2034
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
        --profile) PROFILE="$2"; shift 2 ;;
        --repo) REPO="$2"; shift 2 ;;
        --scenario) SCENARIOS="$2"; shift 2 ;;
        --soak-jobs) SOAK_JOBS="$2"; shift 2 ;;
        --soak-concurrency) SOAK_CONCURRENCY="$2"; shift 2 ;;
        --socket) SOCKET="$2"; shift 2 ;;
        --state-dir) STATE_DIR="$2"; shift 2 ;;
        --restart-cmd) RESTART_CMD="$2"; shift 2 ;;
        --kill-cmd) KILL_CMD="$2"; shift 2 ;;
        --boot-timeout) BOOT_TIMEOUT="$2"; shift 2 ;;
        --run-timeout) RUN_TIMEOUT="$2"; shift 2 ;;
        --json) JSON_REPORT="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
        esac
    done
    [ -n "$PROFILE" ] || { usage >&2; die "--profile is required"; }
    [ -n "$REPO" ] || die "--repo or RUNNERVM_E2E_REPO is required"
    OWNER="${REPO%%/*}"
    local scenario
    for scenario in $(scenario_list); do
        case " $KNOWN_SCENARIOS " in
        *" $scenario "*) ;;
        *) die "unknown scenario: $scenario (known: $KNOWN_SCENARIOS)" ;;
        esac
    done
}

scenario_list() {
    if [ "$SCENARIOS" = "all" ]; then printf '%s' "$KNOWN_SCENARIOS"; else printf '%s' "${SCENARIOS//,/ }"; fi
}

check_preconditions() {
    local tool guest_os
    for tool in jq gh shasum; do
        command -v "$tool" >/dev/null 2>&1 || die "required tool not on PATH: $tool"
    done
    RUNNERCTL_BIN="$(find_runnerctl)"
    [ -n "$RUNNERCTL_BIN" ] || die "runnerctl not found; build it or set RUNNERCTL"
    check_daemon_reachable
    check_gh_cli_auth
    check_github_auth
    guest_os=$(rc profile show "$PROFILE" | jq -r '.guestOS') || die "no such profile: $PROFILE"
    [ "$guest_os" = "macos" ] ||
        die "profile '$PROFILE' is os: $guest_os; use scripts/live-github-e2e.sh for Linux"
    IMAGE_REF=$(rc profile show "$PROFILE" | jq -r '.image')
    IMAGE_DIGEST=$(rc image inspect "$IMAGE_REF" | jq -r '.digest') ||
        die "cannot resolve the profile's image: $IMAGE_REF"
    [ -n "$STATE_DIR" ] ||
        warn "no --state-dir: the identity and directory-leak checks will be skipped"
    log "profile $PROFILE -> $IMAGE_REF ($IMAGE_DIGEST), repo $REPO"
}

# --------------------------------------------------------------------------
# Scenario helpers
# --------------------------------------------------------------------------
dispatch_matrix() {
    local count="$1"
    log "dispatching a matrix of $count job(s) on $PROFILE"
    gh workflow run "$WORKFLOW_FILE" -R "$REPO" \
        -f "job=matrix" -f "count=$count" -f "profile=$PROFILE" -f "minutes=5"
}

live_instance_count() {
    rc vm list 2>/dev/null | jq --arg p "$PROFILE" \
        '[.instances[] | select(.profile==$p and .state!="deleted")] | length' 2>/dev/null || echo 0
}

# 0 once at least $1 instances of the profile are live. Used to catch the ceiling *while* it is
# being exercised, not after the fact.
wait_for_instance_count() {
    local wanted="$1" timeout="$2" deadline count
    deadline=$(($(date +%s) + timeout))
    while true; do
        count=$(live_instance_count)
        [ "$count" -ge "$wanted" ] 2>/dev/null && return 0
        [ "$(date +%s)" -lt "$deadline" ] || return 1
        sleep 3
    done
}

record_scenario() {
    local name="$1" status="$2" detail="${3:-}"
    jq -n --arg name "$name" --arg status "$status" --arg detail "$detail" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{name:$name,status:$status,detail:$detail,at:$at}' >>"$REPORT_TMP"
    if [ "$status" = "pass" ]; then
        log "PASS $name${detail:+ -- $detail}"
    else
        warn "FAIL $name${detail:+ -- $detail}"
        FAILURES=$((FAILURES + 1))
    fi
}

# Every scenario ends here. `assert_no_leftovers` is the shared, guest-agnostic convergence wait;
# `macos_assert_no_leaks` is the macOS-specific invariant set that turns it into a real check.
finish_scenario() {
    local name="$1" ok=0
    assert_no_leftovers "$PROFILE" "$LEFTOVER_TIMEOUT" "" || ok=1
    macos_assert_no_leaks "$IMAGE_DIGEST" || ok=1
    if [ "$ok" -eq 0 ]; then
        record_scenario "$name" pass "invariants hold"
    else
        record_scenario "$name" fail "invariants violated after the scenario"
    fi
}

# --------------------------------------------------------------------------
# H3 - concurrency
# --------------------------------------------------------------------------
# Three jobs, two slots. The host must run exactly two macOS guests, hold the third job until a
# slot frees, and give each running guest its own Apple identity.
scenario_concurrency() {
    local peak run_id conclusion identity_ok=0
    log "=== concurrency: 3 jobs, 2 macOS slots ==="
    start_peak_monitor "$PROFILE"
    local before; before=$(date +%s)
    dispatch_matrix 3
    run_id=$(find_dispatched_run "$before") || {
        stop_peak_monitor; read_peak >/dev/null
        record_scenario concurrency fail "the workflow run never appeared"
        return
    }

    if wait_for_instance_count 2 "$BOOT_TIMEOUT"; then
        # Sampled while both guests are up: this is the only window in which the identity of two
        # *concurrently running* macOS VMs can be compared, which is the rule Apple actually states.
        macos_assert_identity_unique || identity_ok=1
    else
        identity_ok=1
        warn "never observed 2 concurrent macOS guests within ${BOOT_TIMEOUT}s"
    fi

    conclusion=$(wait_for_run_conclusion "$run_id" "$RUN_TIMEOUT") || conclusion="timeout"
    stop_peak_monitor
    peak=$(read_peak)

    if [ "$conclusion" != "success" ]; then
        record_scenario concurrency_jobs fail "run $run_id concluded $conclusion"
    else
        record_scenario concurrency_jobs pass "run $run_id, all 3 jobs succeeded"
    fi
    # The ceiling is the point: a peak of 3 means the third job was never queued, and a peak of 1
    # means the second slot was never used (a pass by accident, not by design).
    if [ "$peak" = "2" ]; then
        record_scenario concurrency_ceiling pass "peak VM count 2"
    else
        record_scenario concurrency_ceiling fail "peak VM count $peak, expected 2"
    fi
    if [ "$identity_ok" -eq 0 ]; then
        record_scenario concurrency_identity pass "distinct machine id / MAC / auxiliary storage"
    else
        record_scenario concurrency_identity fail "the two guests did not have distinct identity"
    fi
    finish_scenario concurrency_invariants
}

# --------------------------------------------------------------------------
# H4 - recovery
# --------------------------------------------------------------------------
# The Linux recovery harness already proves the state machine; what is unproven is that a macOS
# guest converges through the same paths. Each pass interrupts one state, then requires the same
# terminal invariants as every other scenario.
scenario_recovery() {
    local state
    log "=== recovery: interrupt at each state, graceful and SIGKILL ==="
    for state in $RECOVERY_STATES; do
        recovery_pass "$state" restart
        recovery_pass "$state" sigkill
    done
}

recovery_pass() {
    local state="$1" mode="$2" before instance
    local name="recovery_${state}_${mode}"
    log "--- $name ---"
    before=$(date +%s)
    dispatch_matrix 1
    find_dispatched_run "$before" >/dev/null || {
        record_scenario "$name" fail "the workflow run never appeared"
        return
    }
    instance=$(wait_for_instance_state "$PROFILE" "$state" "$BOOT_TIMEOUT") || instance=""
    if [ -z "$instance" ]; then
        # Some states are simply too short to catch on a warm host; that is not a failure of the
        # recovery logic, and reporting it as one would make the matrix meaningless.
        record_scenario "$name" skip "never observed state $state within ${BOOT_TIMEOUT}s"
        assert_no_leftovers "$PROFILE" "$LEFTOVER_TIMEOUT" "" || true
        return
    fi
    log "interrupting runnerd while $instance is $state ($mode)"
    if [ "$mode" = "sigkill" ]; then
        kill_runnerd || { record_scenario "$name" fail "could not SIGKILL runnerd"; return; }
    fi
    restart_runnerd || { record_scenario "$name" fail "could not restart runnerd"; return; }
    wait_for_daemon_up 120 || { record_scenario "$name" fail "runnerd did not come back"; return; }
    finish_scenario "$name"
}

# --------------------------------------------------------------------------
# H5 - soak
# --------------------------------------------------------------------------
scenario_soak() {
    local completed=0 failed=0 index before run_id conclusion started
    log "=== soak: $SOAK_JOBS job(s) at concurrency $SOAK_CONCURRENCY ==="
    started=$(date +%s)
    index=0
    while [ "$index" -lt "$SOAK_JOBS" ]; do
        before=$(date +%s)
        dispatch_matrix "$SOAK_CONCURRENCY"
        if ! run_id=$(find_dispatched_run "$before"); then
            failed=$((failed + 1))
            index=$((index + SOAK_CONCURRENCY))
            continue
        fi
        conclusion=$(wait_for_run_conclusion "$run_id" "$RUN_TIMEOUT") || conclusion="timeout"
        if [ "$conclusion" = "success" ]; then
            completed=$((completed + SOAK_CONCURRENCY))
        else
            failed=$((failed + SOAK_CONCURRENCY))
            warn "soak run $run_id concluded $conclusion"
        fi
        index=$((index + SOAK_CONCURRENCY))
        log "soak progress: $completed succeeded, $failed failed, $((SOAK_JOBS - index)) to go"
    done
    if [ "$failed" -eq 0 ]; then
        record_scenario soak_jobs pass "$completed job(s) in $(($(date +%s) - started))s"
    else
        record_scenario soak_jobs fail "$failed of $((completed + failed)) job(s) did not succeed"
    fi
    finish_scenario soak_invariants
}

# --------------------------------------------------------------------------
print_plan() {
    cat <<PLAN
live-macos-e2e.sh plan
  profile      $PROFILE
  repo         $REPO
  scenarios    $(scenario_list)
  soak         $SOAK_JOBS job(s) at concurrency $SOAK_CONCURRENCY
  state dir    ${STATE_DIR:-<unset: identity and directory checks skipped>}

  concurrency: gh workflow run $WORKFLOW_FILE -f job=matrix -f count=3 -f profile=$PROFILE
               assert peak VM count == 2, third job queued, distinct machine id / MAC / nvram
  recovery:    for each of [$RECOVERY_STATES] x [restart, sigkill]:
               dispatch one job, wait for the state, interrupt runnerd, assert convergence
  soak:        $SOAK_JOBS job(s), then the invariants

  invariants after every scenario:
    GitHub runners for $PROFILE       == 0
    non-terminal sessions             == 0
    capacity-consuming instances      == 0
    instance directories              == 0
    vmworker processes                == 0
    macOS guest slots held            == 0
    image digest                      == $IMAGE_DIGEST
PLAN
}

write_macos_report() {
    local out
    [ -n "$REPORT_TMP" ] || return 0
    out="$JSON_REPORT"
    if [ -z "$out" ]; then
        out="${STATE_DIR:-$REPO_ROOT/.build}/logs/macos-e2e-$(date -u +%Y%m%dT%H%M%SZ).json"
    fi
    mkdir -p "$(dirname "$out")"
    jq -n --arg profile "$PROFILE" --arg repo "$REPO" --arg image "$IMAGE_DIGEST" \
        --argjson failures "$FAILURES" --slurpfile scenarios "$REPORT_TMP" \
        '{profile:$profile,repo:$repo,imageDigest:$image,failures:$failures,
          passed:($failures == 0),scenarios:$scenarios}' >"$out"
    rm -f "$REPORT_TMP"
    REPORT_TMP=""
    log "report written to $out"
}

cleanup() {
    local code=$?
    stop_peak_monitor 2>/dev/null || true
    [ -z "$REPORT_TMP" ] || write_macos_report
    return "$code"
}

main() {
    parse_args "$@"
    check_preconditions
    if [ "$DRY_RUN" -eq 1 ]; then print_plan; exit 0; fi
    REPORT_TMP=$(mktemp)
    trap cleanup EXIT
    local scenario
    for scenario in $(scenario_list); do
        case "$scenario" in
        concurrency) scenario_concurrency ;;
        recovery) scenario_recovery ;;
        soak) scenario_soak ;;
        esac
    done
    write_macos_report
    if [ "$FAILURES" -eq 0 ]; then
        log "all scenarios passed"
        exit 0
    fi
    warn "$FAILURES check(s) failed"
    exit 1
}

# Guarded so scripts/tests/live-macos-e2e-test.sh can source this file and exercise its pure
# helpers with no daemon, no VM and no GitHub.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
