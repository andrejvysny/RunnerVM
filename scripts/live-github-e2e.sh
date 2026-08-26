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
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --------------------------------------------------------------------------
# Defaults, env, flags
# --------------------------------------------------------------------------
PROFILE="ubuntu-24"
STATE_DIR="$HOME/Library/Application Support/RunnerVM"
SOCKET=""
CONCURRENCY=4
LONG_MINUTES=65
JSON_REPORT=""
DRY_RUN=0
RESTART_CMD=""
WORKFLOW_FILE="e2e.yml"

SCENARIOS=()
ALL_SCENARIOS=(
  success cancel-before-assignment cancel-during-job restart-while-booting
  restart-during-job redelivery long-job concurrent queue-overflow
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

FAIL_COUNT=0
REPORT_TMP=""
PEAK_FILE=""
PEAK_MONITOR_PID=""

find_runnerctl() {
  if [ -n "${RUNNERCTL:-}" ]; then printf '%s' "$RUNNERCTL"; return 0; fi
  local candidate
  for candidate in "$REPO_ROOT/.build/debug/runnerctl" "$REPO_ROOT/.build/release/runnerctl"; do
    if [ -x "$candidate" ]; then printf '%s' "$candidate"; return 0; fi
  done
  command -v runnerctl 2>/dev/null || true
}
RUNNERCTL_BIN="$(find_runnerctl)"

# --------------------------------------------------------------------------
# Logging
# --------------------------------------------------------------------------
log()  { printf '[e2e] %s\n' "$*"; }
warn() { printf '[e2e] warning: %s\n' "$*" >&2; }
die()  { printf '[e2e] error: %s\n' "$*" >&2; exit 2; }

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
  --dry-run              Print the commands each selected scenario would run; touches nothing,
                         requires no daemon/gh/PAT to actually work.
  -h, --help             Show this help.

Scenarios:
  success                   Dispatch a quick job; assert success and no leftovers.
  cancel-before-assignment  Drain, dispatch, cancel while still queued, resume; no leftovers.
  cancel-during-job         Dispatch a long job, cancel once running; assert teardown.
  restart-while-booting     Restart runnerd while the VM boots; assert the job still completes.
  restart-during-job        Restart runnerd mid-job; assert completion, no duplicate runner.
  redelivery                Best-effort: restart runnerd right after dispatch; assert one VM.
  long-job                  A real 65+ minute job; assert it is not torn down early.
  concurrent                N quick jobs at once; assert peak VM count stays within capacity.
  queue-overflow            2x capacity jobs; assert GitHub never over-assigns.

Timeout overrides (seconds): RUNNERVM_E2E_RUN_TIMEOUT, RUNNERVM_E2E_JOB_START_TIMEOUT,
RUNNERVM_E2E_BOOT_WINDOW_TIMEOUT, RUNNERVM_E2E_LEFTOVER_TIMEOUT, RUNNERVM_E2E_PRE_CANCEL_GRACE,
RUNNERVM_E2E_REDELIVERY_DELAY, RUNNERVM_E2E_POLL_INTERVAL. RUNNERCTL overrides the runnerctl
binary path (default: .build/debug/runnerctl, falling back to .build/release then PATH).
USAGE
}

# --------------------------------------------------------------------------
# Argument parsing / validation
# --------------------------------------------------------------------------
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
# runnerctl / profile helpers
# --------------------------------------------------------------------------

# Always runs, JSON-only; the cmd array keeps at least one element so it is safe to expand under
# `set -u` on bash 3.2 (macOS's stock /bin/bash), which errors on "${empty_array[@]}".
rc() {
  local -a cmd
  cmd=("$RUNNERCTL_BIN")
  if [ -n "$SOCKET" ]; then cmd+=(--socket "$SOCKET"); fi
  cmd+=(--output json)
  cmd+=("$@")
  "${cmd[@]}"
}

# Mirrors RunnerProfileConfig.shortName (Sources/RunnerCore/Models/RunnerProfileConfig.swift):
# strip non-alphanumerics, lowercase, first 12 chars. Runner names are "rvm-<shortName>-<id>".
profile_short_name() {
  printf '%s' "$1" | tr -cd 'A-Za-z0-9' | tr '[:upper:]' '[:lower:]' | cut -c1-12
}

# Advertised ceiling for the profile: its own maxInstances if set, else the scale set's most
# recently advertised capacity, else 1 (fail closed rather than accept an unbounded peak).
#
# Every $(...) assignment below that polls runnerctl/gh is guarded with `|| var=<fallback>`: a
# bare `var=$(cmd)` is a simple command in its own right, so under `set -e` a transient failure
# (network blip, daemon hiccup right after a restart) would abort the whole multi-hour suite
# instead of just this poll iteration. The fallback always means "treat as not converged yet" or
# "not found", never "assume success".
profile_capacity() {
  local profile="$1" max
  max=$(rc profile show "$profile" 2>/dev/null | jq -r '.maxInstances // empty' 2>/dev/null) || max=""
  if [ -z "$max" ]; then
    max=$(rc scaleset list 2>/dev/null | jq -r --arg p "$profile" \
      '[.scaleSets[] | select(.profile==$p)][0].advertisedCapacity // 1' 2>/dev/null) || max=""
  fi
  if [ -n "$max" ] && [ "$max" -gt 0 ] 2>/dev/null; then printf '%s\n' "$max"; else printf '1\n'; fi
}

scale_set_idle() {
  rc scaleset list | jq -e --arg p "$1" \
    '([.scaleSets[] | select(.profile==$p)][0].assignedJobs // 0) == 0' >/dev/null
}

# --------------------------------------------------------------------------
# Preconditions
# --------------------------------------------------------------------------
check_daemon_reachable() {
  rc status >/dev/null || die "runnerctl status failed; is runnerd running? (docs/install.md)"
}

check_github_auth() {
  local result
  result=$(rc github test) || die "runnerctl github test failed (daemon-side GitHub check)"
  echo "$result" | jq -e '.auth.state=="healthy"' >/dev/null \
    || die "GitHub auth is not healthy: $(echo "$result" | jq -r '.auth.problem // "unknown"')"
  echo "$result" | jq -e '[.scopes[] | select(.status!="healthy")] | length==0' >/dev/null \
    || die "unhealthy scope(s): $(echo "$result" | jq -c '[.scopes[]|select(.status!="healthy")]')"
}

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

check_gh_cli_auth() {
  gh auth status >/dev/null 2>&1 \
    || die "gh auth status failed; run 'gh auth login' or check RUNNERVM_GITHUB_TOKEN"
  gh repo view "$REPO" >/dev/null 2>&1 \
    || die "gh cannot see repo '$REPO'; check token scope and the repo name"
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
# Workflow dispatch / polling
# --------------------------------------------------------------------------
dispatch_workflow() {
  local job="$1" count="${2:-1}"
  log "dispatching: job=$job count=$count profile=$PROFILE"
  gh workflow run "$WORKFLOW_FILE" -R "$REPO" \
    -f "job=$job" -f "count=$count" -f "profile=$PROFILE"
}

# $1 = epoch seconds right before dispatch. Prints the new run's databaseId.
find_dispatched_run() {
  local before="$1" tries=0 id
  while [ "$tries" -lt 30 ]; do
    id=$(gh run list -R "$REPO" --workflow="$WORKFLOW_FILE" \
        --json databaseId,createdAt,event -L 15 2>/dev/null \
      | jq -r --argjson before "$before" '
          [ .[] | select(.event=="workflow_dispatch")
                 | select((.createdAt | fromdateiso8601) >= $before) ]
          | sort_by(.createdAt) | .[0].databaseId // empty' 2>/dev/null) || id=""
    if [ -n "$id" ]; then printf '%s\n' "$id"; return 0; fi
    sleep 2
    tries=$((tries + 1))
  done
  return 1
}

# $1=run id $2=timeout seconds. Prints the conclusion once the run is completed.
wait_for_run_conclusion() {
  local run_id="$1" timeout="$2" deadline now status conclusion
  deadline=$(($(date +%s) + timeout))
  while true; do
    now=$(date +%s)
    [ "$now" -lt "$deadline" ] || return 1
    status=$(gh run view "$run_id" -R "$REPO" --json status --jq '.status' 2>/dev/null) || status=""
    if [ "$status" = "completed" ]; then
      conclusion=$(gh run view "$run_id" -R "$REPO" --json conclusion --jq '.conclusion // "unknown"' 2>/dev/null) \
        || conclusion="unknown"
      printf '%s\n' "$conclusion"
      return 0
    fi
    sleep "$RUN_POLL_INTERVAL"
  done
}

gh_cancel_run() { gh run cancel "$1" -R "$REPO"; }

# --------------------------------------------------------------------------
# runnerd/instance/session polling
# --------------------------------------------------------------------------

# $1=profile $2=space-separated instance states $3=timeout. Prints the first matching instance id.
wait_for_instance_state() {
  local profile="$1" states="$2" timeout="$3" deadline now id
  deadline=$(($(date +%s) + timeout))
  while true; do
    now=$(date +%s)
    [ "$now" -lt "$deadline" ] || return 1
    id=$(rc vm list 2>/dev/null | jq -r --arg p "$profile" --arg s "$states" '
      ($s | split(" ")) as $wanted
      | [.instances[] | select(.profile==$p and (.state as $st | $wanted | index($st) != null))]
      | .[0].id // empty' 2>/dev/null) || id=""
    [ -n "$id" ] && { printf '%s\n' "$id"; return 0; }
    sleep 2
  done
}

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

# GitHub-side runner count matching this profile's naming (rvm-<shortName>-<id>); best-effort,
# non-paginated (fine for a dedicated test org with a handful of runners).
github_runner_count() {
  local profile="$1" prefix org_count repo_count
  prefix="rvm-$(profile_short_name "$profile")"
  org_count=$(gh api "orgs/$OWNER/actions/runners" --jq \
    ".runners // [] | [.[] | select(.name | startswith(\"$prefix\"))] | length" 2>/dev/null || echo 0)
  repo_count=$(gh api "repos/$REPO/actions/runners" --jq \
    ".runners // [] | [.[] | select(.name | startswith(\"$prefix\"))] | length" 2>/dev/null || echo 0)
  echo $((${org_count:-0} + ${repo_count:-0}))
}

# $1=profile $2=timeout. 0 once no non-deleted instances and no active sessions remain for it.
assert_no_leftovers() {
  local profile="$1" timeout="${2:-$LEFTOVER_TIMEOUT}" deadline now vms sessions gh_runners
  deadline=$(($(date +%s) + timeout))
  vms=-1; sessions=-1
  while true; do
    now=$(date +%s)
    vms=$(rc vm list 2>/dev/null | jq --arg p "$profile" \
      '[.instances[] | select(.profile==$p and .state!="deleted")] | length' 2>/dev/null) || vms=-1
    sessions=$(rc runner list --active 2>/dev/null | jq --arg p "$profile" \
      '[.sessions[] | select(.profile==$p)] | length' 2>/dev/null) || sessions=-1
    { [ "$vms" -eq 0 ] && [ "$sessions" -eq 0 ]; } && break
    [ "$now" -lt "$deadline" ] || break
    sleep 5
  done
  if ! { [ "$vms" -eq 0 ] && [ "$sessions" -eq 0 ]; }; then
    warn "leftovers after ${timeout}s: $vms VM(s), $sessions active session(s) for profile $profile"
    return 1
  fi
  gh_runners=$(github_runner_count "$profile")
  [ "$gh_runners" -eq 0 ] \
    || warn "GitHub still lists $gh_runners runner(s) matching rvm-$(profile_short_name "$profile") (may lag briefly; not fatal)"
  return 0
}

# --------------------------------------------------------------------------
# Peak VM count monitor (concurrent / queue-overflow)
# --------------------------------------------------------------------------
start_peak_monitor() {
  local profile="$1"
  PEAK_FILE=$(mktemp)
  echo 0 >"$PEAK_FILE"
  (
    while true; do
      local n cur
      n=$(rc vm list 2>/dev/null | jq --arg p "$profile" \
        '[.instances[] | select(.profile==$p and .state!="deleted")] | length' 2>/dev/null || echo 0)
      cur=$(cat "$PEAK_FILE" 2>/dev/null || echo 0)
      if [ "$n" -gt "$cur" ] 2>/dev/null; then echo "$n" >"$PEAK_FILE"; fi
      sleep 3
    done
  ) &
  PEAK_MONITOR_PID=$!
}

stop_peak_monitor() {
  [ -n "$PEAK_MONITOR_PID" ] && kill "$PEAK_MONITOR_PID" 2>/dev/null
  wait "$PEAK_MONITOR_PID" 2>/dev/null || true
  PEAK_MONITOR_PID=""
}

read_peak() {
  cat "$PEAK_FILE" 2>/dev/null || echo 0
  rm -f "$PEAK_FILE"
}

# --------------------------------------------------------------------------
# Host maintenance / restart
# --------------------------------------------------------------------------
system_drain() { rc system drain --wait --timeout "${1:-30}" >/dev/null; }
system_resume() { rc system resume >/dev/null; }

restart_runnerd() {
  log "restarting runnerd"
  if [ -n "$RESTART_CMD" ]; then
    sh -c "$RESTART_CMD"
    return $?
  fi
  local label
  label="gui/$(id -u)/com.runnervm.runnerd"
  if launchctl print "$label" >/dev/null 2>&1; then
    launchctl kickstart -k "$label"
    return $?
  fi
  die "no com.runnervm.runnerd launchd job found; pass --restart-cmd '<how to restart runnerd>'"
}

wait_for_daemon_up() {
  local timeout="${1:-60}" deadline now
  deadline=$(($(date +%s) + timeout))
  while true; do
    now=$(date +%s)
    [ "$now" -lt "$deadline" ] || return 1
    rc status >/dev/null 2>&1 && return 0
    sleep 2
  done
}

# --------------------------------------------------------------------------
# --dry-run plans: one function per scenario, printing the exact commands it would run, in
# order, with real $OWNER/$REPO/$PROFILE substituted. Kept next to the matching scenario_*
# below for easy comparison; nothing here executes anything.
# --------------------------------------------------------------------------
plan_success() {
  local prefix; prefix="rvm-$(profile_short_name "$PROFILE")"
  cat <<PLAN
  gh workflow run $WORKFLOW_FILE -R "$REPO" -f job=quick -f count=1 -f profile=$PROFILE
  gh run list -R "$REPO" --workflow=$WORKFLOW_FILE --json databaseId,createdAt,event -L 15
  gh run view <run-id> -R "$REPO" --json status,conclusion            # poll every ${RUN_POLL_INTERVAL}s up to ${RUN_TIMEOUT}s
  $RUNNERCTL_BIN --output json vm list                                # poll up to ${LEFTOVER_TIMEOUT}s: 0 instances of $PROFILE
  $RUNNERCTL_BIN --output json runner list --active                   # poll: 0 active sessions of $PROFILE
  gh api orgs/$OWNER/actions/runners --jq '.runners[]|select(.name|startswith("$prefix"))'
  $RUNNERCTL_BIN --output json scaleset list                          # assert $PROFILE assignedJobs == 0
PLAN
}

plan_cancel-before-assignment() {
  cat <<PLAN
  $RUNNERCTL_BIN --output json system drain --wait --timeout 30
  gh workflow run $WORKFLOW_FILE -R "$REPO" -f job=quick -f count=1 -f profile=$PROFILE
  gh run list -R "$REPO" --workflow=$WORKFLOW_FILE --json databaseId,createdAt,event -L 15
  sleep ${PRE_CANCEL_GRACE}                                           # grace period; run must still be queued
  gh run cancel <run-id> -R "$REPO"
  $RUNNERCTL_BIN --output json system resume
  gh run view <run-id> -R "$REPO" --json status,conclusion            # poll up to 120s for completed
  $RUNNERCTL_BIN --output json vm list                                # poll: 0 instances of $PROFILE
  $RUNNERCTL_BIN --output json runner list --active                   # poll: 0 active sessions of $PROFILE
PLAN
}

plan_cancel-during-job() {
  cat <<PLAN
  gh workflow run $WORKFLOW_FILE -R "$REPO" -f job=long -f count=1 -f profile=$PROFILE
  gh run list -R "$REPO" --workflow=$WORKFLOW_FILE --json databaseId,createdAt,event -L 15
  $RUNNERCTL_BIN --output json runner list --active                   # poll up to ${JOB_START_TIMEOUT}s for state jobRunning
  gh run cancel <run-id> -R "$REPO"
  gh run view <run-id> -R "$REPO" --json status,conclusion            # poll up to 120s for completed
  $RUNNERCTL_BIN --output json vm list                                # poll up to ${LEFTOVER_TIMEOUT}s: 0 instances of $PROFILE
  $RUNNERCTL_BIN --output json runner list --active                   # poll: 0 active sessions of $PROFILE
PLAN
}

plan_restart-while-booting() {
  cat <<PLAN
  gh workflow run $WORKFLOW_FILE -R "$REPO" -f job=quick -f count=1 -f profile=$PROFILE
  gh run list -R "$REPO" --workflow=$WORKFLOW_FILE --json databaseId,createdAt,event -L 15
  $RUNNERCTL_BIN --output json vm list                                # poll up to ${BOOT_WINDOW_TIMEOUT}s for state in
                                                                       # startingWorker/startingVM/waitingForAgent
  launchctl kickstart -k gui/$(id -u)/com.runnervm.runnerd            # or --restart-cmd
  $RUNNERCTL_BIN --output json status                                 # poll up to 60s for the daemon to answer again
  gh run view <run-id> -R "$REPO" --json status,conclusion            # poll every ${RUN_POLL_INTERVAL}s up to ${RUN_TIMEOUT}s
  $RUNNERCTL_BIN --output json vm list                                # assert 0 instances of $PROFILE
PLAN
}

plan_restart-during-job() {
  cat <<PLAN
  gh workflow run $WORKFLOW_FILE -R "$REPO" -f job=long -f count=1 -f profile=$PROFILE
  $RUNNERCTL_BIN --output json runner list --active                   # poll up to ${JOB_START_TIMEOUT}s for state jobRunning
  launchctl kickstart -k gui/$(id -u)/com.runnervm.runnerd            # or --restart-cmd
  $RUNNERCTL_BIN --output json status                                 # poll up to 60s for the daemon to answer again
  gh run view <run-id> -R "$REPO" --json status,conclusion            # poll every ${RUN_POLL_INTERVAL}s up to ${RUN_TIMEOUT}s
  $RUNNERCTL_BIN --output json runner list                            # assert <= 1 session with a github runner id for this job
  $RUNNERCTL_BIN --output json vm list                                # assert 0 instances of $PROFILE
PLAN
}

plan_redelivery() {
  cat <<PLAN
  # best-effort: no runnerd.log line marks "JobAvailable received, not yet acked" (see
  # docs/live-integration.md); the restart delay below is a fixed guess, not a real signal.
  gh workflow run $WORKFLOW_FILE -R "$REPO" -f job=quick -f count=1 -f profile=$PROFILE
  sleep ${REDELIVERY_RESTART_DELAY}
  launchctl kickstart -k gui/$(id -u)/com.runnervm.runnerd            # or --restart-cmd
  $RUNNERCTL_BIN --output json status                                 # poll up to 60s for the daemon to answer again
  gh run view <run-id> -R "$REPO" --json status,conclusion            # poll every ${RUN_POLL_INTERVAL}s up to ${RUN_TIMEOUT}s
  $RUNNERCTL_BIN --output json vm list --all                          # assert exactly 1 instance was created for $PROFILE
PLAN
}

plan_long-job() {
  local half=$((LONG_MINUTES * 60 / 2)) timeout=$(((LONG_MINUTES + 15) * 60))
  cat <<PLAN
  gh workflow run $WORKFLOW_FILE -R "$REPO" -f job=long -f count=1 -f profile=$PROFILE
  $RUNNERCTL_BIN --output json runner list --active                   # poll up to ${JOB_START_TIMEOUT}s for state jobRunning
  sleep $half                                                         # halfway through the expected $LONG_MINUTES-minute job
  $RUNNERCTL_BIN --output json vm show <instance-id>                  # assert state is not stopped/deleted (JobCompleted
                                                                       # arriving early must not tear the VM down)
  gh run view <run-id> -R "$REPO" --json status,conclusion            # poll every ${RUN_POLL_INTERVAL}s up to ${timeout}s
  $RUNNERCTL_BIN --output json vm list                                # assert 0 instances of $PROFILE
PLAN
}

plan_concurrent() {
  cat <<PLAN
  $RUNNERCTL_BIN --output json profile show $PROFILE                  # or scaleset list; resolves advertised capacity
  gh workflow run $WORKFLOW_FILE -R "$REPO" -f job=matrix -f count=$CONCURRENCY -f profile=$PROFILE
  $RUNNERCTL_BIN --output json vm list                                # sampled every 3s while the run is in progress; peak kept
  gh run view <run-id> -R "$REPO" --json status,conclusion            # poll every ${RUN_POLL_INTERVAL}s up to ${RUN_TIMEOUT}s
                                                                       # assert peak VM count <= advertised capacity
  $RUNNERCTL_BIN --output json vm list                                # assert 0 instances of $PROFILE
PLAN
}

plan_queue-overflow() {
  cat <<PLAN
  $RUNNERCTL_BIN --output json profile show $PROFILE                  # or scaleset list; resolves advertised capacity, N = 2x it
  gh workflow run $WORKFLOW_FILE -R "$REPO" -f job=matrix -f count=<2x capacity> -f profile=$PROFILE
  $RUNNERCTL_BIN --output json vm list                                # sampled every 3s while the run is in progress; peak kept
  gh run view <run-id> -R "$REPO" --json status,conclusion            # poll up to $((RUN_TIMEOUT * 2))s
                                                                       # assert peak VM count never exceeded advertised capacity
  $RUNNERCTL_BIN --output json vm list                                # assert 0 instances of $PROFILE
PLAN
}

# --------------------------------------------------------------------------
# Scenarios. Each returns 0 (pass) or 1 (fail); run_scenarios logs start/end and records the
# result. Every rc/gh query that feeds a bare `var=$(...)` assignment is guarded (see the note
# above profile_capacity) so a transient failure fails just this scenario, not the whole suite.
# --------------------------------------------------------------------------
scenario_success() {
  local before run_id conclusion
  before=$(date +%s)
  dispatch_workflow quick 1
  run_id=$(find_dispatched_run "$before") || { warn "could not locate the dispatched run"; return 1; }
  log "run $run_id dispatched"
  conclusion=$(wait_for_run_conclusion "$run_id" "$RUN_TIMEOUT") \
    || { warn "run $run_id did not complete within ${RUN_TIMEOUT}s"; return 1; }
  [ "$conclusion" = "success" ] || { warn "run $run_id concluded '$conclusion', expected success"; return 1; }
  assert_no_leftovers "$PROFILE" "$LEFTOVER_TIMEOUT" || return 1
  scale_set_idle "$PROFILE" || { warn "scale set for $PROFILE still shows assigned jobs"; return 1; }
  return 0
}

scenario_cancel-before-assignment() {
  local before run_id
  system_drain 30 || { warn "system drain failed"; return 1; }
  before=$(date +%s)
  dispatch_workflow quick 1
  run_id=$(find_dispatched_run "$before") \
    || { warn "could not locate the dispatched run"; system_resume || true; return 1; }
  sleep "$PRE_CANCEL_GRACE"
  gh_cancel_run "$run_id" || warn "gh run cancel returned nonzero (run may already be settling)"
  system_resume || warn "system resume failed"
  wait_for_run_conclusion "$run_id" 120 >/dev/null || true
  assert_no_leftovers "$PROFILE" "$LEFTOVER_TIMEOUT" || return 1
  return 0
}

scenario_cancel-during-job() {
  local before run_id
  before=$(date +%s)
  dispatch_workflow long 1
  run_id=$(find_dispatched_run "$before") || { warn "could not locate the dispatched run"; return 1; }
  wait_for_session_instance "$PROFILE" "$JOB_START_TIMEOUT" >/dev/null \
    || { warn "no session reached jobRunning within ${JOB_START_TIMEOUT}s"; return 1; }
  gh_cancel_run "$run_id" || { warn "gh run cancel failed"; return 1; }
  wait_for_run_conclusion "$run_id" 120 >/dev/null || true
  assert_no_leftovers "$PROFILE" "$LEFTOVER_TIMEOUT" || return 1
  return 0
}

scenario_restart-while-booting() {
  local before run_id conclusion
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
  assert_no_leftovers "$PROFILE" "$LEFTOVER_TIMEOUT" || return 1
  return 0
}

scenario_restart-during-job() {
  local before run_id conclusion sessions
  before=$(date +%s)
  dispatch_workflow long 1
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
       and ((.createdAt|fromdateiso8601) >= $before))] | length' 2>/dev/null) \
    || { warn "could not query runner list to check for a duplicate runner"; return 1; }
  [ "$sessions" -le 1 ] || { warn "found $sessions runner session(s) for one job; expected at most 1"; return 1; }
  assert_no_leftovers "$PROFILE" "$LEFTOVER_TIMEOUT" || return 1
  return 0
}

scenario_redelivery() {
  local before run_id conclusion vms
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
    '[.instances[] | select(.profile==$p and ((.createdAt|fromdateiso8601) >= $before))] | length' 2>/dev/null) \
    || { warn "could not query vm list to check for a duplicate instance"; return 1; }
  [ "$vms" -le 1 ] || { warn "saw $vms instance(s) for one job; possible duplicate from redelivery"; return 1; }
  assert_no_leftovers "$PROFILE" "$LEFTOVER_TIMEOUT" || return 1
  return 0
}

scenario_long-job() {
  local before run_id conclusion timeout half instance_id instance_state
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
  assert_no_leftovers "$PROFILE" "$LEFTOVER_TIMEOUT" || return 1
  return 0
}

scenario_concurrent() {
  local before run_id conclusion cap peak
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
  assert_no_leftovers "$PROFILE" "$LEFTOVER_TIMEOUT" || return 1
  return 0
}

scenario_queue-overflow() {
  local before run_id conclusion cap n peak
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
  assert_no_leftovers "$PROFILE" "$LEFTOVER_TIMEOUT" || return 1
  return 0
}

# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------
report_init() { REPORT_TMP=$(mktemp); }

record_result() {
  local name="$1" status="$2" started="$3" ended="$4" detail="${5:-}"
  jq -n --arg name "$name" --arg status "$status" \
    --arg startedAt "$(date -u -r "$started" +%Y-%m-%dT%H:%M:%SZ)" \
    --arg endedAt "$(date -u -r "$ended" +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson durationSeconds "$((ended - started))" --arg detail "$detail" \
    '{name:$name,status:$status,startedAt:$startedAt,endedAt:$endedAt,
      durationSeconds:$durationSeconds,detail:$detail}' \
    >>"$REPORT_TMP"
}

write_report() {
  local out
  out="$JSON_REPORT"
  [ -n "$out" ] || out="$STATE_DIR/logs/e2e-report-$(date -u +%Y%m%dT%H%M%SZ).json"
  mkdir -p "$(dirname "$out")"
  jq -n --arg owner "$OWNER" --arg repo "$REPO" --arg profile "$PROFILE" \
    --slurpfile scenarios "$REPORT_TMP" \
    '{owner:$owner,repo:$repo,profile:$profile,scenarios:$scenarios}' >"$out"
  rm -f "$REPORT_TMP"
  log "report written to $out"
}

# --------------------------------------------------------------------------
# Dispatch loop / entry point
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
