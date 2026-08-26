#!/bin/sh
# Installs the RunnerVM guest agent and its service unit inside a guest
# image. Run as root during image build, not on a running host.
#
# Usage: packaging/install.sh <path-to-guest-agent-binary>
set -eu

BINARY="${1:?usage: install.sh <path-to-guest-agent-binary>}"
PREFIX="${PREFIX:-/usr/local}"
STATE_DIR="${STATE_DIR:-/var/lib/runnervm-guest-agent}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
    echo "install.sh must run as root" >&2
    exit 1
fi

install -d -m 0755 "$PREFIX/bin"
install -m 0755 "$BINARY" "$PREFIX/bin/runnervm-guest-agent"

# The agent needs this before its first agent.cleanup; systemd's
# StateDirectory= would also create it, but launchd has no equivalent.
install -d -m 0750 "$STATE_DIR"

case "$(uname -s)" in
Linux)
    install -m 0644 "$SCRIPT_DIR/systemd/runnervm-guest-agent.service" \
        /etc/systemd/system/runnervm-guest-agent.service
    systemctl daemon-reload
    systemctl enable runnervm-guest-agent.service
    echo "installed: $PREFIX/bin/runnervm-guest-agent + systemd unit (enabled)"
    ;;
Darwin)
    install -m 0644 "$SCRIPT_DIR/launchd/com.runnervm.guest-agent.plist" \
        /Library/LaunchDaemons/com.runnervm.guest-agent.plist
    chown root:wheel /Library/LaunchDaemons/com.runnervm.guest-agent.plist
    echo "installed: $PREFIX/bin/runnervm-guest-agent + LaunchDaemon"
    echo "load with: launchctl bootstrap system /Library/LaunchDaemons/com.runnervm.guest-agent.plist"
    ;;
*)
    echo "unsupported OS: $(uname -s)" >&2
    exit 1
    ;;
esac
