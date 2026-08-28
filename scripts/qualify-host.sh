#!/usr/bin/env bash
# Hardware qualification kit for running RunnerVM unattended on a Mac mini (plan T4).
#
# Proves the whole unattended chain: cold-boot host settings -> launchd job online ->
# vmworker reachable -> a real VM boots to `idle` -> guest agent ready -> (optional) a GitHub
# job runs end to end. Every check is read-only against the host except the one test VM this
# script creates and deletes itself (spec: no reboot, no pmset writes, no launchctl bootout).
#
# Run this as the RunnerVM service user (e.g. from an SSH session logged in as `_runnervm`, or
# from a LaunchAgent in its GUI session) so keychain/session checks reflect the account runnerd
# actually runs as. Use --user to inspect a different account's session via `sudo -u` instead.
#
# See docs/qualification.md for the full cold-boot / power-cut / reboot-under-load procedure.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNERD_LABEL="com.runnervm.runnerd"
DEFAULT_RESERVE_DISK_BYTES=$((50 * 1024 * 1024 * 1024))

# --------------------------------------------------------------------------
# Options (defaults mirror scripts/install.sh's production layout)
# --------------------------------------------------------------------------
PREFIX="/usr/local"
STATE_DIR="/Library/Application Support/RunnerVM"
RUNTIME_DIR="/var/run/runnervm"
CONFIG_PATH=""
SOCKET=""
RUNNERCTL_BIN=""
VMWORKER_BIN=""
PROFILE=""
LAUNCHD_MODE="auto"
SKIP_VM=0
SKIP_BUILD=0
GITHUB_JOB=0
DRY_RUN=0
REPORT_PATH=""
RUN_AS_USER=""
FV_MODE="warn"
FV_MODE_EXPLICIT=0
VM_TIMEOUT=180
WAIT_TIMEOUT=900
BUILD_RECIPE=""

usage() {
    cat <<'USAGE'
usage: qualify-host.sh [options]

Design checks (see docs/qualification.md):
  --profile <name>          Profile to boot for the VM chain check. Required unless --skip-vm.
  --github-job               Also run `runnerctl debug run-jit <profile> --wait` (needs --profile).
  --launchd agent|daemon|auto  Which launchd variant to check (default: auto-detect the loaded job).
  --skip-vm                  Skip the vm create/idle/exec/delete chain.
  --skip-build                Skip check_build_as_service's `image build` (the hdiutil-as-service
                              smoke test still runs).
  --report <path>            Append one JSON-lines record per run to this file.
  --require-filevault-off    Treat "FileVault on + auto-login" as FAIL, not WARN.
  --allow-filevault          Treat "FileVault on + auto-login" as an accepted trade-off, not WARN.
  --user <name>               Inspect this account's session via `sudo -u` instead of the caller's;
                              also the identity `check_build_as_service` builds as and
                              `runnerctl doctor --service-user` checks ownership against.
  --dry-run                  Print the VM-create/exec/delete, image-build and GitHub-job commands;
                              run every other (read-only) check for real.
  -h, --help                  Show this help.

Path overrides (defaults match scripts/install.sh's --launchd install):
  --state-dir <dir>          RunnerVM state root (default: /Library/Application Support/RunnerVM).
  --runtime-dir <dir>        Directory holding runnerd.sock (default: /var/run/runnervm).
  --config <yaml>            Config file passed to `runnerctl doctor --config`.
  --runnerctl-bin <path>      runnerctl binary (default: first found on PATH, then <prefix>/bin).
  --vmworker-bin <path>       vmworker binary (default: RUNNERVM_VMWORKER, then <prefix>/libexec).
  --build-recipe <path>       Recipe directory/file for check_build_as_service (default:
                              <state-dir>/share/recipes/ubuntu-24-minimal if installed, else the
                              repo's images/recipes/ubuntu-24-minimal).
  --vm-timeout <seconds>      Timeout waiting for the test VM to reach idle (default: 180).
  --wait-timeout <seconds>    Timeout for --github-job's run-jit --wait and for the service-identity
                              image build to reach a terminal state (default: 900).

Exit: non-zero if any check FAILs.
USAGE
}

# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
        --profile) PROFILE="$2"; shift 2 ;;
        --github-job) GITHUB_JOB=1; shift ;;
        --launchd) LAUNCHD_MODE="$2"; shift 2 ;;
        --skip-vm) SKIP_VM=1; shift ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        --build-recipe) BUILD_RECIPE="$2"; shift 2 ;;
        --report) REPORT_PATH="$2"; shift 2 ;;
        --require-filevault-off) FV_MODE="require-off"; FV_MODE_EXPLICIT=$((FV_MODE_EXPLICIT + 1)); shift ;;
        --allow-filevault) FV_MODE="allow"; FV_MODE_EXPLICIT=$((FV_MODE_EXPLICIT + 1)); shift ;;
        --user) RUN_AS_USER="$2"; shift 2 ;;
        --state-dir) STATE_DIR="$2"; shift 2 ;;
        --runtime-dir) RUNTIME_DIR="$2"; shift 2 ;;
        --config) CONFIG_PATH="$2"; shift 2 ;;
        --runnerctl-bin) RUNNERCTL_BIN="$2"; shift 2 ;;
        --vmworker-bin) VMWORKER_BIN="$2"; shift 2 ;;
        --vm-timeout) VM_TIMEOUT="$2"; shift 2 ;;
        --wait-timeout) WAIT_TIMEOUT="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
        esac
    done
}

validate_args() {
    case "$LAUNCHD_MODE" in
    agent | daemon | auto) ;;
    *) echo "--launchd must be agent, daemon or auto (got: $LAUNCHD_MODE)" >&2; exit 2 ;;
    esac
    if [ "$SKIP_VM" -eq 0 ] && [ -z "$PROFILE" ]; then
        echo "--profile is required unless --skip-vm is given" >&2
        exit 2
    fi
    if [ "$GITHUB_JOB" -eq 1 ] && [ -z "$PROFILE" ]; then
        echo "--github-job requires --profile" >&2
        exit 2
    fi
    if [ "$FV_MODE_EXPLICIT" -gt 1 ]; then
        echo "--require-filevault-off and --allow-filevault are mutually exclusive" >&2
        exit 2
    fi
}

resolve_defaults() {
    [ -n "$SOCKET" ] || SOCKET="$RUNTIME_DIR/runnerd.sock"
    if [ -z "$RUNNERCTL_BIN" ]; then
        RUNNERCTL_BIN="$(command -v runnerctl 2>/dev/null || true)"
        [ -n "$RUNNERCTL_BIN" ] || RUNNERCTL_BIN="$PREFIX/bin/runnerctl"
        [ -x "$RUNNERCTL_BIN" ] || RUNNERCTL_BIN="$REPO_ROOT/.build/debug/runnerctl"
    fi
    if [ -z "$VMWORKER_BIN" ]; then
        VMWORKER_BIN="${RUNNERVM_VMWORKER:-}"
        [ -n "$VMWORKER_BIN" ] || VMWORKER_BIN="$PREFIX/libexec/runnervm/vmworker"
        [ -x "$VMWORKER_BIN" ] || VMWORKER_BIN="$REPO_ROOT/.build/debug/vmworker"
    fi
    if [ -z "$CONFIG_PATH" ] && [ -f "$STATE_DIR/config.yaml" ]; then
        CONFIG_PATH="$STATE_DIR/config.yaml"
    fi
    if [ -z "$BUILD_RECIPE" ]; then
        if [ -f "$STATE_DIR/share/recipes/ubuntu-24-minimal/Runnerfile" ]; then
            BUILD_RECIPE="$STATE_DIR/share/recipes/ubuntu-24-minimal"
        else
            BUILD_RECIPE="$REPO_ROOT/images/recipes/ubuntu-24-minimal"
        fi
    fi
    BOOT_EPOCH="$(sysctl -n kern.boottime 2>/dev/null | sed -E 's/^\{ sec = ([0-9]+).*/\1/')" || BOOT_EPOCH=""
    resolve_service_user
}

# --------------------------------------------------------------------------
# Which account owns <state-dir> / should run the actual image build. `--user` wins outright
# (same identity the rest of the script already inspects via `as_user`); otherwise root never
# builds as itself -- fall back to the well-known default service account -- and a non-root
# caller with no --user is used as-is, noted as unproven since nothing here can confirm it is
# actually the account `scripts/install.sh` provisioned.
# --------------------------------------------------------------------------
SERVICE_USER=""
SERVICE_USER_NOTE=""

resolve_service_user() {
    SERVICE_USER_NOTE=""
    if [ -n "$RUN_AS_USER" ]; then
        # Explicitly chosen: no caveat, whatever the name -- the operator already said who.
        SERVICE_USER="$RUN_AS_USER"
        return
    fi
    if [ "$(id -u)" -eq 0 ]; then
        SERVICE_USER="_runnervm"
        return
    fi
    SERVICE_USER="$(id -un)"
    if [ "$SERVICE_USER" != "_runnervm" ]; then
        SERVICE_USER_NOTE=" (running as $SERVICE_USER, not the default _runnervm service account -- pass --user _runnervm, or run as root, to validate the real service identity)"
    fi
}

as_service_user() {
    if [ "$(id -un)" != "$SERVICE_USER" ]; then
        sudo -H -u "$SERVICE_USER" "$@"
    else
        "$@"
    fi
}

# --------------------------------------------------------------------------
# Result recording: PASS|WARN|FAIL <title>: <detail>, plus a JSON record per check.
# --------------------------------------------------------------------------
CHECK_JSON=()
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

record() {
    local id="$1" title="$2" status="$3" detail="$4"
    case "$status" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    WARN) WARN_COUNT=$((WARN_COUNT + 1)) ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    SKIP) SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
    esac
    printf '%-4s %s: %s\n' "$status" "$title" "$detail"
    CHECK_JSON+=("{\"id\":\"$(json_escape "$id")\",\"title\":\"$(json_escape "$title")\",\"status\":\"$status\",\"detail\":\"$(json_escape "$detail")\"}")
}
pass() { record "$1" "$2" PASS "$3"; }
warn() { record "$1" "$2" WARN "$3"; }
fail() { record "$1" "$2" FAIL "$3"; }
# "not applicable here", never a verdict: a skip counts towards nothing and never fails the run.
skipped() { record "$1" "$2" SKIP "$3"; }

# --------------------------------------------------------------------------
# JSON field extraction from runnerctl's `--output json` (JSONEncoder, prettyPrinted,
# sortedKeys: one `"key" : value` per line). No jq dependency — a fresh service account may
# not have Homebrew.
# --------------------------------------------------------------------------
jf_str() {
    printf '%s\n' "$1" | sed -n -E "s/^[[:space:]]*\"$2\" : \"(.*)\",?\$/\1/p" | head -1
}
jf_raw() {
    printf '%s\n' "$1" | sed -n -E "s/^[[:space:]]*\"$2\" : ([^,]*),?\$/\1/p" | head -1
}

bytes_human() {
    awk -v b="$1" 'BEGIN {
        split("B KiB MiB GiB TiB", u, " "); i = 1; v = b
        while (v >= 1024 && i < 5) { v /= 1024; i++ }
        printf "%.1f%s", v, u[i]
    }'
}

# --------------------------------------------------------------------------
# Running commands as the service user
# --------------------------------------------------------------------------
as_user() {
    if [ -n "$RUN_AS_USER" ] && [ "$(id -un)" != "$RUN_AS_USER" ]; then
        sudo -H -u "$RUN_AS_USER" "$@"
    else
        "$@"
    fi
}

runctl() {
    as_user "$RUNNERCTL_BIN" --socket "$SOCKET" "$@"
}

# --------------------------------------------------------------------------
# Host settings checks
# --------------------------------------------------------------------------
check_apple_silicon() {
    local arch hv
    arch="$(uname -m)"
    hv="$(sysctl -n kern.hv_support 2>/dev/null || echo 0)"
    if [ "$arch" = "arm64" ] && [ "$hv" = "1" ]; then
        pass apple_silicon "Apple Silicon" "arch=$arch, kern.hv_support=$hv"
    else
        fail apple_silicon "Apple Silicon" "arch=$arch, kern.hv_support=$hv; RunnerVM requires Apple Silicon"
    fi
}

check_macos_version() {
    local version major
    version="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
    major="${version%%.*}"
    if [ "$major" -ge 15 ] 2>/dev/null; then
        pass macos_version "macOS version" "macOS $version"
    else
        fail macos_version "macOS version" "macOS $version; RunnerVM requires macOS 15+"
    fi
}

pmset_value() {
    pmset -g 2>/dev/null | sed -n -E "s/^[[:space:]]*$1[[:space:]]+([0-9]+).*/\1/p" | head -1
}

check_sleep() {
    local sleep_v disksleep_v
    sleep_v="$(pmset_value sleep)"
    disksleep_v="$(pmset_value disksleep)"
    if [ -z "$sleep_v" ] || [ -z "$disksleep_v" ]; then
        warn host_sleep "Host sleep" "could not read sleep/disksleep from pmset -g"
    elif [ "$sleep_v" -eq 0 ] && [ "$disksleep_v" -eq 0 ]; then
        pass host_sleep "Host sleep" "sleep=0, disksleep=0"
    else
        warn host_sleep "Host sleep" "sleep=$sleep_v, disksleep=$disksleep_v; a sleeping host drops running VMs. Run: sudo pmset sleep 0 disksleep 0"
    fi
}

check_autorestart() {
    local v
    v="$(pmset_value autorestart)"
    if [ -z "$v" ]; then
        warn autorestart "Automatic restart on power loss" "autorestart not reported by pmset -g; run: sudo pmset autorestart 1"
    elif [ "$v" -eq 1 ]; then
        pass autorestart "Automatic restart on power loss" "autorestart=1"
    else
        warn autorestart "Automatic restart on power loss" "autorestart=$v; run: sudo pmset autorestart 1 so the host reboots itself after a power cut"
    fi
}

check_womp() {
    local v
    v="$(pmset_value womp)"
    if [ -z "$v" ]; then
        warn wake_on_lan "Wake on LAN (womp)" "womp not reported by pmset -g"
    else
        pass wake_on_lan "Wake on LAN (womp)" "womp=$v"
    fi
}

check_auto_updates() {
    local out
    out="$(softwareupdate --schedule 2>&1 || true)"
    if printf '%s' "$out" | grep -qi "turned on"; then
        warn auto_updates "Automatic macOS updates" "$out; an unattended reboot mid-job would interrupt it. Consider System Settings > General > Software Update > Automatic Updates"
    else
        pass auto_updates "Automatic macOS updates" "$out"
    fi
}

check_wired_ethernet() {
    local ports current_name="" dev wired_active=0 wifi_active=0 line
    ports="$(networksetup -listallhardwareports 2>/dev/null || true)"
    while IFS= read -r line; do
        case "$line" in
        "Hardware Port: "*) current_name="${line#Hardware Port: }" ;;
        "Device: "*)
            dev="${line#Device: }"
            if printf '%s' "$current_name" | grep -qiE 'ethernet|lan'; then
                ifconfig "$dev" 2>/dev/null | grep -q "status: active" && wired_active=1
            elif printf '%s' "$current_name" | grep -qiE 'wi-fi|airport'; then
                ifconfig "$dev" 2>/dev/null | grep -q "status: active" && wifi_active=1
            fi
            ;;
        esac
    done <<EOF
$ports
EOF
    if [ "$wired_active" -eq 1 ]; then
        pass wired_ethernet "Wired Ethernet" "an active wired Ethernet interface is present"
    elif [ "$wifi_active" -eq 1 ]; then
        warn wired_ethernet "Wired Ethernet" "only Wi-Fi is active; a dedicated CI host should use wired Ethernet"
    else
        warn wired_ethernet "Wired Ethernet" "no active wired Ethernet or Wi-Fi interface detected"
    fi
}

# --------------------------------------------------------------------------
# launchd variant + job health
# --------------------------------------------------------------------------
LAUNCHD_KIND=""

detect_launchd() {
    if [ "$LAUNCHD_MODE" != "auto" ]; then
        LAUNCHD_KIND="$LAUNCHD_MODE"
        return
    fi
    local uid
    uid="$(as_user id -u)"
    if launchctl print "gui/$uid/$RUNNERD_LABEL" >/dev/null 2>&1; then
        LAUNCHD_KIND="agent"
    elif launchctl print "system/$RUNNERD_LABEL" >/dev/null 2>&1; then
        LAUNCHD_KIND="daemon"
    else
        LAUNCHD_KIND="none"
    fi
}

check_boot_lag() {
    local pid="$1" lstart trimmed start_epoch lag
    lstart="$(ps -o lstart= -p "$pid" 2>/dev/null || true)"
    if [ -z "$lstart" ] || [ -z "$BOOT_EPOCH" ]; then
        warn launchd_boot_lag "launchd job boot-time start" "could not compute boot lag for pid $pid"
        return
    fi
    trimmed="$(printf '%s' "$lstart" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    start_epoch="$(date -j -f "%a %b %d %T %Y" "$trimmed" +%s 2>/dev/null)" || start_epoch=""
    if [ -z "$start_epoch" ]; then
        warn launchd_boot_lag "launchd job boot-time start" "could not parse process start time '$trimmed'"
        return
    fi
    lag=$((start_epoch - BOOT_EPOCH))
    pass launchd_boot_lag "launchd job boot-time start" "started ${lag}s after kern.boottime"
}

check_launchd_job() {
    local domain uid out state pid
    case "$LAUNCHD_KIND" in
    agent)
        uid="$(as_user id -u)"
        domain="gui/$uid"
        ;;
    daemon) domain="system" ;;
    *)
        fail launchd_job "launchd job" "no $RUNNERD_LABEL loaded in gui or system domain"
        return
        ;;
    esac
    if ! out="$(launchctl print "$domain/$RUNNERD_LABEL" 2>&1)"; then
        fail launchd_job "launchd job" "$domain/$RUNNERD_LABEL not loaded: $(printf '%s' "$out" | head -1)"
        return
    fi
    state="$(printf '%s\n' "$out" | sed -n -E 's/^[[:space:]]*state = (.*)$/\1/p' | head -1)"
    pid="$(printf '%s\n' "$out" | sed -n -E 's/^[[:space:]]*pid = ([0-9]+)$/\1/p' | head -1)"
    if [ "$state" = "running" ] && [ -n "$pid" ]; then
        pass launchd_job "launchd job" "$domain/$RUNNERD_LABEL ($LAUNCHD_KIND) running, pid $pid"
        check_boot_lag "$pid"
    else
        fail launchd_job "launchd job" "$domain/$RUNNERD_LABEL loaded but not running (state=${state:-unknown})"
    fi
}

# --------------------------------------------------------------------------
# FileVault / auto-login trade-off (macOS 15+ Virtualization.framework needs an unlocked login
# keychain in the session that creates the VM; see packaging/launchd/README.md).
# --------------------------------------------------------------------------
check_filevault_autologin() {
    local fv_status fv_on=0 autologin_user="" has_autologin=0 msg
    fv_status="$(fdesetup status 2>/dev/null || true)"
    case "$fv_status" in
    "FileVault is On."*) fv_on=1 ;;
    esac
    if autologin_user="$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null)"; then
        has_autologin=1
    fi

    if [ "$LAUNCHD_KIND" = "agent" ] && [ "$has_autologin" -eq 0 ]; then
        fail filevault_autologin "FileVault / auto-login" \
            "no auto-login user configured; a LaunchAgent cannot start after a cold boot with nobody logged in. FileVault: $([ "$fv_on" -eq 1 ] && echo on || echo off)"
        return
    fi

    if [ "$fv_on" -eq 1 ] && [ "$has_autologin" -eq 1 ]; then
        msg="FileVault is on and auto-login is configured for '$autologin_user'; FileVault's pre-boot password prompt defeats auto-login after a cold boot (a warm reboot with the volume already unlocked still auto-logs in). Trade-off: FileVault off gives true unattended cold-boot recovery; FileVault on gives at-rest disk encryption but needs a human at the console after a cold boot."
        case "$FV_MODE" in
        require-off) fail filevault_autologin "FileVault / auto-login" "$msg" ;;
        allow) pass filevault_autologin "FileVault / auto-login" "$msg (accepted via --allow-filevault)" ;;
        *) warn filevault_autologin "FileVault / auto-login" "$msg" ;;
        esac
        return
    fi

    pass filevault_autologin "FileVault / auto-login" \
        "FileVault $([ "$fv_on" -eq 1 ] && echo on || echo off); auto-login $([ "$has_autologin" -eq 1 ] && echo "as $autologin_user" || echo "not configured")"
}

# --------------------------------------------------------------------------
# LaunchDaemon keychain (EXPERIMENTAL, plan spike S3): a headless service account has no GUI
# session and therefore no automatically-unlocked login keychain.
# --------------------------------------------------------------------------
check_daemon_keychain() {
    [ "$LAUNCHD_KIND" = "daemon" ] || return 0
    local user home kc rc=0
    user="${RUN_AS_USER:-$(id -un)}"
    home="$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    [ -n "$home" ] || home="/Users/$user"
    kc="$home/Library/Keychains/login.keychain-db"
    as_user security show-keychain-info "$kc" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        pass daemon_keychain "LaunchDaemon keychain (EXPERIMENTAL)" "$kc is provisioned and unlocked for $user"
    else
        fail daemon_keychain "LaunchDaemon keychain (EXPERIMENTAL)" \
            "$kc missing or locked for $user (security show-keychain-info exit $rc); Virtualization.framework needs an unlocked login keychain to create a VM. doctor gap: runnerctl doctor has no equivalent check yet (tracked)."
    fi
}

# --------------------------------------------------------------------------
# Disk headroom vs. host.reserve.disk
# --------------------------------------------------------------------------
nearest_existing_ancestor() {
    local p="$1"
    while [ ! -d "$p" ] && [ "$p" != "/" ]; do p="$(dirname "$p")"; done
    printf '%s' "$p"
}

byte_size_to_bytes() {
    local s="$1" num unit
    num="$(printf '%s' "$s" | sed -E 's/^([0-9.]+).*/\1/')"
    unit="$(printf '%s' "$s" | sed -E 's/^[0-9.]+//')"
    case "$unit" in
    KiB) awk -v n="$num" 'BEGIN { printf "%.0f", n * 1024 }' ;;
    MiB) awk -v n="$num" 'BEGIN { printf "%.0f", n * 1024 * 1024 }' ;;
    GiB) awk -v n="$num" 'BEGIN { printf "%.0f", n * 1024 * 1024 * 1024 }' ;;
    TiB) awk -v n="$num" 'BEGIN { printf "%.0f", n * 1024 * 1024 * 1024 * 1024 }' ;;
    KB) awk -v n="$num" 'BEGIN { printf "%.0f", n * 1000 }' ;;
    MB) awk -v n="$num" 'BEGIN { printf "%.0f", n * 1000000 }' ;;
    GB) awk -v n="$num" 'BEGIN { printf "%.0f", n * 1000000000 }' ;;
    TB) awk -v n="$num" 'BEGIN { printf "%.0f", n * 1000000000000 }' ;;
    B | "") awk -v n="$num" 'BEGIN { printf "%.0f", n }' ;;
    *) return 1 ;;
    esac
}

parse_reserve_disk() {
    printf '%s\n' "$1" | awk '
        /^host:/ { h = 1; next }
        h && /^[a-zA-Z]/ { h = 0 }
        h && /reserve:/ { r = 1 }
        h && r && /disk:/ { gsub(/^[[:space:]]*disk:[[:space:]]*/, ""); print; exit }
    '
}

check_disk_reserve() {
    local anc free_kb free_bytes yaml disk_raw reserve_bytes source
    anc="$(nearest_existing_ancestor "$STATE_DIR")"
    free_kb="$(df -k "$anc" 2>/dev/null | awk 'NR==2{print $4}')"
    if [ -z "$free_kb" ]; then
        warn disk_reserve "Disk headroom" "could not read free space at $anc"
        return
    fi
    free_bytes=$((free_kb * 1024))
    yaml="$(runctl config get 2>/dev/null)" || yaml=""
    disk_raw="$(parse_reserve_disk "$yaml")"
    if [ -n "$disk_raw" ] && reserve_bytes="$(byte_size_to_bytes "$disk_raw")" && [ -n "$reserve_bytes" ]; then
        source="host.reserve.disk=$disk_raw (from runnerctl config get)"
    else
        reserve_bytes="$DEFAULT_RESERVE_DISK_BYTES"
        source="host.reserve.disk unknown (no applied config reachable); using the 50GiB default"
    fi
    if [ "$free_bytes" -ge "$reserve_bytes" ]; then
        pass disk_reserve "Disk headroom" "$(bytes_human "$free_bytes") free at $anc, $source"
    else
        fail disk_reserve "Disk headroom" "$(bytes_human "$free_bytes") free at $anc, below $source"
    fi
}

# --------------------------------------------------------------------------
# runnerd/vmworker reachability
# --------------------------------------------------------------------------
check_runnerctl_status() {
    local out rc=0
    out="$(runctl status --output json 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ]; then
        pass runnerctl_status "runnerctl status" "daemon reachable at $SOCKET"
    else
        fail runnerctl_status "runnerctl status" "exit $rc: $(printf '%s' "$out" | tail -1)"
    fi
}

# Captured for check_state_ownership/check_runtime_dir/check_free_memory/check_image_store below,
# so those checks read the ownership/memory/image-store-integrity verdicts `runnerctl doctor`
# already computed (Sources/runnerctl/Doctor*.swift) instead of re-implementing the same
# permission/arithmetic/sha256 logic a second time in bash. `--deep` re-hashes every stored image
# against its manifest -- worth the extra seconds here, where doctor runs once per qualification
# pass rather than on every `runnerctl doctor` invocation.
DOCTOR_JSON=""

check_runnerctl_doctor() {
    local args rc=0
    args=(doctor --state-dir "$STATE_DIR" --socket-dir "$RUNTIME_DIR" --output json --deep --service-user "$SERVICE_USER")
    [ -z "$CONFIG_PATH" ] || args+=(--config "$CONFIG_PATH")
    DOCTOR_JSON="$(runctl "${args[@]}" 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ]; then
        pass runnerctl_doctor "runnerctl doctor" "exit 0 (no failing checks)"
    else
        fail runnerctl_doctor "runnerctl doctor" "exit $rc; run 'runnerctl doctor' for detail"
    fi
}

# --------------------------------------------------------------------------
# Per-check breakouts from `runnerctl doctor --output json`'s `checks` array (JSONEncoder,
# prettyPrinted, sortedKeys: each check is exactly {"detail", "id", "status", "title"} in that
# alphabetical order, four lines). `doctor_check_block` isolates one check's four lines by its
# `id` so `jf_str` -- built for a flat single-object blob -- reads the right `status`/`detail`
# instead of the first match anywhere in the whole report.
# --------------------------------------------------------------------------
doctor_check_block() {
    printf '%s\n' "$1" | grep -B1 -A2 "\"id\" : \"$2\"" || true
}

record_from_doctor() {
    local id="$1" title="$2" block status detail
    block="$(doctor_check_block "$DOCTOR_JSON" "$id")"
    status="$(jf_str "$block" status)"
    if [ -z "$status" ]; then
        warn "$id" "$title" "not present in runnerctl doctor's report (doctor did not run, or predates this check)"
        return
    fi
    detail="$(jf_str "$block" detail)"
    case "$status" in
    ok) pass "$id" "$title" "$detail" ;;
    warn) warn "$id" "$title" "$detail" ;;
    fail) fail "$id" "$title" "$detail" ;;
    skip) skipped "$id" "$title" "$detail" ;;
    *) warn "$id" "$title" "unrecognized doctor status '$status': $detail" ;;
    esac
}

check_state_ownership() {
    record_from_doctor service_user_ownership "State/config ownership (service_user_ownership)"
}

check_runtime_dir() {
    record_from_doctor runtime_dir_perms "Runtime directory permissions (runtime_dir_perms)"
}

check_free_memory() {
    record_from_doctor free_memory "Free memory (free_memory)"
}

check_image_store() {
    record_from_doctor image_store_integrity "Image store integrity, deep (image_store_integrity)"
}

check_vmworker_probe() {
    if [ ! -x "$VMWORKER_BIN" ]; then
        fail vmworker_probe "vmworker probe (service user)" "vmworker binary not found/executable at $VMWORKER_BIN"
        return
    fi
    local out rc=0
    out="$(as_user "$VMWORKER_BIN" probe --json 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail vmworker_probe "vmworker probe (service user)" "exit $rc: $(printf '%s' "$out" | tail -1)"
        return
    fi
    local supported
    supported="$(jf_raw "$out" virtualizationSupported)"
    if [ "$supported" = "true" ]; then
        pass vmworker_probe "vmworker probe (service user)" "virtualizationSupported=true"
    else
        fail vmworker_probe "vmworker probe (service user)" "probe succeeded but virtualizationSupported=$supported"
    fi
}

# --------------------------------------------------------------------------
# VM boot chain: create -> idle -> exec -> delete. The only mutating steps in this script.
# --------------------------------------------------------------------------
VM_ID=""
VM_DELETED=1
BUILD_ID=""
BUILD_TERMINAL=1

cleanup() {
    if [ -n "$VM_ID" ] && [ "$VM_DELETED" -eq 0 ]; then
        runctl vm delete "$VM_ID" >/dev/null 2>&1 || true
    fi
    if [ -n "$BUILD_ID" ] && [ "$BUILD_TERMINAL" -eq 0 ]; then
        as_service_user "$RUNNERCTL_BIN" --socket "$SOCKET" build cancel "$BUILD_ID" >/dev/null 2>&1 || true
    fi
}

vm_wait_idle() {
    local id="$1" timeout="$2" deadline now json state
    deadline=$(($(date +%s) + timeout))
    while true; do
        now=$(date +%s)
        json="$(runctl vm show "$id" --output json 2>/dev/null)" || json=""
        state="$(jf_str "$json" state)"
        case "$state" in
        idle) printf 'idle'; return 0 ;;
        failed | interrupted | orphaned) printf '%s' "$state"; return 1 ;;
        esac
        [ "$now" -lt "$deadline" ] || { printf 'timeout'; return 1; }
        sleep 3
    done
}

vm_create_step() {
    local t0 t1 json
    t0=$(date +%s)
    if ! json="$(runctl vm create --profile "$PROFILE" --output json 2>&1)"; then
        fail vm_create "vm create" "runnerctl vm create --profile $PROFILE failed: $(printf '%s' "$json" | tail -1)"
        return 1
    fi
    VM_ID="$(jf_str "$json" id)"
    if [ -z "$VM_ID" ]; then
        fail vm_create "vm create" "could not parse instance id from response"
        return 1
    fi
    VM_DELETED=0
    t1=$(date +%s)
    pass vm_create "vm create" "instance $VM_ID created in $((t1 - t0))s"
}

vm_idle_step() {
    local t0 t1 outcome
    t0=$(date +%s)
    outcome="$(vm_wait_idle "$VM_ID" "$VM_TIMEOUT")" || {
        t1=$(date +%s)
        fail vm_idle "vm boot to idle" "instance $VM_ID did not reach idle within ${VM_TIMEOUT}s (last state: $outcome, waited $((t1 - t0))s)"
        return 1
    }
    t1=$(date +%s)
    pass vm_idle "vm boot to idle" "instance $VM_ID reached idle in $((t1 - t0))s"
}

vm_exec_step() {
    local t0 t1 out rc=0
    t0=$(date +%s)
    out="$(runctl vm exec "$VM_ID" -- uname -a 2>&1)" || rc=$?
    t1=$(date +%s)
    if [ "$rc" -ne 0 ]; then
        fail vm_exec "vm exec uname -a" "exit $rc after $((t1 - t0))s: $(printf '%s' "$out" | tail -1)"
    else
        pass vm_exec "vm exec uname -a" "$(printf '%s' "$out" | tr '\n' ' ') ($((t1 - t0))s)"
    fi
}

vm_delete_step() {
    local t0 t1
    t0=$(date +%s)
    if runctl vm delete "$VM_ID" >/dev/null 2>&1; then
        VM_DELETED=1
        t1=$(date +%s)
        pass vm_delete "vm delete" "instance $VM_ID deleted in $((t1 - t0))s"
    else
        fail vm_delete "vm delete" "failed to delete instance $VM_ID; delete it by hand: runnerctl vm delete $VM_ID"
    fi
}

vm_boot_chain() {
    if [ "$SKIP_VM" -eq 1 ]; then
        warn vm_boot "VM boot chain" "skipped (--skip-vm)"
        return
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        warn vm_boot "VM boot chain" "dry-run: would run: runnerctl vm create --profile $PROFILE; poll vm show until idle (timeout ${VM_TIMEOUT}s); vm exec -- uname -a; vm delete"
        return
    fi
    vm_create_step || return
    vm_idle_step || { vm_delete_step; return; }
    vm_exec_step
    vm_delete_step
}

# --------------------------------------------------------------------------
# Image build under the service identity: `hdiutil makehybrid` (the same probe doctor's
# `build_tools`/`build_tools_service_context` run, here guaranteed to execute as $SERVICE_USER
# rather than merely advising about a mismatch) plus, unless --skip-build, a real
# `runnerctl image build` through the running daemon -- the one part of the builder that unit
# tests and fakes cannot reach: whether the LaunchDaemon's service account can actually render a
# boot seed and drive the build to a sealed image (`docs/status.md`: "hdiutil makehybrid under a
# LaunchDaemon is gated by doctor build_tools, not yet qualified").
# --------------------------------------------------------------------------
build_wait_terminal() {
    local id="$1" timeout="$2" deadline now json state
    deadline=$(($(date +%s) + timeout))
    while true; do
        now=$(date +%s)
        json="$(as_service_user "$RUNNERCTL_BIN" --socket "$SOCKET" build show "$id" --output json 2>/dev/null)" || json=""
        state="$(jf_str "$json" state)"
        case "$state" in
        succeeded) printf 'succeeded'; return 0 ;;
        failed | cancelled) printf '%s' "$state"; return 1 ;;
        esac
        [ "$now" -lt "$deadline" ] || { printf 'timeout'; return 1; }
        sleep 5
    done
}

check_build_as_service() {
    local staging iso hdiutil_rc=0
    staging="$(mktemp -d "${TMPDIR:-/tmp}/rvm-qual-hdiutil-XXXXXX")"
    iso="$staging/smoke-test.iso"
    if as_service_user hdiutil makehybrid -quiet -iso -joliet -default-volume-name cidata -o "$iso" "$staging" >/dev/null 2>&1; then
        pass build_tools_service_context "Build tools (hdiutil, as service user)" \
            "hdiutil makehybrid succeeded as $SERVICE_USER$SERVICE_USER_NOTE"
    else
        hdiutil_rc=$?
        fail build_tools_service_context "Build tools (hdiutil, as service user)" \
            "hdiutil makehybrid failed as $SERVICE_USER (exit $hdiutil_rc)$SERVICE_USER_NOTE"
    fi
    rm -rf "$staging"

    if [ "$SKIP_BUILD" -eq 1 ]; then
        warn image_build_service "Image build (as service user)" "skipped (--skip-build)"
        return
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        warn image_build_service "Image build (as service user)" \
            "dry-run: would run: sudo -u $SERVICE_USER $RUNNERCTL_BIN --socket $SOCKET image build $BUILD_RECIPE --name qual-<ts> --no-wait; poll build show (timeout ${WAIT_TIMEOUT}s); image inspect; image delete"
        return
    fi
    if [ ! -e "$BUILD_RECIPE" ]; then
        fail image_build_service "Image build (as service user)" \
            "recipe not found at $BUILD_RECIPE; pass --build-recipe <dir-or-Runnerfile>"
        return
    fi

    local name t0 t1 json
    name="qual-$(date -u +%Y%m%d%H%M%S)"
    t0=$(date +%s)
    if ! json="$(as_service_user "$RUNNERCTL_BIN" --socket "$SOCKET" image build "$BUILD_RECIPE" --name "$name" --no-wait --output json 2>&1)"; then
        fail image_build_service "Image build (as service user)" \
            "image build $BUILD_RECIPE failed to start: $(printf '%s' "$json" | tail -1)"
        return
    fi
    BUILD_ID="$(jf_str "$json" buildId)"
    if [ -z "$BUILD_ID" ]; then
        fail image_build_service "Image build (as service user)" "could not parse buildId from response"
        return
    fi
    BUILD_TERMINAL=0

    local outcome
    outcome="$(build_wait_terminal "$BUILD_ID" "$WAIT_TIMEOUT")"
    BUILD_TERMINAL=1
    t1=$(date +%s)
    json="$(as_service_user "$RUNNERCTL_BIN" --socket "$SOCKET" build show "$BUILD_ID" --output json 2>/dev/null)" || json=""
    if [ "$outcome" != "succeeded" ]; then
        fail image_build_service "Image build (as service user)" \
            "build $BUILD_ID ($BUILD_RECIPE) ended in $outcome after $((t1 - t0))s as $SERVICE_USER: $(jf_str "$json" failureMessage)"
        return
    fi

    local digest inspect_rc=0
    digest="$(jf_str "$json" imageDigest)"
    if [ -z "$digest" ]; then
        fail image_build_service "Image build (as service user)" \
            "build $BUILD_ID succeeded after $((t1 - t0))s but reported no imageDigest"
        return
    fi
    if ! as_service_user "$RUNNERCTL_BIN" --socket "$SOCKET" image inspect "$digest" >/dev/null 2>&1; then
        inspect_rc=$?
    fi
    as_service_user "$RUNNERCTL_BIN" --socket "$SOCKET" image delete "$digest" >/dev/null 2>&1 || true

    if [ "$inspect_rc" -ne 0 ]; then
        fail image_build_service "Image build (as service user)" \
            "build $BUILD_ID succeeded ($digest) but image inspect failed (exit $inspect_rc); image deleted anyway"
        return
    fi
    pass image_build_service "Image build (as service user)" \
        "build $BUILD_ID ($BUILD_RECIPE) succeeded in $((t1 - t0))s as $SERVICE_USER$SERVICE_USER_NOTE; image $digest inspected and deleted"
}

# --------------------------------------------------------------------------
# Optional GitHub job (spec §148 debug surface)
# --------------------------------------------------------------------------
github_job_check() {
    [ "$GITHUB_JOB" -eq 1 ] || return 0
    if [ "$DRY_RUN" -eq 1 ]; then
        warn github_job "GitHub job (debug run-jit)" "dry-run: would run: runnerctl debug run-jit $PROFILE --wait --wait-timeout $WAIT_TIMEOUT"
        return
    fi
    local t0 t1 out rc=0 state result
    t0=$(date +%s)
    out="$(runctl debug run-jit "$PROFILE" --wait --wait-timeout "$WAIT_TIMEOUT" --output json 2>&1)" || rc=$?
    t1=$(date +%s)
    if [ "$rc" -ne 0 ]; then
        fail github_job "GitHub job (debug run-jit)" "exit $rc after $((t1 - t0))s: $(printf '%s' "$out" | tail -1)"
        return
    fi
    state="$(jf_str "$out" state)"
    result="$(jf_str "$out" result)"
    if [ "$state" = "completed" ]; then
        pass github_job "GitHub job (debug run-jit)" "session completed in $((t1 - t0))s (result=${result:-unknown})"
    else
        fail github_job "GitHub job (debug run-jit)" "session ended in state=$state after $((t1 - t0))s"
    fi
}

# --------------------------------------------------------------------------
# Report (JSON Lines: one record appended per run, so a reboot loop accumulates a history)
# --------------------------------------------------------------------------
write_report() {
    [ -n "$REPORT_PATH" ] || return 0
    local checks_json now_iso boot_iso
    checks_json="$(
        IFS=,
        printf '%s' "${CHECK_JSON[*]}"
    )"
    now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    boot_iso="unknown"
    if [ -n "$BOOT_EPOCH" ]; then
        boot_iso="$(date -u -r "$BOOT_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    fi
    printf '{"schema":1,"run_at":"%s","boot_time":"%s","launchd":"%s","profile":"%s","github_job":%s,"skip_vm":%s,"dry_run":%s,"summary":{"pass":%d,"warn":%d,"fail":%d},"checks":[%s]}\n' \
        "$now_iso" "$boot_iso" "$LAUNCHD_KIND" "$(json_escape "$PROFILE")" \
        "$([ "$GITHUB_JOB" -eq 1 ] && echo true || echo false)" \
        "$([ "$SKIP_VM" -eq 1 ] && echo true || echo false)" \
        "$([ "$DRY_RUN" -eq 1 ] && echo true || echo false)" \
        "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT" "$checks_json" >>"$REPORT_PATH"
    echo "report appended: $REPORT_PATH"
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
main() {
    parse_args "$@"
    validate_args
    resolve_defaults
    trap cleanup EXIT

    echo "RunnerVM host qualification — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "runnerctl: $RUNNERCTL_BIN"
    echo "vmworker:  $VMWORKER_BIN"
    echo "socket:    $SOCKET"
    echo

    check_apple_silicon
    check_macos_version
    check_sleep
    check_autorestart
    check_womp
    check_auto_updates
    check_wired_ethernet
    detect_launchd
    check_launchd_job
    check_filevault_autologin
    check_daemon_keychain
    check_disk_reserve
    check_runnerctl_status
    check_runnerctl_doctor
    check_state_ownership
    check_runtime_dir
    check_free_memory
    check_image_store
    check_vmworker_probe
    vm_boot_chain
    check_build_as_service
    github_job_check

    echo
    echo "summary: $PASS_COUNT pass, $WARN_COUNT warn, $FAIL_COUNT fail, $SKIP_COUNT skipped"
    write_report

    [ "$FAIL_COUNT" -eq 0 ]
}

# Guarded so scripts/tests/qualify-host-test.sh can `source` this file to unit-test its pure
# helpers (json_escape, byte_size_to_bytes, doctor_check_block, ...) in isolation, without running
# the checks below -- run directly (`./scripts/qualify-host.sh` or `bash scripts/qualify-host.sh`)
# this still executes exactly as before.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
