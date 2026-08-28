# shellcheck shell=bash
# Tart VM lifecycle and the build-time SSH transport for scripts/provision-macos-tart.sh.
# Sourced, never executed: `source scripts/lib/macos-provision-vm.sh`.
#
# Same convention as scripts/lib/live-common.sh: every function reads its context (NAME, SOURCE,
# FORCE, SSH_USER, SSH_PASSWORD, SSH_KEY, GUEST_IP, TART_PID, WORK, GRACEFUL_SHUTDOWN, the
# *_TIMEOUT values) from globals the sourcing script sets first, and log/warn/die come from there
# too. Nothing here sets `set -euo pipefail`; the caller already did.
#
# This file exists because provisioning macOS needs a real login channel -- there is no cloud-init
# for a macOS guest -- and that transport is the one part of the script with no place in the
# finished image: RunnerVM manages the built guest over vsock.

# Timeouts and the expect-helper paths live here rather than in the caller: they are read only by
# the functions below, and a per-file shellcheck pass over the caller would call them unused.
IP_TIMEOUT="${RVM_IP_TIMEOUT:-300}"
SSH_TIMEOUT="${RVM_SSH_TIMEOUT:-300}"
SHUTDOWN_TIMEOUT="${RVM_SHUTDOWN_TIMEOUT:-300}"
EXPECT_HELPER=""
PASS_FILE=""

# --------------------------------------------------------------------------
# Tart
# --------------------------------------------------------------------------

# Pure: does $1 appear as a VM name in the `tart list --quiet` output $2? OCI-sourced images are
# listed under their full reference, which is how --source is spelled.
vm_exists_in_list() {
    printf '%s\n' "$2" | grep -Fxq "$1"
}

vm_exists() { vm_exists_in_list "$1" "$(tart list --quiet 2>/dev/null || true)"; }

vm_dir() { printf '%s/vms/%s' "$TART_HOME" "$1"; }

clone_vm() {
    if vm_exists "$NAME"; then
        [ "$FORCE" -eq 1 ] || die "VM already exists: $NAME (pass --force to replace it)"
        # The only `tart delete` in this script, and only ever against --name.
        log "deleting the existing VM $NAME (--force)"
        tart delete "$NAME"
    fi
    log "cloning $SOURCE -> $NAME"
    tart clone "$SOURCE" "$NAME"
}

start_vm() {
    log "booting $NAME headless"
    tart run --no-graphics "$NAME" >"$WORK/tart-run.log" 2>&1 &
    TART_PID=$!
    local deadline=$((SECONDS + IP_TIMEOUT))
    while [ "$SECONDS" -lt "$deadline" ]; do
        kill -0 "$TART_PID" 2>/dev/null ||
            die "tart run exited before the guest got an IP; see $WORK/tart-run.log"
        GUEST_IP="$(tart ip "$NAME" --wait 10 2>/dev/null || true)"
        [ -z "$GUEST_IP" ] || break
        sleep 2
    done
    [ -n "$GUEST_IP" ] || die "no guest IP after ${IP_TIMEOUT}s; see $WORK/tart-run.log"
    log "guest IP: $GUEST_IP"
    wait_for_ssh
}

wait_for_ssh() {
    local deadline=$((SECONDS + SSH_TIMEOUT))
    while ! nc -z -G 5 "$GUEST_IP" 22 >/dev/null 2>&1; do
        [ "$SECONDS" -lt "$deadline" ] || die "guest never opened port 22 (${SSH_TIMEOUT}s)"
        sleep 3
    done
    # A listening port is not a usable session: sshd accepts connections while the guest is still
    # finishing first-boot setup, so wait until a command actually runs.
    deadline=$((SECONDS + SSH_TIMEOUT))
    while ! guest_ssh true >/dev/null 2>&1; do
        [ "$SECONDS" -lt "$deadline" ] || die "ssh to $SSH_USER@$GUEST_IP never succeeded"
        sleep 5
    done
    log "ssh to $SSH_USER@$GUEST_IP is up"
}

shutdown_guest() {
    log "halting the guest"
    # The halt tears down this very ssh session, so its exit status carries no information.
    guest_ssh "sudo shutdown -h now" >/dev/null 2>&1 || true
    wait_for_guest_down
}

# Waits for a halt that has already been issued -- by `shutdown_guest` above, or by the guest
# itself at the end of the seal-time lockdown, which runs after SSH is gone.
#
# Sets GRACEFUL_SHUTDOWN=1 only when the guest brought itself down. A forced `tart stop` is a power
# cut: APFS is then merely crash-consistent, and the caller (`require_clean_shutdown`) refuses to
# seal an image out of those bytes. The VM is still stopped either way -- leaving a runaway guest
# behind would be worse than a failed build.
wait_for_guest_down() {
    local deadline=$((SECONDS + SHUTDOWN_TIMEOUT))
    GRACEFUL_SHUTDOWN=1
    while kill -0 "$TART_PID" 2>/dev/null; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            warn "guest still running after ${SHUTDOWN_TIMEOUT}s; forcing tart stop"
            GRACEFUL_SHUTDOWN=0
            tart stop "$NAME" || true
            break
        fi
        sleep 5
    done
    wait "$TART_PID" 2>/dev/null || true
    TART_PID=""
    if [ "$GRACEFUL_SHUTDOWN" -eq 1 ]; then
        log "guest is down (graceful)"
    else
        warn "guest is down after a forced stop"
    fi
}

# --------------------------------------------------------------------------
# SSH transport. Password auth goes through expect: macOS ships no sshpass, and the base image's
# credentials are the documented admin/admin rather than something this script invents.
# --------------------------------------------------------------------------
SSH_OPTS=()

init_ssh_opts() {
    # Throwaway build VM on a NAT address that changes every boot: pinning host keys would only
    # manufacture false mismatches, and nothing secret crosses this channel.
    SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
        -o LogLevel=ERROR -o ConnectTimeout=10 -o ServerAliveInterval=30)
    if [ -n "$SSH_KEY" ]; then
        SSH_OPTS+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
    else
        # Keep ssh from spending its prompt budget on agent keys before it offers password auth.
        SSH_OPTS+=(-o PreferredAuthentications=password -o PubkeyAuthentication=no)
    fi
}

write_expect_helper() {
    EXPECT_HELPER="$WORK/ssh-expect.exp"
    PASS_FILE="$WORK/ssh-password"
    # The password reaches expect through a 0600 file inside a 0700 work directory -- never argv,
    # never the environment -- so it cannot be read out of `ps` on the host.
    (umask 077; printf '%s' "$SSH_PASSWORD" >"$PASS_FILE")
    cat >"$EXPECT_HELPER" <<'EXPECTEOF'
# argv: <password-file> <command> [args...]
set pwfile [lindex $argv 0]
set cmd [lrange $argv 1 end]
set fh [open $pwfile r]
set password [string trim [read $fh]]
close $fh
if {[info exists env(RVM_EXPECT_TIMEOUT)]} {
    set timeout $env(RVM_EXPECT_TIMEOUT)
} else {
    set timeout 600
}
set sent 0
spawn -noecho {*}$cmd
expect {
    -re {(?i)are you sure you want to continue connecting} {
        send -- "yes\r"
        exp_continue
    }
    -re {(?i)(password|passphrase[^:]*):} {
        incr sent
        # A fourth prompt means the credential is simply wrong; without this the exp_continue
        # loop would hang the whole run behind the expect timeout instead of failing.
        if {$sent > 3} {
            send_user "\nssh keeps asking for a password; giving up\n"
            exit 5
        }
        send -- "$password\r"
        exp_continue
    }
    timeout {
        send_user "\nexpect: timed out waiting for the remote command\n"
        exit 124
    }
    eof
}
catch wait result
exit [lindex $result 3]
EXPECTEOF
}

# Runs ssh/scp under the expect wrapper when authenticating with a password.
ssh_run() {
    if [ -n "$SSH_KEY" ]; then "$@"; else expect -f "$EXPECT_HELPER" "$PASS_FILE" "$@"; fi
}

guest_ssh() { ssh_run ssh "${SSH_OPTS[@]}" "$SSH_USER@$GUEST_IP" "$@"; }

guest_scp() { ssh_run scp "${SSH_OPTS[@]}" "$@"; }
