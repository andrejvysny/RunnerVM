#!/usr/bin/env bash
# Live builder -> GitHub -> GHCR E2E driver for RunnerVM (production-hardening plan WP7).
#
# Manually triggered, opt-in: builds a real image in-daemon from a recipe, runs a real GitHub
# Actions job against it, then round-trips the same image through a real OCI registry (push,
# delete the local copy, pull back by immutable digest) and proves a job still runs on the
# re-pulled image. This is NOT part of `swift test` or CI's default triggers and must never point
# at a production org, repo or registry. Same conventions as scripts/live-github-e2e.sh: opt-in,
# `--dry-run` prints the plan without touching anything, a JSON report is written at the end.
#
# Read docs/live-integration.md before the first run. Shared logging/runnerctl/polling/report
# helpers live in scripts/lib/live-common.sh, also used by scripts/live-github-e2e.sh; see that
# file's header for exactly what moved there and why.
#
# Pipeline (fixed order; not independently selectable scenarios like live-github-e2e.sh, since
# each step's output feeds the next):
#   1. runnerctl image build <recipe> --name e2e-<timestamp> --wait
#   2. runnerctl image inspect --output json: guestAgent == true, a build record with
#      recipeSHA256, digest captured
#   3. Precondition, not an action: --profile's applied image: must already equal the alias just
#      built (runnerctl profile show --output json). runnerd owns configuration; this script
#      cannot edit it, only apply a document the operator supplies with --config.
#   4. Dispatch docs/../.github/workflows/runnervm-selftest.yml (`profile` input) against the
#      locally built image; wait for success; assert the runner registration/VM/session/capacity
#      all converge back to baseline.
#   5. OCI leg (skip with --skip-oci): push to --registry, delete the local image, pull it back by
#      the immutable @sha256:<digest> the push reported, assert the round-tripped image matches,
#      dispatch the workflow a second time against it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/lib/live-common.sh
# shellcheck disable=SC1091 # dynamic path; run shellcheck -x to actually follow it
source "$REPO_ROOT/scripts/lib/live-common.sh"

# --------------------------------------------------------------------------
# Defaults, env, flags
# --------------------------------------------------------------------------
PROFILE=""
STATE_DIR="$HOME/Library/Application Support/RunnerVM"
SOCKET=""
JSON_REPORT=""
DRY_RUN=0
RECIPE=""
REGISTRY=""
CONFIG_PATH=""
SKIP_OCI=0
WORKFLOW_FILE="runnervm-selftest.yml"

OWNER="${RUNNERVM_E2E_OWNER:-}"
REPO="${RUNNERVM_E2E_REPO:-}"
TOKEN="${RUNNERVM_GITHUB_TOKEN:-}"

RUN_TIMEOUT="${RUNNERVM_E2E_RUN_TIMEOUT:-1800}"
LEFTOVER_TIMEOUT="${RUNNERVM_E2E_LEFTOVER_TIMEOUT:-180}"
RUN_POLL_INTERVAL="${RUNNERVM_E2E_POLL_INTERVAL:-5}"

FAIL_COUNT=0
# shellcheck disable=SC2034 # consumed by report_init/record_result/write_report (live-common.sh)
REPORT_TMP=""
# The built image's name (the --name alias) and digest, set by step_build/step_inspect and read by
# every step after. Not `local`: steps are separate functions run in a fixed sequence, each
# depending on state the earlier ones captured -- the same shape run_steps/record_result already
# assumes for pass/fail bookkeeping (FAIL_COUNT) below.
IMAGE_NAME=""
IMAGE_DIGEST=""

RUNNERCTL_BIN="$(find_runnerctl)"

usage() {
  cat <<'USAGE'
usage: live-builder-e2e.sh --recipe <dir> --profile <name> [options]

Live builder -> GitHub -> GHCR E2E driver for RunnerVM. Manually triggered, opt-in; builds a real
image, dispatches a real GitHub Actions job, and (unless --skip-oci) round-trips the image through
a real OCI registry. Read docs/live-integration.md before the first run.

Required environment:
  RUNNERVM_E2E_OWNER       Dedicated test org (or user) login.
  RUNNERVM_E2E_REPO        Dedicated test repo, "owner/name".
  RUNNERVM_GITHUB_TOKEN    PAT with the scopes docs/live-integration.md lists.

Required options:
  --recipe <dir>          Recipe directory (or file) to build, e.g. images/recipes/ubuntu-24.
  --profile <name>        Profile to exercise. Its applied image: must already equal the image
                           alias this run builds (e2e-<timestamp>); see "Preconditions" below.

Options:
  --registry <ref>        OCI repository for the push/pull leg, e.g. ghcr.io/<owner>/runnervm-e2e.
                           Required unless --skip-oci.
  --config <path>         Configuration YAML to `runnerctl config apply` before checking the
                           profile's image: (optional -- the script never edits configuration
                           itself, only applies a document you supply).
  --skip-oci               Skip step 5 (push/delete/pull-by-digest/redispatch): useful when no
                           registry credentials are set up for this run.
  --state-dir <dir>       RunnerVM state root, for the default report location
                          (default: $HOME/Library/Application Support/RunnerVM).
  --socket <path>         runnerd.sock path, forwarded to every runnerctl call.
  --json-report <path>  Where to write the JSON report
                         (default: <state-dir>/logs/builder-e2e-report-<timestamp>.json).
  --dry-run               Print the commands the pipeline would run; touches nothing, requires no
                           daemon/gh/PAT to actually work.
  -h, --help              Show this help.

Preconditions this script checks but never fixes:
  - runnerd running and reachable, GitHub auth healthy (runnerctl status / github test).
  - gh authenticated and able to see the test repo.
  - The test repo has .github/workflows/runnervm-selftest.yml on its default branch.
  - --profile exists and, once the image is built, its applied image: equals the built alias
    (e2e-<timestamp>) -- apply a configuration that sets this with --config, or apply one by hand
    first with `runnerctl config apply`.

Timeout overrides (seconds): RUNNERVM_E2E_RUN_TIMEOUT, RUNNERVM_E2E_LEFTOVER_TIMEOUT,
RUNNERVM_E2E_POLL_INTERVAL. RUNNERCTL overrides the runnerctl binary path (default:
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
    --recipe) RECIPE="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --registry) REGISTRY="$2"; shift 2 ;;
    --config) CONFIG_PATH="$2"; shift 2 ;;
    --skip-oci) SKIP_OCI=1; shift ;;
    --state-dir) STATE_DIR="$2"; shift 2 ;;
    --socket) SOCKET="$2"; shift 2 ;;
    --json-report) JSON_REPORT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
  done
}

validate_args() {
  [ -n "$RECIPE" ] || die "--recipe <dir> is required; see --help"
  [ -n "$PROFILE" ] || die "--profile <name> is required; see --help"
  if [ "$SKIP_OCI" -eq 0 ]; then
    [ -n "$REGISTRY" ] || die "--registry <ref> is required unless --skip-oci; see --help"
  fi
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
check_recipe_readable() {
  [ -r "$RECIPE" ] || die "cannot read recipe '$RECIPE'"
}

check_selftest_workflow_present() {
  gh api "repos/$REPO/contents/.github/workflows/$WORKFLOW_FILE" >/dev/null 2>&1 \
    || die "'$REPO' has no .github/workflows/$WORKFLOW_FILE"
}

check_preconditions() {
  log "checking preconditions"
  check_daemon_reachable
  check_github_auth
  check_gh_cli_auth
  check_recipe_readable
  check_selftest_workflow_present
  rc profile show "$PROFILE" >/dev/null || die "profile '$PROFILE' not found; check 'runnerctl profile list'"
  log "preconditions OK (profile=$PROFILE owner=$OWNER repo=$REPO)"
}

# --------------------------------------------------------------------------
# Steps. Each returns 0 (pass) or 1 (fail); run_steps logs start/end and records the result, and
# stops at the first failure -- unlike live-github-e2e.sh's independent scenarios, every step here
# depends on state (IMAGE_NAME, IMAGE_DIGEST) the earlier ones captured.
# --------------------------------------------------------------------------

# Step 1 (docs header): build the image. Deliberately NOT `rc` (which forces --output json): the
# daemon writes the build's step-progress and log straight to the fd regardless of --output, so
# JSON mode here would receive raw log text ahead of (not instead of) the trailing JSON object.
# `image build --wait` already blocks until the build reaches a terminal state and exits nonzero
# on failure, so there is nothing further to poll.
step_build() {
  log "building $IMAGE_NAME from $RECIPE"
  rc_human image build "$RECIPE" --name "$IMAGE_NAME" --wait || { warn "image build failed"; return 1; }
  return 0
}

# Step 2: inspect the built image (guestAgent, digest) and its build record (recipeSHA256 --
# ImageProvenanceSummaryDTO itself has no recipe-sha field; that only exists on the build row).
step_inspect() {
  local image_json build_id recipe_sha guest_agent
  image_json=$(rc image inspect "$IMAGE_NAME") || { warn "image inspect failed"; return 1; }
  IMAGE_DIGEST=$(echo "$image_json" | jq -r '.digest // empty')
  [ -n "$IMAGE_DIGEST" ] || { warn "built image '$IMAGE_NAME' reports no digest"; return 1; }
  guest_agent=$(echo "$image_json" | jq -r '.guestAgent // false')
  [ "$guest_agent" = "true" ] \
    || { warn "built image '$IMAGE_NAME' guestAgent is not true (got '$guest_agent')"; return 1; }
  build_id=$(rc build list 2>/dev/null | jq -r --arg name "$IMAGE_NAME" \
    '[.builds[] | select(.name==$name)] | sort_by(.createdAt) | last | .buildId // empty') \
    || build_id=""
  [ -n "$build_id" ] || { warn "could not find the build record for '$IMAGE_NAME'"; return 1; }
  recipe_sha=$(rc build show "$build_id" 2>/dev/null | jq -r '.recipeSHA256 // empty') || recipe_sha=""
  [ -n "$recipe_sha" ] \
    || { warn "build record $build_id for '$IMAGE_NAME' has no recipeSHA256"; return 1; }
  log "image $IMAGE_NAME digest=$IMAGE_DIGEST guestAgent=true recipeSHA256=$recipe_sha"
  return 0
}

# Step 3: not an action, a precondition -- see the file header and --help's "Preconditions". This
# script cannot edit configuration; it can only apply a document the operator already supplied.
step_profile_points_at_image() {
  if [ -n "$CONFIG_PATH" ]; then
    log "applying configuration from $CONFIG_PATH"
    rc config apply "$CONFIG_PATH" >/dev/null || { warn "config apply failed"; return 1; }
  fi
  local profile_image
  profile_image=$(rc profile show "$PROFILE" 2>/dev/null | jq -r '.image // empty') \
    || { warn "could not read profile '$PROFILE'"; return 1; }
  if [ "$profile_image" != "$IMAGE_NAME" ]; then
    warn "profile '$PROFILE' has image: '$profile_image', not the image just built ('$IMAGE_NAME')"
    warn "point the profile's image: at '$IMAGE_NAME' and apply it (--config <path>, or by hand" \
      "with 'runnerctl config apply' first)"
    return 1
  fi
  return 0
}

# Steps 4 and (tail of) 5: dispatch runnervm-selftest.yml against whatever the profile currently
# resolves to, and assert every side effect converges -- runner registration gone (hard-checked,
# not assert_no_leftovers's own best-effort warn), VM gone, session terminal (0 active sessions),
# capacity/demand back at the baseline captured before dispatch.
dispatch_and_assert_selftest() {
  local before run_id conclusion baseline
  baseline=$(capture_capacity_baseline "$PROFILE")
  before=$(date +%s)
  gh workflow run "$WORKFLOW_FILE" -R "$REPO" -f "profile=$PROFILE"
  run_id=$(find_dispatched_run "$before") || { warn "could not locate the dispatched selftest run"; return 1; }
  log "selftest run $run_id dispatched (profile=$PROFILE)"
  conclusion=$(wait_for_run_conclusion "$run_id" "$RUN_TIMEOUT") \
    || { warn "selftest run $run_id did not complete within ${RUN_TIMEOUT}s"; return 1; }
  [ "$conclusion" = "success" ] || { warn "selftest run $run_id concluded '$conclusion'"; return 1; }
  wait_no_github_runner "$PROFILE" "$LEFTOVER_TIMEOUT" \
    || { warn "GitHub still lists a runner matching rvm-$(profile_short_name "$PROFILE")-* after ${LEFTOVER_TIMEOUT}s"; return 1; }
  assert_no_leftovers "$PROFILE" "$LEFTOVER_TIMEOUT" "$baseline" || return 1
  return 0
}

step_selftest() { dispatch_and_assert_selftest; }

# Step 5: push, delete the local copy, pull back by the immutable digest the push itself reported
# (never a mutable tag), and assert the round trip preserved digest and guestAgent. A RunnerVM OCI
# push/pull does not currently round-trip the local `name` alias (ImagePulling.swift names a pulled
# image from the resolved canonical reference, not any prior local alias) -- pointing the profile
# back at the re-pulled image is exactly what step_profile_points_at_image's --config re-apply is
# for, so it runs again here before the second dispatch rather than assuming the same alias still
# resolves.
step_oci() {
  if [ "$SKIP_OCI" -eq 1 ]; then
    log "skipping the OCI leg (--skip-oci)"
    return 0
  fi
  local push_ref pull_ref pulled_json pulled_digest pulled_guest_agent
  push_ref="$REGISTRY:$IMAGE_NAME"
  log "pushing $IMAGE_NAME to $push_ref"
  rc image push "$IMAGE_NAME" "$push_ref" >/dev/null || { warn "image push failed"; return 1; }
  log "deleting the local image $IMAGE_DIGEST (alias $IMAGE_NAME)"
  rc image delete "$IMAGE_DIGEST" >/dev/null || { warn "image delete failed"; return 1; }
  pull_ref="${REGISTRY}@${IMAGE_DIGEST}"
  log "pulling back by immutable digest: $pull_ref"
  rc image pull "$pull_ref" >/dev/null || { warn "image pull by digest failed"; return 1; }
  pulled_json=$(rc image inspect "$IMAGE_DIGEST") || { warn "image inspect after pull failed"; return 1; }
  pulled_digest=$(echo "$pulled_json" | jq -r '.digest // empty')
  pulled_guest_agent=$(echo "$pulled_json" | jq -r '.guestAgent // false')
  [ "$pulled_digest" = "$IMAGE_DIGEST" ] \
    || { warn "pulled image digest '$pulled_digest' does not match the pushed one '$IMAGE_DIGEST'"; return 1; }
  [ "$pulled_guest_agent" = "true" ] \
    || { warn "pulled image guestAgent is not true (got '$pulled_guest_agent')"; return 1; }
  log "pulled image metadata matches: digest=$pulled_digest guestAgent=true"
  # The local alias did not survive delete+pull-by-digest (see the function comment above): make
  # the profile resolve to the re-pulled image before dispatching again, the same way (and with
  # the same "this script never edits configuration" limit) step_profile_points_at_image did for
  # the freshly built one.
  step_profile_points_at_image || {
    warn "profile '$PROFILE' does not resolve to the re-pulled image; point its image: at '$IMAGE_DIGEST' (or the pushed reference) and pass --config again"
    return 1
  }
  dispatch_and_assert_selftest
}

# --------------------------------------------------------------------------
# --dry-run plan: prints the whole pipeline in order; nothing here executes anything.
# --------------------------------------------------------------------------
print_plan() {
  cat <<PLAN
  $RUNNERCTL_BIN image build $RECIPE --name $IMAGE_NAME --wait
  $RUNNERCTL_BIN --output json image inspect $IMAGE_NAME             # assert guestAgent == true, capture digest
  $RUNNERCTL_BIN --output json build list                            # find the build record for $IMAGE_NAME
  $RUNNERCTL_BIN --output json build show <build-id>                 # assert recipeSHA256 is present
PLAN
  if [ -n "$CONFIG_PATH" ]; then
    printf '  %s --output json config apply %s\n' "$RUNNERCTL_BIN" "$CONFIG_PATH"
  fi
  cat <<PLAN
  $RUNNERCTL_BIN --output json profile show $PROFILE                 # assert image: == $IMAGE_NAME
  $RUNNERCTL_BIN --output json status                                # capture busy/idle/demand baseline for $PROFILE
  gh workflow run $WORKFLOW_FILE -R "$REPO" -f profile=$PROFILE
  gh run list -R "$REPO" --workflow=$WORKFLOW_FILE --json databaseId,createdAt,event -L 15
  gh run view <run-id> -R "$REPO" --json status,conclusion           # poll every ${RUN_POLL_INTERVAL}s up to ${RUN_TIMEOUT}s
  gh api orgs/$OWNER/actions/runners                                 # poll up to ${LEFTOVER_TIMEOUT}s: no runner named rvm-$(profile_short_name "$PROFILE")-*
  $RUNNERCTL_BIN --output json vm list                               # poll up to ${LEFTOVER_TIMEOUT}s: 0 instances of $PROFILE
  $RUNNERCTL_BIN --output json runner list --active                  # poll: 0 active sessions of $PROFILE
  $RUNNERCTL_BIN --output json status                                # assert busy/idle/demand back at the captured baseline
PLAN
  if [ "$SKIP_OCI" -eq 1 ]; then
    log "  (--skip-oci: the push/delete/pull-by-digest/redispatch leg below would be skipped)"
  fi
  cat <<PLAN
  $RUNNERCTL_BIN --output json image push $IMAGE_NAME $REGISTRY:$IMAGE_NAME
  $RUNNERCTL_BIN --output json image delete <digest>                 # the digest image inspect captured above
  $RUNNERCTL_BIN --output json image pull $REGISTRY@<digest>         # by immutable digest, never a tag
  $RUNNERCTL_BIN --output json image inspect <digest>                # assert same digest, guestAgent == true
  $RUNNERCTL_BIN --output json profile show $PROFILE                 # re-check image: (the local alias did not survive
                                                                      # the delete+pull-by-digest); re-apply --config if given
  $RUNNERCTL_BIN --output json status                                # capture busy/idle/demand baseline for $PROFILE
  gh workflow run $WORKFLOW_FILE -R "$REPO" -f profile=$PROFILE      # second dispatch, against the re-pulled image
  gh run view <run-id> -R "$REPO" --json status,conclusion           # poll every ${RUN_POLL_INTERVAL}s up to ${RUN_TIMEOUT}s
  gh api orgs/$OWNER/actions/runners                                 # poll up to ${LEFTOVER_TIMEOUT}s: no runner named rvm-$(profile_short_name "$PROFILE")-*
  $RUNNERCTL_BIN --output json vm list                               # poll up to ${LEFTOVER_TIMEOUT}s: 0 instances of $PROFILE
  $RUNNERCTL_BIN --output json runner list --active                  # poll: 0 active sessions of $PROFILE
  $RUNNERCTL_BIN --output json status                                # assert busy/idle/demand back at the captured baseline
PLAN
}

# --------------------------------------------------------------------------
# Dispatch loop / entry point (report_init / record_result / write_report are shared)
# --------------------------------------------------------------------------
run_steps() {
  local name started ended status rc_val
  local -a steps=(build inspect profile_points_at_image selftest oci)
  for name in "${steps[@]}"; do
    log "=== step: $name ==="
    started=$(date +%s)
    if "step_$name"; then rc_val=0; else rc_val=$?; fi
    ended=$(date +%s)
    if [ "$rc_val" -eq 0 ]; then status="pass"; else status="fail"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi
    log "=== $name: $status ($((ended - started))s) ==="
    record_result "$name" "$status" "$started" "$ended" ""
    [ "$rc_val" -eq 0 ] || break
  done
}

main() {
  parse_args "$@"
  validate_args
  require_tools
  require_env
  IMAGE_NAME="e2e-$(date -u +%Y%m%dT%H%M%SZ)"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "dry-run: no live checks, no live calls; profile=$PROFILE owner=$OWNER repo=$REPO"
    print_plan
    log "dry-run complete"
    exit 0
  fi
  check_preconditions
  report_init
  run_steps
  write_report
  [ "$FAIL_COUNT" -eq 0 ] || exit 1
}

main "$@"
