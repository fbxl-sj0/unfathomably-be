#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-protocol-bridges-smoke.sh
#
# Purpose:
#
#   Run the current selective-protocol and onion-transport contracts before
#   the expensive stock-platform federation matrix.
#
# Responsibilities:
#
#   * run every AT Protocol, Nostr, and Diaspora backend contract
#   * prove onion routing remains isolated, validated, and fail-closed
#   * exercise the matching frontend linking and identity presentation paths
#   * use the repository-pinned Elixir and Erlang smoke runtime
#
# This file intentionally does NOT contain:
#
#   * public credentials or production bridge secrets
#   * Bluesky firehose ingestion
#   * live relay, PDS, pod, or onion-service dependencies
#   * the retained two-container Nostr and NIP-29 lifecycle fixture
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BE_ROOT="${BE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
IMAGE="${UNFATHOMABLY_SMOKE_IMAGE:-${SMOKE_IMAGE:-unfathomably-elixir-smoke:otp29}}"
SKIP_FE="${PROTOCOL_BRIDGES_SKIP_FE:-0}"

if [ -n "${FE_ROOT:-}" ]; then
    RESOLVED_FE_ROOT="$FE_ROOT"
elif [ -d "$BE_ROOT/../unfathomably-fe" ]; then
    RESOLVED_FE_ROOT="$(cd "$BE_ROOT/../unfathomably-fe" && pwd)"
elif [ -d "$BE_ROOT/../../unfathomably-fe" ]; then
    RESOLVED_FE_ROOT="$(cd "$BE_ROOT/../../unfathomably-fe" && pwd)"
else
    RESOLVED_FE_ROOT=""
fi

log() {
    printf '\n==> %s\n' "$*"
}

fail() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

run_backend_contracts() {
    log "AT Protocol, Nostr, Diaspora, and Tor backend contracts"

    require_command docker

    if [ -n "${UNFATHOMABLY_SMOKE_IMAGE:-${SMOKE_IMAGE:-}}" ]; then
        UNFATHOMABLY_SMOKE_IMAGE="$IMAGE" \
            bash "$SCRIPT_DIR/unfathomably-smoke-image.sh"
    else
        bash "$SCRIPT_DIR/unfathomably-smoke-image.sh"
    fi

    docker run --rm \
        --network host \
        --user "$(id -u):$(id -g)" \
        -e HOME=/tmp \
        -e MIX_ENV=test \
        -e MIX_BUILD_PATH=/tmp/unfathomably-protocol-bridges-build \
        -e MIX_DEPS_PATH=/tmp/unfathomably-protocol-bridges-deps \
        -e MIX_HOME=/tmp/mix \
        -e HEX_HOME=/tmp/hex \
        -e NOSTR_BRIDGE_SECRET=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
        -v "$BE_ROOT:/work" \
        "$IMAGE" \
        bash -lc '
            set -euo pipefail
            cd /work
            git config --global --add safe.directory /work >/dev/null 2>&1 || true
            mix local.hex --force >/dev/null
            mix local.rebar --force >/dev/null
            mix deps.get >/dev/null
            mix test \
                test/pleroma/atproto \
                test/pleroma/nostr \
                test/pleroma/diaspora \
                test/pleroma/http/onion_test.exs \
                test/pleroma/workers/nostr_thread_repair_worker_test.exs \
                test/pleroma/workers/diaspora_delivery_worker_test.exs \
                test/mix/tasks/pleroma/nostr_test.exs
        '
}

run_frontend_contracts() {
    if [ "$SKIP_FE" = "1" ]; then
        log "skipping frontend protocol bridge contracts"
        return
    fi

    [ -n "$RESOLVED_FE_ROOT" ] ||
        fail "Could not find Unfathomably FE. Set FE_ROOT or PROTOCOL_BRIDGES_SKIP_FE=1."

    require_command corepack

    log "frontend account linking and protocol identity contracts"

    (
        cd "$RESOLVED_FE_ROOT"
        corepack yarn test:run \
            src/features/atproto-link/index.test.tsx \
            src/components/account.test.tsx \
            src/schemas/account.test.ts \
            src/utils/features.test.ts
    )
}

run_backend_contracts
run_frontend_contracts

cat <<'EOF'

protocol bridge smoke passed

Covered:
  * supported: selective AT Protocol reads, OAuth, DPoP, publishing, rich text, and bounded blobs
  * supported: Nostr identities, threads, media references, reactions, direct messages, profiles, and NIP-29 semantics
  * supported: Diaspora identity resolution, signed envelope parsing, encryption, and delivery jobs
  * supported: Tor v3 validation and isolated fail-closed onion routing
  * supported: frontend Bluesky linking and multi-protocol profile identity presentation
EOF

# end of unfathomably-protocol-bridges-smoke.sh
