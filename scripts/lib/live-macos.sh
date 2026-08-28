# shellcheck shell=bash
# macOS-specific assertions for scripts/live-macos-e2e.sh (docs/macos-guests.md, H3-H5).
# Sourced, never executed: `source scripts/lib/live-macos.sh`, after scripts/lib/live-common.sh.
#
# Same convention as scripts/lib/live-common.sh: every function reads its context (PROFILE,
# STATE_DIR, SOCKET, RUNNERCTL_BIN, OWNER, REPO) from globals the sourcing script sets first, and
# log/warn/die come from live-common.sh. Nothing here sets `set -euo pipefail`; the caller did.
#
# What lives here rather than in live-common.sh: everything that is only true of a macOS guest --
# the per-instance Apple identity (`machine-identifier.bin`, the MAC, the auxiliary storage), the
# two-guest ceiling and its `macos-slot-N.lock` files, and the end-of-run leak invariants that
# reference them.

# --------------------------------------------------------------------------
# Per-instance Apple identity
# --------------------------------------------------------------------------
# Apple's rule is not "clones should differ" but "two concurrently *running* macOS VMs must not
# share a VZMacMachineIdentifier". The auxiliary storage is bound to that identifier, so a shared
# one strands both guests. These read the instance directory directly rather than asking the
# daemon: the identity is a file `vmworker` mints under the worker lock, and the API deliberately
# does not carry it (spec §24 keeps instance identity out of every DTO).

# Live (non-deleted) instance ids for $PROFILE, one per line.
macos_live_instance_ids() {
    rc vm list 2>/dev/null | jq -r --arg p "$PROFILE" \
        '.instances[] | select(.profile==$p and .state!="deleted") | .id' 2>/dev/null || true
}

# `<id> <machine-id-sha256> <mac> <nvram-inode>` per live instance. A field that cannot be read is
# `-`, which never compares equal to another `-`... except to itself, so the uniqueness checks
# below count distinct *non-dash* values and compare that against the instance count.
macos_identity_snapshot() {
    local id directory machine mac nvram
    [ -n "$STATE_DIR" ] || { warn "no --state-dir: cannot read per-instance identity"; return 0; }
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        directory="$STATE_DIR/instances/$id"
        machine=$(shasum -a 256 "$directory/machine-identifier.bin" 2>/dev/null | awk '{print $1}') || machine=""
        mac=$(jq -r '.macAddress // empty' "$directory/spec.json" 2>/dev/null) || mac=""
        nvram=$(stat -f '%i' "$directory/nvram.bin" 2>/dev/null) || nvram=""
        printf '%s %s %s %s\n' "$id" "${machine:--}" "${mac:--}" "${nvram:--}"
    done <<EOF
$(macos_live_instance_ids)
EOF
}

# $1 = the field to check (2 machine id, 3 MAC, 4 auxiliary storage inode), $2 = a label.
# 0 when every live instance has its own distinct, readable value.
macos_field_is_unique() {
    local field="$1" label="$2" snapshot total distinct
    snapshot="$(macos_identity_snapshot)"
    total=$(printf '%s' "$snapshot" | grep -c . || true)
    [ "$total" -gt 0 ] || { log "no live instances; $label uniqueness is vacuous"; return 0; }
    distinct=$(printf '%s\n' "$snapshot" | awk -v f="$field" '$f != "-" {print $f}' | sort -u | grep -c . || true)
    if [ "$distinct" -eq "$total" ]; then
        log "$label: $distinct distinct value(s) across $total instance(s)"
        return 0
    fi
    warn "$label: only $distinct distinct value(s) across $total instance(s)"
    printf '%s\n' "$snapshot" >&2
    return 1
}

macos_assert_identity_unique() {
    local failed=0
    macos_field_is_unique 2 "machine identifier" || failed=1
    macos_field_is_unique 3 "MAC address" || failed=1
    macos_field_is_unique 4 "auxiliary storage" || failed=1
    return "$failed"
}

# The identity that must *not* change: a restart of the same instance is the same virtual Mac.
# $1 = instance id. Prints the sha256 of its machine identifier, or nothing.
macos_machine_identifier() {
    [ -n "$STATE_DIR" ] || return 0
    shasum -a 256 "$STATE_DIR/instances/$1/machine-identifier.bin" 2>/dev/null | awk '{print $1}'
}

# --------------------------------------------------------------------------
# The two-guest ceiling
# --------------------------------------------------------------------------
# `HostConstants.macOSGuestLimit`, fenced twice: runnerd's admission check and the
# `macos-slot-N.lock` files each vmworker takes for its whole life
# (Sources/VirtualizationCore/MacOSGuestSlot.swift). After a clean run every slot must be free,
# because the kernel drops a record lock when its holder dies.

macos_slot_dir() {
    if [ -n "${SOCKET:-}" ]; then dirname "$SOCKET"; else printf '%s' "${RUNNERVM_RUNTIME_DIR:-}"; fi
}

# Number of macOS slot locks currently held by a live process. `-1` when it cannot be determined,
# which the caller reports as "unknown" rather than as a leak.
macos_slots_held() {
    local directory held=0 lock
    directory="$(macos_slot_dir)"
    [ -n "$directory" ] && [ -d "$directory" ] || { printf '%s' -1; return 0; }
    command -v python3 >/dev/null 2>&1 || { printf '%s' -1; return 0; }
    for lock in "$directory"/macos-slot-*.lock; do
        [ -e "$lock" ] || continue
        # Taking the lock non-blockingly is the only portable probe: macOS has no `flock(1)`, and
        # `lsof` on a lock file says who has it *open*, not who holds the record lock.
        if python3 -c '
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
try:
    fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(1)
sys.exit(0)
' "$lock" 2>/dev/null; then
            continue
        fi
        held=$((held + 1))
    done
    printf '%s' "$held"
}

# --------------------------------------------------------------------------
# End-of-run invariants
# --------------------------------------------------------------------------
# A soak that reports "100 of 100 workflows succeeded" and leaves two orphaned guests behind is a
# failed soak. These are the assertions that turn a success counter into an invariant test.
#
# $1 = the image digest captured before the run. Returns 0 only when every invariant holds.
macos_assert_no_leaks() {
    local expected_digest="$1" failed=0 value

    value=$(github_runner_count "$PROFILE") || value=-1
    if [ "$value" = "0" ]; then
        log "invariant: GitHub lists no runner for $PROFILE"
    else
        warn "invariant FAILED: GitHub still lists $value runner(s) for $PROFILE"
        failed=1
    fi

    value=$(rc runner list --active 2>/dev/null |
        jq --arg p "$PROFILE" '[.sessions[] | select(.profile==$p)] | length' 2>/dev/null) || value=-1
    if [ "$value" = "0" ]; then
        log "invariant: no non-terminal sessions"
    else
        warn "invariant FAILED: $value non-terminal session(s)"
        failed=1
    fi

    value=$(rc vm list 2>/dev/null | jq --arg p "$PROFILE" \
        '[.instances[] | select(.profile==$p and .state!="deleted")] | length' 2>/dev/null) || value=-1
    if [ "$value" = "0" ]; then
        log "invariant: no capacity-consuming instances"
    else
        warn "invariant FAILED: $value live instance(s)"
        failed=1
    fi

    macos_assert_no_directory_leak || failed=1
    macos_assert_no_worker_leak || failed=1
    macos_assert_slots_free || failed=1

    value=$(rc image inspect "$IMAGE_REF" 2>/dev/null | jq -r '.digest' 2>/dev/null) || value=""
    if [ "$value" = "$expected_digest" ]; then
        log "invariant: the image digest is unchanged"
    else
        warn "invariant FAILED: image digest $expected_digest -> ${value:--}"
        failed=1
    fi
    return "$failed"
}

# `instances/` holds one directory per live VM plus a `.tmp` staging root. A directory that
# outlives its row is the leak that eventually fills the disk.
macos_assert_no_directory_leak() {
    local count
    [ -n "$STATE_DIR" ] || { log "invariant SKIPPED: instance directories (no --state-dir)"; return 0; }
    [ -d "$STATE_DIR/instances" ] || { log "invariant: no instances directory"; return 0; }
    count=$(find "$STATE_DIR/instances" -mindepth 1 -maxdepth 1 -type d \
        ! -name '.*' 2>/dev/null | wc -l | tr -d ' ') || count=-1
    if [ "$count" = "0" ]; then
        log "invariant: no live instance directories"
        return 0
    fi
    warn "invariant FAILED: $count instance director(ies) left in $STATE_DIR/instances"
    find "$STATE_DIR/instances" -mindepth 1 -maxdepth 1 -type d ! -name '.*' >&2 2>/dev/null || true
    return 1
}

macos_assert_no_worker_leak() {
    local pids count
    # The bracket keeps pgrep from matching its own command line.
    pids=$(pgrep -f '[v]mworker' 2>/dev/null || true)
    count=$(printf '%s' "$pids" | grep -c . || true)
    if [ "$count" = "0" ]; then
        log "invariant: no vmworker processes"
        return 0
    fi
    warn "invariant FAILED: $count vmworker process(es) still running: $(printf '%s' "$pids" | tr '\n' ' ')"
    return 1
}

macos_assert_slots_free() {
    local held
    held=$(macos_slots_held)
    case "$held" in
    0) log "invariant: both macOS guest slots are free"; return 0 ;;
    -1) log "invariant SKIPPED: macOS slot locks (no runtime directory or no python3)"; return 0 ;;
    *) warn "invariant FAILED: $held macOS guest slot(s) still held"; return 1 ;;
    esac
}
