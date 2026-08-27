#!/usr/bin/env bash
# Builder fault injection for RunnerVM: SIGKILL a live runnerd in the middle of a real image build,
# restart it, and prove the restarted daemon converges (TODO.md WP8).
#
# This is the live twin of Tests/OrchestrationTests/ImageBuildFaultInjectionTests.swift. Those
# freeze an in-process builder at a hook; this kills a real `runnerd --foreground` with a real
# vmworker and a real VM behind it, once per observable build state, and asserts through
# runnerctl's JSON what the operator would see afterwards: a terminal row, one image at most for
# the built name, no vmworker left running, no build directory, and host capacity back where it
# started.
#
# Manually triggered, opt-in: it boots real VMs and is NOT part of `swift test` or CI. Read
# docs/live-integration.md before the first run. Requires: jq, a built runnerctl and runnerd.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --------------------------------------------------------------------------
# Defaults, env, flags
# --------------------------------------------------------------------------
STATE_DIR="$HOME/Library/Application Support/RunnerVM"
SOCKET_DIR=""
SOCKET=""
RECIPE=""
NAME=""
PUSH=""
CONFIG=""
RUNNERD_CMD=""
JSON_REPORT=""
DRY_RUN=0

PHASES=()
# The `image_builds.state` values a build passes through, in order. `pushing` is not a build state:
# it is "succeeded, with the separate push-image operation not yet started", so it needs --push.
ALL_PHASES=(queued resolving staging booting provisioning sealing)

# Seconds. A build whose vmworker cannot be proven dead stays pending until that worker's own
# lease + orphan-idle backstop (~630 s) fires, so the settle bound has to clear runnerd's
# recoveryDeadline (900 s) rather than a human's patience.
PHASE_TIMEOUT="${RUNNERVM_FAULTS_PHASE_TIMEOUT:-1800}"
SETTLE_TIMEOUT="${RUNNERVM_FAULTS_SETTLE_TIMEOUT:-900}"
WORKER_EXIT_TIMEOUT="${RUNNERVM_FAULTS_WORKER_EXIT_TIMEOUT:-900}"
DAEMON_UP_TIMEOUT="${RUNNERVM_FAULTS_DAEMON_UP_TIMEOUT:-60}"
POLL_INTERVAL="${RUNNERVM_FAULTS_POLL_INTERVAL:-0.2}"

FAIL_COUNT=0
REPORT_TMP=""
RUNNERD_PID=""
DAEMON_LOG=""
BASE_CPU=""
BASE_MEMORY=""
BASE_DISK=""

find_tool() {
  local name="$1" candidate
  for candidate in "$REPO_ROOT/.build/debug/$name" "$REPO_ROOT/.build/release/$name"; do
    if [ -x "$candidate" ]; then printf '%s' "$candidate"; return 0; fi
  done
  command -v "$name" 2>/dev/null || true
}
RUNNERCTL_BIN="${RUNNERCTL:-$(find_tool runnerctl)}"
RUNNERD_BIN="${RUNNERD:-$(find_tool runnerd)}"

# --------------------------------------------------------------------------
# Logging
# --------------------------------------------------------------------------
log()  { printf '[faults] %s\n' "$*"; }
warn() { printf '[faults] warning: %s\n' "$*" >&2; }
die()  { printf '[faults] error: %s\n' "$*" >&2; exit 2; }

usage() {
  cat <<'USAGE'
usage: live-builder-faults.sh --recipe <path> --phase <state> [--phase <state> ...] [options]
       live-builder-faults.sh --recipe <path> --phase all [options]

Kills a live runnerd with SIGKILL at each image-build phase and asserts the restarted daemon
converges: terminal row, no duplicate image, no leaked vmworker, no leaked build directory,
capacity back to baseline. Boots real VMs; read docs/live-integration.md first.

Options:
  --recipe <path>        Recipe file (or directory holding one) to build. Required.
  --name <name>          Local image name to build under (default: faults-<timestamp>).
  --phase <state>        Phase to kill the daemon at. Repeatable. One of:
                           queued resolving staging booting provisioning sealing pushing
                         "all" expands to every phase (pushing only with --push).
  --push <reference>     Registry reference to push to; required for the "pushing" phase.
  --state-dir <dir>      RunnerVM state root, passed to runnerd and used to locate
                          state/builds/<id> (default: $HOME/Library/Application Support/RunnerVM).
  --socket-dir <dir>     Directory holding runnerd.sock; passed to runnerd and to runnerctl.
  --config <path>        Configuration file handed to runnerd at startup.
  --runnerd-cmd <cmd>    Shell command that runs runnerd in the foreground. Default:
                          "<repo>/.build/debug/runnerd --foreground --state-dir ...". The command
                          is exec'd, so its pid is the one this script SIGKILLs.
  --json-report <path>   Where to write the JSON report
                          (default: <state-dir>/logs/builder-faults-<timestamp>.json).
  --dry-run              Print the commands each selected phase would run; touches nothing and
                          needs no daemon, no jq and no built binaries.
  -h, --help             Show this help.

Timeout overrides (seconds): RUNNERVM_FAULTS_PHASE_TIMEOUT (reach the target phase),
RUNNERVM_FAULTS_SETTLE_TIMEOUT (row terminal after the restart), RUNNERVM_FAULTS_WORKER_EXIT_TIMEOUT
(orphaned vmworker to exit), RUNNERVM_FAULTS_DAEMON_UP_TIMEOUT, RUNNERVM_FAULTS_POLL_INTERVAL.
RUNNERCTL and RUNNERD override the binary paths (default: .build/debug, then .build/release, then
PATH).
USAGE
}

# --------------------------------------------------------------------------
# Argument parsing / validation
# --------------------------------------------------------------------------
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
    --recipe) RECIPE="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --phase) PHASES+=("$2"); shift 2 ;;
    --push) PUSH="$2"; shift 2 ;;
    --state-dir) STATE_DIR="$2"; shift 2 ;;
    --socket-dir) SOCKET_DIR="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --runnerd-cmd) RUNNERD_CMD="$2"; shift 2 ;;
    --json-report) JSON_REPORT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
  done
}

is_known_phase() {
  local name="$1" candidate
  for candidate in "${ALL_PHASES[@]}" pushing; do
    [ "$candidate" = "$name" ] && return 0
  done
  return 1
}

expand_phases() {
  local name expanded=()
  for name in "${PHASES[@]}"; do
    if [ "$name" = "all" ]; then
      expanded+=("${ALL_PHASES[@]}")
      if [ -n "$PUSH" ]; then expanded+=(pushing); fi
    else
      expanded+=("$name")
    fi
  done
  PHASES=("${expanded[@]}")
}

validate_args() {
  [ ${#PHASES[@]} -gt 0 ] || die "pass --phase <state> (repeatable) or --phase all; see --help"
  expand_phases
  local name
  for name in "${PHASES[@]}"; do
    is_known_phase "$name" || die "unknown phase: $name (see --help for the list)"
    if [ "$name" = "pushing" ] && [ -z "$PUSH" ]; then
      die "--phase pushing needs --push <reference>: there is nothing to push otherwise"
    fi
  done
  [ -n "$SOCKET_DIR" ] && SOCKET="$SOCKET_DIR/runnerd.sock"
  [ -n "$NAME" ] || NAME="faults-$(date -u +%Y%m%dT%H%M%SZ)"
  return 0
}

require_tools() {
  local missing=()
  command -v jq >/dev/null 2>&1 || missing+=("jq (brew install jq)")
  if [ -z "$RUNNERCTL_BIN" ] || [ ! -x "$RUNNERCTL_BIN" ]; then
    missing+=("runnerctl (swift build, or set RUNNERCTL=/path/to/runnerctl)")
  fi
  if [ -z "$RUNNERD_CMD" ] && { [ -z "$RUNNERD_BIN" ] || [ ! -x "$RUNNERD_BIN" ]; }; then
    missing+=("runnerd (swift build, set RUNNERD=/path/to/runnerd, or pass --runnerd-cmd)")
  fi
  [ ${#missing[@]} -eq 0 ] || die "missing tools: ${missing[*]}"
  [ -n "$RECIPE" ] || die "--recipe <path> is required"
  [ -e "$RECIPE" ] || die "recipe not found: $RECIPE"
}

# --------------------------------------------------------------------------
# runnerctl helpers
#
# Every $(...) that polls runnerctl is guarded with `|| var=<fallback>`: a bare assignment is a
# simple command, so under `set -e` a transient failure while the daemon is restarting would abort
# the whole run instead of just this poll. The fallback always means "not converged yet".
# --------------------------------------------------------------------------
rc() {
  local -a cmd
  cmd=("$RUNNERCTL_BIN")
  if [ -n "$SOCKET" ]; then cmd+=(--socket "$SOCKET"); fi
  cmd+=(--output json)
  cmd+=("$@")
  "${cmd[@]}"
}

build_json() {
  rc build show "$1" 2>/dev/null || true
}

build_field() {
  local json="$1" filter="$2" value
  value=$(printf '%s' "$json" | jq -r "$filter // empty" 2>/dev/null) || value=""
  printf '%s' "$value"
}

is_terminal_state() {
  case "$1" in
  succeeded | failed | cancelled) return 0 ;;
  *) return 1 ;;
  esac
}

# --------------------------------------------------------------------------
# Daemon lifecycle
# --------------------------------------------------------------------------
daemon_command() {
  if [ -n "$RUNNERD_CMD" ]; then printf '%s' "$RUNNERD_CMD"; return 0; fi
  local cmd
  cmd="$(printf '%q' "$RUNNERD_BIN") --foreground --state-dir $(printf '%q' "$STATE_DIR")"
  if [ -n "$SOCKET_DIR" ]; then cmd="$cmd --socket-dir $(printf '%q' "$SOCKET_DIR")"; fi
  if [ -n "$CONFIG" ]; then cmd="$cmd --config $(printf '%q' "$CONFIG")"; fi
  printf '%s' "$cmd"
}

start_daemon() {
  mkdir -p "$(dirname "$DAEMON_LOG")"
  # `exec` so $! is runnerd itself and not the shell wrapping it: this script SIGKILLs that pid,
  # and killing a wrapper would leave the daemon (and its vmworkers) running.
  sh -c "exec $(daemon_command)" >>"$DAEMON_LOG" 2>&1 &
  RUNNERD_PID=$!
  wait_for_daemon_up "$DAEMON_UP_TIMEOUT" \
    || die "runnerd did not answer within ${DAEMON_UP_TIMEOUT}s; see $DAEMON_LOG"
  log "runnerd up (pid $RUNNERD_PID)"
}

wait_for_daemon_up() {
  local deadline
  deadline=$(($(date +%s) + "${1:-60}"))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if rc status >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

kill_daemon() {
  [ -n "$RUNNERD_PID" ] || return 0
  log "SIGKILL runnerd (pid $RUNNERD_PID)"
  kill -9 "$RUNNERD_PID" 2>/dev/null || true
  wait "$RUNNERD_PID" 2>/dev/null || true
  RUNNERD_PID=""
}

cleanup() {
  if [ -n "$RUNNERD_PID" ]; then
    kill "$RUNNERD_PID" 2>/dev/null || true
    wait "$RUNNERD_PID" 2>/dev/null || true
  fi
  [ -n "$REPORT_TMP" ] && rm -f "$REPORT_TMP"
  return 0
}

# --------------------------------------------------------------------------
# Waits
# --------------------------------------------------------------------------

# Polls `build show` until `.state` is the target. `pushing` is not a state: it is "succeeded with
# a push operation attached", which is the last instant before the push would have been started.
wait_for_phase() {
  local id="$1" phase="$2" deadline json state push
  deadline=$(($(date +%s) + PHASE_TIMEOUT))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    json=$(build_json "$id")
    state=$(build_field "$json" '.state')
    if [ "$phase" = "pushing" ]; then
      push=$(build_field "$json" '.pushOperationId')
      if [ -n "$push" ]; then return 0; fi
    elif [ "$state" = "$phase" ]; then
      return 0
    fi
    if [ "$phase" != "pushing" ] && is_terminal_state "$state"; then
      warn "build reached '$state' without ever being observed in '$phase'"
      return 1
    fi
    sleep "$POLL_INTERVAL"
  done
  warn "build did not reach '$phase' within ${PHASE_TIMEOUT}s"
  return 1
}

# Polls until the row is terminal. Records, through PENDING_SEEN, whether recovery ever had to hold
# the build pending first -- a legitimate outcome (the vmworker was not yet proven dead), not a
# failure, but one worth having in the report.
PENDING_SEEN="no"
wait_for_settled() {
  local id="$1" deadline json state pending
  PENDING_SEEN="no"
  deadline=$(($(date +%s) + SETTLE_TIMEOUT))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    json=$(build_json "$id")
    state=$(build_field "$json" '.state')
    pending=$(build_field "$json" '.recoverySince')
    if [ -n "$pending" ]; then PENDING_SEEN="yes"; fi
    if is_terminal_state "$state"; then return 0; fi
    sleep 1
  done
  warn "build $id was still '$state' after ${SETTLE_TIMEOUT}s (pending=$PENDING_SEEN)"
  return 1
}

wait_for_worker_exit() {
  local id="$1" deadline
  deadline=$(($(date +%s) + WORKER_EXIT_TIMEOUT))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if ! worker_running "$id"; then return 0; fi
    sleep 1
  done
  warn "a vmworker for $id was still running after ${WORKER_EXIT_TIMEOUT}s"
  return 1
}

worker_running() {
  pgrep -f "vmworker.*$1" >/dev/null 2>&1
}

# --------------------------------------------------------------------------
# Assertions
# --------------------------------------------------------------------------
capture_baseline() {
  local json
  json=$(rc status) || die "runnerctl status failed"
  BASE_CPU=$(echo "$json" | jq -r '.capacity.reservedCPUCount')
  BASE_MEMORY=$(echo "$json" | jq -r '.capacity.reservedMemoryBytes')
  BASE_DISK=$(echo "$json" | jq -r '.capacity.reservedDiskBytes')
  log "capacity baseline: cpu=$BASE_CPU memory=$BASE_MEMORY disk=$BASE_DISK"
}

# The row is terminal, and if it did not succeed it failed for the one reason a restart may cause.
assert_row_converged() {
  local id="$1" phase="$2" json state code
  json=$(build_json "$id")
  state=$(build_field "$json" '.state')
  code=$(build_field "$json" '.failureCode')
  is_terminal_state "$state" || { warn "build $id is '$state', not terminal"; return 1; }
  if [ "$phase" = "pushing" ]; then
    [ "$state" = "succeeded" ] || { warn "build killed after sealing is '$state'"; return 1; }
    return 0
  fi
  case "$state:$code" in
  succeeded:) return 0 ;;
  failed:BUILD_INTERRUPTED) return 0 ;;
  failed:BUILD_RECOVERY_ABANDONED)
    warn "build $id was abandoned rather than proven dead (its worker never released the lock)"
    return 1
    ;;
  *) warn "build $id ended '$state' with failureCode '${code:-none}'"; return 1 ;;
  esac
}

# At most one image answers to the built name -- a replayed registration must never publish a
# second -- and if the build succeeded that image is inspectable, i.e. actually in the store.
assert_image_catalogue() {
  local id="$1" json state count
  json=$(build_json "$id")
  state=$(build_field "$json" '.state')
  count=$(rc image list 2>/dev/null | jq --arg n "$NAME" \
    '[.images[] | select(.name==$n)] | length' 2>/dev/null) || count=""
  [ -n "$count" ] || { warn "runnerctl image list failed"; return 1; }
  [ "$count" -le 1 ] || { warn "$count images answer to '$NAME'; expected at most one"; return 1; }
  if [ "$state" = "succeeded" ]; then
    [ "$count" -eq 1 ] || { warn "a succeeded build left no image named '$NAME'"; return 1; }
    rc image inspect "$NAME" >/dev/null 2>&1 \
      || { warn "image inspect '$NAME' failed: the registered image is not readable"; return 1; }
  else
    [ "$count" -eq 0 ] || { warn "a non-succeeded build published an image named '$NAME'"; return 1; }
  fi
  return 0
}

assert_no_leftovers() {
  local id="$1" json directory
  ! worker_running "$id" || { warn "a vmworker for $id is still running"; return 1; }
  directory="$STATE_DIR/state/builds/$id"
  [ ! -e "$directory" ] || { warn "build directory left behind: $directory"; return 1; }
  json=$(rc status) || { warn "runnerctl status failed"; return 1; }
  echo "$json" | jq -e '(.builds.running // 0) == 0 and (.builds.queued // 0) == 0' >/dev/null \
    || { warn "status still reports builds: $(echo "$json" | jq -c '.builds')"; return 1; }
  echo "$json" | jq -e --argjson cpu "$BASE_CPU" --argjson memory "$BASE_MEMORY" \
    --argjson disk "$BASE_DISK" \
    '.capacity.reservedCPUCount==$cpu and .capacity.reservedMemoryBytes==$memory
     and .capacity.reservedDiskBytes==$disk' >/dev/null \
    || { warn "capacity did not return to baseline: $(echo "$json" | jq -c '.capacity')"; return 1; }
  return 0
}

# --------------------------------------------------------------------------
# One phase
# --------------------------------------------------------------------------
start_build() {
  local -a cmd
  cmd=(image build "$RECIPE" --name "$NAME" --no-wait)
  if [ -n "$PUSH" ]; then cmd+=(--push "$PUSH"); fi
  rc "${cmd[@]}" | jq -r '.buildId // empty'
}

run_phase() {
  local phase="$1" id
  [ -n "$RUNNERD_PID" ] || start_daemon
  id=$(start_build) || { warn "runnerctl image build failed"; return 1; }
  [ -n "$id" ] || { warn "runnerctl image build returned no build id"; return 1; }
  log "build $id started; waiting for phase '$phase'"
  PHASE_BUILD_ID="$id"

  wait_for_phase "$id" "$phase" || return 1
  kill_daemon
  start_daemon
  wait_for_settled "$id" || return 1
  wait_for_worker_exit "$id" || return 1

  assert_row_converged "$id" "$phase" || return 1
  assert_image_catalogue "$id" || return 1
  assert_no_leftovers "$id" || return 1
  return 0
}

# --------------------------------------------------------------------------
# --dry-run plan: every phase runs the same command sequence, so one plan covers them all.
# --------------------------------------------------------------------------
plan_phase() {
  local phase="$1" target
  if [ "$phase" = "pushing" ]; then
    target='.pushOperationId != null'
  else
    target=".state == \"$phase\""
  fi
  cat <<PLAN
  $(daemon_command)                                   # started in the background, pid recorded
  runnerctl build show <id> --output json             # poll every ${POLL_INTERVAL}s until $target
  kill -9 <runnerd-pid>                               # the crash
  $(daemon_command)                                   # the restart
  runnerctl build show <id> --output json             # poll until .state is terminal (<= ${SETTLE_TIMEOUT}s)
  pgrep -f "vmworker.*<id>"                           # poll until empty (<= ${WORKER_EXIT_TIMEOUT}s)
  runnerctl image list --output json                  # assert <= 1 image named "$NAME"
  runnerctl image inspect "$NAME" --output json       # assert readable when the build succeeded
  runnerctl status --output json                      # assert builds running 0 / queued 0
  test ! -e "$STATE_DIR/state/builds/<id>"            # assert no leaked build directory
PLAN
}

# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------
report_init() { REPORT_TMP=$(mktemp); }

record_result() {
  local phase="$1" status="$2" started="$3" ended="$4" detail="${5:-}"
  jq -n --arg phase "$phase" --arg status "$status" \
    --arg startedAt "$(date -u -r "$started" +%Y-%m-%dT%H:%M:%SZ)" \
    --arg endedAt "$(date -u -r "$ended" +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson durationSeconds "$((ended - started))" --arg detail "$detail" \
    '{phase:$phase,status:$status,startedAt:$startedAt,endedAt:$endedAt,
      durationSeconds:$durationSeconds,detail:$detail}' \
    >>"$REPORT_TMP"
}

write_report() {
  local out
  out="$JSON_REPORT"
  [ -n "$out" ] || out="$STATE_DIR/logs/builder-faults-$(date -u +%Y%m%dT%H%M%SZ).json"
  mkdir -p "$(dirname "$out")"
  jq -n --arg recipe "$RECIPE" --arg name "$NAME" --arg stateDir "$STATE_DIR" \
    --arg daemonLog "$DAEMON_LOG" --slurpfile phases "$REPORT_TMP" \
    '{recipe:$recipe,name:$name,stateDir:$stateDir,daemonLog:$daemonLog,phases:$phases}' >"$out"
  rm -f "$REPORT_TMP"
  REPORT_TMP=""
  log "report written to $out"
}

# --------------------------------------------------------------------------
# Dispatch loop / entry point
# --------------------------------------------------------------------------
PHASE_BUILD_ID=""

run_phases() {
  local phase started ended status rc_val detail
  for phase in "${PHASES[@]}"; do
    if [ "$DRY_RUN" -eq 1 ]; then
      log "=== [dry-run] $phase ==="
      plan_phase "$phase"
      continue
    fi
    log "=== phase: $phase ==="
    PHASE_BUILD_ID=""
    started=$(date +%s)
    if run_phase "$phase"; then rc_val=0; else rc_val=$?; fi
    ended=$(date +%s)
    if [ "$rc_val" -eq 0 ]; then status="pass"; else status="fail"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi
    detail="build=${PHASE_BUILD_ID:-none} recoveryPending=$PENDING_SEEN"
    if [ -n "$PHASE_BUILD_ID" ]; then
      detail="$detail finalState=$(build_field "$(build_json "$PHASE_BUILD_ID")" '.state')"
    fi
    log "=== $phase: $status ($((ended - started))s) -- $detail ==="
    record_result "$phase" "$status" "$started" "$ended" "$detail"
  done
}

main() {
  parse_args "$@"
  validate_args
  DAEMON_LOG="$STATE_DIR/logs/builder-faults-runnerd.log"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "dry-run: nothing is started, killed or asserted; name=$NAME phases=${PHASES[*]}"
    run_phases
    log "dry-run complete"
    exit 0
  fi
  require_tools
  trap cleanup EXIT
  start_daemon
  capture_baseline
  report_init
  run_phases
  write_report
  [ "$FAIL_COUNT" -eq 0 ] || exit 1
}

main "$@"
