#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-snac-smoke.sh
#
# Purpose:
#
#   Run a stock snac peer through the established account-federation smoke
#   harness. snac provides the Mastodon-compatible operations used by the
#   harness, while this adapter handles its interactive data initialization.
#
# Responsibilities:
#
#   * build the upstream snac container image when it is not cached
#   * initialize an isolated HTTP test server and local account
#   * obtain a native snac API token
#   * reuse the proven bidirectional follow, post, reply, reaction, delete,
#     unfollow, and Group actor checks
#
# This file intentionally does NOT contain:
#
#   * a copied account-federation assertion matrix
#   * production snac configuration or TLS termination
#   * changes to the upstream snac source
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAMILY_HARNESS="$SCRIPT_DIR/unfathomably-gotosocial-smoke.sh"

if [ ! -f "$FAMILY_HARNESS" ]; then
    printf 'Required account-federation harness not found: %s\n' "$FAMILY_HARNESS" >&2
    exit 1
fi

export SMOKE_PREFIX="${SMOKE_PREFIX:-unfathomably-snac-smoke}"
export BE_HOST="${BE_HOST:-unfathomably-snac.test}"
export BE_PORT="${BE_PORT:-5005}"
export BE_DB_NAME="${BE_DB_NAME:-unfathomably_snac_smoke_be}"
export GTS_HOST="${GTS_HOST:-snac-ref.test}"
export GTS_PORT="${GTS_PORT:-5006}"
export GTS_APP_PORT="${GTS_APP_PORT:-8001}"
export GTS_LABEL="${GTS_LABEL:-snac}"
export GTS_USERNAME="${GTS_USERNAME:-snac}"
export GTS_GROUP_NAME="${GTS_GROUP_NAME:-unfathomably_snac_smoke}"
export GTS_IMAGE="${SNAC_IMAGE:-unfathomably-snac-smoke:upstream}"

# shellcheck source=unfathomably-gotosocial-smoke.sh
source "$FAMILY_HARNESS"

require_command md5sum

SNAC_GIT_URL="${SNAC_GIT_URL:-https://codeberg.org/grunfink/snac2.git}"
SNAC_GIT_REF="${SNAC_GIT_REF:-master}"
SNAC_PASSWORD=""

ensure_snac_image() {
    if docker image inspect "$GTS_IMAGE" >/dev/null 2>&1; then
        return 0
    fi

    log "Building stock snac image from $SNAC_GIT_URL#$SNAC_GIT_REF"
    docker build -t "$GTS_IMAGE" "$SNAC_GIT_URL#$SNAC_GIT_REF"
}

start_gotosocial() {
    ensure_snac_image
    docker volume create "$GTS_VOLUME" >/dev/null

    printf '0.0.0.0\n%s\n%s\n\n\n' "$GTS_APP_PORT" "$GTS_HOST" | docker run --rm -i \
        --entrypoint snac \
        -v "$GTS_VOLUME:/data" \
        "$GTS_IMAGE" init /data/data >/dev/null

    docker run --rm \
        -v "$GTS_VOLUME:/data" \
        "$POSTGRES_IMAGE" \
        sh -c "sed -i 's/\"protocol\": *\"https\"/\"protocol\": \"http\"/' /data/data/server.json" \
        >/dev/null

    docker run -d \
        --name "$GTS_CONTAINER" \
        --hostname "$GTS_APP_HOST" \
        --network "$NETWORK" \
        --network-alias "$GTS_APP_HOST" \
        -v "$GTS_VOLUME:/data" \
        "$GTS_IMAGE" >/dev/null
}

create_gts_user() {
    local username="$1"
    local output

    output="$(docker exec "$GTS_CONTAINER" snac adduser /data/data "$username")"
    SNAC_PASSWORD="$(printf '%s\n' "$output" | sed -n 's/^User password is //p' | tail -1)"

    if [ -z "$SNAC_PASSWORD" ]; then
        printf '%s\n' "$output" >&2
        fail "snac did not report the generated test-account password"
    fi
}

create_gts_token() {
    local username="$1"

    if [ -z "$SNAC_PASSWORD" ]; then
        fail "snac test-account password is unavailable"
    fi

    http_form POST "$GTS_BASE/oauth/x-snac-get-token" "" 200 \
        "login=$username" \
        "passwd=$SNAC_PASSWORD"
}

resolve_gts_be_account_id() {
    local acct="$1"
    local actor_url

    actor_url="http://$BE_HOST/users/${acct%%@*}"
    docker exec "$GTS_CONTAINER" snac follow /data/data "$GTS_USERNAME" "$actor_url" >/dev/null
    printf '%s' "$actor_url" | md5sum | cut -d ' ' -f 1
}

resolve_gts_be_status_id() {
    local token="$1"
    local uri="$2"
    local message="$3"
    local result status_id

    for _ in $(seq 1 90); do
        result="$(http_form GET "$GTS_BASE/api/v1/timelines/home?limit=40" "$token" 200 || true)"
        status_id="$(JSON_INPUT="$result" EXPECTED_URI="$uri" python3 - <<'PY'
import json
import os

try:
    statuses = json.loads(os.environ["JSON_INPUT"])
except (json.JSONDecodeError, KeyError):
    statuses = []

expected = os.environ["EXPECTED_URI"]

for status in statuses:
    if status.get("uri") == expected or status.get("url") == expected:
        print(status.get("id", ""))
        break
PY
)"

        if [ -n "$status_id" ]; then
            printf '%s\n' "$status_id"
            return 0
        fi

        sleep 2
    done

    fail "$message"
}

run_account_peer_smoke

# end of build_scripts/unfathomably-snac-smoke.sh
