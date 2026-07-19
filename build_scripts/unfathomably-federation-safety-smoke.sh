#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-federation-safety-smoke.sh
#
# Purpose:
#
#   Run the shared federation-safety contract before the expensive per-platform
#   local peer matrix.
#
# Responsibilities:
#
#   * prove local defederation policy is visible through the API
#   * prove account and source follows stop with a clear policy reason
#   * prove local group bans expose blocked relationship state
#   * prove the frontend renders disabled blocked/federation controls
#
# This file intentionally does NOT contain:
#
#   * Docker peer setup
#   * production deployment logic
#   * broad backend or frontend unit-test coverage
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BE_ROOT="${BE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BE_IMAGE="${FEDERATION_SAFETY_BE_IMAGE:-}"

if [ -n "${FE_ROOT:-}" ]; then
    RESOLVED_FE_ROOT="$FE_ROOT"
elif [ -d "$BE_ROOT/../unfathomably-fe" ]; then
    RESOLVED_FE_ROOT="$(cd "$BE_ROOT/../unfathomably-fe" && pwd)"
elif [ -d "$BE_ROOT/../../unfathomably-fe" ]; then
    RESOLVED_FE_ROOT="$(cd "$BE_ROOT/../../unfathomably-fe" && pwd)"
else
    RESOLVED_FE_ROOT=""
fi

SKIP_FE="${FEDERATION_SAFETY_SKIP_FE:-0}"

log() {
    printf '\n==> %s\n' "$*"
}

run_backend_contract() {
    log "backend federation safety contract"

    if [ -n "$BE_IMAGE" ]; then
        if ! command -v docker >/dev/null 2>&1; then
            printf 'Docker is required for FEDERATION_SAFETY_BE_IMAGE=%s.\n' "$BE_IMAGE" >&2
            exit 1
        fi

        if ! docker image inspect "$BE_IMAGE" >/dev/null 2>&1; then
            printf 'Federation safety backend image is unavailable: %s\n' "$BE_IMAGE" >&2
            exit 1
        fi

        docker run --rm \
            --network host \
            --user "$(id -u):$(id -g)" \
            -e HOME=/tmp \
            -e MIX_ENV=test \
            -e MIX_BUILD_PATH=/tmp/unfathomably-federation-safety-build \
            -e MIX_DEPS_PATH=/tmp/unfathomably-federation-safety-deps \
            -e MIX_HOME=/tmp/mix \
            -e HEX_HOME=/tmp/hex \
            -v "$BE_ROOT:/work" \
            "$BE_IMAGE" \
            bash -lc '
                set -euo pipefail
                cd /work

                #
                # Peer adapters may compile the mounted checkout as root.  A
                # Private build and dependency paths prevent this non-root
                # safety lane from sharing or attempting to clean those
                # mutable artifacts.  Some Erlang dependencies also write
                # generated files inside their own source directory.
                #
                git config --global --add safe.directory /work >/dev/null 2>&1 || true
                mix local.hex --force >/dev/null
                mix local.rebar --force >/dev/null
                mix deps.get >/dev/null
                mix test \
                    test/pleroma/federation_status_test.exs \
                    test/pleroma/web/mastodon_api/controllers/federation_status_controller_test.exs \
                    test/pleroma/web/mastodon_api/controllers/account_controller_test.exs \
                    test/pleroma/web/mastodon_api/controllers/source_controller_test.exs \
                    test/pleroma/web/mastodon_api/controllers/federated_group_controller_test.exs \
                    test/pleroma/web/mastodon_api/controllers/federated_target_controller_test.exs \
                    test/pleroma/web/mastodon_api/views/account_view_test.exs
            '
        return
    fi

    (
        cd "$BE_ROOT"
        MIX_ENV=test mix test \
            test/pleroma/federation_status_test.exs \
            test/pleroma/web/mastodon_api/controllers/federation_status_controller_test.exs \
            test/pleroma/web/mastodon_api/controllers/account_controller_test.exs \
            test/pleroma/web/mastodon_api/controllers/source_controller_test.exs \
            test/pleroma/web/mastodon_api/controllers/federated_group_controller_test.exs \
            test/pleroma/web/mastodon_api/controllers/federated_target_controller_test.exs \
            test/pleroma/web/mastodon_api/views/account_view_test.exs
    )
}

run_frontend_contract() {
    if [ "$SKIP_FE" = "1" ]; then
        log "skipping frontend federation safety contract"
        return
    fi

    if [ -z "$RESOLVED_FE_ROOT" ]; then
        printf 'Could not find the Unfathomably frontend checkout. Set FE_ROOT or FEDERATION_SAFETY_SKIP_FE=1.\n' >&2
        exit 1
    fi

    log "frontend federation safety contract"

    (
        cd "$RESOLVED_FE_ROOT"
        corepack yarn test:run \
            src/features/group/components/group-action-button.test.tsx \
            src/features/sources/index.test.tsx
    )
}

run_backend_contract
run_frontend_contract

cat <<'EOF'

federation safety smoke passed

Covered:
  * supported: known local defederation policy is visible through the federation status API
  * supported: blocked account and source follows return a concrete federation-policy reason
  * supported: local group bans expose blocked_by, can_follow, can_post, and a moderation message
  * supported: local group bans federate an ActivityPub Block to the affected remote actor
  * supported: frontend group and feed controls render blocked and defederated relationships as disabled with an explanation
EOF

# end of build_scripts/unfathomably-federation-safety-smoke.sh
