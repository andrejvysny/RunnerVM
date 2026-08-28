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
SERVICE_GROUP="_runnervm"
LAUNCHD="none"
CONFIG_SRC=""
LOG_LEVEL="info"
DRY_RUN=0
UNINSTALL=0
ALLOW_STAFF_GROUP=0
SKIP_GUEST_AGENT=0
PREBUILT_DIR=""
: "${CODESIGN_IDENTITY:=-}"

usage() {
    cat <<'USAGE'
usage: install.sh [options]

  --prefix <dir>        Install prefix for binaries (default: /usr/local).
  --state-dir <dir>     RunnerVM state root: images/instances/logs live under it
                         (default: /Library/Application Support/RunnerVM).
  --runtime-dir <dir>   Directory for runnerd.sock and worker sockets (default: /var/run/runnervm).
  --user <name>         Dedicated service account the daemon runs as (default: _runnervm).
  --group <name>        Group for that account (default: _runnervm). --allow-staff-group is
                         required to set this to "staff".
  --launchd <kind>      agent | daemon | none (default: none — print manual-start instructions).
  --config <yaml>       Configuration file, copied to <state-dir>/config.yaml.
  --allow-staff-group   Permit --group staff (or a default left unchanged from an older install).
                         Refused otherwise: every local macOS user is in "staff", so state/log/
                         config modes end up readable by every account on the Mac.
  --skip-guest-agent    Skip building/installing the Linux guest-agent binary the image builder's
                         boot seed installs. Only useful when Go is unavailable and a build isn't
                         needed on this host; `runnerctl image build` will fail without it.
  --prebuilt-dir <dir>  Use already-built artifacts from <dir> instead of building from source:
                         <dir>/bin/runnerctl, <dir>/libexec/{runnerd,vmworker},
                         <dir>/share/runnervm/{Resources,recipes,guest-agent/...} -- the layout a
                         Homebrew keg installs (see the runnervm formula). Skips `swift build` and
                         `make -C GuestAgent build-linux` entirely; everything else (signing,
                         service account, state dir, launchd) is unchanged.
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
    --allow-staff-group) ALLOW_STAFF_GROUP=1; shift ;;
    --skip-guest-agent) SKIP_GUEST_AGENT=1; shift ;;
    --prebuilt-dir) PREBUILT_DIR="$2"; shift 2 ;;
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
if [ -n "$PREBUILT_DIR" ] && [ ! -d "$PREBUILT_DIR" ]; then
    echo "--prebuilt-dir not found: $PREBUILT_DIR" >&2
    exit 2
fi

# --group staff is refused by default: every local macOS user is a member of "staff" (GID 20, the
# default primary group for admin and most human accounts), so <state-dir> at 0750 and config/log
# files at 0640 owned by $SERVICE_USER:staff end up readable by every other account on the Mac --
# including runner _diag bundles, serial console logs and GitHub credentials (spec §129). Fails
# fast, before any build or filesystem work.
if [ "$SERVICE_GROUP" = "staff" ] && [ "$ALLOW_STAFF_GROUP" -ne 1 ]; then
    cat >&2 <<EOF
error: --group staff refused.

Every local user account on this Mac is a member of "staff". Running the service under that
group means <state-dir> (0750) and its config/log files (0640) are readable by every other
account, defeating the point of the restrictive modes -- this includes GitHub credentials and
runner _diag bundles that can contain job output.

Use the dedicated "_runnervm" group instead (this script's default; see "docs/install.md",
"Dedicated service account and auto-login"), or pass --allow-staff-group if you have reviewed
and accept that every local account can read RunnerVM's state, logs and secrets.
EOF
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
RUNNERD_DEST="$LIBEXEC_DIR/runnerd"
VMWORKER_DEST="$LIBEXEC_DIR/vmworker"
RUNNERCTL_DEST="$BIN_DIR/runnerctl"
AGENT_PLIST_DEST="/Library/LaunchAgents/com.runnervm.runnerd.agent.plist"
DAEMON_PLIST_DEST="/Library/LaunchDaemons/com.runnervm.runnerd.daemon.plist"
# Image builder assets (spec P6): the Linux guest agent the boot seed installs, the shipped
# Runnerfile recipes, and the directories the builder itself expects under STATE_DIR
# (RunnerPaths.buildsDir/baseImageCacheDir/buildLogsDir -- see Sources/RunnerCore/Configuration/Paths.swift).
GUEST_AGENT_DIR="$STATE_DIR/guest-agent/linux-arm64"
GUEST_AGENT_DEST="$GUEST_AGENT_DIR/runnervm-guest-agent"
GUEST_AGENT_UNIT_DEST="$GUEST_AGENT_DIR/runnervm-guest-agent.service"
RECIPES_DEST="$STATE_DIR/share/recipes"

# Where the binaries/assets to install come from: either freshly built from this checkout
# (default), or already built and staged by something else (a Homebrew keg -- see the runnervm
# formula) and pointed at via --prebuilt-dir. Either way, everything past this point (signing,
# service account, state dir, launchd) is identical.
if [ -n "$PREBUILT_DIR" ]; then
    RUNNERD_BUILT="$PREBUILT_DIR/libexec/runnerd"
    RUNNERCTL_BUILT="$PREBUILT_DIR/bin/runnerctl"
    VMWORKER_BUILT="$PREBUILT_DIR/libexec/vmworker"
    ENTITLEMENTS_PATH="$PREBUILT_DIR/share/runnervm/Resources/vmworker.entitlements"
    GUEST_AGENT_BUILT="$PREBUILT_DIR/share/runnervm/guest-agent/linux-arm64/runnervm-guest-agent"
    GUEST_AGENT_UNIT_SRC="$PREBUILT_DIR/share/runnervm/guest-agent/systemd/runnervm-guest-agent.service"
    RECIPES_SRC="$PREBUILT_DIR/share/runnervm/recipes"
else
    RUNNERD_BUILT="$REPO_ROOT/.build/release/runnerd"
    RUNNERCTL_BUILT="$REPO_ROOT/.build/release/runnerctl"
    VMWORKER_BUILT="$REPO_ROOT/.build/release/vmworker"
    ENTITLEMENTS_PATH="$REPO_ROOT/Resources/vmworker.entitlements"
    GUEST_AGENT_BUILT="$REPO_ROOT/GuestAgent/bin/linux-arm64/runnervm-guest-agent"
    GUEST_AGENT_UNIT_SRC="$REPO_ROOT/GuestAgent/packaging/systemd/runnervm-guest-agent.service"
    RECIPES_SRC="$REPO_ROOT/images/recipes"
fi

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
        --entitlements "$ENTITLEMENTS_PATH" "$bin" \
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
# Service group/user (spec §7.2, §129)
#
# dscl reads (existence/GID checks) are harmless without privilege and always run for real, dry
# run or not, so the plan below reflects this machine's actual directory service state. Only the
# dscl mutations that create/fix records go through privileged() -- this script still never calls
# sudo itself.
#
# The account is created with dscl alone, never `sysadminctl -addUser`: that command's
# `-password -` prompts on stdin, which hangs a non-interactive install, and it provisions a
# login-capable account with a home under /Users. The service account never logs in -- no GUI
# session, no login keychain, no password -- so a hidden record with `Password '*'`,
# `UserShell /usr/bin/false` and a home inside the state directory is both sufficient and tighter.
# --------------------------------------------------------------------------
GROUP_GID_MIN=200
GROUP_GID_MAX=400

# Hidden "system" GID range on macOS is everything below 500; 200-400 avoids the low end that
# Apple's own daemons occupy densely. Prints the first unused GID in range on stdout.
find_free_gid() {
    local gid="$GROUP_GID_MIN" used
    used="$(dscl . -list /Groups PrimaryGroupID 2>/dev/null | awk '{print $2}')"
    while [ "$gid" -le "$GROUP_GID_MAX" ]; do
        if ! printf '%s\n' "$used" | grep -qx "$gid"; then
            printf '%s' "$gid"
            return 0
        fi
        gid=$((gid + 1))
    done
    return 1
}

# Same range for UIDs. Prefers uid == the service group's gid when that number is free, purely so
# the pair reads as one identity in `ls -n` output; falls back to the first free UID otherwise.
find_free_uid() {
    local preferred="$1" uid="$GROUP_GID_MIN" used
    used="$(dscl . -list /Users UniqueID 2>/dev/null | awk '{print $2}')"
    if [ -n "$preferred" ] && ! printf '%s\n' "$used" | grep -qx "$preferred"; then
        printf '%s' "$preferred"
        return 0
    fi
    while [ "$uid" -le "$GROUP_GID_MAX" ]; do
        if ! printf '%s\n' "$used" | grep -qx "$uid"; then
            printf '%s' "$uid"
            return 0
        fi
        uid=$((uid + 1))
    done
    return 1
}

# Ensure $SERVICE_GROUP and $SERVICE_USER exist, and that the user's primary group is
# $SERVICE_GROUP. Missing/incorrect pieces are queued as manual dscl steps (or run directly when
# this shell already has the privilege, same as every other step in this script).
ensure_service_principals() {
    local group_attr user_attr group_gid user_pgid new_gid new_uid

    group_attr="$(dscl . -read "/Groups/$SERVICE_GROUP" PrimaryGroupID 2>/dev/null || true)"
    if [ -z "$group_attr" ]; then
        new_gid="$(find_free_gid)" || {
            echo "error: no free GID in ${GROUP_GID_MIN}-${GROUP_GID_MAX} for group $SERVICE_GROUP" >&2
            exit 1
        }
        log "group $SERVICE_GROUP does not exist — queuing creation with GID $new_gid"
        privileged "create group $SERVICE_GROUP" dscl . -create "/Groups/$SERVICE_GROUP"
        privileged "set $SERVICE_GROUP PrimaryGroupID $new_gid" \
            dscl . -create "/Groups/$SERVICE_GROUP" PrimaryGroupID "$new_gid"
        privileged "set $SERVICE_GROUP RealName" \
            dscl . -create "/Groups/$SERVICE_GROUP" RealName "RunnerVM Service"
        privileged "set $SERVICE_GROUP Password" \
            dscl . -create "/Groups/$SERVICE_GROUP" Password "*"
        group_gid="$new_gid"
    else
        group_gid="${group_attr#PrimaryGroupID: }"
        log "group $SERVICE_GROUP exists (GID $group_gid)"
    fi

    user_attr="$(dscl . -read "/Users/$SERVICE_USER" PrimaryGroupID 2>/dev/null || true)"
    if [ -z "$user_attr" ]; then
        new_uid="$(find_free_uid "$group_gid")" || {
            echo "error: no free UID in ${GROUP_GID_MIN}-${GROUP_GID_MAX} for user $SERVICE_USER" >&2
            exit 1
        }
        log "user $SERVICE_USER does not exist — queuing creation with UID $new_uid, primary group $SERVICE_GROUP (GID $group_gid)"
        privileged "create user $SERVICE_USER" dscl . -create "/Users/$SERVICE_USER"
        # No login shell: the account exists to own files and run launchd jobs, never to log in.
        privileged "set $SERVICE_USER UserShell" \
            dscl . -create "/Users/$SERVICE_USER" UserShell /usr/bin/false
        privileged "set $SERVICE_USER RealName" \
            dscl . -create "/Users/$SERVICE_USER" RealName "RunnerVM Service"
        privileged "set $SERVICE_USER UniqueID $new_uid" \
            dscl . -create "/Users/$SERVICE_USER" UniqueID "$new_uid"
        privileged "set $SERVICE_USER PrimaryGroupID $group_gid" \
            dscl . -create "/Users/$SERVICE_USER" PrimaryGroupID "$group_gid"
        # Home lives inside the state directory, not /Users: nothing about this account belongs in
        # the login window's user list, and $STATE_DIR is already the tree it owns.
        privileged "set $SERVICE_USER NFSHomeDirectory" \
            dscl . -create "/Users/$SERVICE_USER" NFSHomeDirectory "$STATE_DIR/home"
        # '*' is "no password will ever authenticate", not "empty password".
        privileged "set $SERVICE_USER Password" \
            dscl . -create "/Users/$SERVICE_USER" Password '*'
        privileged "hide $SERVICE_USER from the login window" \
            dscl . -create "/Users/$SERVICE_USER" IsHidden 1
    else
        user_pgid="${user_attr#PrimaryGroupID: }"
        if [ "$user_pgid" != "$group_gid" ]; then
            privileged "fix $SERVICE_USER PrimaryGroupID -> $group_gid ($SERVICE_GROUP)" \
                dscl . -create "/Users/$SERVICE_USER" PrimaryGroupID "$group_gid"
            log "user $SERVICE_USER exists but its primary group was GID $user_pgid, not $SERVICE_GROUP — queued fix"
        else
            log "user $SERVICE_USER exists with primary group $SERVICE_GROUP (GID $group_gid)"
        fi
    fi
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
# 1. Ensure the service group/user exist with the right relationship (spec §7.2, §129)
# --------------------------------------------------------------------------
ensure_service_principals

# --------------------------------------------------------------------------
# 2. Verify socket path lengths before doing anything else
# --------------------------------------------------------------------------
check_socket_path_lengths "$RUNTIME_DIR"

# --------------------------------------------------------------------------
# 3. Build release binaries
# --------------------------------------------------------------------------
if [ -n "$PREBUILT_DIR" ]; then
    log "using prebuilt artifacts from $PREBUILT_DIR (skipping swift build)"
else
    # One invocation per product: SwiftPM keeps only the LAST --product flag when the flag is
    # repeated, so the old single call silently built vmworker alone.
    for product in runnerd runnerctl vmworker; do
        step "swift build -c release --product $product" \
            env -C "$REPO_ROOT" swift build -c release --product "$product"
    done
fi

# --------------------------------------------------------------------------
# 4. Sign vmworker with the virtualization entitlement (spec §7.2)
# --------------------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
    printf '+ codesign --force --sign "%s" --entitlements %s %s\n' \
        "$CODESIGN_IDENTITY" "$ENTITLEMENTS_PATH" "$VMWORKER_BUILT"
    printf '+ codesign -d --entitlements :- %s | grep -q com.apple.security.virtualization\n' \
        "$VMWORKER_BUILT"
else
    log "codesign vmworker (identity: $CODESIGN_IDENTITY)"
    sign_and_verify_vmworker "$VMWORKER_BUILT"
    log "vmworker signed and carries com.apple.security.virtualization"
fi

# --------------------------------------------------------------------------
# 5. Install binaries
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
    printf '+ codesign --force --sign "%s" --entitlements %s %s\n' \
        "$CODESIGN_IDENTITY" "$ENTITLEMENTS_PATH" "$VMWORKER_DEST"
    printf '+ codesign --verify --strict %s && %s probe --json\n' "$VMWORKER_DEST" "$VMWORKER_DEST"
elif [ -f "$VMWORKER_DEST" ] && [ -w "$VMWORKER_DEST" ]; then
    sign_and_verify_vmworker "$VMWORKER_DEST"
    log "installed vmworker verified: signature, entitlement and probe OK"
else
    MANUAL_STEPS+=(
        "$(quote_cmd codesign --force --sign "$CODESIGN_IDENTITY" \
            --entitlements "$ENTITLEMENTS_PATH" "$VMWORKER_DEST")"
        "$(quote_cmd codesign --verify --strict "$VMWORKER_DEST")"
        "$(quote_cmd "$VMWORKER_DEST" probe --json)"
    )
    warn "vmworker not signed/verified in place yet: run the queued codesign steps before starting runnerd"
fi

# --------------------------------------------------------------------------
# 6. State and runtime directories (spec §22, §129)
# --------------------------------------------------------------------------
privileged "create $STATE_DIR (0750, $SERVICE_USER:$SERVICE_GROUP)" \
    mkdir -p -m 0750 "$STATE_DIR"
privileged "chown $STATE_DIR to $SERVICE_USER:$SERVICE_GROUP" \
    chown "$SERVICE_USER:$SERVICE_GROUP" "$STATE_DIR"
for sub in images instances logs state cache; do
    privileged "create $STATE_DIR/$sub" mkdir -p "$STATE_DIR/$sub"
    privileged "chown $STATE_DIR/$sub to $SERVICE_USER:$SERVICE_GROUP" \
        chown "$SERVICE_USER:$SERVICE_GROUP" "$STATE_DIR/$sub"
done
# The service account's NFSHomeDirectory (see ensure_service_principals). It is never logged into,
# but anything that resolves $HOME for the daemon -- git, the GitHub runner's own tooling -- needs
# a directory that exists and that the account owns.
privileged "create $STATE_DIR/home (0750, $SERVICE_USER:$SERVICE_GROUP)" \
    mkdir -p -m 0750 "$STATE_DIR/home"
privileged "chown $STATE_DIR/home to $SERVICE_USER:$SERVICE_GROUP" \
    chown "$SERVICE_USER:$SERVICE_GROUP" "$STATE_DIR/home"
privileged "chmod 0750 $STATE_DIR/home" chmod 0750 "$STATE_DIR/home"
# logs/ and logs/instances hold runner _diag bundles, serial console output and job logs --
# owner + service group only, no world access, matching <state-dir> itself.
privileged "chmod 0750 $STATE_DIR/logs" chmod 0750 "$STATE_DIR/logs"
privileged "create $STATE_DIR/logs/instances (0750, $SERVICE_USER:$SERVICE_GROUP)" \
    mkdir -p -m 0750 "$STATE_DIR/logs/instances"
privileged "chown $STATE_DIR/logs/instances to $SERVICE_USER:$SERVICE_GROUP" \
    chown "$SERVICE_USER:$SERVICE_GROUP" "$STATE_DIR/logs/instances"
# Image builder directories (spec P6): RunnerPaths.buildsDir / .baseImageCacheDir / .buildLogsDir
# (Sources/RunnerCore/Configuration/Paths.swift) -- runnerd creates these lazily too, but a fresh
# install lays them out up front with the same ownership as everything else under $STATE_DIR.
privileged "create $STATE_DIR/state/builds" mkdir -p "$STATE_DIR/state/builds"
privileged "chown $STATE_DIR/state/builds to $SERVICE_USER:$SERVICE_GROUP" \
    chown "$SERVICE_USER:$SERVICE_GROUP" "$STATE_DIR/state/builds"
privileged "create $STATE_DIR/cache/base-images" mkdir -p "$STATE_DIR/cache/base-images"
privileged "chown $STATE_DIR/cache/base-images to $SERVICE_USER:$SERVICE_GROUP" \
    chown "$SERVICE_USER:$SERVICE_GROUP" "$STATE_DIR/cache/base-images"
privileged "create $LOG_DIR/builds (0750, $SERVICE_USER:$SERVICE_GROUP)" \
    mkdir -p -m 0750 "$LOG_DIR/builds"
privileged "chown $LOG_DIR/builds to $SERVICE_USER:$SERVICE_GROUP" \
    chown "$SERVICE_USER:$SERVICE_GROUP" "$LOG_DIR/builds"
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
# 6b. Image builder assets (spec P6): the Linux guest agent the boot seed installs, and the
#     shipped Runnerfile recipes. Both are optional-ish (guest agent build can be skipped; a
#     recipe root can always be pointed at directly), but `runnerctl image build` needs at least
#     one of them to be useful out of the box.
# --------------------------------------------------------------------------
if [ "$SKIP_GUEST_AGENT" -eq 1 ]; then
    warn "--skip-guest-agent: not installing a guest agent; \`runnerctl image build\` will fail until one is placed at $GUEST_AGENT_DEST"
elif [ -f "$GUEST_AGENT_BUILT" ]; then
    log "found prebuilt guest agent: $GUEST_AGENT_BUILT"
elif [ -n "$PREBUILT_DIR" ]; then
    # --prebuilt-dir has no GuestAgent source tree to build from -- the keg was expected to
    # already carry this binary (the runnervm formula always builds it).
    echo "error: guest agent not found at $GUEST_AGENT_BUILT (expected under --prebuilt-dir $PREBUILT_DIR)" >&2
    echo "pass --skip-guest-agent to install without it (image builds will fail until one is" >&2
    echo "placed at $GUEST_AGENT_DEST)." >&2
    exit 1
elif [ "$DRY_RUN" -eq 1 ]; then
    # Never actually build in a dry run: whether Go happens to be installed on the machine
    # running --dry-run has nothing to do with what a real install would do.
    printf '+ make -C GuestAgent build-linux\n'
elif command -v go >/dev/null 2>&1; then
    step "make -C GuestAgent build-linux" make -C "$REPO_ROOT/GuestAgent" build-linux
else
    echo "error: $GUEST_AGENT_BUILT not found and Go is not installed to build it." >&2
    echo "install Go, or pass --skip-guest-agent to install without it (image builds will fail" >&2
    echo "until a guest agent is placed at $GUEST_AGENT_DEST)." >&2
    exit 1
fi

if [ "$SKIP_GUEST_AGENT" -ne 1 ]; then
    privileged "create $GUEST_AGENT_DIR" mkdir -p "$GUEST_AGENT_DIR"
    privileged "install guest agent -> $GUEST_AGENT_DEST" \
        install -m 0755 "$GUEST_AGENT_BUILT" "$GUEST_AGENT_DEST"
    privileged "chown $GUEST_AGENT_DEST to $SERVICE_USER:$SERVICE_GROUP" \
        chown "$SERVICE_USER:$SERVICE_GROUP" "$GUEST_AGENT_DEST"
    # The unit is never read by the builder (BuildSeed.guestAgentUnit ships it inline, kept
    # byte-identical to this file) -- installed alongside the binary purely for operator reference.
    privileged "install guest agent systemd unit -> $GUEST_AGENT_UNIT_DEST" \
        install -m 0644 "$GUEST_AGENT_UNIT_SRC" "$GUEST_AGENT_UNIT_DEST"
    privileged "chown $GUEST_AGENT_UNIT_DEST to $SERVICE_USER:$SERVICE_GROUP" \
        chown "$SERVICE_USER:$SERVICE_GROUP" "$GUEST_AGENT_UNIT_DEST"
fi

# root:$SERVICE_GROUP (not $SERVICE_USER) on purpose: the daemon reads these but must not be able
# to rewrite the shipped recipes it builds from.
install_recipes() {
    privileged "create $RECIPES_DEST" mkdir -p "$RECIPES_DEST"
    privileged "chown $RECIPES_DEST to root:$SERVICE_GROUP" chown "root:$SERVICE_GROUP" "$RECIPES_DEST"
    privileged "chmod 0755 $RECIPES_DEST" chmod 0755 "$RECIPES_DEST"

    local src rel dest
    while IFS= read -r -d '' src; do
        rel="${src#"$RECIPES_SRC"/}"
        dest="$RECIPES_DEST/$rel"
        if [ -d "$src" ]; then
            privileged "create $dest" mkdir -p "$dest"
            privileged "chown $dest to root:$SERVICE_GROUP" chown "root:$SERVICE_GROUP" "$dest"
            privileged "chmod 0755 $dest" chmod 0755 "$dest"
        else
            privileged "install $rel -> $dest" install -m 0644 "$src" "$dest"
            privileged "chown $dest to root:$SERVICE_GROUP" chown "root:$SERVICE_GROUP" "$dest"
        fi
    done < <(find "$RECIPES_SRC" -mindepth 1 \( -type d -o -type f \) -print0 | sort -z)
}
install_recipes

# --------------------------------------------------------------------------
# 7. launchd job (spec §7.2; plan C3 S3 — see packaging/launchd/README.md)
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
