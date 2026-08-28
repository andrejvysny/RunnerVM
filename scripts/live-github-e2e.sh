#!/usr/bin/env bash
# Live GitHub integration E2E suite for RunnerVM (TODO.md T3, "Live checklist for M6").
#
# Manually triggered, opt-in: dispatches real workflow_dispatch runs against a dedicated test
# org/repo on GitHub.com and drives runnerd through REST JIT + Runner Scale Set flows. This is
# NOT part of `swift test` or CI's default triggers -- it costs real wall-clock time (the
# long-job scenario alone runs 65+ minutes) and must never point at a production org.
#
# Read docs/live-integration.md before the first run: preconditions, PAT scopes, how the test
# repo's workflow (docs/e2e/test-repo-workflow.yml) needs to be installed, and what each
# scenario asserts. Requires: gh (authenticated), jq, and a built runnerctl.
#
# Shared logging/runnerctl/polling/report helpers live in scripts/lib/live-common.sh, also used by
# scripts/live-builder-e2e.sh; see that file's header for exactly what moved there and why.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/lib/live-common.sh
# shellcheck disable=SC1091 # dynamic path; run shellcheck -x to actually follow it
source "$REPO_ROOT/scripts/lib/live-common.sh"

# --------------------------------------------------------------------------
# Defaults, env, flags
# --------------------------------------------------------------------------
PROFILE="ubuntu-24"
STATE_DIR="$HOME/Library/Application Support/RunnerVM"
SOCKET=""
CONCURRENCY=4
LONG_MINUTES=65
SHORT_LONG_MINUTES="${RUNNERVM_E2E_SHORT_LONG_MINUTES:-5}"
JSON_REPORT=""
DRY_RUN=0
RESTART_CMD=""
KILL_CMD=""
WORKFLOW_FILE="e2e.yml"

SCENARIOS=()
ALL_SCENARIOS=(
  success cancel-before-assignment cancel-during-job restart-while-booting
  restart-while-runner-starts restart-during-job restart-during-job-sigkill redelivery
  scaleset-reconnect long-job concurrent queue-overflow
)

OWNER="${RUNNERVM_E2E_OWNER:-}"
REPO="${RUNNERVM_E2E_REPO:-}"
TOKEN="${RUNNERVM_GITHUB_TOKEN:-}"

RUN_TIMEOUT="${RUNNERVM_E2E_RUN_TIMEOUT:-1800}"
JOB_START_TIMEOUT="${RUNNERVM_E2E_JOB_START_TIMEOUT:-600}"
BOOT_WINDOW_TIMEOUT="${RUNNERVM_E2E_BOOT_WINDOW_TIMEOUT:-180}"
LEFTOVER_TIMEOUT="${RUNNERVM_E2E_LEFTOVER_TIMEOUT:-180}"
PRE_CANCEL_GRACE="${RUNNERVM_E2E_PRE_CANCEL_GRACE:-15}"
REDELIVERY_RESTART_DELAY="${RUNNERVM_E2E_REDELIVERY_DELAY:-5}"
RUN_POLL_INTERVAL="${RUNNERVM_E2E_POLL_INTERVAL:-5}"
# An unclean (SIGKILL) restart has more to recover -- worker reconnect, session/runner teardown,
# GitHub-side runner-list lag -- than the graceful restarts the other scenarios exercise, so it
# gets a longer leftover budget rather than sharing LEFTOVER_TIMEOUT.
SIGKILL_TIMEOUT="${RUNNERVM_E2E_SIGKILL_TIMEOUT:-240}"
# How long to wait for scaleset.list to show a new session/generation after debug.scaleSetReconnect.
RECONNECT_TIMEOUT="${RUNNERVM_E2E_RECONNECT_TIMEOUT:-60}"

FAIL_COUNT=0
# shellcheck disable=SC2034 # consumed by report_init/record_result/write_report (live-common.sh)
REPORT_TMP=""
PEAK_FILE=""
PEAK_MONITOR_PID=""

RUNNERCTL_BIN="$(find_runnerctl)"

usage() {
  cat <<'USAGE'
usage: live-github-e2e.sh --scenario <name> [--scenario <name> ...] [options]
       live-github-e2e.sh --all [options]

Live GitHub integration E2E suite for RunnerVM. Manually triggered, opt-in; hits a real
GitHub org/repo. Read docs/live-integration.md before the first run.

Required environment:
  RUNNERVM_E2E_OWNER       Dedicated test org (or user) login.
  RUNNERVM_E2E_REPO        Dedicated test repo, "owner/name".
  RUNNERVM_GITHUB_TOKEN    PAT with the scopes docs/live-integration.md lists.

Options:
  --profile <name>       Profile to exercise (default: ubuntu-24).
  --state-dir <dir>      RunnerVM state root, for the default report/log location
                          (default: $HOME/Library/Application Support/RunnerVM).
  --socket <path>        runnerd.sock path, forwarded to every runnerctl call.
  --scenario <name>      Run one scenario. Repeatable.
  --all                  Run every scenario, in the order listed below.
  --concurrency <n>      Jobs dispatched by the "concurrent" scenario (default: 4).
  --long-minutes <n>     Expected length of the workflow's "long" job (default: 65); must match
                         LONG_MINUTES in the test repo's e2e.yml (docs/e2e/test-repo-workflow.yml).
  --json-report <path>  Where to write the JSON report
                         (default: <state-dir>/logs/e2e-report-<timestamp>.json).
  --restart-cmd <cmd>    Shell command that restarts runnerd
                         (default: launchctl kickstart -k gui/$(id -u)/com.runnervm.runnerd).
  --kill-cmd <cmd>       Shell command that SIGKILLs runnerd, for restart-during-job-sigkill
                         (default: `kill -9` the pid from `runnerctl status`'s daemon.pid, falling
                         back to `pgrep -f runnerd`). Runs before --restart-cmd, never instead of it.
  --dry-run              Print the commands each selected scenario would run; touches nothing,
                          requires no daemon/gh/PAT to actually work.
  -h, --help             Show this help.

Scenarios:
  success                    Dispatch a quick job; assert success and no leftovers.
  cancel-before-assignment   Drain, dispatch, cancel while still queued, resume; no leftovers.
  cancel-during-job          Dispatch a long job, cancel once running; assert teardown.
  restart-while-booting      Restart runnerd while the VM boots; assert the job still completes.
  restart-while-runner-starts
                             Restart runnerd while the runner is being configured/started
                             (configuringRunner/runnerStarting); assert the job still completes
                             once, no duplicate runner session.
  restart-during-job         Restart runnerd mid-job; assert completion, no duplicate runner.
  restart-during-job-sigkill Same, but SIGKILL runnerd instead of a graceful restart; assert one
                             GitHub run attempt, one job, the vmworker survives untouched, and the
                             runner registration/VM/capacity all converge afterward.
  redelivery                 Best-effort: restart runnerd right after dispatch; assert one VM.
  scaleset-reconnect         Force-drop the scale set's message session mid-job (debug RPC);
                             assert the job still completes once on a new session generation.
  long-job                   A real 65+ minute job; assert it is not torn down early.
  concurrent                 N quick jobs at once; assert peak VM count stays within capacity.
  queue-overflow              2x capacity jobs; assert GitHub never over-assigns.

Timeout overrides (seconds): RUNNERVM_E2E_RUN_TIMEOUT, RUNNERVM_E2E_JOB_START_TIMEOUT,
RUNNERVM_E2E_BOOT_WINDOW_TIMEOUT, RUNNERVM_E2E_LEFTOVER_TIMEOUT, RUNNERVM_E2E_PRE_CANCEL_GRACE,
RUNNERVM_E2E_REDELIVERY_DELAY, RUNNERVM_E2E_POLL_INTERVAL, RUNNERVM_E2E_SIGKILL_TIMEOUT,
RUNNERVM_E2E_RECONNECT_TIMEOUT. RUNNERCTL overrides the runnerctl binary path (default:
.build/debug/runnerctl, falling back to .build/release then PATH).
USAGE
}

# --------------------------------------------------------------------------
# Argument parsing / validation
# --------------------------------------------------------------------------

# STATE_DIR/SOCKET/JSON_REPORT below are consumed by write_report/rc() in
# scripts/lib/live-common.sh, invisible to a plain (non -x) shellcheck pass over this file alone.
# shellcheck disable=SC2034
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --state-dir) STATE_DIR="$2"; shift 2 ;;
    --socket) SOCKET="$2"; shift 2 ;;
    --scenario) SCENARIOS+=("$2"); shift 2 ;;
    --all) SCENARIOS=("${ALL_SCENARIOS[@]}"); shift ;;
    --concurrency) CONCURRENCY="$2"; shift 2 ;;
    --long-minutes) LONG_MINUTES="$2"; shift 2 ;;
    --json-report) JSON_REPORT="$2"; shift 2 ;;
    --restart-cmd) RESTART_CMD="$2"; shift 2 ;;
    --kill-cmd) KILL_CMD="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
  done
}

is_known_scenario() {
  local name="$1" candidate
  for candidate in "${ALL_SCENARIOS[@]}"; do
    [ "$candidate" = "$name" ] && return 0
  done
  return 1
}

validate_args() {
  [ ${#SCENARIOS[@]} -gt 0 ] || die "pass --scenario <name> (repeatable) or --all; see --help"
  local name
  for name in "${SCENARIOS[@]}"; do
    is_known_scenario "$name" || die "unknown scenario: $name (see --help for the list)"
  done
  case "$CONCURRENCY" in '' | *[!0-9]*) die "--concurrency must be a positive integer" ;; esac
  case "$LONG_MINUTES" in '' | *[!0-9]*) die "--long-minutes must be a positive integer" ;; esac
  [ "$CONCURRENCY" -ge 1 ] || die "--concurrency must be at least 1"
  [ "$LONG_MINUTES" -ge 1 ] || die "--long-minutes must be at least 1"
}

require_tools() {
  local missing=()
  command -v gh >/dev/null 2>&1 || missing+=("gh (https://cli.github.com)")
  command -v jq >/dev/null 2>&1 || missing+=("jq (brew install jq)")
  if [ -z "$RUNNERCTL_BIN" ] || [ ! -x "$RUNNERCTL_BIN" ]; then
    missing+=("runnerctl (swift build, or set RUNNERCTL=/path/to/runnerctl)")
  fi
  [ ${#missing[@]} -eq 0 ] || die "missing tools: ${missing[*]}"
}

require_env() {
  [ -n "$OWNER" ] || die "RUNNERVM_E2E_OWNER is required (dedicated test org/user login)"
  [ -n "$REPO" ] || die "RUNNERVM_E2E_REPO is required (owner/repo of the dedicated test repo)"
  [ -n "$TOKEN" ] || die "RUNNERVM_GITHUB_TOKEN is required (PAT; scopes: docs/live-integration.md)"
  export GH_TOKEN="$TOKEN"
}

# --------------------------------------------------------------------------
# Preconditions (check_daemon_reachable / check_github_auth / check_gh_cli_auth are shared;
# scripts/lib/live-common.sh)
# --------------------------------------------------------------------------
check_profile_image_ready() {
  local profile_json="$1" image_ref images_json ready
  image_ref=$(echo "$profile_json" | jq -r '.image')
  images_json=$(rc image list) || die "runnerctl image list failed"
  ready=$(echo "$images_json" | jq --arg ref "$image_ref" \
    '[.images[] | select((.canonicalReference==$ref or .name==$ref) and .state=="ready")] | length')
  [ "$ready" -gt 0 ] \
    || die "image '$image_ref' for profile '$PROFILE' is not locally ready; run 'runnerctl image pull $image_ref' (or 'image import')"
}

check_profile_ready() {
  local profile_json
  profile_json=$(rc profile show "$PROFILE") \
    || die "profile '$PROFILE' not found; check 'runnerctl profile list'"
  echo "$profile_json" | jq -e '.enabled==true' >/dev/null \
    || die "profile '$PROFILE' is disabled; enable it and 'runnerctl config apply'"
  check_profile_image_ready "$profile_json"
}

check_test_workflow_present() {
  gh api "repos/$REPO/contents/.github/workflows/$WORKFLOW_FILE" >/dev/null 2>&1 \
    || die "'$REPO' has no .github/workflows/$WORKFLOW_FILE; copy docs/e2e/test-repo-workflow.yml there first"
}

check_preconditions() {
  log "checking preconditions"
  check_daemon_reachable
  check_github_auth
  check_profile_ready
  check_gh_cli_auth
  check_test_workflow_present
  log "preconditions OK (profile=$PROFILE owner=$OWNER repo=$REPO)"
}

# --------------------------------------------------------------------------
# Workflow dispatch (find_dispatched_run / wait_for_run_conclusion are shared)
# --------------------------------------------------------------------------
# $3 = minutes for the `long` job. Restart/cancel scenarios only need a job that is still running
# when they act, so they dispatch a short one (SHORT_LONG_MINUTES); only `long-job` asks for the
# full LONG_MINUTES -- a 65-minute job can never finish inside RUN_TIMEOUT (seen live).
dispatch_workflow() {
  local job="$1" count="${2:-1}" minutes="${3:-$LONG_MINUTES}"
  log "dispatching: job=$job count=$count profile=$PROFILE minutes=$minutes"
  gh workflow run "$WORKFLOW_FILE" -R "$REPO" \
    -f "job=$job" -f "count=$count" -f "profile=$PROFILE" -f "minutes=$minutes"
}

gh_cancel_run() { gh run cancel "$1" -R "$REPO"; }

# --------------------------------------------------------------------------
# runnerd/instance/session polling (wait_for_instance_state, assert_no_leftovers and
# wait_no_github_runner all live in scripts/lib/live-common.sh)
# --------------------------------------------------------------------------

# $1=profile $2=timeout. Prints the instanceId of the first session that reached jobRunning.
wait_for_session_instance() {
  local profile="$1" timeout="$2" deadline now id
  deadline=$(($(date +%s) + timeout))
  while true; do
    now=$(date +%s)
    [ "$now" -lt "$deadline" ] || return 1
    id=$(rc runner list --active 2>/dev/null | jq -r --arg p "$profile" \
      '[.sessions[] | select(.profile==$p and .state=="jobRunning")] | .[0].instanceId // empty' 2>/dev/null) \
      || id=""
    [ -n "$id" ] && { printf '%s\n' "$id"; return 0; }
    sleep 3
  done
}

# --------------------------------------------------------------------------
# Host maintenance / restart (start_peak_monitor/stop_peak_monitor/read_peak,
# wait_for_instance_state, restart_runnerd/runnerd_pid/kill_runnerd and wait_for_daemon_up all
# live in scripts/lib/live-common.sh -- scripts/live-macos-e2e.sh needs them too)
# --------------------------------------------------------------------------
system_drain() { rc system drain --wait --timeout "${1:-30}" >/dev/null; }
system_resume() { rc system resume >/dev/null; }

# --------------------------------------------------------------------------
# --dry-run plans: one function per scenario, printing the exact commands it would run, in
# order, with real $OWNER/$REPO/$PROFILE substituted. Kept next to the matching scenario_*
# below for easy comparison; nothing here executes anything.
# --------------------------------------------------------------------------
plan_success() {
  local prefix; prefix="rvm-$(profile_short_name "$PROFILE")"
  cat <<PLAN
  $RUNNERCTL_BIN --output json status                                 # capture busy/idle/demand baseline for $PROFILE
  gh workflow run $WORKFLOW_FILE -R "$REPO" -f job=quick -f count=1 -f profile=$PROFILE
  gh run list -R "$REPO" --workflow=$WORKFLOW_FILE --json databaseId,createdAt,event -L 15
  gh run view <run-id> -R "$REPO" --json status,conclusion            # poll every ${RUN_POLL_INTERVAL}s up to ${RUN_TIMEOUT}s
  $RUNNERCTL_BIN --output json vm list                                # poll up to ${LEFTOVER_TIMEOUT}s: 0 instances of $PROFILE
  $RUNNERCTL_BIN --output json runner list --active                   # poll: 0 active sessions of $PROFILE
  $RUNNERCTL_BIN --output json status                                 # assert busy/idle/demand back at the captured baseline
  gh api orgs/$OWNER/actions/runners --jq '.runners[]|select(.name|startswith("$prefix"))'
  $RUNNERCTL_BIN --output json scaleset list                          # assert $PROFILE assignedJobs == 0
PLAN
}

plan_cancel-before-assignment() {
  cat <<PLAN
  $RUNNERCTL_BIN --output json status                                 # capture busy/idle/demand baseline for $PROFILE
  $RUNNERCTL_BIN --output json system drain --wait --timeout 30
  gh workflow run $WORKFLOW_FILE -R "$REPO" -f job=quick -f count=1 -f profile=$PROFILE
  gh run list -R "$REPO" --workflow=$WORKFLOW_FILE --json databaseId,createdAt,event -L 15
  sleep ${PRE_CANCEL_GRACE}                                           # grace period; run must still be queued
  gh run cancel <run-id> -R "$REPO"
  $RUNNERCTL_BIN --output json system resume
  gh run view <run-id> -R "$REPO" --json status,conclusion            # poll up to 120s for completed
  $RUNNERCTL_BIN --output json vm list                                # poll: 0 instances of $PROFILE
  $RUNNERCTL_BIN --output json runner list --active                   # poll: 0 active sessions of $PROFILE
  $RUNNERCTL_BIN --output json status                                 # assert busy/idle/demand back at the captured baseline
PLAN
}

plan_cancel-during-job() {
  cat <<PLAN
  $RUNNERCTL_BIN --output json status                                 # capture busy/idle/demand baseline for $PROFILE
  gh workflow run $WORKFLOW_FILE -R "$REPO" -f job=long -f count=1 -f profile=$PROFILE
  gh run list -R "$REPO" --workflow=$WORKFLOW_FILE --json databaseId,createdAt,event -L 15
  $RUNNERCTL_BIN --output json runner list --active                   # poll up to ${JOB_START_TIMEOUT}s for state jobRunning
  gh run cancel <run-id> -R "$REPO"
  gh run view <run-id> -R "$REPO" --json status,conclusion            # poll up to 120s for completed
  $RUNNERCTL_BIN --output json vm list                                # poll up to ${LEFTOVER_TIMEOUT}s: 0 instances of $PROFILE
  $RUNNERCTL_BIN --output json runner list --active                   # poll: 0 active sessions of $PROFILE
  $RUNNERCTL_BIN --output json status                                 # assert busy/idle/demand back at the captured baseline
PLAN
}

plan_restart-while-booting() {
  cat <<PLAN
  $RUNNERCTL_BIN --output json status                                 # capture busy/idle/demand baseline for $PROFILE
  gh workflow run $WORKFLOW_FILE -R "$REPO" -f job=quick -f count=1 -f profile=$PROFILE
  gh run list -R "$REPO" --workflow=$WORKFLOW_FILE --json databaseId,createdAt,event -L 15
  $RUNNERCTL_BIN --output json vm list                                # poll up to ${BOOT_WINDOW_TIMEOUT}s for state in
                                                                       # startingWorker/startingVM/waitingForAgent
  launchctl kickstart -k gui/$(id -u)/com.runnervm.runnerd            # or --restart-cmd
  $RUNNERCTL_BIN --output json status                                 # poll up to 60s for the daemon to answer again
  gh run view <run-id> -R "$REPO" --json status,conclusion            # poll every ${RUN_POLL_INTERVAL}s up to ${RUN_TIMEOUT}s
  $RUNNERCTL_BIN --output json vm list                                # assert 0 instances of $PROFILE
  $RUNNERCTL_BIN --output json status                                 # assert busy/idle/demand back at the captured baseline
PLAN
}

plan_restart-while-runner-starts() {
  cat <<PLAN
  $RUNNERCTL_BIN --output json status                                 # capture busy/idle/demand baseline for $PROFILE
  gh workflow run $WORKFLOW_FILE -R "$REPO" -f job=quick -f count=1 -f profile=$PROFILE
  gh run list -R "$REPO" --workflow=$WORKFLOW_FILE --json databaseId,createdAt,event -L 15
  $RUNNERCTL_BIN --output json vm list                                # poll up to ${BOOT_WINDOW_TIMEOUT}s for state in
                                                                       # configuringRunner/runnerStarting
  launchctl kickstart -k gui/$(id -u)/com.runnervm.runnerd            # or --restart-cmd
  $RUNNERCTL_BIN --output json status                                 # poll up to 60s for the daemon to answer again
  gh run view <run-id> -R "$REPO" --json status,conclusion            # poll every ${RUN_POLL_INTERVAL}s up to ${RUN_TIMEOUT}s
  $RUNNERCTL_BIN --output json runner list                            # assert <= 1 session with a github runner id for this job
  $RUNNERCTL_BIN --output json vm list                                # assert 0 instances of $PROFILE
  $RUNNERCTL_BIN --output json status                                 # assert busy/idle/demand back at the captured baseline
PLAN
}

plan_restart-during-job() {
  cat <<PLAN
  $RUNNERCTL_BIN --output json status                                 # capture busy/idle/demand baseline for $PROFILE
  gh workflow run $WORKFLOW_FILE -R "$REPO" -f job=long -f count=1 -f profile=$PROFILE
  $RUNNERCTL_BIN --output json runner list --active                   # poll up to ${JOB_START_TIMEOUT}s for state jobRunning
  launchctl kickstart -k gui/$(id -u)/com.runnervm.runnerd            # or --restart-cmd
  $RUNNERCTL_BIN --output json status                                 # poll up to 60s for the daemon to answer again
  gh run view <run-id> -R "$REPO" --json status,conclusion            # poll every ${RUN_POLL_INTERVAL}s up to ${RUN_TIMEOUT}s
  $RUNNERCTL_BIN --output json runner list                            # assert <= 1 session with a github runner id for this job
  $RUNNERCTL_BIN --output json vm list                                # assert 0 instances of $PROFILE
  $RUNNERCTL_BIN --output json status                                 # assert busy/idle/demand back at the captured baseline
PLAN
}

plan_restart-during-job-sigkill() {
  cat <<PLAN
  $RUNNERCTL_BIN --output json status                                 # capture busy/idle/demand baseline for $PROFILE
  gh workflow run $WORKFLOW_FILE -R "$REPO" -f job=long -f count=1 -f profile=$PROFILE
  $RUNNERCTL_BIN --output json runner list --active                   # poll up to ${JOB_START_TIMEOUT}s for state jobRunning
  $RUNNERCTL_BIN --output json vm list                                # capture workerPid for the bound instance
  ${KILL_CMD:-kill -9 <runnerd-pid>}                                  # <runnerd-pid> from runnerctl status's daemon.pid, or pgrep -f runnerd
  launchctl kickstart -k gui/$(id -u)/com.runnervm.runnerd            # or --restart-cmd
  $RUNNERCTL_BIN --output json status                                 # poll up to 60s for the daemon to answer again
  $RUNNERCTL_BIN --output json vm list                                # assert the instance's workerPid is unchanged (vmworker untouched)
  gh run view <run-id> -R "$REPO" --json status,conclusion            # poll every ${RUN_POLL_INTERVAL}s up to ${RUN_TIMEOUT}s
  gh api repos/$REPO/actions/runs/<run-id>                            # assert run_attempt == 1
  gh api repos/$REPO/actions/runs/<run-id>/jobs                       # assert exactly 1 job
  $RUNNERCTL_BIN --output json runner list                            # assert <= 1 session with a github runner id for this job
  gh api orgs/$OWNER/actions/runners                                  # poll up to ${SIGKILL_TIMEOUT}s: no runner named rvm-$(profile_short_name "$PROFILE")-*
  $RUNNERCTL_BIN --output json vm list                                # poll up to ${SIGKILL_TIMEOUT}s: 0 instances of $PROFILE
  $RUNNERCTL_BIN --output json status                                 # assert busy/idle/demand back at the captured baseline
PLAN
}

plan_redelivery() {
  cat <<PLAN
  # best-effort: no runnerd.log line marks "JobAvailable received, not yet acked" (see
  # docs/live-integration.md); the restart delay below is a fixed guess, not a real signal.
  $RUNNERCTL_BIN --output json status                                 # capture busy/idle/demand baseline for $PROFILE
  gh workflow run $WORKFLOW_FILE -R "$REPO" -f job=quick -f count=1 -f profile=$PROFILE
  sleep ${REDELIVERY_RESTART_DELAY}
  launchctl kickstart -k gui/$(id -u)/com.runnervm.runnerd            # or --restart-cmd
  $RUNNERCTL_BIN --output json status                                 # poll up to 60s for the daemon to answer again
  gh run view <run-id> -R "$REPO" --json status,conclusion            # poll every ${RUN_POLL_INTERVAL}s up to ${RUN_TIMEOUT}s
  $RUNNERCTL_BIN --output json vm list --all                          # assert exactly 1 instance was created for $PROFILE
  $RUNNERCTL_BIN --output json status                                 # assert busy/idle/demand back at the captured baseline
PLAN
}

plan_scaleset-reconnect() {
  cat <<PLAN
  $RUNNERCTL_BIN --output json status                                 # capture busy/idle/demand baseline for $PROFILE
  $RUNNERCTL_BIN --output json scaleset list                          # capture the current session generation for $PROFILE
  gh workflow run $WORKFLOW_FILE -R "$REPO" -f job=quick -f count=1 -f profile=$PROFILE
  gh run list -R "$REPO" --workflow=$WORKFLOW_FILE --json databaseId,createdAt,event -L 15
  $RUNNERCTL_BIN --output json debug scaleset reconnect $PROFILE      # drop the message session while the job is queued/running
  $RUNNERCTL_BIN --output json scaleset list                          # poll up to ${RECONNECT_TIMEOUT}s for a new session generation
  gh run view <run-id> -R "$REPO" --json status,conclusion            # poll every ${RUN_POLL_INTERVAL}s up to ${RUN_TIMEOUT}s
  $RUNNERCTL_BIN --output json vm list --all                          # assert <= 1 instance was created for this job
  $RUNNERCTL_BIN --output json vm list                                # poll up to ${LEFTOVER_TIMEOUT}s: 0 instances of $PROFILE
  $RUNNERCTL_BIN --output json runner list --active                   # poll: 0 active sessions of $PROFILE
  $RUNNERCTL_BIN --output json status                                 # assert busy/idle/demand back at the captured baseline
  $RUNNERCTL_BIN --output json scaleset list                          # assert $PROFILE assignedJobs == 0
PLAN
}

plan_long-job() {
  local half=$((LONG_MINUTES * 60 / 2)) timeout=$(((LONG_MINUTES + 15) * 60))
  cat <<PLAN
  $RUNNERCTL_BIN --output json status                                 # capture busy/idle/demand baseline for $PROFILE
  gh workflow run $WORKFLOW_FILE -R "$REPO" -f job=long -f count=1 -f profile=$PROFILE
  $RUNNERCTL_BIN --output json runner list --active                   # poll up to ${JOB_START_TIMEOUT}s for state jobRunning
  sleep $half                                                         # halfway through the expected $LONG_MINUTES-minute job
  $RUNNERCTL_BIN --output json vm show <instance-id>                  # assert state is not stopped/deleted (JobCompleted
                                                                       # arriving early must not tear the VM down)
  gh run view <run-id> -R "$REPO" --json status,conclusion            # poll every ${RUN_POLL_INTERVAL}s up to ${timeout}s
  $RUNNERCTL_BIN --output json vm list                                # assert 0 instances of $PROFILE
  $RUNNERCTL_BIN --output json status                                 # assert busy/idle/demand back at the captured baseline
PLAN
}

plan_concurrent() {
  cat <<PLAN
  $RUNNERCTL_BIN --output json status                                 # capture busy/idle/demand baseline for $PROFILE
  $RUNNERCTL_BIN --output json profile show $PROFILE                  # or scaleset list; resolves advertised capacity
  gh workflow run $WORKFLOW_FILE -R "$REPO" -f job=matrix -f count=$CONCURRENCY -f profile=$PROFILE
  $RUNNERCTL_BIN --output json vm list                                # sampled every 3s while the run is in progress; peak kept
  gh run view <run-id> -R "$REPO" --json status,conclusion            # poll every ${RUN_POLL_INTERVAL}s up to ${RUN_TIMEOUT}s
                                                                       # assert peak VM count <= advertised capacity
  $RUNNERCTL_BIN --output json vm list                                # assert 0 instances of $PROFILE
  $RUNNERCTL_BIN --output json status                                 # assert busy/idle/demand back at the captured baseline
PLAN
}

plan_queue-overflow() {
  cat <<PLAN
  $RUNNERCTL_BIN --output json status                                 # capture busy/idle/demand baseline for $PROFILE
  $RUNNERCTL_BIN --output json profile show $PROFILE                  # or scaleset list; resolves advertised capacity, N = 2x it
  gh workflow run $WORKFLOW_FILE -R "$REPO" -f job=matrix -f count=<2x capacity> -f profile=$PROFILE
  $RUNNERCTL_BIN --output json vm list                                # sampled every 3s while the run is in progress; peak kept
  gh run view <run-id> -R "$REPO" --json status,conclusion            # poll up to $((RUN_TIMEOUT * 2))s
                                                                       # assert peak VM count never exceeded advertised capacity
  $RUNNERCTL_BIN --output json vm list                                # assert 0 instances of $PROFILE
  $RUNNERCTL_BIN --output json status                                 # assert busy/idle/demand back at the captured baseline
PLAN
}

# --------------------------------------------------------------------------
# Scenarios. Each returns 0 (pass) or 1 (fail); run_scenarios logs start/end and records the
# result. Every rc/gh query that feeds a bare `var=$(...)` assignment is guarded (see the note
# above profile_capacity in scripts/lib/live-common.sh) so a transient failure fails just this
# scenario, not the whole suite.
# --------------------------------------------------------------------------
scenario_success() {
  local before run_id conclusion baseline
  baseline=$(capture_capacity_baseline "$PROFILE")
  before=$(date +%s)
  dispatch_workflow quick 1
  run_id=$(find_dispatched_run "$before") || { warn "could not locate the dispatched run"; return 1; }
  log "run $run_id dispatched"
  conclusion=$(wait_for_run_conclusion "$run_id" "$RUN_TIMEOUT") \
    || { warn "run $run_id did not complete within ${RUN_TIMEOUT}s"; return 1; }
  [ "$conclusion" = "success" ] || { warn "run $run_id concluded '$conclusion', expected success"; return 1; }
  assert_no_leftovers "$PROFILE" "$LEFTOVER_TIMEOUT" "$baseline" || return 1
  scale_set_idle "$PROFILE" || { warn "scale set for $PROFILE still shows assigned jobs"; return 1; }
  return 0
}

scenario_cancel-before-assignment() {
  local before run_id baseline
  baseline=$(capture_capacity_baseline "$PROFILE")
  # A drain that "fails" may still have switched the host to draining (it did, live, before the
  # daemon's `drained` flag was fixed): always resume on the way out, or every later scenario
  # queues forever against an advertised capacity of 0.
  system_drain 30 || { warn "system drain failed"; system_resume || true; return 1; }
  before=$(date +%s)
  dispatch_workflow quick 1
  run_id=$(find_dispatched_run "$before") \
    || { warn "could not locate the dispatched run"; system_resume || true; return 1; }
  sleep "$PRE_CANCEL_GRACE"
  gh_cancel_run "$run_id" || warn "gh run cancel returned nonzero (run may already be settling)"
  system_resume || warn "system resume failed"
  wait_for_run_conclusion "$run_id" 120 >/dev/null || true
  assert_no_leftovers "$PROFILE" "$LEFTOVER_TIMEOUT" "$baseline" || return 1
  return 0
}

scenario_cancel-during-job() {
  local before run_id baseline
  baseline=$(capture_capacity_baseline "$PROFILE")
  before=$(date +%s)
  dispatch_workflow long 1 "$SHORT_LONG_MINUTES"
  run_id=$(find_dispatched_run "$before") || { warn "could not locate the dispatched run"; return 1; }
  wait_for_session_instance "$PROFILE" "$JOB_START_TIMEOUT" >/dev/null \
    || { warn "no session reached jobRunning within ${JOB_START_TIMEOUT}s"; return 1; }
  gh_cancel_run "$run_id" || { warn "gh run cancel failed"; return 1; }
  wait_for_run_conclusion "$run_id" 120 >/dev/null || true
  assert_no_leftovers "$PROFILE" "$LEFTOVER_TIMEOUT" "$baseline" || return 1
  return 0
}

scenario_restart-while-booting() {
  local before run_id conclusion baseline
  baseline=$(capture_capacity_baseline "$PROFILE")
  before=$(date +%s)
  dispatch_workflow quick 1
  run_id=$(find_dispatched_run "$before") || { warn "could not locate the dispatched run"; return 1; }
  wait_for_instance_state "$PROFILE" "startingWorker startingVM waitingForAgent" "$BOOT_WINDOW_TIMEOUT" \
    >/dev/null || { warn "no instance observed booting within ${BOOT_WINDOW_TIMEOUT}s (served by a warm VM?)"; return 1; }
  restart_runnerd || return 1
  wait_for_daemon_up 60 || { warn "runnerd did not come back up"; return 1; }
  conclusion=$(wait_for_run_conclusion "$run_id" "$RUN_TIMEOUT") \
    || { warn "run did not complete after the boot-time restart"; return 1; }
  [ "$conclusion" = "success" ] || { warn "run concluded '$conclusion' after boot-time restart"; return 1; }
  assert_no_leftovers "$PROFILE" "$LEFTOVER_TIMEOUT" "$baseline" || return 1
  return 0
}

# Restarts runnerd while the runner is being configured/started for the job (configuringRunner or
# runnerStarting, InstanceState.swift) rather than while the VM itself is still booting
# (restart-while-booting) or once the job is actually running (restart-during-job): the JIT
# secret has been (or is about to be) delivered but the runner has not gone online yet, a
# narrower and later window than either of the other two restart scenarios cover.
scenario_restart-while-runner-starts() {
  local before run_id conclusion sessions baseline
  baseline=$(capture_capacity_baseline "$PROFILE")
  before=$(date +%s)
  dispatch_workflow quick 1
  run_id=$(find_dispatched_run "$before") || { warn "could not locate the dispatched run"; return 1; }
  wait_for_instance_state "$PROFILE" "configuringRunner runnerStarting" "$BOOT_WINDOW_TIMEOUT" \
    >/dev/null || { warn "no instance observed configuring/starting the runner within ${BOOT_WINDOW_TIMEOUT}s"; return 1; }
  restart_runnerd || return 1
  wait_for_daemon_up 60 || { warn "runnerd did not come back up"; return 1; }
  conclusion=$(wait_for_run_conclusion "$run_id" "$RUN_TIMEOUT") \
    || { warn "run did not complete after the runner-starting restart"; return 1; }
  [ "$conclusion" = "success" ] || { warn "run concluded '$conclusion' after runner-starting restart"; return 1; }
  # Same duplicate-runner heuristic as restart-during-job (docs/live-integration.md): the daemon
  # has no scale_set_id/job-id column on runner_sessions, so this counts sessions for the profile
  # with a non-null githubRunnerId created after this scenario's own dispatch time.
  sessions=$(rc runner list 2>/dev/null | jq --arg p "$PROFILE" --argjson before "$before" \
    '[.sessions[] | select(.profile==$p and .githubRunnerId!=null
       and ((.createdAt | sub("\\.[0-9]+"; "") | fromdateiso8601) >= $before))] | length' 2>/dev/null) \
    || { warn "could not query runner list to check for a duplicate runner"; return 1; }
  [ "$sessions" -le 1 ] || { warn "found $sessions runner session(s) for one job; expected at most 1"; return 1; }
  assert_no_leftovers "$PROFILE" "$LEFTOVER_TIMEOUT" "$baseline" || return 1
  return 0
}

scenario_restart-during-job() {
  local before run_id conclusion sessions baseline
  baseline=$(capture_capacity_baseline "$PROFILE")
  before=$(date +%s)
  dispatch_workflow long 1 "$SHORT_LONG_MINUTES"
  run_id=$(find_dispatched_run "$before") || { warn "could not locate the dispatched run"; return 1; }
  wait_for_session_instance "$PROFILE" "$JOB_START_TIMEOUT" >/dev/null \
    || { warn "no session reached jobRunning within ${JOB_START_TIMEOUT}s"; return 1; }
  restart_runnerd || return 1
  wait_for_daemon_up 60 || { warn "runnerd did not come back up"; return 1; }
  conclusion=$(wait_for_run_conclusion "$run_id" "$RUN_TIMEOUT") \
    || { warn "run did not complete after the mid-job restart"; return 1; }
  [ "$conclusion" = "success" ] || { warn "run concluded '$conclusion' after mid-job restart"; return 1; }
  sessions=$(rc runner list 2>/dev/null | jq --arg p "$PROFILE" --argjson before "$before" \
    '[.sessions[] | select(.profile==$p and .githubRunnerId!=null
       and ((.createdAt | sub("\\.[0-9]+"; "") | fromdateiso8601) >= $before))] | length' 2>/dev/null) \
    || { warn "could not query runner list to check for a duplicate runner"; return 1; }
  [ "$sessions" -le 1 ] || { warn "found $sessions runner session(s) for one job; expected at most 1"; return 1; }
  assert_no_leftovers "$PROFILE" "$LEFTOVER_TIMEOUT" "$baseline" || return 1
  return 0
}

# Like restart-during-job, but runnerd dies uncleanly (SIGKILL) instead of restarting gracefully.
# Proves worker recovery does not depend on runnerd getting a chance to shut down: the vmworker
# and its VM must be completely unaffected by the daemon's own death, the GitHub run must show
# exactly one attempt and one job (no GitHub-side retry masked a RunnerVM-side duplicate), and
# every side effect (runner registration, VM, host capacity) must still converge afterward. Own
# timeouts throughout (SIGKILL_TIMEOUT): an unclean restart has strictly more to recover than a
# graceful one, so it is not held to the same LEFTOVER_TIMEOUT budget as the other scenarios.
scenario_restart-during-job-sigkill() {
  local before run_id conclusion sessions baseline instance_id
  local worker_before worker_after run_attempt job_count
  baseline=$(capture_capacity_baseline "$PROFILE")
  before=$(date +%s)
  dispatch_workflow long 1 "$SHORT_LONG_MINUTES"
  run_id=$(find_dispatched_run "$before") || { warn "could not locate the dispatched run"; return 1; }
  instance_id=$(wait_for_session_instance "$PROFILE" "$JOB_START_TIMEOUT") \
    || { warn "no session reached jobRunning within ${JOB_START_TIMEOUT}s"; return 1; }
  worker_before=$(rc vm list 2>/dev/null | jq -r --arg id "$instance_id" \
    '[.instances[] | select(.id==$id)][0].workerPid // empty' 2>/dev/null) || worker_before=""
  kill_runnerd || return 1
  restart_runnerd || return 1
  wait_for_daemon_up 60 || { warn "runnerd did not come back up after SIGKILL"; return 1; }
  worker_after=$(rc vm list 2>/dev/null | jq -r --arg id "$instance_id" \
    '[.instances[] | select(.id==$id)][0].workerPid // empty' 2>/dev/null) || worker_after=""
  if [ -z "$worker_before" ] || [ "$worker_before" != "$worker_after" ]; then
    warn "vmworker for $instance_id was not left untouched by the SIGKILL (workerPid before='$worker_before' after='$worker_after')"
    return 1
  fi
  conclusion=$(wait_for_run_conclusion "$run_id" "$RUN_TIMEOUT") \
    || { warn "run did not complete after the SIGKILL restart"; return 1; }
  [ "$conclusion" = "success" ] || { warn "run concluded '$conclusion' after SIGKILL restart"; return 1; }
  # GitHub never retried the job on its own (which would hide a RunnerVM-side duplicate behind a
  # second attempt that also happened to succeed): exactly one run attempt, exactly one job.
  run_attempt=$(gh api "repos/$REPO/actions/runs/$run_id" --jq '.run_attempt // 1' 2>/dev/null) \
    || { warn "could not query run_attempt for run $run_id"; return 1; }
  [ "$run_attempt" = "1" ] \
    || { warn "run $run_id shows run_attempt=$run_attempt; expected exactly 1"; return 1; }
  # e2e.yml declares four jobs and skips three of them via `if:`; skipped jobs still count in
  # `total_count`, so only the ones that actually ran are a duplicate-execution signal.
  job_count=$(gh api "repos/$REPO/actions/runs/$run_id/jobs" \
    --jq '[.jobs[] | select(.conclusion != "skipped")] | length' 2>/dev/null) \
    || { warn "could not query job count for run $run_id"; return 1; }
  [ "$job_count" = "1" ] \
    || { warn "run $run_id has $job_count job(s); expected exactly 1"; return 1; }
  sessions=$(rc runner list 2>/dev/null | jq --arg p "$PROFILE" --argjson before "$before" \
    '[.sessions[] | select(.profile==$p and .githubRunnerId!=null
       and ((.createdAt | sub("\\.[0-9]+"; "") | fromdateiso8601) >= $before))] | length' 2>/dev/null) \
    || { warn "could not query runner list to check for a duplicate runner"; return 1; }
  [ "$sessions" -le 1 ] || { warn "found $sessions runner session(s) for one job; expected at most 1"; return 1; }
  # runnerctl-side terminal state is covered by assert_no_leftovers's active-session check below;
  # the GitHub-side registration is checked here explicitly (hard-fail, not assert_no_leftovers's
  # best-effort warn), since a lingering registration is exactly what this scenario exists to rule
  # out for an unclean daemon death.
  wait_no_github_runner "$PROFILE" "$SIGKILL_TIMEOUT" \
    || { warn "GitHub still lists a runner matching rvm-$(profile_short_name "$PROFILE")-* after ${SIGKILL_TIMEOUT}s"; return 1; }
  assert_no_leftovers "$PROFILE" "$SIGKILL_TIMEOUT" "$baseline" || return 1
  return 0
}

scenario_redelivery() {
  local before run_id conclusion vms baseline
  baseline=$(capture_capacity_baseline "$PROFILE")
  before=$(date +%s)
  dispatch_workflow quick 1
  run_id=$(find_dispatched_run "$before") || { warn "could not locate the dispatched run"; return 1; }
  log "redelivery is best-effort: no log line marks 'received, not yet acked' (docs/live-integration.md)"
  sleep "$REDELIVERY_RESTART_DELAY"
  restart_runnerd || return 1
  wait_for_daemon_up 60 || { warn "runnerd did not come back up"; return 1; }
  conclusion=$(wait_for_run_conclusion "$run_id" "$RUN_TIMEOUT") || { warn "run did not complete"; return 1; }
  [ "$conclusion" = "success" ] || { warn "run concluded '$conclusion'"; return 1; }
  vms=$(rc vm list --all 2>/dev/null | jq --arg p "$PROFILE" --argjson before "$before" \
    '[.instances[] | select(.profile==$p and ((.createdAt | sub("\\.[0-9]+"; "") | fromdateiso8601) >= $before))] | length' 2>/dev/null) \
    || { warn "could not query vm list to check for a duplicate instance"; return 1; }
  # The hard assertion is "the job ran once": at most one runner session with a registration.
  # A second *instance* is only a warning -- a VM booted before the restart can legitimately be
  # replaced by one booted after it -- and is reported so the boot count stays visible.
  [ "$vms" -le 1 ] || warn "saw $vms instance(s) for one job (one may have been replaced across the restart)"
  sessions=$(rc runner list 2>/dev/null | jq --arg p "$PROFILE" --argjson before "$before" \
    '[.sessions[] | select(.profile==$p and .githubRunnerId!=null
       and ((.createdAt | sub("\\.[0-9]+"; "") | fromdateiso8601) >= $before))] | length' 2>/dev/null) \
    || { warn "could not query runner list to check for a duplicate runner"; return 1; }
  [ "$sessions" -le 1 ] || { warn "found $sessions runner session(s) for one job; expected at most 1"; return 1; }
  assert_no_leftovers "$PROFILE" "$LEFTOVER_TIMEOUT" "$baseline" || return 1
  return 0
}

# Forces the scale set's message session (the long poll `ScaleSetDemandProvider` holds open) to
# drop and reconnect mid-job via `debug.scaleSetReconnect` (Proto/daemon_api.md, debug-only): the
# same recovery path a network blip or a GitHub-side session expiry would force, exercised on
# demand instead of waiting for one to happen naturally. Asserts the job still completes exactly
# once on a new session generation and no duplicate VM appears.
scenario_scaleset-reconnect() {
  local before run_id conclusion baseline generation_before generation_after
  local deadline now vms
  baseline=$(capture_capacity_baseline "$PROFILE")
  generation_before=$(rc scaleset list 2>/dev/null | jq -r --arg p "$PROFILE" \
    '[.scaleSets[] | select(.profile==$p)][0].sessionGeneration // -1' 2>/dev/null) || generation_before="-1"
  before=$(date +%s)
  dispatch_workflow quick 1
  run_id=$(find_dispatched_run "$before") || { warn "could not locate the dispatched run"; return 1; }
  rc debug scaleset reconnect "$PROFILE" >/dev/null \
    || { warn "runnerctl debug scaleset reconnect failed"; return 1; }
  deadline=$(($(date +%s) + RECONNECT_TIMEOUT))
  generation_after="$generation_before"
  while true; do
    now=$(date +%s)
    generation_after=$(rc scaleset list 2>/dev/null | jq -r --arg p "$PROFILE" \
      '[.scaleSets[] | select(.profile==$p)][0].sessionGeneration // -1' 2>/dev/null) || generation_after="-1"
    { [ "$generation_after" != "$generation_before" ] && [ "$generation_after" != "-1" ]; } && break
    [ "$now" -lt "$deadline" ] || {
      warn "scale set session generation for $PROFILE did not advance within ${RECONNECT_TIMEOUT}s (still $generation_before)"
      return 1
    }
    sleep 2
  done
  conclusion=$(wait_for_run_conclusion "$run_id" "$RUN_TIMEOUT") \
    || { warn "run did not complete after the forced scale-set reconnect"; return 1; }
  [ "$conclusion" = "success" ] || { warn "run concluded '$conclusion' after forced scale-set reconnect"; return 1; }
  vms=$(rc vm list --all 2>/dev/null | jq --arg p "$PROFILE" --argjson before "$before" \
    '[.instances[] | select(.profile==$p and ((.createdAt | sub("\\.[0-9]+"; "") | fromdateiso8601) >= $before))] | length' 2>/dev/null) \
    || { warn "could not query vm list to check for a duplicate instance"; return 1; }
  [ "$vms" -le 1 ] || { warn "saw $vms instance(s) for one job after a forced reconnect; possible duplicate"; return 1; }
  assert_no_leftovers "$PROFILE" "$LEFTOVER_TIMEOUT" "$baseline" || return 1
  scale_set_idle "$PROFILE" || { warn "scale set for $PROFILE still shows assigned jobs"; return 1; }
  return 0
}

scenario_long-job() {
  local before run_id conclusion timeout half instance_id instance_state baseline
  baseline=$(capture_capacity_baseline "$PROFILE")
  timeout=$(((LONG_MINUTES + 15) * 60))
  half=$((LONG_MINUTES * 60 / 2))
  before=$(date +%s)
  dispatch_workflow long 1
  run_id=$(find_dispatched_run "$before") || { warn "could not locate the dispatched run"; return 1; }
  instance_id=$(wait_for_session_instance "$PROFILE" "$JOB_START_TIMEOUT") \
    || { warn "no session reached jobRunning within ${JOB_START_TIMEOUT}s"; return 1; }
  log "job running on $instance_id; sleeping ${half}s then checking it is still up"
  sleep "$half"
  instance_state=$(rc vm show "$instance_id" 2>/dev/null | jq -r '.state' 2>/dev/null) \
    || { warn "could not query vm show $instance_id"; return 1; }
  case "$instance_state" in
  deleted | stopped | deleting | stopping)
    warn "instance $instance_id was torn down mid-job (state=$instance_state); JobCompleted must not be authoritative"
    return 1
    ;;
  esac
  conclusion=$(wait_for_run_conclusion "$run_id" "$timeout") \
    || { warn "long job did not complete within ${timeout}s"; return 1; }
  [ "$conclusion" = "success" ] || { warn "long job concluded '$conclusion'"; return 1; }
  assert_no_leftovers "$PROFILE" "$LEFTOVER_TIMEOUT" "$baseline" || return 1
  return 0
}

scenario_concurrent() {
  local before run_id conclusion cap peak baseline
  baseline=$(capture_capacity_baseline "$PROFILE")
  cap=$(profile_capacity "$PROFILE")
  before=$(date +%s)
  dispatch_workflow matrix "$CONCURRENCY"
  run_id=$(find_dispatched_run "$before") || { warn "could not locate the dispatched run"; return 1; }
  start_peak_monitor "$PROFILE"
  conclusion=$(wait_for_run_conclusion "$run_id" "$RUN_TIMEOUT") || conclusion="timeout"
  stop_peak_monitor
  peak=$(read_peak)
  [ "$conclusion" = "success" ] || { warn "matrix run concluded '$conclusion'"; return 1; }
  [ "$peak" -le "$cap" ] || { warn "peak VM count $peak exceeded advertised capacity $cap"; return 1; }
  assert_no_leftovers "$PROFILE" "$LEFTOVER_TIMEOUT" "$baseline" || return 1
  return 0
}

scenario_queue-overflow() {
  local before run_id conclusion cap n peak baseline
  baseline=$(capture_capacity_baseline "$PROFILE")
  cap=$(profile_capacity "$PROFILE")
  n=$((cap * 2))
  before=$(date +%s)
  dispatch_workflow matrix "$n"
  run_id=$(find_dispatched_run "$before") || { warn "could not locate the dispatched run"; return 1; }
  start_peak_monitor "$PROFILE"
  conclusion=$(wait_for_run_conclusion "$run_id" "$((RUN_TIMEOUT * 2))") || conclusion="timeout"
  stop_peak_monitor
  peak=$(read_peak)
  [ "$conclusion" = "success" ] || { warn "overflow run concluded '$conclusion'"; return 1; }
  [ "$peak" -le "$cap" ] || { warn "GitHub over-assigned: peak $peak > advertised capacity $cap"; return 1; }
  assert_no_leftovers "$PROFILE" "$LEFTOVER_TIMEOUT" "$baseline" || return 1
  return 0
}

# --------------------------------------------------------------------------
# Dispatch loop / entry point (report_init / record_result / write_report are shared)
# --------------------------------------------------------------------------
run_scenarios() {
  local name started ended status rc_val
  for name in "${SCENARIOS[@]}"; do
    if [ "$DRY_RUN" -eq 1 ]; then
      log "=== [dry-run] $name ==="
      "plan_$name"
      continue
    fi
    log "=== scenario: $name ==="
    started=$(date +%s)
    if "scenario_$name"; then rc_val=0; else rc_val=$?; fi
    ended=$(date +%s)
    if [ "$rc_val" -eq 0 ]; then status="pass"; else status="fail"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi
    log "=== $name: $status ($((ended - started))s) ==="
    record_result "$name" "$status" "$started" "$ended" ""
  done
}

main() {
  parse_args "$@"
  validate_args
  require_tools
  require_env
  if [ "$DRY_RUN" -eq 1 ]; then
    log "dry-run: no live checks, no live calls; profile=$PROFILE owner=$OWNER repo=$REPO"
    run_scenarios
    log "dry-run complete"
    exit 0
  fi
  check_preconditions
  report_init
  run_scenarios
  write_report
  [ "$FAIL_COUNT" -eq 0 ] || exit 1
}

main "$@"
