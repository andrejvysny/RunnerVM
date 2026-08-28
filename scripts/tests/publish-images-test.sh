#!/usr/bin/env bash
# Unit checks for scripts/publish-images.sh that need no daemon, no image and no network.
#
# Two styles, matched to what each check needs (same split as scripts/tests/qualify-macos-image-test.sh):
#   - argument handling is exercised as a real subprocess, because those paths exit;
#   - the pure helpers (reference grammar, metadata path algebra) are exercised by `source`-ing the
#     script, which guards its own `main` behind `[ "${BASH_SOURCE[0]}" = "${0}" ]` exactly so this
#     file can call them directly.
#
# The refusal ladder in check_publishable() is exercised too, by setting the globals resolve_image()
# would have set and calling it in a subshell -- it never touches the daemon itself.
#
# usage: scripts/tests/publish-images-test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/publish-images.sh"
TWORK="$(mktemp -d "${TMPDIR:-/tmp}/rvm-publish-test-XXXXXX")"
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

# $1=description, $2..=arguments. Passes when the script exits non-zero and says $EXPECT.
expect_refusal() {
    local what="$1" needle="$2"
    shift 2
    local out
    if out="$("$SCRIPT" "$@" 2>&1)"; then
        no "$what" "expected a non-zero exit, got 0: $out"
    else
        expect_contains "$out" "$needle" "$what"
    fi
}

# --------------------------------------------------------------------------
# 1. Argument handling, as a subprocess (these paths exit before any daemon call)
# --------------------------------------------------------------------------
if help_out="$("$SCRIPT" --help 2>&1)"; then
    expect_contains "$help_out" "usage: publish-images.sh" "--help prints usage"
    expect_contains "$help_out" "--allow-ssh" "--help documents --allow-ssh"
    expect_contains "$help_out" "--allow-dirty" "--help documents --allow-dirty"
    expect_contains "$help_out" "--allow-stale-runner" "--help documents --allow-stale-runner"
    expect_contains "$help_out" "registry login" "--help names the credential command"
else
    no "--help exits 0" "$help_out"
fi

expect_refusal "unknown argument is refused" "unknown argument: --nonsense" --nonsense
expect_refusal "--image is required" "--image <name|digest> is required" \
    --package ubuntu-24-base --repo ghcr.io/o/r --tag v1
expect_refusal "--package is required" "--package <name> is required" \
    --image ubuntu-24 --repo ghcr.io/o/r --tag v1
expect_refusal "--repo is required" "--repo <registry/owner/path> is required" \
    --image ubuntu-24 --package ubuntu-24-base --tag v1
expect_refusal "at least one --tag is required" "at least one --tag is required" \
    --image ubuntu-24 --package ubuntu-24-base --repo ghcr.io/o/r
expect_refusal "an uppercase package name is refused" "invalid --package" \
    --image ubuntu-24 --package Ubuntu-24-Base --repo ghcr.io/o/r --tag v1
expect_refusal "a registry-less repo is refused" "invalid --repo" \
    --image ubuntu-24 --package ubuntu-24-base --repo owner/repo --tag v1
expect_refusal "a malformed tag is refused" "invalid --tag" \
    --image ubuntu-24 --package ubuntu-24-base --repo ghcr.io/o/r --tag -leading-dash

# --------------------------------------------------------------------------
# 2. Pure helpers, by sourcing
# --------------------------------------------------------------------------
# shellcheck source=SCRIPTDIR/../publish-images.sh
# shellcheck disable=SC1091 # dynamic path; run shellcheck -x to actually follow it
source "$SCRIPT"

if valid_tag "2026-08-28"; then ok "a date tag is valid"; else no "a date tag is valid"; fi
if valid_tag "r2.337.0"; then ok "a runner-version tag is valid"; else no "a runner-version tag is valid"; fi
if valid_tag "stable"; then ok "'stable' is a valid tag"; else no "'stable' is a valid tag"; fi
if valid_tag "_underscore"; then ok "a leading underscore is valid"; else no "a leading underscore is valid"; fi
if valid_tag ".dot"; then no "a leading dot is refused"; else ok "a leading dot is refused"; fi
if valid_tag "-dash"; then no "a leading dash is refused"; else ok "a leading dash is refused"; fi
if valid_tag "with space"; then no "a space is refused"; else ok "a space is refused"; fi
if valid_tag ""; then no "an empty tag is refused"; else ok "an empty tag is refused"; fi
if valid_tag "$(printf 'a%.0s' $(seq 1 129))"; then
    no "a 129-character tag is refused"
else
    ok "a 129-character tag is refused"
fi

if valid_package_name "ubuntu-24-base"; then ok "ubuntu-24-base is a valid package"; else no "ubuntu-24-base is a valid package"; fi
if valid_package_name "macos-26-base"; then ok "macos-26-base is a valid package"; else no "macos-26-base is a valid package"; fi
if valid_package_name "Ubuntu"; then no "uppercase is refused"; else ok "uppercase is refused"; fi
if valid_package_name "double--dash"; then no "a doubled separator is refused"; else ok "a doubled separator is refused"; fi
if valid_package_name "trailing-"; then no "a trailing separator is refused"; else ok "a trailing separator is refused"; fi
if valid_package_name "a/b"; then no "a slash is refused in a package name"; else ok "a slash is refused in a package name"; fi

if valid_registry_repo "ghcr.io/andrejvysny/runnervm"; then
    ok "a ghcr.io repo is valid"
else
    no "a ghcr.io repo is valid"
fi
if valid_registry_repo "localhost:5000/runners"; then ok "localhost:5000 is valid"; else no "localhost:5000 is valid"; fi
if valid_registry_repo "ubuntu-24"; then no "a bare name is refused"; else ok "a bare name is refused"; fi
if valid_registry_repo "owner/repo"; then no "an implicit Docker Hub reference is refused"; else ok "an implicit Docker Hub reference is refused"; fi
if valid_registry_repo "ghcr.io/"; then no "an empty path is refused"; else ok "an empty path is refused"; fi
if valid_registry_repo "ghcr.io/Owner/repo"; then no "an uppercase path is refused"; else ok "an uppercase path is refused"; fi

expect_eq "$(registry_host ghcr.io/andrejvysny/runnervm)" "ghcr.io" "registry_host takes the first component"
expect_eq "$(registry_host localhost:5000/runners)" "localhost:5000" "registry_host keeps the port"

expect_eq "$(image_reference ghcr.io/o/r ubuntu-24-base 2026-08-28)" \
    "ghcr.io/o/r/ubuntu-24-base:2026-08-28" "image_reference joins repo, package and tag"

# The manifest directory swaps the digest's colon for a dash (LocalImageManifest.swift).
expect_eq "$(metadata_path_for_digest /s sha256:abc123)" \
    "/s/images/manifests/sha256-abc123/metadata.json" "metadata_path_for_digest de-colons the digest"

# --------------------------------------------------------------------------
# 3. The refusal ladder in check_publishable()
# --------------------------------------------------------------------------
# Runs in a subshell so `die`'s exit does not end this file, and so each case can set the globals
# resolve_image() would have set without leaking them into the next one.
publishable_out() {
    local os="$1" state="$2" guest_agent="$3" ssh="$4" agent_version="$5" health="$6"
    shift 6
    (
        IMAGE="fixture"
        IMAGE_OS="$os"
        IMAGE_JSON=$(printf '{"state":"%s","guestAgent":%s}' "$state" "$guest_agent")
        IMAGE_SSH="$ssh"
        IMAGE_AGENT_VERSION="$agent_version"
        IMAGE_RUNNER_HEALTH="$health"
        IMAGE_RUNNER_VERSION="2.337.0"
        ALLOW_SSH=0
        ALLOW_DIRTY=0
        ALLOW_STALE_RUNNER=0
        for flag in "$@"; do
            case "$flag" in
            --allow-ssh) ALLOW_SSH=1 ;;
            --allow-dirty) ALLOW_DIRTY=1 ;;
            --allow-stale-runner) ALLOW_STALE_RUNNER=1 ;;
            esac
        done
        check_publishable 2>&1
    )
}

expect_publishable_refusal() {
    local what="$1" needle="$2"
    shift 2
    local out
    if out="$(publishable_out "$@")"; then
        no "$what" "expected a refusal, got: $out"
    else
        expect_contains "$out" "$needle" "$what"
    fi
}

if out="$(publishable_out linux ready true false c139b7d healthy)"; then
    ok "a clean, fresh Linux image is publishable"
else
    no "a clean, fresh Linux image is publishable" "$out"
fi
if out="$(publishable_out macos ready true false a3cca52 healthy)"; then
    ok "a hardened macOS image is publishable"
else
    no "a hardened macOS image is publishable" "$out"
fi

expect_publishable_refusal "a pulling image is refused" "is 'pulling', not ready" \
    linux pulling true false c139b7d healthy
expect_publishable_refusal "an agent-less image is refused" "carries no RunnerVM guest agent" \
    linux ready false false c139b7d healthy
expect_publishable_refusal "an SSH-open macOS image is refused" "kept the Tart base's admin credential" \
    macos ready true true a3cca52 healthy
expect_publishable_refusal "a dirty guest agent is refused" "dirty working tree" \
    linux ready true false a3cca52-dirty healthy
expect_publishable_refusal "a stale runner is refused" "graded 'stale'" \
    linux ready true false c139b7d stale
expect_publishable_refusal "a tooOld runner is refused" "graded 'tooOld'" \
    linux ready true false c139b7d tooOld

# Linux sshd carries no keys and no password auth (docs/images.md), so ssh: true is normal there
# and must not be a refusal -- every shipped Linux recipe installs openssh-server.
if out="$(publishable_out linux ready true true c139b7d healthy)"; then
    ok "a Linux image with ssh: true is published without an override"
else
    no "a Linux image with ssh: true is published without an override" "$out"
fi

# The overrides, and the warning each one must still print.
if out="$(publishable_out macos ready true true a3cca52 healthy --allow-ssh)"; then
    expect_contains "$out" "SSH enabled" "--allow-ssh publishes a macOS image and warns"
else
    no "--allow-ssh publishes a macOS image" "$out"
fi
if out="$(publishable_out linux ready true false a3cca52-dirty healthy --allow-dirty)"; then
    expect_contains "$out" "a3cca52-dirty" "--allow-dirty publishes and warns"
else
    no "--allow-dirty publishes" "$out"
fi
if out="$(publishable_out linux ready true false c139b7d tooOld --allow-stale-runner)"; then
    expect_contains "$out" "tooOld" "--allow-stale-runner publishes and warns"
else
    no "--allow-stale-runner publishes" "$out"
fi
# An unreadable metadata.json must not be fatal: the two checks it feeds warn instead.
if out="$(publishable_out macos ready true unreadable unreadable unknown)"; then
    expect_contains "$out" "SSH capability unknown" "an unreadable metadata.json warns, does not refuse"
else
    no "an unreadable metadata.json warns, does not refuse" "$out"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
