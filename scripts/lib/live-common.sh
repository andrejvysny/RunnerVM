# shellcheck shell=bash
# Shared bash helpers for RunnerVM's live E2E drivers (scripts/live-github-e2e.sh,
# scripts/live-builder-e2e.sh). Sourced, never executed: `source scripts/lib/live-common.sh`.
#
# Every function here reads its context (RUNNERCTL_BIN, SOCKET, OWNER, REPO, LEFTOVER_TIMEOUT,
# WORKFLOW_FILE, RUN_POLL_INTERVAL, STATE_DIR, JSON_REPORT, REPORT_TMP, PROFILE) from globals the
# sourcing script sets before calling it -- the same convention `rc()` already used before this
# split, so moving a function here changes where it lives, not how it is called. Nothing in this
# file sets `set -euo pipefail` itself; both callers already do, before sourcing this file.
#
# What stays script-local (not here): anything shaped around one driver's own scenario/workflow
# vocabulary -- e.g. live-github-e2e.sh's `dispatch_workflow` (e2e.yml's job/count/profile inputs;
# runnervm-selftest.yml's inputs are shaped differently: profile/sleep_seconds/fanout), its
# restart/kill helpers, its peak-VM monitor, and both drivers' own `--dry-run` plans, argument
# parsing and top-level scenario/step functions.

# --------------------------------------------------------------------------
# Logging
# --------------------------------------------------------------------------
# $LOG_PREFIX lets a non-e2e caller (scripts/publish-images.sh) label its own output without
# shadowing these three functions; both live drivers leave it unset and stay "[e2e]".
log()  { printf '[%s] %s\n' "${LOG_PREFIX:-e2e}" "$*"; }
warn() { printf '[%s] warning: %s\n' "${LOG_PREFIX:-e2e}" "$*" >&2; }
die()  { printf '[%s] error: %s\n' "${LOG_PREFIX:-e2e}" "$*" >&2; exit 2; }

# --------------------------------------------------------------------------
# runnerctl
# --------------------------------------------------------------------------

# Reads $REPO_ROOT (set by the sourcing script before it sources this file). $RUNNERCTL overrides
# outright; otherwise prefers a freshly built debug binary, falls back to release, then PATH.
find_runnerctl() {
  if [ -n "${RUNNERCTL:-}" ]; then printf '%s' "$RUNNERCTL"; return 0; fi
  local candidate
  for candidate in "$REPO_ROOT/.build/debug/runnerctl" "$REPO_ROOT/.build/release/runnerctl"; do
    if [ -x "$candidate" ]; then printf '%s' "$candidate"; return 0; fi
  done
  command -v runnerctl 2>/dev/null || true
}

# Always runs, JSON-only; the cmd array keeps at least one element so it is safe to expand under
# `set -u` on bash 3.2 (macOS's stock /bin/bash), which errors on "${empty_array[@]}".
rc() {
  local -a cmd
  cmd=("$RUNNERCTL_BIN")
  if [ -n "${SOCKET:-}" ]; then cmd+=(--socket "$SOCKET"); fi
  cmd+=(--output json)
  cmd+=("$@")
  "${cmd[@]}"
}

# Like rc(), but without forcing --output json: for commands whose human-mode output is itself a
# live stream a script wants to show as it happens (`image build --wait` interleaves the build log
# with progress; the daemon's own step-progress/log writes go straight to the fd regardless of
# --output, so JSON mode there would receive raw log text ahead of the trailing JSON object rather
# than clean, parseable output).
rc_human() {
  local -a cmd
  cmd=("$RUNNERCTL_BIN")
  if [ -n "${SOCKET:-}" ]; then cmd+=(--socket "$SOCKET"); fi
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
# "not found", never "assume success". Every function below follows the same convention.
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
# GitHub-side runner registration
# --------------------------------------------------------------------------

# GitHub-side runner count matching this profile's naming (rvm-<shortName>-<id>); best-effort,
# non-paginated (fine for a dedicated test org with a handful of runners). Reads $OWNER, $REPO.
github_runner_count() {
  local profile="$1" prefix org_count repo_count
  prefix="rvm-$(profile_short_name "$profile")"
  # `gh api` prints the error body on stdout for a 404 (a user login has no /orgs endpoint), so
  # a failed call must reset the count instead of appending "0" after the JSON.
  org_count=$(gh api "orgs/$OWNER/actions/runners" --jq \
    ".runners // [] | [.[] | select(.name | startswith(\"$prefix\"))] | length" 2>/dev/null) \
    || org_count=0
  repo_count=$(gh api "repos/$REPO/actions/runners" --jq \
    ".runners // [] | [.[] | select(.name | startswith(\"$prefix\"))] | length" 2>/dev/null) \
    || repo_count=0
  [[ "$org_count" =~ ^[0-9]+$ ]] || org_count=0
  [[ "$repo_count" =~ ^[0-9]+$ ]] || repo_count=0
  echo $((org_count + repo_count))
}

# $1=profile $2=timeout. Hard-fails once GitHub still lists a runner matching this profile's
# prefix after the deadline -- unlike assert_no_leftovers's own GitHub-runner check below, which
# only warns (GitHub's own runner-list can lag the daemon-side teardown by a few seconds, which is
# fine for a soft leftover check but not for a scenario whose whole point is proving the
# registration is gone).
wait_no_github_runner() {
  local profile="$1" timeout="$2" deadline now count
  deadline=$(($(date +%s) + timeout))
  while true; do
    now=$(date +%s)
    count=$(github_runner_count "$profile") || count=1
    [ "$count" -eq 0 ] && return 0
    [ "$now" -lt "$deadline" ] || return 1
    sleep 5
  done
}

# --------------------------------------------------------------------------
# Capacity baseline
# --------------------------------------------------------------------------

# $1=profile. Prints `runnerctl status`'s busy/idle/demand/starting for one profile
# (ProfileRuntimeSummary, Sources/DaemonAPI/SystemDTOs.swift) as one-line JSON, so two captures
# can be compared with a plain string `=`. "running" in the informal "running/busy/idle/demand"
# shorthand maps to busy+idle here: `system.status` has no separate "running" field, and
# busy+idle is exactly the VM count actually up for the profile.
capture_capacity_baseline() {
  rc status 2>/dev/null | jq -c --arg p "$1" \
    '([.profiles[] | select(.name==$p)][0] // {busy:0,idle:0,demand:0,starting:0})
     | {busy,idle,demand,starting}' 2>/dev/null || echo '{"busy":0,"idle":0,"demand":0,"starting":0}'
}

# $1=profile $2=timeout $3=capacity baseline JSON from capture_capacity_baseline (optional; empty
# skips the capacity comparison). 0 once no non-deleted instances, no active sessions, and (when a
# baseline was given) runnerctl status's busy/idle/demand/starting for the profile match it again.
assert_no_leftovers() {
  local profile="$1" timeout="${2:-$LEFTOVER_TIMEOUT}" baseline="${3:-}"
  local deadline now vms sessions gh_runners capacity capacity_ok
  deadline=$(($(date +%s) + timeout))
  vms=-1; sessions=-1; capacity=""; capacity_ok=1
  while true; do
    now=$(date +%s)
    vms=$(rc vm list 2>/dev/null | jq --arg p "$profile" \
      '[.instances[] | select(.profile==$p and .state!="deleted")] | length' 2>/dev/null) || vms=-1
    sessions=$(rc runner list --active 2>/dev/null | jq --arg p "$profile" \
      '[.sessions[] | select(.profile==$p)] | length' 2>/dev/null) || sessions=-1
    if [ -n "$baseline" ]; then
      capacity=$(capture_capacity_baseline "$profile")
      [ "$capacity" = "$baseline" ] && capacity_ok=0 || capacity_ok=1
    else
      capacity_ok=0
    fi
    { [ "$vms" -eq 0 ] && [ "$sessions" -eq 0 ] && [ "$capacity_ok" -eq 0 ]; } && break
    [ "$now" -lt "$deadline" ] || break
    sleep 5
  done
  if ! { [ "$vms" -eq 0 ] && [ "$sessions" -eq 0 ] && [ "$capacity_ok" -eq 0 ]; }; then
    warn "leftovers after ${timeout}s: $vms VM(s), $sessions active session(s) for profile $profile"
    if [ "$capacity_ok" -ne 0 ]; then
      warn "capacity did not converge: baseline $baseline now $capacity"
    fi
    return 1
  fi
  gh_runners=$(github_runner_count "$profile")
  [ "$gh_runners" -eq 0 ] \
    || warn "GitHub still lists $gh_runners runner(s) matching rvm-$(profile_short_name "$profile") (may lag briefly; not fatal)"
  return 0
}

# --------------------------------------------------------------------------
# Workflow run polling (reads $REPO, $WORKFLOW_FILE, $RUN_POLL_INTERVAL)
# --------------------------------------------------------------------------

# $1 = epoch seconds right before dispatch. Prints the new run's databaseId. Works for any
# workflow file named in $WORKFLOW_FILE -- only the dispatch inputs differ between drivers.
find_dispatched_run() {
  local before="$1" tries=0 id
  while [ "$tries" -lt 30 ]; do
    id=$(gh run list -R "$REPO" --workflow="$WORKFLOW_FILE" \
        --json databaseId,createdAt,event -L 15 2>/dev/null \
      | jq -r --argjson before "$before" '
          [ .[] | select(.event=="workflow_dispatch")
                 | select((.createdAt | sub("\\.[0-9]+"; "") | fromdateiso8601) >= $before) ]
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

# --------------------------------------------------------------------------
# Shared preconditions
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

check_gh_cli_auth() {
  gh auth status >/dev/null 2>&1 \
    || die "gh auth status failed; run 'gh auth login' or check RUNNERVM_GITHUB_TOKEN"
  gh repo view "$REPO" >/dev/null 2>&1 \
    || die "gh cannot see repo '$REPO'; check token scope and the repo name"
}

# --------------------------------------------------------------------------
# JSON report (reads $OWNER, $REPO, $PROFILE, $JSON_REPORT, $STATE_DIR; writes/reads $REPORT_TMP)
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
  # shellcheck disable=SC2153 # $PROFILE is set by the sourcing script, not a typo'd $profile
  jq -n --arg owner "$OWNER" --arg repo "$REPO" --arg profile "$PROFILE" \
    --slurpfile scenarios "$REPORT_TMP" \
    '{owner:$owner,repo:$repo,profile:$profile,scenarios:$scenarios}' >"$out"
  rm -f "$REPORT_TMP"
  log "report written to $out"
}
