#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-owncast-smoke.sh
#
# Purpose:
#
#   Run a stock Owncast server against Unfathomably using the same isolated
#   backend and proxy layout as the account-federation smoke tests.
#
# Responsibilities:
#
#   * configure Owncast federation through its documented admin API
#   * prove follow, post, like, reply, unfollow, and follower-block behavior
#   * record unsupported account-server operations without hiding them
#   * check both services for crash-class log failures
#
# This file intentionally does NOT contain:
#
#   * a patched Owncast build
#   * claims that Owncast is a general Mastodon-compatible account server
#   * production Owncast configuration
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAMILY_HARNESS="$SCRIPT_DIR/unfathomably-gotosocial-smoke.sh"

if [ ! -f "$FAMILY_HARNESS" ]; then
    printf 'Required account-federation harness not found: %s\n' "$FAMILY_HARNESS" >&2
    exit 1
fi

export SMOKE_PREFIX="${SMOKE_PREFIX:-unfathomably-owncast-smoke}"
export BE_HOST="${BE_HOST:-unfathomably-owncast.test}"
export BE_PORT="${BE_PORT:-5007}"
export BE_DB_NAME="${BE_DB_NAME:-unfathomably_owncast_smoke_be}"
export GTS_HOST="${GTS_HOST:-owncast-ref.test}"
export GTS_PORT="${GTS_PORT:-5008}"
export GTS_APP_PORT="${GTS_APP_PORT:-8080}"
export GTS_LABEL=Owncast
export GTS_USERNAME="${OWNCAST_FEDERATION_USERNAME:-streamer}"
export GTS_IMAGE="${OWNCAST_IMAGE:-owncast/owncast:latest}"
export SMOKE_TLS=1
export BE_FEDERATION_SCHEME=https
export BE_FEDERATION_PORT=443

# shellcheck source=unfathomably-gotosocial-smoke.sh
source "$FAMILY_HARNESS"

OWNCAST_ADMIN_USER="${OWNCAST_ADMIN_USER:-admin}"
OWNCAST_ADMIN_PASSWORD="${OWNCAST_ADMIN_PASSWORD:-abc123}"
OWNCAST_ACTOR="https://$GTS_HOST/federation/user/$GTS_USERNAME"

owncast_request() {
    local method="$1"
    local path="$2"
    local expected="$3"
    local payload="${4:-}"
    local args=(-sS -X "$method" -w '\n%{http_code}' -u "$OWNCAST_ADMIN_USER:$OWNCAST_ADMIN_PASSWORD")

    if [ -n "$payload" ]; then
        args+=(-H 'Content-Type: application/json' --data "$payload")
    fi

    local response status body
    response="$(curl "${args[@]}" "$GTS_BASE$path")" || return 1
    status="${response##*$'\n'}"
    body="${response%$'\n'*}"

    if [ "$status" != "$expected" ]; then
        printf 'Unexpected Owncast HTTP status for %s %s: expected %s got %s\n' \
            "$method" "$path" "$expected" "$status" >&2
        printf '%s\n' "$body" >&2
        return 1
    fi

    printf '%s\n' "$body"
}

owncast_config_value() {
    local path="$1"
    local value_json="$2"
    local result

    result="$(owncast_request POST "/api/admin/config/$path" 200 "{\"value\":$value_json}")"
    json_assert "$result" 'data.get("success") is True' "Owncast rejected configuration value $path"
}

wait_owncast() {
    for _ in $(seq 1 90); do
        if curl -fsS "$GTS_BASE/api/status" >/dev/null 2>&1; then
            return 0
        fi

        sleep 2
    done

    docker logs "$GTS_CONTAINER" >&2 || true
    fail "Timed out waiting for Owncast at $GTS_BASE"
}

start_owncast() {
    docker volume create "$GTS_VOLUME" >/dev/null
    docker run -d \
        --name "$GTS_CONTAINER" \
        --hostname "$GTS_APP_HOST" \
        --network "$NETWORK" \
        --network-alias "$GTS_APP_HOST" \
        -e OWNCAST_ALLOW_INTERNAL_FEDERATION=true \
        -e OWNCAST_INSECURE_SKIP_VERIFY=true \
        -v "$GTS_VOLUME:/app/data" \
        "$GTS_IMAGE" >/dev/null
}

configure_owncast() {
    owncast_config_value serverurl "\"https://$GTS_HOST\""
    owncast_config_value federation/username "\"$GTS_USERNAME\""
    owncast_config_value federation/enable true
    owncast_config_value federation/private false
    owncast_config_value federation/showengagement true
}

poll_owncast_follower() {
    local present="$1"
    local expression message

    if [ "$present" = "1" ]; then
        expression="any(item.get('link') == 'https://$BE_HOST/users/alice' for item in data.get('results', []))"
        message="Owncast did not register the Unfathomably follower"
    else
        expression="not any(item.get('link') == 'https://$BE_HOST/users/alice' for item in data.get('results', []))"
        message="Owncast retained the Unfathomably follower after unfollow"
    fi

    poll_json_assert \
        "owncast_request GET /api/admin/followers?limit=200 200" \
        "$expression" \
        "$message" >/dev/null
}

poll_owncast_activity() {
    local type="$1"
    local target="$2"
    local message="$3"
    local expression

    expression="any(item.get('type') == '$type' and item.get('actorIRI') == 'https://$BE_HOST/users/alice'"

    if [ -n "$target" ]; then
        expression+=" and item.get('iri') == '$target'"
    fi

    expression+=" for item in data.get('results', []))"

    poll_json_assert \
        "owncast_request GET /api/admin/federation/actions?page=0\&pageSize=200 200" \
        "$expression" \
        "$message" >/dev/null
}

poll_owncast_blocked() {
    poll_json_assert \
        "owncast_request GET /api/admin/followers/blocked 200" \
        "any(item.get('link') == 'https://$BE_HOST/users/alice' for item in data)" \
        "Owncast did not retain the blocked Unfathomably actor" >/dev/null
}

prepare_smoke_tls
write_be_secret
write_proxy_configs

log "Creating Docker network"
docker rm -f \
    "$GTS_PROXY_CONTAINER" \
    "$GTS_CONTAINER" \
    "$BE_PROXY_CONTAINER" \
    "$BE_CONTAINER" \
    "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
docker network rm "$NETWORK" >/dev/null 2>&1 || true
docker volume rm "$GTS_VOLUME" >/dev/null 2>&1 || true
docker network create "$NETWORK" >/dev/null

log "Starting database and stock Owncast"
docker run -d \
    --name "$BE_DB_CONTAINER" \
    --network "$NETWORK" \
    -e POSTGRES_PASSWORD="$BE_DB_PASSWORD" \
    "$POSTGRES_IMAGE" >/dev/null

wait_postgres
prepare_database
start_owncast
start_gts_proxy
wait_owncast
configure_owncast

log "Migrating and starting Unfathomably"
migrate_and_create_be_user alice "alice@$BE_HOST"
start_be
start_be_proxy
wait_be

log "Following Owncast from Unfathomably"
ALICE_TOKEN="$(create_be_token alice)"
OWNCAST_ACCOUNT_ID="$(resolve_account_id "$BE_BASE" "$ALICE_TOKEN" "$OWNCAST_ACTOR" "Unfathomably could not resolve the Owncast actor")"
BE_FOLLOW="$(http_form POST "$BE_BASE/api/v1/accounts/$OWNCAST_ACCOUNT_ID/follow" "$ALICE_TOKEN" 200)"
json_assert "$BE_FOLLOW" 'data.get("following") is True or data.get("requested") is True' "Unfathomably could not follow Owncast"
poll_owncast_follower 1

log "Testing Owncast post delivery and Unfathomably engagement"
OWNCAST_TEXT="Owncast to Unfathomably smoke $(basename "$WORK_DIR")"
OWNCAST_SEND="$(owncast_request POST /api/admin/federation/send 200 "{\"value\":\"$OWNCAST_TEXT\"}")"
json_assert "$OWNCAST_SEND" 'data.get("success") is True' "Owncast could not send a federated post"
BE_VIEW_ID="$(poll_home_status_by_text "$BE_BASE" "$ALICE_TOKEN" "$OWNCAST_TEXT" "Unfathomably did not receive the Owncast post")"
BE_VIEW="$(http_form GET "$BE_BASE/api/v1/statuses/$BE_VIEW_ID" "$ALICE_TOKEN" 200)"
OWNCAST_POST_URI="$(json_get "$BE_VIEW" uri)"

BE_LIKE="$(http_form POST "$BE_BASE/api/v1/statuses/$BE_VIEW_ID/favourite" "$ALICE_TOKEN" 200)"
json_assert "$BE_LIKE" 'data.get("favourited") is True' "Unfathomably could not like the Owncast post"
poll_owncast_activity FEDIVERSE_ENGAGEMENT_LIKE "$OWNCAST_POST_URI" "Owncast did not record the Unfathomably Like"

BE_UNLIKE="$(http_form POST "$BE_BASE/api/v1/statuses/$BE_VIEW_ID/unfavourite" "$ALICE_TOKEN" 200)"
json_assert "$BE_UNLIKE" 'data.get("favourited") is False' "Unfathomably could not undo its Owncast Like"

BE_REPLY_TEXT="Unfathomably reply to Owncast $(basename "$WORK_DIR")"
BE_REPLY="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
    "status=$BE_REPLY_TEXT" \
    "in_reply_to_id=$BE_VIEW_ID")"
BE_REPLY_ID="$(json_get "$BE_REPLY" id)"

# Owncast 0.2.5 acknowledges inbound Create requests but does not retain them
# in the administrator federation-action log. Creating and deleting the reply
# here still checks Unfathomably's outgoing path without treating HTTP 200 as
# proof that Owncast stored the comment.
http_form DELETE "$BE_BASE/api/v1/statuses/$BE_REPLY_ID" "$ALICE_TOKEN" 200 >/dev/null

log "Testing unfollow and Owncast follower blocking"
http_form POST "$BE_BASE/api/v1/accounts/$OWNCAST_ACCOUNT_ID/unfollow" "$ALICE_TOKEN" 200 >/dev/null
poll_owncast_follower 0

http_form POST "$BE_BASE/api/v1/accounts/$OWNCAST_ACCOUNT_ID/follow" "$ALICE_TOKEN" 200 >/dev/null
poll_owncast_follower 1
BLOCK_RESULT="$(owncast_request POST /api/admin/followers/approve 200 \
    "{\"actorIRI\":\"https://$BE_HOST/users/alice\",\"approved\":false}")"
json_assert "$BLOCK_RESULT" 'data.get("success") is True' "Owncast could not block the Unfathomably follower"
poll_owncast_blocked

log "Testing Unfathomably local block state for Owncast"
BE_BLOCK="$(http_form POST "$BE_BASE/api/v1/accounts/$OWNCAST_ACCOUNT_ID/block" "$ALICE_TOKEN" 200)"
json_assert "$BE_BLOCK" 'data.get("blocking") is True' "Unfathomably did not retain the Owncast block"
http_form POST "$BE_BASE/api/v1/accounts/$OWNCAST_ACCOUNT_ID/unblock" "$ALICE_TOKEN" 200 >/dev/null

check_logs "$BE_CONTAINER" "Unfathomably"
check_logs "$GTS_CONTAINER" "Owncast"

cat <<EOF

Owncast federation smoke passed.

Covered against stock Owncast:
* supported: Unfathomably follows and unfollows the Owncast Service actor
* supported: Owncast publishes a post to its Unfathomably follower
* supported: Unfathomably sends a Like and Owncast records it
* supported: Unfathomably sends Undo Like and clears its local relationship
* supported: Owncast locally blocks an Unfathomably follower
* supported: Unfathomably locally blocks and unblocks Owncast
* not_supported: Owncast ignores Undo Like when recording inbound engagement
* not_supported: Owncast has no federated delete operation for manual posts
* not_supported: Owncast 0.2.5 does not retain inbound Create or Delete replies
* not_supported: Owncast only follows other Owncast featured-stream servers
* not_supported: Owncast does not send an ActivityPub Block to notify a blocked follower
* not_supported: Owncast does not implement Group actor membership
* not_supported: Owncast cannot report that a remote server defederated it
EOF

# end of build_scripts/unfathomably-owncast-smoke.sh
