#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-sharkey-smoke.sh
#
# Purpose:
#
#   Run the stock Sharkey server through the proven Misskey-family
#   federation harness.
#
# Responsibilities:
#
#   * select Sharkey's published container image and runtime layout
#   * assign isolated hosts, ports, database names, and container names
#   * reuse the Misskey-family TLS, API, polling, and cleanup behavior
#   * exercise bidirectional follow, post, reply, reaction, delete,
#     quote, and unfollow paths against Unfathomably
#
# This file intentionally does NOT contain:
#
#   * a second copy of the Misskey-compatible federation driver
#   * patched Sharkey source code
#   * production deployment logic
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAMILY_HARNESS="$SCRIPT_DIR/unfathomably-misskey-smoke.sh"

if [ ! -f "$FAMILY_HARNESS" ]; then
    printf 'ERROR: Missing Misskey-family harness: %s\n' "$FAMILY_HARNESS" >&2
    exit 1
fi

export SMOKE_PREFIX="${SMOKE_PREFIX:-unfathomably-sharkey-smoke}"
export BE_HOST="${BE_HOST:-unfathomably-sharkey.test}"
export BE_PORT="${BE_PORT:-5001}"
export BE_DB_NAME="${BE_DB_NAME:-unfathomably_sharkey_smoke_be}"

export MISSKEY_HOST="${SHARKEY_HOST:-${MISSKEY_HOST:-sharkey-ref.test}}"
export MISSKEY_PORT="${SHARKEY_PORT:-${MISSKEY_PORT:-5002}}"
export MISSKEY_DB_NAME="${SHARKEY_DB_NAME:-${MISSKEY_DB_NAME:-sharkey}}"
export MISSKEY_DB_USER="${SHARKEY_DB_USER:-${MISSKEY_DB_USER:-sharkey}}"
export MISSKEY_DB_PASSWORD="${SHARKEY_DB_PASSWORD:-${MISSKEY_DB_PASSWORD:-sharkey}}"
export MISSKEY_IMAGE="${SHARKEY_IMAGE:-${MISSKEY_IMAGE:-registry.activitypub.software/transfem-org/sharkey:latest}}"
export MISSKEY_RUNTIME_HOME="${SHARKEY_RUNTIME_HOME:-/sharkey}"
export MISSKEY_LABEL="Sharkey"
export MISSKEY_USERNAME="${SHARKEY_USERNAME:-sharkey}"

exec bash "$FAMILY_HARNESS" "$@"

# end of build_scripts/unfathomably-sharkey-smoke.sh
