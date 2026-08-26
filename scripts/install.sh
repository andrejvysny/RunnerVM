#!/usr/bin/env bash
# Production install for the RunnerVM host side: runnerd, vmworker, runnerctl (spec §7.2, §22,
# §129, §130). Builds release binaries, ad-hoc (or Developer ID) signs vmworker with the
# virtualization entitlement, lays out the state/runtime directories with restrictive modes, and
# optionally installs a launchd job.
#
# This script never runs `sudo` itself. Any step that needs privileges it does not have is printed
# instead of executed, under "manual steps" at the end — run those yourself, or re-run this whole
# script with `sudo`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --------------------------------------------------------------------------
# Options
# --------------------------------------------------------------------------
PREFIX="/usr/local"
STATE_DIR="/Library/Application Support/RunnerVM"
RUNTIME_DIR="/var/run/runnervm"
SERVICE_USER="_runnervm"
SERVICE_GROUP="staff"
LAUNCHD="none"
CONFIG_SRC=""
LOG_LEVEL="info"
DRY_RUN=0
UNINSTALL=0
: "${CODESIGN_IDENTITY:=-}"

usage() {
    cat <<'USAGE'
usage: install.sh [options]

  --prefix <dir>        Install prefix for binaries (default: /usr/local).
  --state-dir <dir>     RunnerVM state root: images/instances/logs live under it
                         (default: /Library/Application Support/RunnerVM).
  --runtime-dir <dir>   Directory for runnerd.sock and worker sockets (default: /var/run/runnervm).
  --user <name>         Dedicated service account the daemon runs as (default: _runnervm).
  --group <name>        Group for that account (default: staff).
  --launchd <kind>      agent | daemon | none (default: none — print manual-start instructions).
  --config <yaml>       Configuration file, copied to <state-dir>/config.yaml.
  --dry-run             Print every action instead of performing it; no filesystem writes.
  --uninstall           Remove installed binaries and the launchd job; state is left in place.
  -h, --help             Show this help.

Environment: CODESIGN_IDENTITY (default "-", ad-hoc; set to a Developer ID identity for
distribution builds).

This script never invokes sudo. Steps that need privileges this shell does not have are printed
under "manual steps" instead of run; re-invoke with sudo, or run the printed commands by hand.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --state-dir) STATE_DIR="$2"; shift 2 ;;
    --runtime-dir) RUNTIME_DIR="$2"; shift 2 ;;
    --user) SERVICE_USER="$2"; shift 2 ;;
    --group) SERVICE_GROUP="$2"; shift 2 ;;
    --launchd) LAUNCHD="$2"; shift 2 ;;
    --config) CONFIG_SRC="$2"; shift 2 ;;
    --log-level) LOG_LEVEL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$LAUNCHD" in
agent | daemon | none) ;;
*) echo "--launchd must be agent, daemon or none (got: $LAUNCHD)" >&2; exit 2 ;;
esac

[ -n "$PREFIX" ] || { echo "--prefix must not be empty" >&2; exit 2; }
[ -n "$STATE_DIR" ] || { echo "--state-dir must not be empty" >&2; exit 2; }
[ -n "$RUNTIME_DIR" ] || { echo "--runtime-dir must not be empty" >&2; exit 2; }
[ -n "$SERVICE_USER" ] || { echo "--user must not be empty" >&2; exit 2; }
if [ -n "$CONFIG_SRC" ] && [ ! -f "$CONFIG_SRC" ]; then
    echo "--config file not found: $CONFIG_SRC" >&2
    exit 2
fi

# --------------------------------------------------------------------------
# Derived paths
# --------------------------------------------------------------------------
LIBEXEC_DIR="$PREFIX/libexec/runnervm"
BIN_DIR="$PREFIX/bin"
CONFIG_DEST="$STATE_DIR/config.yaml"
LOG_DIR="$STATE_DIR/logs"
LOG_PATH="$LOG_DIR/runnerd.log"
RUNNERD_BUILT="$REPO_ROOT/.build/release/runnerd"
RUNNERCTL_BUILT="$REPO_ROOT/.build/release/runnerctl"
VMWORKER_BUILT="$REPO_ROOT/.build/release/vmworker"
RUNNERD_DEST="$LIBEXEC_DIR/runnerd"
VMWORKER_DEST="$LIBEXEC_DIR/vmworker"
RUNNERCTL_DEST="$BIN_DIR/runnerctl"
AGENT_PLIST_DEST="/Library/LaunchAgents/com.runnervm.runnerd.agent.plist"
DAEMON_PLIST_DEST="/Library/LaunchDaemons/com.runnervm.runnerd.daemon.plist"

log() { printf '[install] %s\n' "$*"; }
warn() { printf '[install] warning: %s\n' "$*" >&2; }

# --------------------------------------------------------------------------
# Privileged-step helper
#
# Tries the command directly first: under a writable --prefix/--state-dir (e.g. a tmpdir) this
# just works with no privilege at all. Only when the attempt fails for a plain (non-root) user is
# the equivalent command queued as a manual "run this with sudo" step instead of retried — this
# script never calls sudo itself.
# --------------------------------------------------------------------------
MANUAL_STEPS=()

privileged() {
    local desc="$1"
    shift
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '+ %s\n' "$*"
        return 0
    fi
    if [ "$(id -u)" -eq 0 ]; then
        log "$desc"
        "$@"
        return 0
    fi
    if "$@" >/dev/null 2>&1; then
        log "$desc"
        return 0
    fi
    MANUAL_STEPS+=("$(quote_cmd "$@")")
    log "$desc — needs root, queued (see 'manual steps' below)"
}

# Sign one vmworker binary with the production entitlement and prove it took: strict signature
# verification, the entitlement present, and a `probe` run (which exercises Virtualization.framework
# without creating a VM). Every failure is fatal — there is no useful vmworker without this.
sign_and_verify_vmworker() {
    local bin="$1"
    codesign --force --sign "$CODESIGN_IDENTITY" \
        --entitlements "$REPO_ROOT/Resources/vmworker.entitlements" "$bin" \
        || { echo "error: codesign failed for $bin" >&2; exit 1; }
    codesign --verify --strict "$bin" \
        || { echo "error: signature verification failed for $bin" >&2; exit 1; }
    if ! codesign -d --entitlements :- "$bin" 2>&1 | grep -q com.apple.security.virtualization; then
        echo "error: $bin is missing com.apple.security.virtualization" >&2
        exit 1
    fi
    "$bin" probe --json >/dev/null \
        || { echo "error: $bin probe failed (entitlement not honoured or binary broken)" >&2; exit 1; }
}

step() {
    local desc="$1"
    shift
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '+ %s\n' "$*"
        return 0
    fi
    log "$desc"
    "$@"
}

quote_cmd() {
    local out="sudo"
    local arg
    for arg in "$@"; do
        out="$out $(printf '%q' "$arg")"
    done
    printf '%s' "$out"
}

# --------------------------------------------------------------------------
# Socket path budget (spec §22, §129; RunnerPaths.socketPathLimit = 100 bytes)
# --------------------------------------------------------------------------
check_socket_path_lengths() {
    local dir="$1" name path len
    for name in runnerd.sock vm-ffffffff.sock vm-ffffffff-agent.sock; do
        path="$dir/$name"
        len=$(printf '%s' "$path" | wc -c | tr -d ' ')
        if [ "$len" -gt 100 ]; then
            echo "error: socket path would be $len bytes (limit 100): $path" >&2
            echo "choose a shorter --runtime-dir" >&2
            exit 1
        fi
    done
    log "socket paths under $dir fit the 100-byte sun_path budget (worst case: $len bytes)"
}

# --------------------------------------------------------------------------
# Uninstall
# --------------------------------------------------------------------------
if [ "$UNINSTALL" -eq 1 ]; then
    log "uninstalling (state under '$STATE_DIR' and runtime dir '$RUNTIME_DIR' are left in place)"
    # --launchd defaults to "none", which for uninstall means "remove whichever is installed";
    # an explicit agent/daemon narrows removal to just that variant.
    remove_plist_if_relevant() {
        local kind="$1" dest="$2" bootout_hint="$3"
        if [ "$LAUNCHD" != "none" ] && [ "$LAUNCHD" != "$kind" ]; then
            return 0
        fi
        if [ "$DRY_RUN" -eq 0 ] && [ ! -f "$dest" ]; then
            return 0
        fi
        log "unload first: $bootout_hint"
        privileged "remove $dest" rm -f "$dest"
    }
    remove_plist_if_relevant agent "$AGENT_PLIST_DEST" \
        "launchctl bootout gui/\$(id -u $SERVICE_USER) $AGENT_PLIST_DEST"
    remove_plist_if_relevant daemon "$DAEMON_PLIST_DEST" \
        "sudo launchctl bootout system $DAEMON_PLIST_DEST"
    privileged "remove $RUNNERD_DEST" rm -f "$RUNNERD_DEST"
    privileged "remove $VMWORKER_DEST" rm -f "$VMWORKER_DEST"
    privileged "remove $RUNNERCTL_DEST" rm -f "$RUNNERCTL_DEST"
    if [ "$DRY_RUN" -eq 0 ] && [ -d "$LIBEXEC_DIR" ]; then
        rmdir "$LIBEXEC_DIR" 2>/dev/null || true
    fi
    if [ "${#MANUAL_STEPS[@]}" -gt 0 ]; then
        printf '\nmanual steps (run with sudo):\n'
        printf '  %s\n' "${MANUAL_STEPS[@]}"
    fi
    log "uninstall complete"
    exit 0
fi

# --------------------------------------------------------------------------
# 1. Verify socket path lengths before doing anything else
# --------------------------------------------------------------------------
check_socket_path_lengths "$RUNTIME_DIR"

# --------------------------------------------------------------------------
# 2. Build release binaries
# --------------------------------------------------------------------------
step "swift build -c release (runnerd, runnerctl, vmworker)" \
    env -C "$REPO_ROOT" swift build -c release \
    --product runnerd --product runnerctl --product vmworker

# --------------------------------------------------------------------------
# 3. Sign vmworker with the virtualization entitlement (spec §7.2)
# --------------------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
    printf '+ codesign --force --sign "%s" --entitlements Resources/vmworker.entitlements %s\n' \
        "$CODESIGN_IDENTITY" "$VMWORKER_BUILT"
    printf '+ codesign -d --entitlements :- %s | grep -q com.apple.security.virtualization\n' \
        "$VMWORKER_BUILT"
else
    log "codesign vmworker (identity: $CODESIGN_IDENTITY)"
    sign_and_verify_vmworker "$VMWORKER_BUILT"
    log "vmworker signed and carries com.apple.security.virtualization"
fi

# --------------------------------------------------------------------------
# 4. Install binaries
# --------------------------------------------------------------------------
privileged "create $LIBEXEC_DIR" mkdir -p "$LIBEXEC_DIR"
privileged "create $BIN_DIR" mkdir -p "$BIN_DIR"
privileged "install runnerd -> $RUNNERD_DEST" install -m 0755 "$RUNNERD_BUILT" "$RUNNERD_DEST"
privileged "install vmworker -> $VMWORKER_DEST" install -m 0755 "$VMWORKER_BUILT" "$VMWORKER_DEST"
privileged "install runnerctl -> $RUNNERCTL_DEST" install -m 0755 "$RUNNERCTL_BUILT" "$RUNNERCTL_DEST"
# `install` strips the code signature it just copied on some toolchains; codesign is idempotent,
# so re-assert it on the installed copy and verify. vmworker cannot create a single VM without
# its entitlement, so this fails closed: a signing or verification failure aborts the install.
# When the copy itself was deferred to a manual sudo step, the same commands are queued after it.
if [ "$DRY_RUN" -eq 1 ]; then
    printf '+ codesign --force --sign "%s" --entitlements Resources/vmworker.entitlements %s\n' \
        "$CODESIGN_IDENTITY" "$VMWORKER_DEST"
    printf '+ codesign --verify --strict %s && %s probe --json\n' "$VMWORKER_DEST" "$VMWORKER_DEST"
elif [ -f "$VMWORKER_DEST" ] && [ -w "$VMWORKER_DEST" ]; then
    sign_and_verify_vmworker "$VMWORKER_DEST"
    log "installed vmworker verified: signature, entitlement and probe OK"
else
    MANUAL_STEPS+=(
        "$(quote_cmd codesign --force --sign "$CODESIGN_IDENTITY" \
            --entitlements "$REPO_ROOT/Resources/vmworker.entitlements" "$VMWORKER_DEST")"
        "$(quote_cmd codesign --verify --strict "$VMWORKER_DEST")"
        "$(quote_cmd "$VMWORKER_DEST" probe --json)"
    )
    warn "vmworker not signed/verified in place yet: run the queued codesign steps before starting runnerd"
fi

# --------------------------------------------------------------------------
# 5. State and runtime directories (spec §22, §129)
# --------------------------------------------------------------------------
privileged "create $STATE_DIR (0750, $SERVICE_USER:$SERVICE_GROUP)" \
    mkdir -p -m 0750 "$STATE_DIR"
privileged "chown $STATE_DIR to $SERVICE_USER:$SERVICE_GROUP" \
    chown "$SERVICE_USER:$SERVICE_GROUP" "$STATE_DIR"
for sub in images instances logs; do
    privileged "create $STATE_DIR/$sub" mkdir -p "$STATE_DIR/$sub"
    privileged "chown $STATE_DIR/$sub to $SERVICE_USER:$SERVICE_GROUP" \
        chown "$SERVICE_USER:$SERVICE_GROUP" "$STATE_DIR/$sub"
done
privileged "create $RUNTIME_DIR (0700, $SERVICE_USER:$SERVICE_GROUP)" \
    mkdir -p -m 0700 "$RUNTIME_DIR"
privileged "chown $RUNTIME_DIR to $SERVICE_USER:$SERVICE_GROUP" \
    chown "$SERVICE_USER:$SERVICE_GROUP" "$RUNTIME_DIR"
privileged "chmod 0700 $RUNTIME_DIR" chmod 0700 "$RUNTIME_DIR"

if [ -n "$CONFIG_SRC" ]; then
    privileged "install config $CONFIG_SRC -> $CONFIG_DEST" \
        install -m 0640 "$CONFIG_SRC" "$CONFIG_DEST"
    privileged "chown $CONFIG_DEST to $SERVICE_USER:$SERVICE_GROUP" \
        chown "$SERVICE_USER:$SERVICE_GROUP" "$CONFIG_DEST"
else
    log "no --config given; place one at $CONFIG_DEST before starting runnerd"
fi

# --------------------------------------------------------------------------
# 6. launchd job (spec §7.2; plan C3 S3 — see packaging/launchd/README.md)
# --------------------------------------------------------------------------
render_plist() {
    # $1 = template path, $2 = destination path (for logging only in dry-run)
    sed \
        -e "s#__RUNNERD_PATH__#$RUNNERD_DEST#g" \
        -e "s#__CONFIG_PATH__#$CONFIG_DEST#g" \
        -e "s#__STATE_DIR__#$STATE_DIR#g" \
        -e "s#__RUNTIME_DIR__#$RUNTIME_DIR#g" \
        -e "s#__LOG_PATH__#$LOG_PATH#g" \
        -e "s#__LOG_LEVEL__#$LOG_LEVEL#g" \
        -e "s#__SERVICE_USER__#$SERVICE_USER#g" \
        -e "s#__SERVICE_GROUP__#$SERVICE_GROUP#g" \
        "$1"
}

install_plist() {
    # $1 = template path, $2 = destination path, $3 = launchctl bootstrap command to print
    local template="$1" dest="$2" load_cmd="$3"
    local rendered
    rendered="$(render_plist "$template")"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '+ render %s -> %s:\n' "$template" "$dest"
        printf '%s\n' "$rendered"
    else
        local tmp
        tmp="$(mktemp)"
        printf '%s\n' "$rendered" >"$tmp"
        privileged "install launchd plist -> $dest" install -m 0644 "$tmp" "$dest"
        rm -f "$tmp"
    fi
    log "load with: $load_cmd"
}

case "$LAUNCHD" in
agent)
    install_plist "$REPO_ROOT/packaging/launchd/com.runnervm.runnerd.agent.plist" \
        "$AGENT_PLIST_DEST" \
        "launchctl bootstrap gui/\$(id -u $SERVICE_USER) $AGENT_PLIST_DEST"
    ;;
daemon)
    install_plist "$REPO_ROOT/packaging/launchd/com.runnervm.runnerd.daemon.plist" \
        "$DAEMON_PLIST_DEST" \
        "sudo launchctl bootstrap system $DAEMON_PLIST_DEST"
    ;;
none)
    log "no --launchd variant chosen; start manually with:"
    log "  $RUNNERD_DEST --foreground --config $CONFIG_DEST --state-dir \"$STATE_DIR\" --socket-dir \"$RUNTIME_DIR\""
    log "or re-run with --launchd agent|daemon; see packaging/launchd/README.md for the trade-off."
    ;;
esac

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
if [ "${#MANUAL_STEPS[@]}" -gt 0 ]; then
    printf '\nmanual steps (this shell is not root; run these with sudo):\n'
    printf '  %s\n' "${MANUAL_STEPS[@]}"
fi
log "run '$RUNNERCTL_DEST doctor' (or 'runnerctl doctor' once $BIN_DIR is on PATH) to verify"
if [ "$DRY_RUN" -eq 1 ]; then
    log "dry run: nothing was written"
else
    log "install complete"
fi
