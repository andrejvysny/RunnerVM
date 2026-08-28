#!/usr/bin/env bash
# Unit checks for scripts/provision-macos-tart.sh that need no VM, no tart, no daemon and no
# network: metadata rendering from a fixture tart config.json, the raw-disk refusal, the osx-arm64
# asset naming, release-digest resolution through the RVM_RELEASE_JSON_FILE seam, and self-check
# parsing.
#
# Two styles, matched to what each check needs (same split as scripts/tests/qualify-host-test.sh):
#   - argument handling is exercised as a real subprocess, because those paths exit;
#   - the pure helpers are exercised by `source`-ing the script, which guards its own `main` behind
#     `[ "${BASH_SOURCE[0]}" = "${0}" ]` exactly so this file can call them directly.
#
# usage: scripts/tests/provision-macos-tart-test.sh
#
# shellcheck disable=SC2034
# SC2034 (appears unused): the globals below (RUNNER_VERSION, AGENT_VERSION, SOURCE,
# GUEST_PRODUCT_VERSION, VIRTUAL_BYTES, CREATED_AT, SELFCHECK, ...) are read by
# scripts/provision-macos-tart.sh's own functions after this file sources it -- invisible to a
# standalone shellcheck pass over just this file.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/provision-macos-tart.sh"
GUEST_SCRIPT="$REPO_ROOT/scripts/lib/macos-guest-provision.sh"
# Not named WORK: sourcing the script below would reset that global to "".
TWORK="$(mktemp -d "${TMPDIR:-/tmp}/rvm-macos-provision-test-XXXXXX")"
trap 'rm -rf "$TWORK"' EXIT

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
# 1. Argument handling, as a subprocess (these paths exit before any host check)
# --------------------------------------------------------------------------
if help_out="$("$SCRIPT" --help 2>&1)"; then
    expect_contains "$help_out" "usage: provision-macos-tart.sh" "--help prints usage"
    expect_contains "$help_out" "--keep-vm-running" "--help documents --keep-vm-running"
    expect_contains "$help_out" "--debug-ssh" "--help documents --debug-ssh"
    expect_contains "$help_out" "--allow-dirty-seal" "--help documents --allow-dirty-seal"
    expect_contains "$help_out" "RVM_RELEASE_JSON_FILE" "--help documents the release JSON seam"
else
    no "--help exits 0" "$help_out"
fi

if out="$("$SCRIPT" --nonsense 2>&1)"; then
    no "an unknown option fails" "exited 0"
else
    rc=$?
    expect_eq "$rc" "2" "an unknown option exits 2"
    expect_contains "$out" "unknown option: --nonsense" "an unknown option names itself"
fi

if out="$("$SCRIPT" --runner-sudo maybe 2>&1)"; then
    no "--runner-sudo maybe fails" "exited 0"
else
    expect_contains "$out" "--runner-sudo must be yes or no" "--runner-sudo is validated"
fi

if out="$("$SCRIPT" --runner-sha256 nothex 2>&1)"; then
    no "a malformed --runner-sha256 fails" "exited 0"
else
    expect_contains "$out" "must be 64 lowercase hex characters" "--runner-sha256 is validated"
fi

# --------------------------------------------------------------------------
# Source the script (and, through it, scripts/lib/macos-provision-vm.sh) so the pure helpers can
# be called directly. Guarded in the script itself, so nothing is provisioned.
# --------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$SCRIPT"

# --------------------------------------------------------------------------
# 2. The runner asset is the macOS one, not the Linux one
# --------------------------------------------------------------------------
expect_eq "$(runner_asset_name 2.337.0)" "actions-runner-osx-arm64-2.337.0.tar.gz" \
    "the asset name is osx-arm64"
expect_eq "$(runner_asset_url 2.337.0)" \
    "https://github.com/actions/runner/releases/download/v2.337.0/actions-runner-osx-arm64-2.337.0.tar.gz" \
    "the asset URL points at the v-tagged release download"

# --------------------------------------------------------------------------
# 3. Digest resolution off a fixture release payload (never the network)
# --------------------------------------------------------------------------
OSX_SHA="5a2cd92908a93d7276a194e1de6008099f3e7946f3f8e14aa7a1a7b4a31fdec2"
LINUX_SHA="1111111111111111111111111111111111111111111111111111111111111111"
RELEASE_JSON="$TWORK/release.json"
cat >"$RELEASE_JSON" <<JSON
{
  "tag_name": "v2.337.0",
  "assets": [
    {"name": "actions-runner-linux-arm64-2.337.0.tar.gz", "digest": "sha256:$LINUX_SHA"},
    {"name": "actions-runner-osx-arm64-2.337.0.tar.gz", "digest": "sha256:$OSX_SHA"},
    {"name": "actions-runner-osx-x64-2.337.0.tar.gz", "digest": "sha256:$LINUX_SHA"}
  ]
}
JSON
export RVM_RELEASE_JSON_FILE="$RELEASE_JSON"

expect_eq "$(resolve_runner_digest 2.337.0)" "$OSX_SHA" \
    "the osx-arm64 asset digest wins over the linux-arm64 one"

# An asset with no digest field is "unknown", not "trusted".
NO_DIGEST_JSON="$TWORK/release-no-digest.json"
cat >"$NO_DIGEST_JSON" <<'JSON'
{"tag_name": "v2.337.0", "assets": [{"name": "actions-runner-osx-arm64-2.337.0.tar.gz"}]}
JSON
if RVM_RELEASE_JSON_FILE="$NO_DIGEST_JSON" resolve_runner_digest 2.337.0 >/dev/null 2>&1; then
    no "a digest-less asset resolves to nothing" "returned success"
else
    ok "a digest-less asset resolves to nothing"
fi

# A pin that disagrees with GitHub's own digest stops the run instead of picking a side.
RUNNER_VERSION="2.337.0"
RUNNER_SHA256="$LINUX_SHA"
if out="$(select_runner_digest 2>&1)"; then
    no "a --runner-sha256 that disagrees with GitHub fails" "exited 0"
else
    expect_contains "$out" "runner digest mismatch" "a --runner-sha256 that disagrees with GitHub fails"
fi

RUNNER_SHA256=""
select_runner_digest
expect_eq "$RUNNER_SHA256" "$OSX_SHA" "with no pin, GitHub's asset digest is adopted"
expect_eq "$RUNNER_DIGEST_SOURCE" "github-release-asset" "the digest source is recorded"

# --------------------------------------------------------------------------
# 4. metadata.json, rendered from a fixture tart config.json
# --------------------------------------------------------------------------
HW_MODEL="YnBsaXN0MDDRAQJTZm9vgA=="
CONFIG="$TWORK/config.json"
cat >"$CONFIG" <<JSON
{
  "version": 1,
  "os": "darwin",
  "arch": "arm64",
  "cpuCount": 4,
  "cpuCountMin": 2,
  "memorySize": 8589934592,
  "memorySizeMin": 4294967296,
  "ecid": "1234567890",
  "hardwareModel": "$HW_MODEL",
  "diskFormat": "raw"
}
JSON

RUNNER_VERSION="2.337.0"
AGENT_VERSION="v0.1.0-3-gdeadbee"
SOURCE="ghcr.io/cirruslabs/macos-tahoe-base:latest"
GUEST_PRODUCT_VERSION="26.1"
VIRTUAL_BYTES=107374182400
CREATED_AT="2026-08-27T12:00:00Z"
META="$TWORK/metadata.json"
write_metadata "$CONFIG" "$META"

expect_eq "$(jq -r .schemaVersion "$META")" "1" "schemaVersion 1"
expect_eq "$(jq -r .os "$META")" "macos" "os macos"
expect_eq "$(jq -r .architecture "$META")" "arm64" "architecture arm64"
expect_eq "$(jq -r .diskFormat "$META")" "raw" "diskFormat raw"
expect_eq "$(jq -r .boot.type "$META")" "macos" "boot type macos"
expect_eq "$(jq -r .minimumHostOS "$META")" "15.0" "minimumHostOS 15.0"
expect_eq "$(jq -r .createdAt "$META")" "2026-08-27T12:00:00Z" "createdAt is the ISO-8601 UTC stamp"
expect_eq "$(jq -r .virtualDiskSizeBytes "$META")" "107374182400" "virtualDiskSizeBytes is recorded"
expect_eq "$(jq -r .runnerVersion "$META")" "2.337.0" "runnerVersion is the host-resolved version"
expect_eq "$(jq -r .guestAgentVersion "$META")" "v0.1.0-3-gdeadbee" "guestAgentVersion is recorded"
expect_eq "$(jq -r .macos.hardwareModel "$META")" "$HW_MODEL" "hardwareModel comes from config.json"
expect_eq "$(jq -r .macos.sourceVersion "$META")" "26.1" "sourceVersion is the guest's productVersion"
expect_eq "$(jq -r .macos.minimumCPUCount "$META")" "2" "minimumCPUCount comes from cpuCountMin"
expect_eq "$(jq -r .macos.minimumMemoryBytes "$META")" "4294967296" \
    "minimumMemoryBytes comes from memorySizeMin"
expect_eq "$(jq -r .capabilities.docker "$META")" "false" "docker is false on macOS"
expect_eq "$(jq -r .capabilities.ssh "$META")" "false" \
    "ssh is false: the seal-time lockdown disables it"
expect_eq "$(jq -r .capabilities.guestAgent "$META")" "true" "guestAgent is true"
expect_eq "$(jq -r '.capabilities.labels."runnervm.source"' "$META")" "tart" "the tart source label"
expect_eq "$(jq -r '.capabilities.labels."runnervm.tart.image"' "$META")" \
    "ghcr.io/cirruslabs/macos-tahoe-base:latest" "the tart image label records --source"
expect_eq "$(jq -r 'has("provenance")' "$META")" "false" \
    "no provenance block is invented for an SSH-provisioned image"

# With --debug-ssh the image keeps SSH, and its metadata has to say so rather than lie about it.
DEBUG_META="$TWORK/metadata-debug-ssh.json"
DEBUG_SSH=1
write_metadata "$CONFIG" "$DEBUG_META"
expect_eq "$(jq -r .capabilities.ssh "$DEBUG_META")" "true" \
    "--debug-ssh records capabilities.ssh: true"
DEBUG_SSH=0

# Missing sizing floors are refused, not silently omitted: admission now requires both, so an
# image without them could never create an instance.
ZERO_CONFIG="$TWORK/config-zero.json"
cat >"$ZERO_CONFIG" <<JSON
{"hardwareModel": "$HW_MODEL", "cpuCountMin": 0, "memorySizeMin": 0}
JSON
if out="$(write_metadata "$ZERO_CONFIG" "$TWORK/never-zero.json" 2>&1)"; then
    no "a config.json with no sizing floors is refused" "exited 0"
else
    expect_contains "$out" "no cpuCountMin/memorySizeMin" \
        "a config.json with no sizing floors is refused"
fi

NO_MEM_CONFIG="$TWORK/config-no-mem.json"
cat >"$NO_MEM_CONFIG" <<JSON
{"hardwareModel": "$HW_MODEL", "cpuCountMin": 2, "memorySizeMin": 0}
JSON
if out="$(write_metadata "$NO_MEM_CONFIG" "$TWORK/never-mem.json" 2>&1)"; then
    no "a config.json with no memorySizeMin is refused" "exited 0"
else
    expect_contains "$out" "no cpuCountMin/memorySizeMin" \
        "a config.json with no memorySizeMin is refused"
fi

# An unknown guest version is still omitted rather than written as an empty string.
NO_VERSION_META="$TWORK/metadata-no-version.json"
GUEST_PRODUCT_VERSION=""
write_metadata "$CONFIG" "$NO_VERSION_META"
expect_eq "$(jq -r '.macos | has("sourceVersion")' "$NO_VERSION_META")" "false" \
    "an unknown guest version is omitted, not written as an empty string"
GUEST_PRODUCT_VERSION="26.1"

DEFAULT_FORMAT_CONFIG="$TWORK/config-default-format.json"
cat >"$DEFAULT_FORMAT_CONFIG" <<JSON
{"hardwareModel": "$HW_MODEL", "cpuCountMin": 2, "memorySizeMin": 4294967296}
JSON
DEFAULT_FORMAT_META="$TWORK/metadata-default-format.json"
write_metadata "$DEFAULT_FORMAT_CONFIG" "$DEFAULT_FORMAT_META"
expect_eq "$(jq -r '.diskFormat' "$DEFAULT_FORMAT_META")" "raw" \
    "a config.json with no diskFormat means raw"

# --------------------------------------------------------------------------
# 5. A non-raw tart disk is refused rather than sealed
# --------------------------------------------------------------------------
ASIF_CONFIG="$TWORK/config-asif.json"
cat >"$ASIF_CONFIG" <<JSON
{"hardwareModel": "$HW_MODEL", "diskFormat": "asif"}
JSON
if out="$(require_raw_disk_format "$ASIF_CONFIG" 2>&1)"; then
    no "an asif disk is refused" "exited 0"
else
    expect_contains "$out" "disk format is 'asif', not raw" "an asif disk is refused"
fi
if out="$(write_metadata "$ASIF_CONFIG" "$TWORK/never.json" 2>&1)"; then
    no "an asif disk is refused before metadata is written" "exited 0"
else
    ok "an asif disk is refused before metadata is written"
fi
if [ -f "$TWORK/never.json" ]; then
    no "no metadata file is left behind" "$TWORK/never.json exists"
else
    ok "no metadata file is left behind"
fi

NO_MODEL_CONFIG="$TWORK/config-no-model.json"
echo '{"diskFormat": "raw", "cpuCountMin": 2, "memorySizeMin": 4294967296}' >"$NO_MODEL_CONFIG"
if out="$(write_metadata "$NO_MODEL_CONFIG" "$TWORK/never2.json" 2>&1)"; then
    no "a config.json with no hardwareModel is refused" "exited 0"
else
    expect_contains "$out" "no hardwareModel" "a config.json with no hardwareModel is refused"
fi

# --------------------------------------------------------------------------
# 6. Self-check parsing
# --------------------------------------------------------------------------
SELFCHECK="$TWORK/selfcheck.txt"
cat >"$SELFCHECK" <<'TXT'
RVM-SELFCHECK-V1
runner_uid=502
runner_dir=/Users/runner/actions-runner
runner_version=2.337.0
agent_version=runnervm-guest-agent v0.1.0 (darwin/arm64)
launchd_loaded=yes
git_version=git version 2.51.0
credential_helper=<empty>
runner_sudo=yes
sw_vers_product_version=26.1
sw_vers_build_version=25G83
RVM-SELFCHECK-END
TXT
expect_eq "$(selfcheck_value "$SELFCHECK" runner_uid)" "502" "runner_uid is parsed"
expect_eq "$(selfcheck_value "$SELFCHECK" sw_vers_build_version)" "25G83" "buildVersion is parsed"
expect_eq "$(selfcheck_value "$SELFCHECK" agent_version)" \
    "runnervm-guest-agent v0.1.0 (darwin/arm64)" "a value with spaces and parens survives"
expect_eq "$(selfcheck_value "$SELFCHECK" credential_helper)" "<empty>" \
    "the empty credential helper is reported explicitly"
expect_eq "$(selfcheck_value "$SELFCHECK" nope)" "" "an absent key parses as empty"

GUEST_PRODUCT_VERSION=""
check_selfcheck
expect_eq "$GUEST_PRODUCT_VERSION" "26.1" "check_selfcheck picks up the guest product version"

# The credential helper is the one macOS setting a runner image must not get wrong.
BAD_SELFCHECK="$TWORK/selfcheck-bad.txt"
sed 's/^credential_helper=.*/credential_helper=osxkeychain/' "$SELFCHECK" >"$BAD_SELFCHECK"
MISSING_GIT="$TWORK/selfcheck-nogit.txt"
grep -v '^git_version=' "$SELFCHECK" >"$MISSING_GIT"
GOOD_SELFCHECK="$SELFCHECK"

# check_selfcheck reads the SELFCHECK global and dies on a bad guest; the command substitution is
# already a subshell, so the `die` only unwinds the check, not this test run.
SELFCHECK="$BAD_SELFCHECK"
if out="$(check_selfcheck 2>&1)"; then
    no "a leftover credential helper fails the run" "exited 0"
else
    expect_contains "$out" "not the required empty override" "a leftover credential helper fails the run"
fi

SELFCHECK="$MISSING_GIT"
if out="$(check_selfcheck 2>&1)"; then
    no "a guest with no git fails the run" "exited 0"
else
    expect_contains "$out" "no git_version" "a guest with no git fails the run"
fi

# A LaunchDaemon that did not load is the one thing that has to work on the first cold boot under
# RunnerVM, so it fails the build instead of warning.
NO_DAEMON="$TWORK/selfcheck-nodaemon.txt"
sed 's/^launchd_loaded=.*/launchd_loaded=no/' "$GOOD_SELFCHECK" >"$NO_DAEMON"
SELFCHECK="$NO_DAEMON"
if out="$(check_selfcheck 2>&1)"; then
    no "an unloaded LaunchDaemon fails the run" "exited 0"
else
    expect_contains "$out" "LaunchDaemon is not loaded" "an unloaded LaunchDaemon fails the run"
fi
SELFCHECK="$GOOD_SELFCHECK"

# "<unset>" is not "<empty>": no helper configured at all leaves nothing to stop a later install
# from adding a Keychain-backed one.
UNSET_SELFCHECK="$TWORK/selfcheck-unset.txt"
sed 's/^credential_helper=.*/credential_helper=<unset>/' "$GOOD_SELFCHECK" >"$UNSET_SELFCHECK"
SELFCHECK="$UNSET_SELFCHECK"
if out="$(check_selfcheck 2>&1)"; then
    no "an unconfigured credential helper fails the run" "exited 0"
else
    expect_contains "$out" "not the required empty override" \
        "an unconfigured credential helper fails the run"
fi
SELFCHECK="$GOOD_SELFCHECK"

# --------------------------------------------------------------------------
# 6b. Seal-time lockdown report parsing
# --------------------------------------------------------------------------
HARDEN_REPORT="$TWORK/harden.txt"
write_harden_report() {
    cat >"$1" <<TXT
RVM-HARDEN-V1
harden_user=admin
password_rotated=${2:-yes}
old_password_rejected=${3:-yes}
authorized_keys_removed=1
sshd_disabled=${4:-yes}
sshd_disabled_readback=yes
remote_login_off_at=next-boot
RVM-HARDEN-END
TXT
}

write_harden_report "$HARDEN_REPORT"
if out="$(check_harden_report 2>&1)"; then
    expect_contains "$out" "password rotated" "a complete lockdown report passes"
else
    no "a complete lockdown report passes" "$out"
fi

write_harden_report "$HARDEN_REPORT" no
if out="$(check_harden_report 2>&1)"; then
    no "an unrotated password fails the build" "exited 0"
else
    expect_contains "$out" "did not rotate" "an unrotated password fails the build"
fi

write_harden_report "$HARDEN_REPORT" yes no
if out="$(check_harden_report 2>&1)"; then
    no "an old password that still authenticates fails the build" "exited 0"
else
    expect_contains "$out" "still authenticates" \
        "an old password that still authenticates fails the build"
fi

write_harden_report "$HARDEN_REPORT" yes yes no
if out="$(check_harden_report 2>&1)"; then
    no "sshd left enabled fails the build" "exited 0"
else
    expect_contains "$out" "did not disable com.openssh.sshd" "sshd left enabled fails the build"
fi

# Key auth cannot prove the old credential is rejected; that is a warning plus a pointer at the
# cold-boot check, not a refusal.
write_harden_report "$HARDEN_REPORT" yes unknown
if out="$(check_harden_report 2>&1)"; then
    expect_contains "$out" "qualify-macos-image.sh" \
        "an unprovable rotation warns and points at the cold-boot check"
else
    no "an unprovable rotation warns rather than failing" "$out"
fi

# --------------------------------------------------------------------------
# 6c. A forced stop must not seal
# --------------------------------------------------------------------------
GRACEFUL_SHUTDOWN=1
if out="$(require_clean_shutdown 2>&1)"; then
    ok "a graceful shutdown may seal"
else
    no "a graceful shutdown may seal" "$out"
fi

GRACEFUL_SHUTDOWN=0
ALLOW_DIRTY_SEAL=0
if out="$(require_clean_shutdown 2>&1)"; then
    no "a forced stop refuses to seal" "exited 0"
else
    expect_contains "$out" "only crash-consistent" "a forced stop refuses to seal"
fi

ALLOW_DIRTY_SEAL=1
if out="$(require_clean_shutdown 2>&1)"; then
    expect_contains "$out" "debugging artifact" "--allow-dirty-seal seals with a warning"
else
    no "--allow-dirty-seal seals with a warning" "$out"
fi
ALLOW_DIRTY_SEAL=0
GRACEFUL_SHUTDOWN=1

# --------------------------------------------------------------------------
# 7. tart list membership (pure; no tart involved)
# --------------------------------------------------------------------------
LISTING="$(printf '%s\n' "ghcr.io/cirruslabs/macos-tahoe-base:latest" "runnervm-macos-base" "other")"
if vm_exists_in_list "runnervm-macos-base" "$LISTING"; then
    ok "an existing VM name is found in a tart listing"
else
    no "an existing VM name is found in a tart listing" "not matched"
fi
if vm_exists_in_list "runnervm-macos" "$LISTING"; then
    no "a partial name does not match" "matched a prefix"
else
    ok "a partial name does not match"
fi
if vm_exists_in_list "ghcr.io/cirruslabs/macos-tahoe-base:latest" "$LISTING"; then
    ok "an OCI source reference is found in a tart listing"
else
    no "an OCI source reference is found in a tart listing" "not matched"
fi

# --------------------------------------------------------------------------
# 8. Remote command quoting, and the guest script's own inputs
# --------------------------------------------------------------------------
expect_eq "$(shq "plain")" "'plain'" "shq quotes a plain value"
expect_eq "$(shq "it's")" "'it'\\''s'" "shq escapes an embedded single quote"

if out="$(STAGE_DIR="$TWORK/missing" bash "$GUEST_SCRIPT" 2>&1)"; then
    no "the guest script refuses to run as a non-root user" "exited 0"
else
    expect_contains "$out" "must run as root" "the guest script refuses to run as a non-root user"
fi

if out="$(STAGE=harden bash "$GUEST_SCRIPT" 2>&1)"; then
    no "the harden stage refuses to run as a non-root user" "exited 0"
else
    expect_contains "$out" "must run as root" "the harden stage refuses to run as a non-root user"
fi

# The old password reaches the guest as a 0600 file, never as an argv assignment: an `ssh ... env
# HARDEN_OLD_PASSWORD=...` command line would be readable in `ps` on the *host*, which is not a
# throwaway VM. The guest reads it once and unlinks it.
#
# The patterns below are deliberately literal (single-quoted): they are source text being matched
# in another file, not expressions to expand here.
# shellcheck disable=SC2016
if grep -q 'HARDEN_OLD_PASSWORD=\$(shq' "$SCRIPT"; then
    no "the old password is never an ssh argv assignment" "found HARDEN_OLD_PASSWORD=... in $SCRIPT"
else
    ok "the old password is never an ssh argv assignment"
fi
# shellcheck disable=SC2016
expect_contains "$(cat "$GUEST_SCRIPT")" 'rm -f "$HARDEN_OLD_PASSWORD_FILE"' \
    "the guest unlinks the staged password file after reading it"

# The lockdown runs the guest script a second time, so the provisioning stage must not delete it
# out from under that. It is the guest's own detached shutdown tail that removes it, and the host
# only does so on the --debug-ssh path where there is no second stage.
# shellcheck disable=SC2016
if grep -q 'rm -f .\$GUEST_SCRIPT_REMOTE' "$SCRIPT" &&
    ! grep -q 'remove_guest_script' "$SCRIPT"; then
    no "the provisioning stage does not delete the script the lockdown re-runs" \
        "the host removes $GUEST_SCRIPT_REMOTE unconditionally"
else
    ok "the provisioning stage does not delete the script the lockdown re-runs"
fi
expect_contains "$(cat "$GUEST_SCRIPT")" "rm -f '\$self'" \
    "the guest removes its own script from the detached shutdown tail"

if out="$(STAGE=nonsense bash "$GUEST_SCRIPT" 2>&1)"; then
    no "an unknown STAGE fails" "exited 0"
else
    expect_contains "$out" "STAGE must be all or harden" "an unknown STAGE fails before doing anything"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
