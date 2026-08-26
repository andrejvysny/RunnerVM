#!/usr/bin/env bash
# Build and ad-hoc sign vmworker with the virtualization entitlement (dev).
# NAT networking needs only com.apple.security.virtualization, so a bare binary suffices
# (no .app bundle / provisioning profile; those are required only for com.apple.vm.networking).
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"
swift build -c "$CONFIG" --product vmworker
BIN=".build/$CONFIG/vmworker"
codesign --force --sign - --entitlements Resources/vmworker-dev.entitlements "$BIN"
codesign -d --entitlements - "$BIN" 2>&1 | grep -q com.apple.security.virtualization
echo "signed: $BIN"
