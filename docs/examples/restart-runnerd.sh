#!/bin/sh
# Restart a `runnerd` that was started by hand rather than by launchd.
#
# `scripts/live-github-e2e.sh --restart-cmd` defaults to
# `launchctl kickstart -k gui/$(id -u)/com.runnervm.runnerd`, which does nothing on a host with no
# launchd job installed -- the restart scenarios then "pass" without ever restarting anything, or
# hang. Point `--restart-cmd` at this script instead on such a host:
#
#   scripts/live-github-e2e.sh --restart-cmd /path/to/restart-runnerd.sh ...
#
# Two things here are not incidental:
#
#   * `pkill -f` matches the *whole* command line of every process, including a shell running a
#     script whose text contains the pattern. The pattern below ("libexec/runnervm/runnerd") does
#     not appear in this file's own argv (`/bin/sh /path/to/restart-runnerd.sh`), so this script
#     cannot kill itself -- but it would if the pattern were spelled out in a `--config` argument
#     here. Keep them apart. See docs/live-integration.md, "Known non-determinism".
#   * The wait for the socket at the end matters: without it the caller races the daemon's startup
#     and the next `runnerctl` call fails with a missing socket rather than a real error.
#
# Override any of these for your own layout.
set -eu

PREFIX="${RUNNERVM_PREFIX:-/usr/local}"
STATE_DIR="${RUNNERVM_STATE_DIR:-/Library/Application Support/RunnerVM}"
SOCKET_DIR="${RUNNERVM_SOCKET_DIR:-/var/run/runnervm}"
CONFIG="${RUNNERVM_CONFIG:-$STATE_DIR/config.yaml}"
LOG="${RUNNERVM_STDIO_LOG:-/tmp/runnerd-stdio.log}"
STOP_TIMEOUT="${RUNNERVM_STOP_TIMEOUT:-30}"
START_TIMEOUT="${RUNNERVM_START_TIMEOUT:-60}"

pkill -f "libexec/runnervm/runnerd" 2>/dev/null || true

i=0
while pgrep -f "libexec/runnervm/runnerd" >/dev/null 2>&1 && [ "$i" -lt "$STOP_TIMEOUT" ]; do
    sleep 1
    i=$((i + 1))
done

nohup "$PREFIX/libexec/runnervm/runnerd" --foreground \
    --config "$CONFIG" \
    --state-dir "$STATE_DIR" \
    --socket-dir "$SOCKET_DIR" >>"$LOG" 2>&1 &

i=0
while [ ! -S "$SOCKET_DIR/runnerd.sock" ] && [ "$i" -lt "$START_TIMEOUT" ]; do
    sleep 1
    i=$((i + 1))
done
[ -S "$SOCKET_DIR/runnerd.sock" ] || {
    echo "runnerd did not publish $SOCKET_DIR/runnerd.sock within ${START_TIMEOUT}s; see $LOG" >&2
    exit 1
}
