#!/usr/bin/env bash
# Unit checks for scripts/build-ubuntu-image.sh that need no VM, no entitlement and
# no network: input verification, --print-seed rendering, manifest extraction and
# metadata composition.
#
# usage: scripts/tests/build-ubuntu-image-test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/build-ubuntu-image.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rvm-build-test-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }

expect_contains() {
    local haystack="$1" needle="$2" what="$3"
    case "$haystack" in
    *"$needle"*) ok "$what" ;;
    *) no "$what" "expected to find: $needle" ;;
    esac
}

expect_eq() {
    if [ "$1" = "$2" ]; then ok "$3"; else no "$3" "expected '$2', got '$1'"; fi
}

# --------------------------------------------------------------------------
# Fixtures
# --------------------------------------------------------------------------
BASE="$WORK/base.img"
head -c 4096 /dev/zero >"$BASE"
BASE_SHA="$(shasum -a 256 "$BASE" | awk '{print $1}')"
AGENT="$WORK/guest-agent"
printf 'not a real agent' >"$AGENT"
RUNNER_SHA="1111111111111111111111111111111111111111111111111111111111111111"

seed() {
    "$SCRIPT" --base "$BASE" --guest-agent "$AGENT" \
        --runner-version 2.999.0 --runner-sha256 "$RUNNER_SHA" \
        --print-seed "$@" 2>&1
}

# --------------------------------------------------------------------------
# 1. Base image verification
# --------------------------------------------------------------------------
if out="$(seed 2>&1)"; then
    no "unverified base is refused" "the build rendered a seed anyway"
else
    expect_contains "$out" "refusing to build from an unverified base image" \
        "unverified base is refused"
fi

if out="$(seed --base-sha256 "$(printf '0%.0s' {1..64})" 2>&1)"; then
    no "a wrong --base-sha256 is refused" "the build rendered a seed anyway"
else
    expect_contains "$out" "base image sha256 mismatch" "a wrong --base-sha256 is refused"
fi

out="$(seed --allow-unverified-base)"
expect_contains "$out" "WARNING: --allow-unverified-base" "--allow-unverified-base warns loudly"
expect_contains "$out" "\"baseSha\": \"$BASE_SHA\"" "--allow-unverified-base still records the digest"

out="$(seed --base-sha256 "$BASE_SHA")"
expect_contains "$out" "base image sha256 verified" "a matching --base-sha256 verifies"

# --------------------------------------------------------------------------
# 2. Rendered cloud-init user-data
# --------------------------------------------------------------------------
USER_DATA="$WORK/user-data"
printf '%s\n' "$out" | awk '/RVM-SEED-USER-DATA-BEGIN/{c=1;next} /RVM-SEED-USER-DATA-END/{c=0} c' \
    >"$USER_DATA"
INPUTS="$WORK/inputs.json"
printf '%s\n' "$out" | awk '/RVM-SEED-INPUTS-BEGIN/{c=1;next} /RVM-SEED-INPUTS-END/{c=0} c' \
    >"$INPUTS"

if grep -q '@[A-Z_]\{3,\}@' "$USER_DATA"; then
    no "every placeholder is substituted" "$(grep -o '@[A-Z_]\{3,\}@' "$USER_DATA" | head -3)"
else
    ok "every placeholder is substituted"
fi
expect_contains "$(cat "$USER_DATA")" \
    "echo \"$RUNNER_SHA  /tmp/actions-runner.tar.gz\" | sha256sum -c -" \
    "the guest verifies the runner tarball"
expect_contains "$(cat "$USER_DATA")" \
    "releases/download/v2.999.0/actions-runner-linux-arm64-2.999.0.tar.gz" \
    "the resolved runner URL reaches the guest"
expect_contains "$(cat "$USER_DATA")" "package_upgrade: true" "--package-upgrade defaults to yes"
expect_contains "$(cat "$USER_DATA")" "RVM-MANIFEST-BEGIN" "the guest emits a manifest block"
expect_eq "$(jq -r .runnerVersion "$INPUTS")" "2.999.0" "resolved inputs name the runner version"

out="$(seed --base-sha256 "$BASE_SHA" --package-upgrade no --docker-suite jammy)"
expect_contains "$out" "package_upgrade: false" "--package-upgrade no reaches cloud-init"
expect_contains "$out" "https://download.docker.com/linux/ubuntu jammy stable" \
    "--docker-suite reaches the docker.list line"

if out="$(seed --base-sha256 "$BASE_SHA" --package-upgrade maybe 2>&1)"; then
    no "--package-upgrade rejects junk" "accepted 'maybe'"
else
    expect_contains "$out" "must be yes or no" "--package-upgrade rejects junk"
fi

# --------------------------------------------------------------------------
# 3. Manifest extraction and metadata composition (helpers, sourced)
# --------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$SCRIPT"

GUEST_JSON="$WORK/guest.json"
cat >"$GUEST_JSON" <<'JSON'
{
  "runnerVersion": "2.999.0",
  "runnerSHA256": "1111111111111111111111111111111111111111111111111111111111111111",
  "dockerVersion": "5:27.3.1-1~ubuntu.24.04~noble",
  "dockerRepository": "https://download.docker.com/linux/ubuntu noble stable",
  "kernelVersion": "6.8.0-51-generic",
  "guestAgentVersion": "runnervm-guest-agent v0.1.0 (linux/arm64)",
  "guestAgentSHA256": "2222222222222222222222222222222222222222222222222222222222222222",
  "packages": ["git=1:2.43.0-1ubuntu7", "jq=1.7.1-3build1"]
}
JSON

# A console log the way it really arrives: CRs, kernel noise inside the block, and
# an earlier aborted block that must lose to the last complete one.
SERIAL="$WORK/serial.log"
{
    printf 'cloud-init running\r\n'
    printf 'RVM-MANIFEST-BEGIN\r\n'
    printf 'dGhpcyBibG9jayBuZXZlciBjbG9zZWQ=\r\n'
    printf 'RVM-MANIFEST-BEGIN\r\n'
    base64 -b 100 <"$GUEST_JSON" | sed 's/$/\r/'
    printf '[  12.345678] random: crng init done\r\n'
    printf 'RVM-MANIFEST-END\r\n'
    printf 'RUNNERVM-BUILD-OK\r\n'
} >"$SERIAL"

DECODED="$WORK/decoded.json"
if extract_manifest "$SERIAL" "$DECODED"; then
    expect_eq "$(jq -r '.packages | length' "$DECODED")" "2" "the manifest survives a noisy console"
    expect_eq "$(jq -r .kernelVersion "$DECODED")" "6.8.0-51-generic" "manifest fields decode"
else
    no "the manifest survives a noisy console" "extract_manifest failed"
    no "manifest fields decode" "extract_manifest failed"
fi

printf 'no manifest here\n' >"$WORK/empty.log"
if extract_manifest "$WORK/empty.log" "$WORK/none.json" 2>/dev/null; then
    no "a console with no manifest fails cleanly" "extract_manifest reported success"
else
    ok "a console with no manifest fails cleanly"
fi

# --------------------------------------------------------------------------
# 4. Sealed metadata.json
# --------------------------------------------------------------------------
# write_metadata reads these as globals from the sourced script -- a use that is
# invisible from here, hence the SC2034 waiver.
# shellcheck disable=SC2034
{
    VIRTUAL_BYTES=17179869184
    PACKAGE_UPGRADE="yes"
    RUNNER_VERSION="2.999.0"
    RUNNER_SHA256="$RUNNER_SHA"
    RUNNER_URL="https://github.com/actions/runner/releases/download/v2.999.0/x.tar.gz"
    AGENT_VERSION="v0.1.0"
    AGENT_COMMIT="abc123"
    AGENT_SHA256="2222222222222222222222222222222222222222222222222222222222222222"
    BASE_SOURCE="https://cloud-images.ubuntu.com/noble.img"
    BASE_SHA256="$BASE_SHA"
    BUILDER_COMMIT="def456"
    HOST_OS_VERSION="26.4"
    BUILT_AT="2026-08-26T10:00:00Z"
    DISK_SHA256="3333333333333333333333333333333333333333333333333333333333333333"
}

META="$WORK/metadata.json"
write_metadata "$DECODED" "$META"
expect_eq "$(jq -r .schemaVersion "$META")" "1" "metadata keeps schemaVersion 1"
expect_eq "$(jq -r .runnerVersion "$META")" "2.999.0" "metadata records the runner version"
expect_eq "$(jq -r .provenance.baseImage.sha256 "$META")" "sha256:$BASE_SHA" \
    "provenance records the base sha256"
expect_eq "$(jq -r .provenance.actionsRunner.sha256 "$META")" "sha256:$RUNNER_SHA" \
    "provenance records the runner sha256"
expect_eq "$(jq -r .provenance.guestAgent.gitCommit "$META")" "abc123" \
    "provenance records the guest agent commit"
expect_eq "$(jq -r .provenance.packageUpgrade "$META")" "true" "provenance records packageUpgrade"
expect_eq "$(jq -r '.provenance.packages | length' "$META")" "2" \
    "provenance carries the package manifest"
expect_eq "$(jq -r .provenance.docker.version "$META")" "5:27.3.1-1~ubuntu.24.04~noble" \
    "provenance records the docker-ce version"
expect_eq "$(jq -r .provenance.diskSHA256 "$META")" "sha256:$DISK_SHA256" \
    "provenance records the sealed disk sha256"
expect_eq "$(jq -r .provenance.builder.script "$META")" "scripts/build-ubuntu-image.sh" \
    "provenance names the build script"

# A build whose console never produced a manifest still seals valid metadata.
echo '{}' >"$WORK/no-guest.json"
write_metadata "$WORK/no-guest.json" "$WORK/degraded.json"
expect_eq "$(jq -r .provenance.packages "$WORK/degraded.json")" "null" \
    "a missing guest manifest degrades to null packages"
expect_eq "$(jq -r .runnerVersion "$WORK/degraded.json")" "2.999.0" \
    "a missing guest manifest still records the host-resolved runner version"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
