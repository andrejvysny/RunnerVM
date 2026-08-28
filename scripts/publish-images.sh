#!/usr/bin/env bash
# Publish a locally sealed RunnerVM image to an OCI registry under one or more tags.
#
# This is the operator-facing wrapper around `runnerctl image push`. It exists for one reason: a
# published image is the thing other hosts boot, so the checks that are advisory for a local image
# ("it still has SSH open", "its guest agent came from a dirty tree", "its actions/runner is
# already stale") are refusals here. Every one of them can be overridden explicitly; none of them
# can be skipped by accident.
#
# Images are built on an Apple Silicon host -- GitHub-hosted macOS runners cannot nest
# Virtualization.framework (see .github/workflows/github-integration.yml), so there is no hosted-CI
# path that could produce one. This script therefore runs by hand, on the build host, against a
# running runnerd.
#
# usage:
#   scripts/publish-images.sh --image ubuntu-24 --package ubuntu-24-base \
#     --repo ghcr.io/andrejvysny/runnervm \
#     --tag 2026-08-28 --tag r2.337.0 --tag stable
#
# The first --tag moves every byte; the rest re-use the blobs already uploaded (the registry client
# checks `blobExists` before each chunk), so extra tags are close to free. The immutable
# `<repo>/<package>@sha256:<hex>` the registry assigns is what the JSON report records and what a
# profile's `image:` should reference -- never a tag.
#
# Credentials come from the daemon, not from this script: `runnerctl registry login <host> -u <user>
# --password-stdin` before the first run. See docs/images.md "Publishing and pulling from a
# registry".
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/lib/live-common.sh
# shellcheck disable=SC1091 # dynamic path; run shellcheck -x to actually follow it
source "$REPO_ROOT/scripts/lib/live-common.sh"
LOG_PREFIX="publish"

# --------------------------------------------------------------------------
# Defaults, flags
# --------------------------------------------------------------------------
IMAGE=""
PACKAGE=""
REGISTRY_REPO=""
TAGS=()
SOCKET=""
STATE_DIR="$HOME/Library/Application Support/RunnerVM"
JSON_REPORT=""
DRY_RUN=0
ALLOW_SSH=0
ALLOW_DIRTY=0
ALLOW_STALE_RUNNER=0

# Set by resolve_image(), read by the check_* functions and by the report.
IMAGE_JSON=""
IMAGE_DIGEST=""
IMAGE_OS=""
IMAGE_VIRTUAL_BYTES=""
IMAGE_RUNNER_VERSION=""
IMAGE_RUNNER_HEALTH=""
IMAGE_AGENT_VERSION=""
IMAGE_SSH=""
PUSHED_REFERENCE=""

usage() {
    cat <<'EOF'
usage: publish-images.sh --image <name|digest> --package <name> --repo <registry/owner/path> \
                         --tag <tag> [--tag <tag> ...] [options]

Publishes one locally sealed RunnerVM image to an OCI registry under one or more tags, after
refusing anything that should not become a published artifact.

required:
  --image <name|digest>   Local image to publish, as `runnerctl image inspect` accepts it.
  --package <name>        Package name under --repo, e.g. ubuntu-24-base.
  --repo <ref>            Registry and namespace, e.g. ghcr.io/andrejvysny/runnervm.
  --tag <tag>             Tag to publish under. Repeatable; the first one carries the upload.

options:
  --socket <path>         runnerd socket (default: runnerctl's own default).
  --state-dir <path>      RunnerVM state directory, used to read the image's metadata.json.
                          Default: ~/Library/Application Support/RunnerVM
  --json-report <path>    Where to write the run report. Default: <state-dir>/logs/publish-<ts>.json
  --dry-run               Print the plan and the resolved references; touch nothing.
  --allow-ssh             Publish a macOS image even though it records capabilities.ssh: true.
  --allow-dirty           Publish even though its guest agent came from a dirty working tree.
  --allow-stale-runner    Publish even though its actions/runner is graded stale or tooOld.
  -h, --help              This text.

Refusals (each with the flag that overrides it):
  * the image is not `ready`                                          -- no override
  * it carries no RunnerVM guest agent (it could never run a job)     -- no override
  * a macOS image records capabilities.ssh: true -- it kept the Tart
    base's admin/admin credential (Linux images legitimately record
    ssh: true; sshd there has no keys and no password auth)           -- --allow-ssh
  * guestAgentVersion contains "-dirty"                               -- --allow-dirty
  * runnerVersionHealth is stale or tooOld                            -- --allow-stale-runner

Credentials belong to the daemon:
  echo "$GHCR_PAT" | runnerctl registry login ghcr.io -u <user> --password-stdin
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
        --image) IMAGE="$2"; shift 2 ;;
        --package) PACKAGE="$2"; shift 2 ;;
        --repo) REGISTRY_REPO="$2"; shift 2 ;;
        --tag) TAGS+=("$2"); shift 2 ;;
        --socket) SOCKET="$2"; shift 2 ;;
        --state-dir) STATE_DIR="$2"; shift 2 ;;
        --json-report) JSON_REPORT="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --allow-ssh) ALLOW_SSH=1; shift ;;
        --allow-dirty) ALLOW_DIRTY=1; shift ;;
        --allow-stale-runner) ALLOW_STALE_RUNNER=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
        esac
    done
}

validate_args() {
    [ -n "$IMAGE" ] || die "--image <name|digest> is required; see --help"
    [ -n "$PACKAGE" ] || die "--package <name> is required; see --help"
    [ -n "$REGISTRY_REPO" ] || die "--repo <registry/owner/path> is required; see --help"
    [ "${#TAGS[@]}" -gt 0 ] || die "at least one --tag is required; see --help"

    valid_package_name "$PACKAGE" || die "invalid --package '$PACKAGE': lowercase alphanumerics, '.', '_' and '-' only"
    valid_registry_repo "$REGISTRY_REPO" || die "invalid --repo '$REGISTRY_REPO': expected <host>/<path>, e.g. ghcr.io/owner/repo"

    local tag
    for tag in "${TAGS[@]}"; do
        valid_tag "$tag" || die "invalid --tag '$tag': [A-Za-z0-9_][A-Za-z0-9._-]{0,127}"
    done
}

# --------------------------------------------------------------------------
# Pure helpers (sourced and exercised directly by scripts/tests/publish-images-test.sh)
# --------------------------------------------------------------------------

# OCI tag grammar (image-spec): first character alphanumeric or '_', then up to 127 more of
# alphanumeric, '.', '_' or '-'.
valid_tag() {
    [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]]
}

# One path component of an OCI repository name: lowercase only, separators never leading, trailing
# or doubled. Deliberately stricter than the spec's full grammar -- a package name is chosen, not
# parsed, and an uppercase one is a typo that a registry would silently reject much later.
valid_package_name() {
    [[ "$1" =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]]
}

# <host>[:port]/<path>, at least one path component. The host must look like a host (contain a '.'
# or a ':', or be "localhost"): RunnerVM never falls back to an implicit Docker Hub, so a reference
# with no registry is a mistake worth catching here rather than at the daemon.
valid_registry_repo() {
    local ref="$1" host="${1%%/*}" path="${1#*/}"
    [ "$ref" != "$host" ] || return 1
    [ -n "$path" ] || return 1
    case "$host" in
    localhost | localhost:*) ;;
    *.* | *:*) ;;
    *) return 1 ;;
    esac
    [[ "$path" =~ ^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*$ ]]
}

registry_host() {
    printf '%s' "${1%%/*}"
}

image_reference() {
    printf '%s/%s:%s' "$1" "$2" "$3"
}

# The manifest directory ImageManager records as local_path uses "sha256-<hex>": a colon is hostile
# in shell paths (Sources/ImageStore/LocalImageManifest.swift).
metadata_path_for_digest() {
    printf '%s/images/manifests/%s/metadata.json' "$1" "${2/:/-}"
}

# --------------------------------------------------------------------------
# Preconditions
# --------------------------------------------------------------------------
require_tools() {
    command -v jq >/dev/null 2>&1 || die "jq is required"
    RUNNERCTL_BIN="$(find_runnerctl)"
    [ -n "$RUNNERCTL_BIN" ] || die "runnerctl not found; build it (swift build) or set RUNNERCTL"
    [ -x "$RUNNERCTL_BIN" ] || die "runnerctl at '$RUNNERCTL_BIN' is not executable"
}

resolve_image() {
    IMAGE_JSON=$(rc image inspect "$IMAGE") || die "no local image '$IMAGE' (runnerctl image list)"
    IMAGE_DIGEST=$(echo "$IMAGE_JSON" | jq -r '.digest // empty')
    [ -n "$IMAGE_DIGEST" ] || die "image inspect returned no digest for '$IMAGE'"
    IMAGE_OS=$(echo "$IMAGE_JSON" | jq -r '.os // "unknown"')
    IMAGE_VIRTUAL_BYTES=$(echo "$IMAGE_JSON" | jq -r '.virtualSizeBytes // 0')
    IMAGE_RUNNER_VERSION=$(echo "$IMAGE_JSON" | jq -r '.runnerVersion // "unknown"')
    IMAGE_RUNNER_HEALTH=$(echo "$IMAGE_JSON" | jq -r '.runnerVersionHealth // "unknown"')

    # guestAgentVersion and capabilities.ssh are not on ImageInfoDTO; they live in the sealed
    # metadata.json beside the manifest, which is what `image push` uploads as the OCI config blob.
    local metadata
    metadata=$(metadata_path_for_digest "$STATE_DIR" "$IMAGE_DIGEST")
    if [ -r "$metadata" ]; then
        IMAGE_AGENT_VERSION=$(jq -r '.guestAgentVersion // "unknown"' "$metadata")
        IMAGE_SSH=$(jq -r '.capabilities.ssh // false' "$metadata")
    else
        IMAGE_AGENT_VERSION="unreadable"
        IMAGE_SSH="unreadable"
        warn "cannot read $metadata -- the SSH and dirty-agent checks below cannot run"
        warn "pass --state-dir if this host's RunnerVM state is not at '$STATE_DIR'"
    fi
}

# Every refusal names the flag that overrides it, so an operator who disagrees does so on purpose.
check_publishable() {
    local state guest_agent
    state=$(echo "$IMAGE_JSON" | jq -r '.state // "unknown"')
    [ "$state" = "ready" ] || die "image '$IMAGE' is '$state', not ready"

    guest_agent=$(echo "$IMAGE_JSON" | jq -r '.guestAgent // false')
    [ "$guest_agent" = "true" ] \
        || die "image '$IMAGE' carries no RunnerVM guest agent -- it could never run a job (IMAGE_NO_GUEST_AGENT)"

    # `capabilities.ssh` means two different things per guest OS, so the refusal is macOS-only.
    # On Linux it records that socket-activated sshd is installed -- with no authorized_keys and
    # PasswordAuthentication off (docs/images.md "No SSH keys are provisioned"), which is true of
    # every shipped recipe and is not a finding. On macOS it means the Tart base image's
    # well-known admin/admin account and Remote Login survived the seal-time lockdown
    # (provision-macos-tart.sh --debug-ssh), so every clone would carry the same working
    # credential, reachable on the guest's NAT address, in front of an untrusted workload.
    if [ "$IMAGE_OS" = "macos" ]; then
        case "$IMAGE_SSH" in
        true)
            [ "$ALLOW_SSH" -eq 1 ] \
                || die "macOS image '$IMAGE' records capabilities.ssh: true -- it kept the Tart base's admin credential; every clone would carry it. Re-provision without --debug-ssh, or pass --allow-ssh"
            warn "publishing a macOS image with SSH enabled (--allow-ssh)"
            ;;
        unreadable) warn "SSH capability unknown for a macOS image; publishing anyway" ;;
        esac
    fi

    case "$IMAGE_AGENT_VERSION" in
    *-dirty)
        [ "$ALLOW_DIRTY" -eq 1 ] \
            || die "guest agent '$IMAGE_AGENT_VERSION' came from a dirty working tree; rebuild it from a clean checkout, or pass --allow-dirty"
        warn "publishing an image whose guest agent is '$IMAGE_AGENT_VERSION' (--allow-dirty)"
        ;;
    esac

    case "$IMAGE_RUNNER_HEALTH" in
    stale | tooOld)
        [ "$ALLOW_STALE_RUNNER" -eq 1 ] \
            || die "actions/runner $IMAGE_RUNNER_VERSION is graded '$IMAGE_RUNNER_HEALTH'; rebuild the image, or pass --allow-stale-runner"
        warn "publishing actions/runner $IMAGE_RUNNER_VERSION, graded '$IMAGE_RUNNER_HEALTH' (--allow-stale-runner)"
        ;;
    unknown)
        warn "actions/runner freshness is unknown (no GitHub credential, or the daemon has not read a release list yet)"
        ;;
    esac
}

# Advisory only: `registry status` lists the registries the *profiles* name, so a host that has
# never referenced this registry in its configuration reports nothing even with a valid credential.
check_credential() {
    local host present
    host=$(registry_host "$REGISTRY_REPO")
    present=$(rc registry status 2>/dev/null \
        | jq -r --arg h "$host" '[.registries[]? | select(.registry==$h and .provider!=null)] | length' 2>/dev/null) \
        || present=0
    [ "$present" != "0" ] \
        || warn "no credential is visible for $host; if the push fails with REGISTRY_AUTH, run: runnerctl registry login $host -u <user> --password-stdin"
}

# --------------------------------------------------------------------------
# Plan and push
# --------------------------------------------------------------------------
print_plan() {
    local tag
    log "image        $IMAGE ($IMAGE_DIGEST)"
    log "os/size      $IMAGE_OS, $IMAGE_VIRTUAL_BYTES bytes virtual"
    log "runner       $IMAGE_RUNNER_VERSION ($IMAGE_RUNNER_HEALTH)"
    log "guest agent  $IMAGE_AGENT_VERSION"
    log "ssh          $IMAGE_SSH"
    for tag in "${TAGS[@]}"; do
        log "push         $(image_reference "$REGISTRY_REPO" "$PACKAGE" "$tag")"
    done
    log "the first tag uploads every chunk; the rest reuse the blobs it just wrote"
}

push_tags() {
    local tag reference response pushed
    for tag in "${TAGS[@]}"; do
        reference=$(image_reference "$REGISTRY_REPO" "$PACKAGE" "$tag")
        log "pushing $IMAGE to $reference"
        response=$(rc image push "$IMAGE" "$reference") || die "image push to $reference failed"
        # The registry's manifest digest is not the image's content digest; the immutable reference
        # to pin is the one the push operation itself recorded.
        pushed=$(echo "$response" | jq -r '.result.pushedReference // empty')
        if [ -n "$pushed" ]; then
            PUSHED_REFERENCE="$pushed"
            log "pushed $pushed"
        else
            warn "push of $reference reported no pushedReference"
        fi
    done
    [ -n "$PUSHED_REFERENCE" ] || die "no push reported an immutable reference; nothing to pin"
}

write_publish_report() {
    local out
    out="$JSON_REPORT"
    [ -n "$out" ] || out="$STATE_DIR/logs/publish-$(date -u +%Y%m%dT%H%M%SZ).json"
    mkdir -p "$(dirname "$out")"
    jq -n \
        --arg image "$IMAGE" --arg digest "$IMAGE_DIGEST" --arg os "$IMAGE_OS" \
        --arg repo "$REGISTRY_REPO" --arg package "$PACKAGE" \
        --arg runnerVersion "$IMAGE_RUNNER_VERSION" --arg runnerHealth "$IMAGE_RUNNER_HEALTH" \
        --arg guestAgentVersion "$IMAGE_AGENT_VERSION" --arg ssh "$IMAGE_SSH" \
        --arg pushedReference "$PUSHED_REFERENCE" \
        --arg publishedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson virtualSizeBytes "$IMAGE_VIRTUAL_BYTES" \
        --args '{image:$image,digest:$digest,os:$os,virtualSizeBytes:$virtualSizeBytes,
                 runnerVersion:$runnerVersion,runnerVersionHealth:$runnerHealth,
                 guestAgentVersion:$guestAgentVersion,ssh:$ssh,
                 repository:$repo,package:$package,tags:$ARGS.positional,
                 pushedReference:$pushedReference,publishedAt:$publishedAt}' \
        "${TAGS[@]}" >"$out"
    log "report written to $out"
    log "pin this, not a tag: $PUSHED_REFERENCE"
}

main() {
    parse_args "$@"
    validate_args
    require_tools
    check_daemon_reachable
    resolve_image
    check_publishable
    if [ "$DRY_RUN" -eq 1 ]; then
        log "dry-run: nothing will be pushed"
        print_plan
        exit 0
    fi
    check_credential
    print_plan
    push_tags
    write_publish_report
}

# Guarded so scripts/tests/publish-images-test.sh can source this file and exercise its pure
# helpers with no daemon, no image and no network.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
