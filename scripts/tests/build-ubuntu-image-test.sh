#!/usr/bin/env bash
# Unit checks for scripts/build-ubuntu-image.sh that need no VM, no entitlement and
# no network: input verification, --print-seed rendering, runner digest resolution,
# manifest extraction/fail-closed and metadata composition.
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
BASE_IMG="$WORK/base.img"
head -c 4096 /dev/zero >"$BASE_IMG"
# The builder refuses a base without a GPT; stamp the signature at sector 1.
printf 'EFI PART' | dd of="$BASE_IMG" bs=1 seek=512 conv=notrunc 2>/dev/null
BASE_SHA="$(shasum -a 256 "$BASE_IMG" | awk '{print $1}')"
AGENT="$WORK/guest-agent"
printf 'not a real agent' >"$AGENT"
RUNNER_SHA="1111111111111111111111111111111111111111111111111111111111111111"

# The default GitHub release asset digest fixture used by every test below unless a
# test overrides RVM_RELEASE_JSON_FILE for itself: matches --runner-version 2.999.0
# and agrees with $RUNNER_SHA, so pre-existing assertions about rendering are
# unaffected by digest resolution now also running (RVM_RELEASE_JSON_FILE keeps it
# off the network).
RELEASE_JSON_DEFAULT="$WORK/release-default.json"
cat >"$RELEASE_JSON_DEFAULT" <<JSON
{
  "tag_name": "v2.999.0",
  "assets": [
    {"name": "actions-runner-osx-arm64-2.999.0.tar.gz", "digest": "sha256:deadbeef"},
    {"name": "actions-runner-linux-arm64-2.999.0.tar.gz", "digest": "sha256:$RUNNER_SHA"}
  ]
}
JSON
export RVM_RELEASE_JSON_FILE="$RELEASE_JSON_DEFAULT"

seed() {
    "$SCRIPT" --base "$BASE_IMG" --guest-agent "$AGENT" \
        --runner-version 2.999.0 --runner-sha256 "$RUNNER_SHA" \
        --print-seed "$@" 2>&1
}

# --------------------------------------------------------------------------
# Source the script so its internal helpers (resolve_runner_digest, extract_manifest,
# check_guest_manifest, write_metadata, ...) can be exercised directly. Guarded by
# BASH_SOURCE in the script itself, so this only defines functions -- it does not
# run the build.
# --------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$SCRIPT"

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
expect_eq "$(jq -r .runnerDigestSource "$INPUTS")" "operator" \
    "resolved inputs record digestSource=operator for a --runner-sha256 pin"

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
# 3. Runner digest resolution: GitHub's own release asset metadata is the trust
#    anchor, not a hash of whatever an unauthenticated first download contains.
# --------------------------------------------------------------------------
run_script() {
    "$SCRIPT" --base "$BASE_IMG" --base-sha256 "$BASE_SHA" --guest-agent "$AGENT" \
        --print-seed "$@" 2>&1
}

DIGEST_HEX="$(printf '4%.0s' {1..64})"
OTHER_HEX="$(printf '5%.0s' {1..64})"

DIGEST_FIXTURE_OK="$WORK/release-ok.json"
cat >"$DIGEST_FIXTURE_OK" <<JSON
{
  "tag_name": "v9.9.9",
  "assets": [
    {"name": "actions-runner-osx-x64-9.9.9.tar.gz", "digest": "sha256:$OTHER_HEX"},
    {"name": "actions-runner-linux-arm64-9.9.9.tar.gz", "digest": "sha256:$DIGEST_HEX"}
  ]
}
JSON
got="$(RVM_RELEASE_JSON_FILE="$DIGEST_FIXTURE_OK" resolve_runner_digest 9.9.9)"
expect_eq "$got" "$DIGEST_HEX" \
    "resolve_runner_digest selects the matching arm64 asset and strips sha256:"

DIGEST_FIXTURE_NOMATCH="$WORK/release-nomatch.json"
cat >"$DIGEST_FIXTURE_NOMATCH" <<JSON
{"tag_name": "v9.9.9", "assets": [{"name": "actions-runner-osx-x64-9.9.9.tar.gz", "digest": "sha256:$OTHER_HEX"}]}
JSON
if RVM_RELEASE_JSON_FILE="$DIGEST_FIXTURE_NOMATCH" resolve_runner_digest 9.9.9 >/dev/null 2>&1; then
    no "resolve_runner_digest fails when no asset matches the name" "printed a digest anyway"
else
    ok "resolve_runner_digest fails when no asset matches the name"
fi

DIGEST_FIXTURE_MALFORMED="$WORK/release-malformed.json"
cat >"$DIGEST_FIXTURE_MALFORMED" <<JSON
{"tag_name": "v9.9.9", "assets": [{"name": "actions-runner-linux-arm64-9.9.9.tar.gz", "digest": "sha256:not-hex"}]}
JSON
if RVM_RELEASE_JSON_FILE="$DIGEST_FIXTURE_MALFORMED" resolve_runner_digest 9.9.9 >/dev/null 2>&1; then
    no "resolve_runner_digest rejects a non-hex digest" "accepted it"
else
    ok "resolve_runner_digest rejects a non-hex digest"
fi

# No --runner-sha256: the release asset digest is trusted and recorded as such.
out="$(run_script --runner-version 2.999.0)"
expect_contains "$out" "\"runnerSha\": \"$RUNNER_SHA\"" \
    "no --runner-sha256: the release asset digest is trusted"
expect_contains "$out" "\"runnerDigestSource\": \"github-release-asset\"" \
    "no --runner-sha256: digestSource records github-release-asset"

# A --runner-sha256 pin that agrees with the release asset digest: operator wins,
# recorded as such (never silently relabelled as the release asset's).
out="$(run_script --runner-version 2.999.0 --runner-sha256 "$RUNNER_SHA")"
expect_contains "$out" "\"runnerDigestSource\": \"operator\"" \
    "a --runner-sha256 pin that agrees with the release asset records digestSource=operator"

# A --runner-sha256 pin that disagrees with the release asset digest: hard error,
# never silently prefer one.
FIXTURE_MISMATCH="$WORK/release-mismatch.json"
cat >"$FIXTURE_MISMATCH" <<JSON
{"tag_name": "v2.999.0", "assets": [{"name": "actions-runner-linux-arm64-2.999.0.tar.gz", "digest": "sha256:$OTHER_HEX"}]}
JSON
if out="$(RVM_RELEASE_JSON_FILE="$FIXTURE_MISMATCH" seed --base-sha256 "$BASE_SHA" 2>&1)"; then
    no "a --runner-sha256 that disagrees with the release asset is a hard error" \
        "the build rendered a seed anyway"
else
    expect_contains "$out" "runner digest mismatch" \
        "a --runner-sha256 that disagrees with the release asset is a hard error"
fi

# No pin, no release asset digest, no --allow-unverified-runner: refuse.
FIXTURE_NODIGEST="$WORK/release-nodigest.json"
cat >"$FIXTURE_NODIGEST" <<JSON
{"tag_name": "v0.0.0", "assets": []}
JSON
if out="$(RVM_RELEASE_JSON_FILE="$FIXTURE_NODIGEST" run_script --runner-version 2.996.0)"; then
    no "a missing release asset digest is refused without a pin or --allow-unverified-runner" \
        "the build rendered a seed anyway"
else
    expect_contains "$out" "could not read a release asset digest" \
        "a missing release asset digest is refused without a pin or --allow-unverified-runner"
fi

# --allow-unverified-runner: falls back to hashing the host's own download -- here an
# already-cached file, so --print-seed can exercise it without touching the network.
CACHE_AU="$WORK/cache-allow-unverified"
mkdir -p "$CACHE_AU"
AU_TARBALL="$CACHE_AU/actions-runner-linux-arm64-2.997.0.tar.gz"
printf 'not a real tarball, just cached bytes' >"$AU_TARBALL"
AU_SHA="$(shasum -a 256 "$AU_TARBALL" | awk '{print $1}')"
out="$(RVM_RELEASE_JSON_FILE="$FIXTURE_NODIGEST" RUNNERVM_BUILD_CACHE="$CACHE_AU" \
    run_script --runner-version 2.997.0 --allow-unverified-runner)"
expect_contains "$out" "WARNING: --allow-unverified-runner" "--allow-unverified-runner warns loudly"
expect_contains "$out" "\"runnerSha\": \"$AU_SHA\"" \
    "--allow-unverified-runner records the hash of the host's own download"
expect_contains "$out" "\"runnerDigestSource\": \"download\"" \
    "--allow-unverified-runner records digestSource=download"

# --print-seed still refuses outright when the digest is unknown and nothing is cached
# to hash -- --allow-unverified-runner does not license a network download here.
if out="$(RVM_RELEASE_JSON_FILE="$FIXTURE_NODIGEST" RUNNERVM_BUILD_CACHE="$WORK/cache-empty" \
    run_script --runner-version 2.995.0 --allow-unverified-runner 2>&1)"; then
    no "--print-seed refuses to download just to compute an unverified digest" \
        "the build rendered a seed anyway"
else
    expect_contains "$out" "cannot hash an unverified runner tarball without downloading" \
        "--print-seed refuses to download just to compute an unverified digest"
fi

# --------------------------------------------------------------------------
# 4. Manifest extraction (helpers, sourced)
# --------------------------------------------------------------------------
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
# 5. Manifest fail-closed (check_guest_manifest): a build whose guest manifest could
#    not be recovered must not seal silently.
# --------------------------------------------------------------------------
if check_guest_manifest "$WORK/empty.log" "$WORK/cgm-none.json" 0; then
    no "a missing manifest fails closed without --allow-partial-provenance" \
        "check_guest_manifest returned success"
else
    expect_contains "$PARTIAL_REASON" "no usable RVM-MANIFEST block" \
        "a missing manifest fails closed without --allow-partial-provenance"
fi

if check_guest_manifest "$WORK/empty.log" "$WORK/cgm-partial.json" 1; then
    ok "--allow-partial-provenance lets a missing manifest through"
    expect_eq "$(cat "$WORK/cgm-partial.json")" "{}" \
        "a partial build still writes an empty guest manifest"
else
    no "--allow-partial-provenance lets a missing manifest through" \
        "check_guest_manifest still failed"
fi

NO_PACKAGES_JSON="$WORK/no-packages.json"
printf '{"runnerVersion":"2.999.0","kernelVersion":"6.8.0-51-generic"}' >"$NO_PACKAGES_JSON"
NO_PACKAGES_SERIAL="$WORK/no-packages-serial.log"
{
    echo RVM-MANIFEST-BEGIN
    base64 -b 100 <"$NO_PACKAGES_JSON"
    echo RVM-MANIFEST-END
} >"$NO_PACKAGES_SERIAL"

if check_guest_manifest "$NO_PACKAGES_SERIAL" "$WORK/cgm-nopkg.json" 0; then
    no "a manifest with no packages field fails closed" "check_guest_manifest returned success"
else
    expect_contains "$PARTIAL_REASON" "no packages field" \
        "a manifest with no packages field fails closed"
fi

if check_guest_manifest "$SERIAL" "$WORK/cgm-ok.json" 0; then
    expect_eq "$PARTIAL_REASON" "" "a full manifest is not partial"
else
    no "a full manifest is not partial" "check_guest_manifest failed on a good manifest"
fi

# --------------------------------------------------------------------------
# 6. Sealed metadata.json
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
    RUNNER_DIGEST_SOURCE="github-release-asset"
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

PARTIAL_REASON=""
META="$WORK/metadata.json"
write_metadata "$DECODED" "$META"
expect_eq "$(jq -r .schemaVersion "$META")" "1" "metadata keeps schemaVersion 1"
expect_eq "$(jq -r .runnerVersion "$META")" "2.999.0" "metadata records the runner version"
expect_eq "$(jq -r .provenance.baseImage.sha256 "$META")" "sha256:$BASE_SHA" \
    "provenance records the base sha256"
expect_eq "$(jq -r .provenance.actionsRunner.sha256 "$META")" "sha256:$RUNNER_SHA" \
    "provenance records the runner sha256"
expect_eq "$(jq -r .provenance.actionsRunner.digestSource "$META")" "github-release-asset" \
    "provenance records the runner digestSource"
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
expect_eq "$(jq -r .provenance.partial "$META")" "false" "a full build is not partial"
expect_eq "$(jq -r .provenance.partialReason "$META")" "null" "a full build has no partialReason"

# A build whose console never produced a manifest still seals valid metadata, but
# degraded and clearly marked as partial.
echo '{}' >"$WORK/no-guest.json"
PARTIAL_REASON="no usable RVM-MANIFEST block in serial.log"
write_metadata "$WORK/no-guest.json" "$WORK/degraded.json"
expect_eq "$(jq -r .provenance.packages "$WORK/degraded.json")" "null" \
    "a missing guest manifest degrades to null packages"
expect_eq "$(jq -r .runnerVersion "$WORK/degraded.json")" "2.999.0" \
    "a missing guest manifest still records the host-resolved runner version"
expect_eq "$(jq -r .provenance.partial "$WORK/degraded.json")" "true" \
    "a missing guest manifest is recorded as partial"
expect_eq "$(jq -r .provenance.partialReason "$WORK/degraded.json")" \
    "no usable RVM-MANIFEST block in serial.log" \
    "a missing guest manifest records the partial reason"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
