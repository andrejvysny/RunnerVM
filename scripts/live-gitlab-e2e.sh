#!/usr/bin/env bash
# Live GitLab E2E for RunnerVM's fleeting integration. Opt-in, never part of CI or `swift test`.
#
# Creates a throwaway project runner on a real GitLab project, starts gitlab-runner with the
# autoscaler config pointing at `fleeting-plugin-runnervm`, triggers one pipeline from
# docs/e2e/gitlab-ci.yml, asserts it succeeds inside a RunnerVM VM, then asserts every fleet VM of
# the profile is gone again. Cleanup (stop gitlab-runner, delete the runner, remove temp files)
# runs from a trap, including after a failure.
#
# Read docs/gitlab.md and docs/live-integration.md first: the project must already contain
# docs/e2e/gitlab-ci.yml as .gitlab-ci.yml. Requires: gitlab-runner, curl, jq, a built runnerctl,
# `fleeting-plugin-runnervm` on PATH, and a running daemon with a `provider: gitlab` profile.
#
# Exit codes: 0 pass; 1 pipeline did not succeed; 2 usage/config error; 3 preflight failed;
# 4 GitLab API or gitlab-runner failure; 5 pipeline timed out; 6 fleet VMs left over.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/lib/live-common.sh
# shellcheck disable=SC1091 # dynamic path; run shellcheck -x to actually follow it
source "$REPO_ROOT/scripts/lib/live-common.sh"

GITLAB_URL="${RUNNERVM_E2E_GITLAB_URL:-https://gitlab.com}"
PROJECT="${RUNNERVM_E2E_GITLAB_PROJECT:-}"
TOKEN="${RUNNERVM_E2E_GITLAB_TOKEN:-}"
PROFILE="${RUNNERVM_E2E_GITLAB_PROFILE:-}"
EXECUTOR="${RUNNERVM_E2E_GITLAB_EXECUTOR:-instance}"
# shellcheck disable=SC2034 # consumed by rc() in scripts/lib/live-common.sh
SOCKET="${RUNNERVM_E2E_SOCKET:-}"
DRY_RUN="${RUNNERVM_E2E_DRY_RUN:-0}"
GITLAB_RUNNER_BIN="${RUNNERVM_E2E_GITLAB_RUNNER:-gitlab-runner}"
PIPELINE_TIMEOUT="${RUNNERVM_E2E_PIPELINE_TIMEOUT:-1200}"
LEFTOVER_TIMEOUT="${RUNNERVM_E2E_LEFTOVER_TIMEOUT:-180}"
POLL_INTERVAL="${RUNNERVM_E2E_POLL_INTERVAL:-5}"
LEASE="${RUNNERVM_E2E_GITLAB_LEASE:-10m}"
RUNNER_TAG="runnervm-e2e"
DOCKER_IMAGE="alpine:3.20"

WORKDIR=""
HEADER_FILE=""
RUNNER_ID=""
RUNNER_PID=""
PROJECT_ENC=""
PROJECT_ID=""
DEFAULT_BRANCH=""
GUEST_OS=""
RUNNERCTL_BIN="$(find_runnerctl)"

usage() {
  cat <<'USAGE'
usage: live-gitlab-e2e.sh [--dry-run] [-h|--help]

Live GitLab E2E for RunnerVM's gitlab-runner fleeting plugin. Opt-in; talks to a real GitLab
project. Read docs/gitlab.md and docs/live-integration.md before the first run.

Required environment:
  RUNNERVM_E2E_GITLAB_PROJECT   Project path ("group/name") or numeric id. Its .gitlab-ci.yml must be
                                docs/e2e/gitlab-ci.yml.
  RUNNERVM_E2E_GITLAB_PROFILE   RunnerVM profile with `provider: gitlab`.
  RUNNERVM_E2E_GITLAB_TOKEN     PAT with api + create_runner + manage_runner (not needed for --dry-run).

Optional environment:
  RUNNERVM_E2E_GITLAB_URL       GitLab base URL (default: https://gitlab.com).
  RUNNERVM_E2E_GITLAB_EXECUTOR  instance (default) or docker-autoscaler (Linux profiles only).
  RUNNERVM_E2E_SOCKET           runnerd.sock path, for runnerctl and the plugin.
  RUNNERVM_E2E_DRY_RUN=1        Same as --dry-run: print the actions, touch nothing.
  RUNNERVM_E2E_PIPELINE_TIMEOUT seconds to wait for the pipeline (default: 1200).
  RUNNERVM_E2E_LEFTOVER_TIMEOUT seconds to wait for fleet VMs to disappear (default: 180).
  RUNNERVM_E2E_POLL_INTERVAL    seconds between polls (default: 5).
  RUNNERVM_E2E_GITLAB_LEASE     plugin lease (default: 10m).
  RUNNERVM_E2E_GITLAB_RUNNER    gitlab-runner binary (default: gitlab-runner).
  RUNNERCTL                     runnerctl binary (default: .build/debug/runnerctl, release, PATH).

Exit codes: 0 pass; 1 pipeline did not succeed; 2 usage/config error; 3 preflight failed;
4 GitLab API or gitlab-runner failure; 5 pipeline timed out; 6 fleet VMs left over.
USAGE
}

# fail <exit-code> <message>: like die() but with a distinct exit code per failure class.
fail() {
  local code="$1"
  shift
  printf '[e2e] error: %s\n' "$*" >&2
  exit "$code"
}

# Strips the PAT and any GitLab runner token before text reaches a terminal or a log.
redact() {
  local text
  text="$(cat)"
  if [ -n "$TOKEN" ]; then text="${text//"$TOKEN"/<redacted>}"; fi
  printf '%s\n' "$text" | sed -E 's/glrt-[A-Za-z0-9_.-]+/glrt-<redacted>/g'
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
  done
}

validate_env() {
  [ -n "$PROJECT" ] || die "RUNNERVM_E2E_GITLAB_PROJECT is required (path or id)"
  [ -n "$PROFILE" ] || die "RUNNERVM_E2E_GITLAB_PROFILE is required (a provider: gitlab profile)"
  case "$EXECUTOR" in instance | docker-autoscaler) ;; *) die "RUNNERVM_E2E_GITLAB_EXECUTOR must be instance or docker-autoscaler" ;; esac
  case "$PIPELINE_TIMEOUT$LEFTOVER_TIMEOUT$POLL_INTERVAL" in '' | *[!0-9]*) die "timeouts and poll interval must be integers" ;; esac
  [ "$DRY_RUN" = "1" ] || [ -n "$TOKEN" ] \
    || die "RUNNERVM_E2E_GITLAB_TOKEN is required (PAT: api + create_runner + manage_runner)"
}

# --------------------------------------------------------------------------
# config.toml
# --------------------------------------------------------------------------
# $1 = runner auth token (or a placeholder in a dry run), $2 = guest OS (linux|macos).
# Always one job per VM: capacity_per_instance = 1, max_use_count = 1, scale to zero.
render_config() {
  local token="$1" os="$2" conn_os="linux"
  [ "$os" = "macos" ] && conn_os="darwin"
  cat <<TOML
concurrent = 2
check_interval = 3

[[runners]]
  name = "runnervm-e2e"
  url = "$GITLAB_URL"
  token = "$token"
  executor = "$EXECUTOR"
TOML
  if [ "$EXECUTOR" = "instance" ]; then
    echo '  shell = "bash"'
  else
    printf '  [runners.docker]\n    image = "%s"\n' "$DOCKER_IMAGE"
  fi
  cat <<TOML
  [runners.autoscaler]
    plugin = "runnervm"
    capacity_per_instance = 1
    max_use_count = 1
    max_instances = 2
    delete_instances_on_shutdown = true
    [runners.autoscaler.plugin_config]
      profile = "$PROFILE"
TOML
  if [ -n "$SOCKET" ]; then printf '      socket = "%s"\n' "$SOCKET"; fi
  cat <<TOML
      lease = "$LEASE"
    [runners.autoscaler.connector_config]
      os = "$conn_os"
      arch = "arm64"
      protocol = "ssh"
      username = "runner"
      timeout = "10m"
    [[runners.autoscaler.policy]]
      idle_count = 0
TOML
}

# --------------------------------------------------------------------------
# GitLab API (the PAT travels in a 0600 header file, never on a command line)
# --------------------------------------------------------------------------
gl() {
  local method="$1" path="$2"
  shift 2
  curl -sS --fail-with-body --max-time 60 -X "$method" -H "@$HEADER_FILE" "$@" \
    "$GITLAB_URL/api/v4$path"
}

gl_project() { gl "$1" "/projects/$PROJECT_ENC$2" "${@:3}"; }

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
preflight() {
  log "checking preconditions"
  local missing=() profile_json image_ref ready project_json branch ci_json
  command -v "$GITLAB_RUNNER_BIN" >/dev/null 2>&1 || missing+=("$GITLAB_RUNNER_BIN")
  command -v curl >/dev/null 2>&1 || missing+=("curl")
  command -v jq >/dev/null 2>&1 || missing+=("jq")
  command -v fleeting-plugin-runnervm >/dev/null 2>&1 \
    || missing+=("fleeting-plugin-runnervm on PATH (make -C GuestAgent build-plugin; docs/gitlab.md)")
  if [ -z "$RUNNERCTL_BIN" ] || [ ! -x "$RUNNERCTL_BIN" ]; then
    missing+=("runnerctl (swift build, or set RUNNERCTL=/path/to/runnerctl)")
  fi
  [ ${#missing[@]} -eq 0 ] || fail 3 "missing tools: ${missing[*]}"

  rc status >/dev/null 2>&1 || fail 3 "runnerctl status failed; is runnerd running? (docs/install.md)"
  profile_json=$(rc profile show "$PROFILE" 2>/dev/null) \
    || fail 3 "profile '$PROFILE' not found; check 'runnerctl profile list'"
  echo "$profile_json" | jq -e '.provider=="gitlab"' >/dev/null \
    || fail 3 "profile '$PROFILE' is not provider: gitlab"
  echo "$profile_json" | jq -e '.enabled==true' >/dev/null \
    || fail 3 "profile '$PROFILE' is disabled"
  GUEST_OS=$(echo "$profile_json" | jq -r '.guestOS')
  if [ "$EXECUTOR" = "docker-autoscaler" ] && [ "$GUEST_OS" != "linux" ]; then
    fail 3 "docker-autoscaler needs a Linux profile; '$PROFILE' is $GUEST_OS"
  fi
  image_ref=$(echo "$profile_json" | jq -r '.image')
  ready=$(rc image list 2>/dev/null | jq --arg ref "$image_ref" \
    '[.images[] | select((.canonicalReference==$ref or .name==$ref) and .state=="ready")] | length') \
    || ready=0
  [ "${ready:-0}" -gt 0 ] \
    || fail 3 "image '$image_ref' is not locally ready; run 'runnerctl image pull $image_ref'"

  project_json=$(gl_project GET "" 2>&1) \
    || fail 3 "cannot read project '$PROJECT' on $GITLAB_URL: $(echo "$project_json" | redact | head -c 300)"
  PROJECT_ID=$(echo "$project_json" | jq -r '.id')
  branch=$(echo "$project_json" | jq -r '.default_branch // empty')
  [ -n "$branch" ] || fail 3 "project '$PROJECT' has no default branch"
  DEFAULT_BRANCH="$branch"
  ci_json=$(gl_project GET "/repository/files/.gitlab-ci.yml?ref=$branch" 2>/dev/null) \
    || fail 3 "'$PROJECT' has no .gitlab-ci.yml on $branch; copy docs/e2e/gitlab-ci.yml there first"
  echo "$ci_json" | jq -r '.content' | base64 -d 2>/dev/null | grep -q "$RUNNER_TAG" \
    || fail 3 ".gitlab-ci.yml in '$PROJECT' does not use the $RUNNER_TAG tag; copy docs/e2e/gitlab-ci.yml"
  log "preconditions OK (profile=$PROFILE os=$GUEST_OS executor=$EXECUTOR project=$PROJECT)"
}

# --------------------------------------------------------------------------
# Runner lifecycle
# --------------------------------------------------------------------------
create_runner() {
  local resp token
  log "creating project runner (tag $RUNNER_TAG)"
  resp=$(gl POST /user/runners \
    --data-urlencode "runner_type=project_type" --data-urlencode "project_id=$PROJECT_ID" \
    --data-urlencode "tag_list=$RUNNER_TAG" --data-urlencode "run_untagged=false" \
    --data-urlencode "description=runnervm-live-e2e-$$" 2>&1) \
    || fail 4 "POST /user/runners failed: $(echo "$resp" | redact | head -c 300)"
  RUNNER_ID=$(echo "$resp" | jq -r '.id // empty')
  token=$(echo "$resp" | jq -r '.token // empty')
  [ -n "$RUNNER_ID" ] && [ -n "$token" ] || fail 4 "runner creation response had no id/token"
  log "created runner id=$RUNNER_ID"
  (umask 077 && render_config "$token" "$GUEST_OS" >"$WORKDIR/config.toml")
}

start_runner() {
  log "starting $GITLAB_RUNNER_BIN (log: $WORKDIR/gitlab-runner.log)"
  "$GITLAB_RUNNER_BIN" run --config "$WORKDIR/config.toml" --working-directory "$WORKDIR/work" \
    >"$WORKDIR/gitlab-runner.log" 2>&1 &
  RUNNER_PID=$!
  sleep 2
  kill -0 "$RUNNER_PID" 2>/dev/null || fail 4 "gitlab-runner exited at startup; see log: $(redact <"$WORKDIR/gitlab-runner.log" | tail -5)"
}

cleanup() {
  local code=$?
  set +e
  if [ -n "$RUNNER_PID" ] && kill -0 "$RUNNER_PID" 2>/dev/null; then
    log "stopping gitlab-runner"
    kill -TERM "$RUNNER_PID" 2>/dev/null
    local i=0
    while kill -0 "$RUNNER_PID" 2>/dev/null && [ "$i" -lt 60 ]; do sleep 1; i=$((i + 1)); done
    kill -KILL "$RUNNER_PID" 2>/dev/null
  fi
  if [ -n "$RUNNER_ID" ]; then
    log "deleting runner id=$RUNNER_ID"
    gl DELETE "/runners/$RUNNER_ID" >/dev/null 2>&1 || warn "could not delete runner $RUNNER_ID; remove it in the GitLab UI"
  fi
  if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
    if [ "$code" -ne 0 ] && [ -f "$WORKDIR/gitlab-runner.log" ]; then
      local keep="${TMPDIR:-/tmp}/runnervm-gitlab-e2e-$$.log"
      redact <"$WORKDIR/gitlab-runner.log" >"$keep" 2>/dev/null && warn "gitlab-runner log kept at $keep"
    fi
    rm -rf "$WORKDIR"
  fi
  exit "$code"
}

# --------------------------------------------------------------------------
# Pipeline
# --------------------------------------------------------------------------
run_pipeline() {
  local resp pid status deadline now jobs
  resp=$(gl_project POST "/pipeline" -H "Content-Type: application/json" \
    --data "$(jq -n --arg ref "$DEFAULT_BRANCH" --arg e "$EXECUTOR" \
      '{ref:$ref, variables:[{key:"RUNNERVM_E2E_EXECUTOR", value:$e}]}')" 2>&1) \
    || fail 4 "pipeline trigger failed: $(echo "$resp" | redact | head -c 300)"
  pid=$(echo "$resp" | jq -r '.id')
  log "pipeline $pid triggered on $DEFAULT_BRANCH: $(echo "$resp" | jq -r '.web_url')"
  deadline=$(($(date +%s) + PIPELINE_TIMEOUT))
  while true; do
    status=$(gl_project GET "/pipelines/$pid" 2>/dev/null | jq -r '.status') || status="unknown"
    case "$status" in
    success) break ;;
    failed | canceled | skipped)
      jobs=$(gl_project GET "/pipelines/$pid/jobs" 2>/dev/null \
        | jq -r '.[] | "  \(.name): \(.status) \(.failure_reason // "")"') || jobs=""
      printf '%s\n' "$jobs" >&2
      fail 1 "pipeline $pid ended $status" ;;
    esac
    kill -0 "$RUNNER_PID" 2>/dev/null || fail 4 "gitlab-runner died while waiting for pipeline $pid"
    now=$(date +%s)
    [ "$now" -lt "$deadline" ] || fail 5 "pipeline $pid still '$status' after ${PIPELINE_TIMEOUT}s"
    sleep "$POLL_INTERVAL"
  done
  log "pipeline $pid succeeded"
}

wait_no_fleet_instances() {
  local deadline count
  deadline=$(($(date +%s) + LEFTOVER_TIMEOUT))
  while true; do
    count=$(rc vm list 2>/dev/null | jq --arg p "$PROFILE" \
      '[.instances[] | select(.profile==$p and .purpose=="fleet" and .state!="deleted")] | length' \
      2>/dev/null) || count=-1
    [ "$count" = "0" ] && { log "no fleet instances of $PROFILE remain"; return 0; }
    [ "$(date +%s)" -lt "$deadline" ] || fail 6 "$count fleet instance(s) of $PROFILE left after ${LEFTOVER_TIMEOUT}s"
    sleep "$POLL_INTERVAL"
  done
}

plan() {
  cat <<PLAN
  rc profile show $PROFILE; rc image list; rc status    # profile is provider: gitlab, image ready
  GET  $GITLAB_URL/api/v4/projects/$PROJECT             # default branch; .gitlab-ci.yml uses $RUNNER_TAG
  POST $GITLAB_URL/api/v4/user/runners                  # project_type, tag_list=$RUNNER_TAG (token never printed)
  write \$WORKDIR/config.toml (0600), executor=$EXECUTOR:
PLAN
  render_config "<runner-token>" "linux" | sed 's/^/    /'
  cat <<PLAN
  $GITLAB_RUNNER_BIN run --config \$WORKDIR/config.toml --working-directory \$WORKDIR/work &
  POST $GITLAB_URL/api/v4/projects/$PROJECT/pipeline    # ref=<default branch>, RUNNERVM_E2E_EXECUTOR=$EXECUTOR
  GET  .../pipelines/<id>                               # poll every ${POLL_INTERVAL}s up to ${PIPELINE_TIMEOUT}s; expect success
  $RUNNERCTL_BIN --output json vm list                  # poll up to ${LEFTOVER_TIMEOUT}s: 0 fleet instances of $PROFILE
  cleanup (trap): stop gitlab-runner; DELETE $GITLAB_URL/api/v4/runners/<id>; rm -rf \$WORKDIR
PLAN
}

main() {
  parse_args "$@"
  validate_env
  if [ "$DRY_RUN" = "1" ]; then
    log "dry-run: no live checks, no live calls; profile=$PROFILE project=$PROJECT executor=$EXECUTOR"
    plan
    log "dry-run complete"
    exit 0
  fi
  trap cleanup EXIT
  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/rvm-gitlab-e2e-XXXXXX")"
  mkdir -p "$WORKDIR/work"
  HEADER_FILE="$WORKDIR/header"
  (umask 077 && printf 'PRIVATE-TOKEN: %s\n' "$TOKEN" >"$HEADER_FILE")
  PROJECT_ENC="$(printf '%s' "$PROJECT" | jq -sRr @uri)"
  preflight
  create_runner
  start_runner
  run_pipeline
  wait_no_fleet_instances
  log "PASS"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
