#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-smoke-image.sh
#
# Purpose:
#
#   Ensure the shared Elixir/Erlang smoke image exists before an adapter tries
#   to run Mix commands inside it.
#
# Responsibilities:
#
#   * honor the existing smoke-image environment overrides
#   * reuse an already-built local image
#   * build the pinned local image when it is absent
#
# This file intentionally does NOT contain:
#
#   * peer setup or federation assertions
#   * registry credentials
#   * production image construction
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CUSTOM_IMAGE="${UNFATHOMABLY_SMOKE_IMAGE:-${SMOKE_IMAGE:-}}"

read_tool_version() {
    local name="$1"

    awk -v wanted="$name" '$1 == wanted { print $2; exit }' "$BE_ROOT/.tool-versions"
}

ELIXIR_TOOL_VERSION="$(read_tool_version elixir)"
OTP_TOOL_VERSION="$(read_tool_version erlang)"

if [ -z "$ELIXIR_TOOL_VERSION" ] || [ -z "$OTP_TOOL_VERSION" ]; then
    printf 'Could not read Elixir and Erlang versions from %s/.tool-versions\n' "$BE_ROOT" >&2
    exit 1
fi

ELIXIR_VERSION="${ELIXIR_TOOL_VERSION%%-otp-*}"
ELIXIR_OTP_MAJOR="${ELIXIR_TOOL_VERSION##*-otp-}"
OTP_MAJOR="${OTP_TOOL_VERSION%%.*}"

if [ "$ELIXIR_OTP_MAJOR" = "$ELIXIR_TOOL_VERSION" ] || \
   [ "$ELIXIR_OTP_MAJOR" != "$OTP_MAJOR" ]; then
    printf 'Elixir runtime %s does not match Erlang runtime %s\n' \
        "$ELIXIR_TOOL_VERSION" "$OTP_TOOL_VERSION" >&2
    exit 1
fi

ELIXIR_IMAGE="elixir:$ELIXIR_VERSION-otp-$OTP_MAJOR"
IMAGE="${CUSTOM_IMAGE:-unfathomably-elixir-smoke:otp$OTP_MAJOR}"
RUNTIME_LABEL="$ELIXIR_TOOL_VERSION+$OTP_TOOL_VERSION"

if ! command -v docker >/dev/null 2>&1; then
    printf 'Required command not found: docker\n' >&2
    exit 1
fi

if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    if [ -n "$CUSTOM_IMAGE" ]; then
        printf 'Reusing operator-provided federation smoke image: %s\n' "$IMAGE"
        exit 0
    fi

    EXISTING_RUNTIME="$(
        docker image inspect \
            --format '{{ index .Config.Labels "org.unfathomably.smoke.runtime" }}' \
            "$IMAGE" 2>/dev/null || true
    )"

    if [ "$EXISTING_RUNTIME" = "$RUNTIME_LABEL" ]; then
        printf 'Reusing federation smoke image: %s (%s)\n' "$IMAGE" "$RUNTIME_LABEL"
        exit 0
    fi

    printf 'Rebuilding stale federation smoke image: %s (%s -> %s)\n' \
        "$IMAGE" "${EXISTING_RUNTIME:-unlabelled}" "$RUNTIME_LABEL"
fi

printf 'Building federation smoke image: %s from %s\n' "$IMAGE" "$ELIXIR_IMAGE"
docker build \
    --pull \
    --build-arg "ELIXIR_IMAGE=$ELIXIR_IMAGE" \
    --label "org.unfathomably.smoke.runtime=$RUNTIME_LABEL" \
    --tag "$IMAGE" \
    --file "$SCRIPT_DIR/Dockerfile.smoke" \
    "$SCRIPT_DIR"

# end of unfathomably-smoke-image.sh
