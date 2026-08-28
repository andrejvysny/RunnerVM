#!/usr/bin/env bash
# Qualify a macOS image by cold-booting a clone of it under RunnerVM (docs/macos-guests.md, H2).
#
# The premise, and the reason this exists as its own driver:
#
#   A macOS image is not valid because scripts/provision-macos-tart.sh finished. It is valid
#   because RunnerVM successfully cold-booted a clone of it and got a working guest agent back.
#
# A provisioning run can only ever check the guest it is sitting inside, over the SSH channel it is
# about to destroy. That misses everything that only shows up on a fresh boot of a *clone*: a
# LaunchDaemon that loaded once but does not start at boot, auxiliary storage the clone cannot use,
# a hardware model this host will not run, a guest agent that cannot reach vsock, an SSH lockdown
# that did not survive the reboot.
#
# What it proves, in order:
#   1. the daemon admits the profile and creates an instance from the image (no `failed` row)
#   2. the clone cold-boots and the guest agent completes its vsock handshake (`idle`)
#   3. the agent answers health/guestInfo and executes a command
#   4. the guest is the macOS the image claims to be (`sw_vers`)
#   5. the guest agent's LaunchDaemon is loaded, from a real boot rather than from `launchctl
#      bootstrap` during provisioning
#   6. the seal-time lockdown held: nothing is listening on TCP/22, `com.openssh.sshd` is disabled,
#      and the base image's `admin`/`admin` credential no longer authenticates
#   7. the instance tears down cleanly and leaves nothing behind
#   8. the image's digest is unchanged -- qualification is read-only with respect to the image
#
# usage: scripts/qualify-macos-image.sh --profile rvm-macos-26 [options]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROFILE=""
SOCKET="${RUNNERVM_SOCKET:-}"
STATE_DIR="${RUNNERVM_STATE_DIR:-}"
JSON_REPORT=""
BOOT_TIMEOUT=900
TEARDOWN_TIMEOUT=300
EXEC_TIMEOUT=60
ALLOW_SSH=0
KEEP_VM=0
DRY_RUN=0

RUNNERCTL_BIN=""
INSTANCE_ID=""
IMAGE_DIGEST_BEFORE=""
REPORT_TMP=""
CHECKS_FAILED=0
# `assert` records into the report and keeps going, so one run reports every problem rather than
# only the first. The exit status is what gates the image.
CHECKS_RUN=0

usage() {
    cat <<'USAGE'
usage: qualify-macos-image.sh --profile <name> [options]

Cold-boots one instance of a macOS profile, proves the guest agent and the seal-time SSH lockdown,
then destroys it. Exits non-zero if any check fails; the image is only qualified on exit 0.

Required:
  --profile <name>       macOS profile to qualify. Its `image:` is the image under test.

Options:
  --socket <path>        runnerd.sock (default: $RUNNERVM_SOCKET, else runnerctl's own default).
  --state-dir <path>     Only used to place the report when --json is not given.
  --json <path>          Write the JSON report here.
  --boot-timeout <s>     Seconds to wait for the clone to reach `idle` (default: 900).
  --teardown-timeout <s> Seconds to wait for the instance to disappear (default: 300).
  --allow-ssh            The image was built with --debug-ssh: skip the SSH lockdown checks and
                         record them as skipped rather than failing them.
  --keep                 Leave the instance running when the run finishes (debugging; the
                         teardown and leak checks are then skipped and the run is not a pass).
  --dry-run              Print the plan and exit.
  -h, --help             This text.

Environment: RUNNERVM_SOCKET, RUNNERVM_STATE_DIR, RUNNERCTL.
USAGE
}

# `[qualify]`, not `[e2e]`: this driver does not source scripts/lib/live-common.sh, because that
# file's log/warn/die and its GitHub-shaped helpers belong to the workflow drivers. The runnerctl
# discovery below is the one thing worth repeating rather than inheriting all of that.
log()  { printf '[qualify %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[qualify] warning: %s\n' "$*" >&2; }
die()  { printf '[qualify] error: %s\n' "$*" >&2; exit 2; }

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
        --profile) PROFILE="$2"; shift 2 ;;
        --socket) SOCKET="$2"; shift 2 ;;
        --state-dir) STATE_DIR="$2"; shift 2 ;;
        --json) JSON_REPORT="$2"; shift 2 ;;
        --boot-timeout) BOOT_TIMEOUT="$2"; shift 2 ;;
        --teardown-timeout) TEARDOWN_TIMEOUT="$2"; shift 2 ;;
        --allow-ssh) ALLOW_SSH=1; shift ;;
        --keep) KEEP_VM=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
        esac
    done
    [ -n "$PROFILE" ] || { usage >&2; die "--profile is required"; }
}

find_runnerctl() {
    if [ -n "${RUNNERCTL:-}" ]; then printf '%s' "$RUNNERCTL"; return 0; fi
    local candidate
    for candidate in "$REPO_ROOT/.build/debug/runnerctl" "$REPO_ROOT/.build/release/runnerctl"; do
        if [ -x "$candidate" ]; then printf '%s' "$candidate"; return 0; fi
    done
    command -v runnerctl 2>/dev/null || true
}

rc() {
    local -a cmd
    cmd=("$RUNNERCTL_BIN")
    if [ -n "$SOCKET" ]; then cmd+=(--socket "$SOCKET"); fi
    cmd+=(--output json)
    cmd+=("$@")
    "${cmd[@]}"
}

# Runs a command inside the guest and prints its stdout. Never fails the script itself: the caller
# decides what an empty or unexpected answer means, because "the agent refused" and "the guest
# answered something wrong" are different failures with different reports.
guest() {
    local out
    out=$(rc vm exec "$INSTANCE_ID" --timeout "$EXEC_TIMEOUT" -- "$@" 2>/dev/null) || out=""
    printf '%s' "$out"
}

guest_sh() { guest /bin/sh -c "$1"; }

# --------------------------------------------------------------------------
# Reporting. One line of JSON per check, assembled at the end, so a run that dies half way still
# leaves a readable partial report.
# --------------------------------------------------------------------------
report_init() { REPORT_TMP=$(mktemp); }

record() {
    local name="$1" status="$2" detail="${3:-}"
    jq -n --arg name "$name" --arg status "$status" --arg detail "$detail" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{name:$name,status:$status,detail:$detail,at:$at}' >>"$REPORT_TMP"
}

# $2 is a shell-style status: 0 passes, anything else (including a non-numeric answer from a guest
# command that never ran) fails.
assert() {
    local name="$1" ok="$2" detail="${3:-}"
    CHECKS_RUN=$((CHECKS_RUN + 1))
    if [ "$ok" = "0" ]; then
        log "PASS $name${detail:+ -- $detail}"
        record "$name" pass "$detail"
    else
        warn "FAIL $name${detail:+ -- $detail}"
        record "$name" fail "$detail"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
    fi
}

skip() {
    log "SKIP $1${2:+ -- $2}"
    record "$1" skip "${2:-}"
}

write_report() {
    local out
    [ -n "$REPORT_TMP" ] || return 0
    out="$JSON_REPORT"
    if [ -z "$out" ]; then
        if [ -n "$STATE_DIR" ]; then
            out="$STATE_DIR/logs/macos-qualification-$(date -u +%Y%m%dT%H%M%SZ).json"
        else
            out="$REPO_ROOT/.build/macos-qualification-$(date -u +%Y%m%dT%H%M%SZ).json"
        fi
    fi
    mkdir -p "$(dirname "$out")"
    jq -n --arg profile "$PROFILE" --arg image "$IMAGE_DIGEST_BEFORE" \
        --arg instance "$INSTANCE_ID" --argjson failed "$CHECKS_FAILED" \
        --argjson total "$CHECKS_RUN" --slurpfile checks "$REPORT_TMP" \
        '{profile:$profile,imageDigest:$image,instanceId:$instance,
          checksRun:$total,checksFailed:$failed,
          qualified:($failed == 0 and $total > 0),checks:$checks}' >"$out"
    rm -f "$REPORT_TMP"
    REPORT_TMP=""
    log "report written to $out"
}

# --------------------------------------------------------------------------
# Preconditions
# --------------------------------------------------------------------------
PROFILE_JSON=""
IMAGE_REF=""

check_preconditions() {
    local tool guest_os
    for tool in jq nc; do
        command -v "$tool" >/dev/null 2>&1 || die "required tool not on PATH: $tool"
    done
    RUNNERCTL_BIN="$(find_runnerctl)"
    [ -n "$RUNNERCTL_BIN" ] || die "runnerctl not found; build it or set RUNNERCTL"
    rc status >/dev/null || die "runnerctl status failed; is runnerd running? (docs/install.md)"
    PROFILE_JSON=$(rc profile show "$PROFILE") || die "no such profile: $PROFILE"
    guest_os=$(printf '%s' "$PROFILE_JSON" | jq -r '.guestOS')
    [ "$guest_os" = "macos" ] ||
        die "profile '$PROFILE' is os: $guest_os; this driver qualifies macOS images only"
    IMAGE_REF=$(printf '%s' "$PROFILE_JSON" | jq -r '.image')
    IMAGE_DIGEST_BEFORE=$(rc image inspect "$IMAGE_REF" | jq -r '.digest') ||
        die "cannot resolve the profile's image: $IMAGE_REF"
    log "profile $PROFILE -> image $IMAGE_REF ($IMAGE_DIGEST_BEFORE)"
}

# --------------------------------------------------------------------------
# 1-2. Create, then cold-boot to `idle`
# --------------------------------------------------------------------------
instance_field() {
    rc vm show "$INSTANCE_ID" 2>/dev/null | jq -r "$1 // empty" 2>/dev/null || true
}

create_instance() {
    local created
    log "creating an instance of $PROFILE"
    created=$(rc vm create --profile "$PROFILE") ||
        die "vm create failed; the image or profile was refused before any VM booted"
    INSTANCE_ID=$(printf '%s' "$created" | jq -r '.id')
    [ -n "$INSTANCE_ID" ] || die "vm create returned no instance id"
    log "instance $INSTANCE_ID"
    record instance_created pass "$INSTANCE_ID"
}

# `idle` is the state the daemon assigns once the guest agent has completed its handshake, so
# reaching it *is* the cold-boot-plus-vsock proof. `failed`/`interrupted` are terminal and are
# reported immediately rather than waited out.
wait_for_idle() {
    local deadline state elapsed started
    started=$(date +%s)
    deadline=$((started + BOOT_TIMEOUT))
    while true; do
        state=$(instance_field '.state')
        case "$state" in
        idle)
            elapsed=$(($(date +%s) - started))
            assert cold_boot_to_idle 0 "${elapsed}s"
            return 0
            ;;
        failed | interrupted | deleted)
            assert cold_boot_to_idle 1 \
                "instance reached $state: $(instance_field '.failureCode') $(instance_field '.failureMessage')"
            return 1
            ;;
        esac
        if [ "$(date +%s)" -ge "$deadline" ]; then
            assert cold_boot_to_idle 1 "still $state after ${BOOT_TIMEOUT}s"
            return 1
        fi
        sleep 5
    done
}

# --------------------------------------------------------------------------
# 3-5. The guest answers, and is what the image says it is
# --------------------------------------------------------------------------
check_agent() {
    local boot_id product
    boot_id=$(instance_field '.bootId')
    assert agent_handshake "$([ -n "$boot_id" ] && echo 0 || echo 1)" "bootId=${boot_id:--}"

    local metrics_status=0
    rc vm metrics "$INSTANCE_ID" >/dev/null 2>&1 || metrics_status=$?
    assert agent_metrics "$metrics_status" "agent.metrics"

    product=$(guest /usr/bin/sw_vers -productVersion)
    product="$(printf '%s' "$product" | tr -d '\r\n')"
    assert guest_is_macos "$([ -n "$product" ] && echo 0 || echo 1)" "sw_vers -productVersion=${product:--}"
}

# The LaunchDaemon is the one thing that has to work on a *boot* rather than on a `launchctl
# bootstrap` the provisioner ran by hand -- which is exactly what provisioning-time checks cannot
# distinguish.
check_launch_daemon() {
    local out
    out=$(guest_sh 'launchctl print system/com.runnervm.guest-agent >/dev/null 2>&1 && echo loaded')
    assert guest_agent_launchdaemon_loaded \
        "$([ "$(printf '%s' "$out" | tr -d '\r\n')" = "loaded" ] && echo 0 || echo 1)"
}

# --------------------------------------------------------------------------
# 6. The seal-time lockdown survived the reboot
# --------------------------------------------------------------------------
check_ssh_lockdown() {
    if [ "$ALLOW_SSH" -eq 1 ]; then
        skip ssh_port_closed "--allow-ssh: the image was built with --debug-ssh"
        skip sshd_disabled "--allow-ssh"
        skip default_credential_rejected "--allow-ssh"
        skip ssh_unreachable_from_host "--allow-ssh"
        return 0
    fi

    # Inside the guest, so it holds whatever the host's own routing looks like. A macOS `netstat`
    # renders a listening socket as `*.22` or `<addr>.22`, never `:22`.
    local listening
    listening=$(guest_sh "netstat -an -p tcp 2>/dev/null | grep LISTEN | grep -c '\\.22 ' || true")
    listening="$(printf '%s' "$listening" | tr -cd '0-9')"
    assert ssh_port_closed "$([ "${listening:-1}" = "0" ] && echo 0 || echo 1)" \
        "${listening:-unknown} listener(s) on tcp/22"

    local disabled
    disabled=$(guest_sh "launchctl print-disabled system 2>/dev/null | grep -c '\"com.openssh.sshd\" => \\(true\\|disabled\\|1\\)' || true")
    disabled="$(printf '%s' "$disabled" | tr -cd '0-9')"
    assert sshd_disabled "$([ "${disabled:-0}" -ge 1 ] 2>/dev/null && echo 0 || echo 1)" \
        "launchctl print-disabled matches: ${disabled:-0}"

    # The credential the Tart base image ships. `dscl . -authonly` is the local-directory
    # authentication check, so this is true whether or not anything is listening.
    local accepted
    accepted=$(guest_sh "dscl . -authonly admin admin >/dev/null 2>&1 && echo yes || echo no")
    accepted="$(printf '%s' "$accepted" | tr -d '\r\n')"
    assert default_credential_rejected "$([ "$accepted" = "no" ] && echo 0 || echo 1)" \
        "admin/admin accepted=$accepted"

    check_ssh_unreachable_from_host
}

# Belt and braces from the host's side of the NAT. Best effort: the guest may report no address,
# in which case the in-guest checks above are what stand.
check_ssh_unreachable_from_host() {
    local address
    address=$(guest_sh 'ipconfig getifaddr en0 2>/dev/null || true')
    address="$(printf '%s' "$address" | tr -d '\r\n')"
    if [ -z "$address" ]; then
        skip ssh_unreachable_from_host "the guest reported no en0 address"
        return 0
    fi
    if nc -z -G 5 "$address" 22 >/dev/null 2>&1; then
        assert ssh_unreachable_from_host 1 "$address:22 accepted a connection"
    else
        assert ssh_unreachable_from_host 0 "$address:22 refused"
    fi
}

# --------------------------------------------------------------------------
# 7-8. Teardown, and the image is untouched
# --------------------------------------------------------------------------
teardown() {
    local deadline state
    log "deleting instance $INSTANCE_ID"
    rc vm delete "$INSTANCE_ID" >/dev/null 2>&1 || true
    deadline=$(($(date +%s) + TEARDOWN_TIMEOUT))
    while true; do
        state=$(instance_field '.state')
        if [ -z "$state" ] || [ "$state" = "deleted" ]; then
            assert teardown_clean 0 "final state=${state:-gone}"
            return 0
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            assert teardown_clean 1 "still $state after ${TEARDOWN_TIMEOUT}s"
            return 0
        fi
        sleep 3
    done
}

check_no_leftovers() {
    local live directory
    live=$(rc vm list 2>/dev/null |
        jq --arg p "$PROFILE" '[.instances[] | select(.profile==$p and .state!="deleted")] | length' \
            2>/dev/null) || live=-1
    assert no_live_instances "$([ "$live" = "0" ] && echo 0 || echo 1)" "$live non-deleted instance(s)"

    if [ -n "$STATE_DIR" ]; then
        directory="$STATE_DIR/instances/$INSTANCE_ID"
        assert instance_directory_removed \
            "$([ ! -d "$directory" ] && echo 0 || echo 1)" "$directory"
    else
        skip instance_directory_removed "--state-dir was not given"
    fi
}

check_image_unchanged() {
    local after
    after=$(rc image inspect "$IMAGE_REF" 2>/dev/null | jq -r '.digest') || after=""
    assert image_digest_unchanged \
        "$([ "$after" = "$IMAGE_DIGEST_BEFORE" ] && echo 0 || echo 1)" \
        "before=$IMAGE_DIGEST_BEFORE after=${after:--}"
}

# --------------------------------------------------------------------------
cleanup() {
    local rc_code=$?
    # A run that died between `create` and `teardown` must not leave a macOS guest holding one of
    # the host's two slots. `--keep` is the only way to opt out, and it is not a passing run.
    if [ -n "$INSTANCE_ID" ] && [ "$KEEP_VM" -eq 0 ] && [ "$rc_code" -ne 0 ]; then
        warn "removing instance $INSTANCE_ID after an aborted run"
        rc vm delete "$INSTANCE_ID" >/dev/null 2>&1 || true
    fi
    [ -z "$REPORT_TMP" ] || write_report
    return "$rc_code"
}

print_plan() {
    cat <<PLAN
qualify-macos-image.sh plan
  profile          $PROFILE
  socket           ${SOCKET:-<runnerctl default>}
  boot timeout     ${BOOT_TIMEOUT}s
  teardown timeout ${TEARDOWN_TIMEOUT}s
  ssh checks       $([ "$ALLOW_SSH" -eq 1 ] && echo "skipped (--allow-ssh)" || echo "enforced")

  1. resolve the profile and its image digest
  2. runnerctl vm create --profile $PROFILE
  3. wait for state=idle (cold boot + guest agent over vsock)
  4. agent handshake (bootId), agent.metrics, exec sw_vers
  5. guest agent LaunchDaemon loaded after a real boot
  6. tcp/22 closed, com.openssh.sshd disabled, admin/admin rejected, host cannot reach :22
  7. runnerctl vm delete, then no live instances and no instance directory
  8. the image digest is unchanged
PLAN
}

main() {
    parse_args "$@"
    if [ "$DRY_RUN" -eq 1 ]; then print_plan; exit 0; fi
    check_preconditions
    report_init
    trap cleanup EXIT
    create_instance
    if wait_for_idle; then
        check_agent
        check_launch_daemon
        check_ssh_lockdown
    else
        warn "the clone never reached idle; skipping the in-guest checks"
    fi
    if [ "$KEEP_VM" -eq 1 ]; then
        warn "--keep: leaving $INSTANCE_ID running; teardown and leak checks skipped"
        skip teardown_clean "--keep"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
    else
        teardown
        check_no_leftovers
    fi
    check_image_unchanged
    write_report
    if [ "$CHECKS_FAILED" -eq 0 ]; then
        log "QUALIFIED: $CHECKS_RUN checks passed for $IMAGE_REF ($IMAGE_DIGEST_BEFORE)"
        exit 0
    fi
    warn "NOT QUALIFIED: $CHECKS_FAILED of $CHECKS_RUN checks failed for $IMAGE_REF"
    exit 1
}

# Guarded so scripts/tests/qualify-macos-image-test.sh can source this file and exercise its pure
# helpers with no daemon, no VM and no network.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
