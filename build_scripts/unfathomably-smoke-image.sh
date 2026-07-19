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
CUSTOM_IMAGE="${UNFATHOMABLY_SMOKE_IMAGE:-${SMOKE_IMAGE:-}}"
IMAGE="${CUSTOM_IMAGE:-unfathomably-elixir-smoke:otp28}"

if ! command -v docker >/dev/null 2>&1; then
    printf 'Required command not found: docker\n' >&2
    exit 1
fi

if [ -n "$CUSTOM_IMAGE" ] && docker image inspect "$IMAGE" >/dev/null 2>&1; then
    printf 'Reusing federation smoke image: %s\n' "$IMAGE"
    exit 0
fi

printf 'Building federation smoke image: %s\n' "$IMAGE"
docker build \
    --pull \
    --tag "$IMAGE" \
    --file "$SCRIPT_DIR/Dockerfile.smoke" \
    "$SCRIPT_DIR"

# end of unfathomably-smoke-image.sh
