#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-wafrn-smoke.sh
#
# Purpose:
#
#   Run the stock wafrn backend against Unfathomably and exercise wafrn's
#   native API, database state, and ActivityPub worker queues.
#
# Responsibilities:
#
#   * migrate and boot a disposable wafrn, PostgreSQL, and Redis stack
#   * test bidirectional follows, including a remote Group actor
#   * test posts, replies, Likes, Undo Likes, and Deletes in both directions
#   * test inbound ActivityPub Block plus local user and server blocking
#   * distinguish Person-only wafrn behavior from native Group behavior
#
# This file intentionally does NOT contain:
#
#   * a patched wafrn image or frontend build
#   * production wafrn settings
#   * claims that wafrn can detect another server's private block list
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAMILY_HARNESS="$SCRIPT_DIR/unfathomably-gotosocial-smoke.sh"

if [ ! -f "$FAMILY_HARNESS" ]; then
    printf 'Required account-federation harness not found: %s\n' "$FAMILY_HARNESS" >&2
    exit 1
fi

export SMOKE_PREFIX="${SMOKE_PREFIX:-unfathomably-wafrn-smoke}"
export BE_HOST="${BE_HOST:-unfathomably-wafrn.test}"
export BE_PORT="${BE_PORT:-5017}"
export BE_DB_NAME="${BE_DB_NAME:-unfathomably_wafrn_smoke_be}"
export GTS_HOST="${GTS_HOST:-wafrn-ref.test}"
export GTS_PORT="${GTS_PORT:-5018}"
export GTS_APP_PORT=9000
export GTS_LABEL=wafrn
export GTS_USERNAME="${WAFRN_ADMIN_USER:-admin}"
export GTS_IMAGE="${WAFRN_IMAGE:-codeberg.org/wafrn/wafrn-backend:main}"
export SMOKE_TLS=1
export BE_FEDERATION_SCHEME=https
export BE_FEDERATION_PORT=443

# shellcheck source=unfathomably-gotosocial-smoke.sh
source "$FAMILY_HARNESS"

WAFRN_DB_CONTAINER="${PREFIX}-wafrn-db"
WAFRN_REDIS_CONTAINER="${PREFIX}-wafrn-redis"
WAFRN_DB_USER=wafrn
WAFRN_DB_PASSWORD=wafrn-smoke-password
WAFRN_DB_NAME=wafrn
WAFRN_POSTGRES_IMAGE="${WAFRN_POSTGRES_IMAGE:-postgres:15-alpine}"
WAFRN_REDIS_IMAGE="${WAFRN_REDIS_IMAGE:-redis:8-alpine}"
WAFRN_ADMIN_EMAIL="${WAFRN_ADMIN_EMAIL:-admin@wafrn-smoke.test}"
WAFRN_ACTOR="https://$GTS_HOST/fediverse/blog/$GTS_USERNAME"
WAFRN_VAPID_PUBLIC="${WAFRN_VAPID_PUBLIC:-BBaZj3xMrE5gGq3UkkWRMkWRUTKziZF8uQzwfTNkFq35snJSGrKTHZIqa_XcA8ZKd5DaWZnxFV6y4af61-jUpSA}"
WAFRN_VAPID_PRIVATE="${WAFRN_VAPID_PRIVATE:-X93TfauqAa5crDy66cesHMnwqwjtAAvikMnY2t-DpOM}"
WAFRN_MIGRATION_LOG="$WORK_DIR/wafrn-migration.log"

WAFRN_ENV_ARGS=(
    -e "POSTGRES_HOST=$WAFRN_DB_CONTAINER"
    -e POSTGRES_PORT=5432
    -e "POSTGRES_USER=$WAFRN_DB_USER"
    -e "POSTGRES_PASSWORD=$WAFRN_DB_PASSWORD"
    -e "POSTGRES_DBNAME=$WAFRN_DB_NAME"
    -e "REDIS_HOST=$WAFRN_REDIS_CONTAINER"
    -e REDIS_PORT=6379
    -e "ADMIN_USER=$GTS_USERNAME"
    -e "ADMIN_EMAIL=$WAFRN_ADMIN_EMAIL"
    -e "ADMIN_PASSWORD=$PASSWORD"
    -e JWT_SECRET=unfathomably-wafrn-smoke-jwt-secret
    -e "DOMAIN_NAME=$GTS_HOST"
    -e "FRONTEND_FQDN_URL=https://$GTS_HOST"
    -e "FRONTEND_MEDIA_URL=https://$GTS_HOST/uploads"
    -e "FRONTEND_CACHE_URL=https://$GTS_HOST/api/cache?media="
    -e REGISTRATION_LEVEL=PUBLIC
    -e REVIEW_REGISTRATIONS=false
    -e DISABLE_REQUIRE_SEND_EMAIL=true
    -e USE_WORKERS=true
    -e WEBPUSH_EMAIL=mailto:admin@wafrn-smoke.test
    -e "WEBPUSH_PUBLIC=$WAFRN_VAPID_PUBLIC"
    -e "WEBPUSH_PRIVATE=$WAFRN_VAPID_PRIVATE"
    -e NODE_EXTRA_CA_CERTS=/tls/ca.crt
)

cleanup() {
    local status="$?"

    if [ "$KEEP_CONTAINERS" = "1" ]; then
        printf '\nKEEP_CONTAINERS=1, leaving containers and work directory in place.\n' >&2
        exit "$status"
    fi

    docker rm -f \
        "$GTS_PROXY_CONTAINER" \
        "$GTS_CONTAINER" \
        "$WAFRN_REDIS_CONTAINER" \
        "$WAFRN_DB_CONTAINER" \
        "$BE_PROXY_CONTAINER" \
        "$BE_CONTAINER" \
        "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    docker volume rm "$GTS_VOLUME" >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR"
    exit "$status"
}

wafrn_request() {
    local method="$1"
    local path="$2"
    local token="$3"
    local expected="$4"
    local payload="${5:-}"
    local args=(-sS -X "$method" -w '\n%{http_code}' -H 'Accept: application/json')

    if [ -n "$token" ]; then
        args+=(-H "Authorization: Bearer $token")
    fi

    if [ -n "$payload" ]; then
        args+=(-H 'Content-Type: application/json' --data "$payload")
    fi

    local response status body
    response="$(curl "${args[@]}" "$GTS_BASE$path")" || return 1
    status="${response##*$'\n'}"
    body="${response%$'\n'*}"

    if [ "$status" != "$expected" ]; then
        printf 'Unexpected wafrn HTTP status for %s %s: expected %s got %s\n' \
            "$method" "$path" "$expected" "$status" >&2
        printf '%s\n' "$body" >&2
        return 1
    fi

    printf '%s\n' "$body"
}

wait_wafrn_database() {
    for _ in $(seq 1 90); do
        if docker exec "$WAFRN_DB_CONTAINER" \
            pg_isready -U "$WAFRN_DB_USER" -d "$WAFRN_DB_NAME" >/dev/null 2>&1; then
            return 0
        fi

        sleep 1
    done

    docker logs "$WAFRN_DB_CONTAINER" >&2 || true
    fail "Timed out waiting for the wafrn database"
}

wait_wafrn() {
    for _ in $(seq 1 120); do
        if curl -fsS "$GTS_BASE/.well-known/nodeinfo" >/dev/null 2>&1; then
            return 0
        fi

        sleep 2
    done

    docker logs "$GTS_CONTAINER" >&2 || true
    fail "Timed out waiting for wafrn at $GTS_BASE"
}

start_wafrn() {
    docker volume create "$GTS_VOLUME" >/dev/null

    docker run -d \
        --name "$WAFRN_DB_CONTAINER" \
        --network "$NETWORK" \
        -e "POSTGRES_USER=$WAFRN_DB_USER" \
        -e "POSTGRES_PASSWORD=$WAFRN_DB_PASSWORD" \
        -e "POSTGRES_DB=$WAFRN_DB_NAME" \
        "$WAFRN_POSTGRES_IMAGE" >/dev/null

    docker run -d \
        --name "$WAFRN_REDIS_CONTAINER" \
        --network "$NETWORK" \
        "$WAFRN_REDIS_IMAGE" >/dev/null

    wait_wafrn_database

    if ! docker run --rm \
        --network "$NETWORK" \
        "${WAFRN_ENV_ARGS[@]}" \
        -v "$SMOKE_CA_CERT:/tls/ca.crt:ro" \
        "$GTS_IMAGE" \
        npm exec tsx migrate.ts init-container >"$WAFRN_MIGRATION_LOG" 2>&1; then
        cat "$WAFRN_MIGRATION_LOG" >&2 || true
        fail "wafrn database migration failed"
    fi

    docker run -d \
        --name "$GTS_CONTAINER" \
        --hostname "$GTS_APP_HOST" \
        --network "$NETWORK" \
        --network-alias "$GTS_APP_HOST" \
        "${WAFRN_ENV_ARGS[@]}" \
        -v "$SMOKE_CA_CERT:/tls/ca.crt:ro" \
        -v "$GTS_VOLUME:/app/packages/backend/cache" \
        "$GTS_IMAGE" >/dev/null

    start_gts_proxy
    wait_wafrn
}

wafrn_database_scalar() {
    local sql="$1"

    docker exec "$WAFRN_DB_CONTAINER" \
        psql -U "$WAFRN_DB_USER" -d "$WAFRN_DB_NAME" -Atc "$sql"
}

poll_wafrn_database() {
    local sql="$1"
    local expected="$2"
    local message="$3"
    local value=""

    for _ in $(seq 1 90); do
        value="$(wafrn_database_scalar "$sql" 2>/dev/null || true)"

        if [ "$value" = "$expected" ]; then
            return 0
        fi

        sleep 2
    done

    fail "$message; last wafrn database value was ${value:-empty}"
}

wafrn_login() {
    local payload response

    payload="$(WAFRN_EMAIL="$WAFRN_ADMIN_EMAIL" WAFRN_PASSWORD="$PASSWORD" python3 - <<'PY'
import json
import os

print(json.dumps({
    "email": os.environ["WAFRN_EMAIL"],
    "password": os.environ["WAFRN_PASSWORD"],
}))
PY
)"
    response="$(wafrn_request POST /api/login "" 200 "$payload")"
    json_get "$response" token
}

wafrn_resolve_user() {
    local handle="$1"
    local message="$2"
    local response user_id

    response="$(wafrn_request GET "/api/userSearch/$(urlencode "$handle")" "$WAFRN_TOKEN" 200)"
    user_id="$(json_get_optional "$response" users.0.id)"

    if [ -z "$user_id" ]; then
        printf '%s\n' "$response" >&2
        fail "$message"
    fi

    printf '%s\n' "$user_id"
}

wafrn_create_post() {
    local content="$1"
    local parent_id="${2:-}"
    local payload

    payload="$(WAFRN_CONTENT="$content" WAFRN_PARENT="$parent_id" python3 - <<'PY'
import json
import os

payload = {
    "content": os.environ["WAFRN_CONTENT"],
    "content_warning": "",
    "privacy": 0,
    "medias": [],
    "mentionedUserIds": [],
    "tags": "",
    "canReply": 0,
    "canBeQuoted": 0,
    "canLike": 0,
    "language": "eng",
}

if os.environ.get("WAFRN_PARENT"):
    payload["parent"] = os.environ["WAFRN_PARENT"]

print(json.dumps(payload))
PY
)"
    wafrn_request POST /api/v3/createPost "$WAFRN_TOKEN" 200 "$payload"
}

poll_wafrn_remote_post_id() {
    local remote_uri="$1"
    local message="$2"
    local post_id=""

    for _ in $(seq 1 90); do
        post_id="$(wafrn_database_scalar \
            "select id from posts where \"remotePostId\" = '$remote_uri' and \"isDeleted\" = false limit 1" \
            2>/dev/null || true)"

        if [ -n "$post_id" ]; then
            printf '%s\n' "$post_id"
            return 0
        fi

        sleep 2
    done

    fail "$message"
}

poll_be_followed_by() {
    local expected="$1"
    local message="$2"

    poll_json_assert \
        "http_form GET '$BE_BASE/api/v1/accounts/relationships?id[]=$WAFRN_ACCOUNT_ID' '$ALICE_TOKEN' 200" \
        "len(data) == 1 and data[0].get('followed_by') is $expected" \
        "$message" >/dev/null
}

prepare_smoke_tls
write_be_secret
write_proxy_configs

log "Creating Docker network"
docker rm -f \
    "$GTS_PROXY_CONTAINER" \
    "$GTS_CONTAINER" \
    "$WAFRN_REDIS_CONTAINER" \
    "$WAFRN_DB_CONTAINER" \
    "$BE_PROXY_CONTAINER" \
    "$BE_CONTAINER" \
    "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
docker network rm "$NETWORK" >/dev/null 2>&1 || true
docker volume rm "$GTS_VOLUME" >/dev/null 2>&1 || true
docker network create "$NETWORK" >/dev/null

log "Starting databases and stock wafrn"
docker run -d \
    --name "$BE_DB_CONTAINER" \
    --network "$NETWORK" \
    -e POSTGRES_PASSWORD="$BE_DB_PASSWORD" \
    "$POSTGRES_IMAGE" >/dev/null

wait_postgres
prepare_database
start_wafrn
WAFRN_TOKEN="$(wafrn_login)"

log "Migrating and starting Unfathomably"
migrate_and_create_be_user alice "alice@$BE_HOST"
start_be
start_be_proxy
wait_be
ALICE_TOKEN="$(create_be_token alice)"

log "Creating the Unfathomably Group actor"
BE_GROUP="$(http_form POST "$BE_BASE/api/v1/groups" "$ALICE_TOKEN" 200 \
    'display_name=Unfathomably wafrn Smoke' \
    'name=unfathomably_wafrn_smoke' \
    'note=Open group used by the wafrn federation smoke.' \
    'locked=false')"
BE_GROUP_ACTOR="https://$BE_HOST/users/unfathomably_wafrn_smoke"
BE_ALICE_ACTOR="https://$BE_HOST/users/alice"

log "Following wafrn from Unfathomably"
WAFRN_ACCOUNT_ID="$(resolve_account_id "$BE_BASE" "$ALICE_TOKEN" "$WAFRN_ACTOR" \
    "Unfathomably could not resolve the wafrn actor")"
BE_FOLLOW="$(http_form POST "$BE_BASE/api/v1/accounts/$WAFRN_ACCOUNT_ID/follow" "$ALICE_TOKEN" 200)"
json_assert "$BE_FOLLOW" \
    'data.get("following") is True or data.get("requested") is True' \
    "Unfathomably could not follow wafrn"
poll_wafrn_database \
    "select count(*) from follows f join users u on u.id = f.\"followerId\" where u.\"remoteId\" = '$BE_ALICE_ACTOR' and f.accepted = true" \
    1 \
    "wafrn did not register the Unfathomably follower"

log "Following Unfathomably Person and Group actors from wafrn"
WAFRN_BE_USER_ID="$(wafrn_resolve_user "@alice@$BE_HOST" \
    "wafrn could not resolve the Unfathomably Person actor")"
wafrn_request POST /api/follow "$WAFRN_TOKEN" 200 \
    "{\"userId\":\"$WAFRN_BE_USER_ID\"}" >/dev/null
poll_be_followed_by True "Unfathomably did not register the wafrn follow"

WAFRN_BE_GROUP_ID="$(wafrn_resolve_user "@unfathomably_wafrn_smoke@$BE_HOST" \
    "wafrn could not resolve the Unfathomably Group actor")"
wafrn_request POST /api/follow "$WAFRN_TOKEN" 200 \
    "{\"userId\":\"$WAFRN_BE_GROUP_ID\"}" >/dev/null
poll_wafrn_database \
    "select count(*) from follows where \"followerId\" = (select id from users where url = '$GTS_USERNAME') and \"followedId\" = '$WAFRN_BE_GROUP_ID'" \
    1 \
    "wafrn did not retain its Group follow"

log "Testing wafrn post delivery and Unfathomably engagement"
WAFRN_POST_TEXT="wafrn to Unfathomably $(basename "$WORK_DIR")"
WAFRN_POST="$(wafrn_create_post "$WAFRN_POST_TEXT")"
WAFRN_POST_ID="$(json_get "$WAFRN_POST" id)"
BE_VIEW_ID="$(poll_home_status_by_text "$BE_BASE" "$ALICE_TOKEN" "$WAFRN_POST_TEXT" \
    "Unfathomably did not receive the wafrn post")"
BE_VIEW="$(http_form GET "$BE_BASE/api/v1/statuses/$BE_VIEW_ID" "$ALICE_TOKEN" 200)"
WAFRN_POST_URI="$(json_get "$BE_VIEW" uri)"

BE_LIKE="$(http_form POST "$BE_BASE/api/v1/statuses/$BE_VIEW_ID/favourite" "$ALICE_TOKEN" 200)"
json_assert "$BE_LIKE" 'data.get("favourited") is True' \
    "Unfathomably could not Like the wafrn post"
poll_wafrn_database \
    "select count(*) from \"userLikesPostRelations\" where \"postId\" = '$WAFRN_POST_ID'" \
    1 \
    "wafrn did not register the Unfathomably Like"

http_form POST "$BE_BASE/api/v1/statuses/$BE_VIEW_ID/unfavourite" "$ALICE_TOKEN" 200 >/dev/null
poll_wafrn_database \
    "select count(*) from \"userLikesPostRelations\" where \"postId\" = '$WAFRN_POST_ID'" \
    0 \
    "wafrn retained the Unfathomably Like after Undo"

BE_REPLY_TEXT="Unfathomably reply to wafrn $(basename "$WORK_DIR")"
BE_REPLY="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
    "status=$BE_REPLY_TEXT" \
    "in_reply_to_id=$BE_VIEW_ID")"
BE_REPLY_ID="$(json_get "$BE_REPLY" id)"
BE_REPLY_URI="$(json_get "$BE_REPLY" uri)"
WAFRN_BE_REPLY_ID="$(poll_wafrn_remote_post_id "$BE_REPLY_URI" \
    "wafrn did not store the Unfathomably reply")"
http_form DELETE "$BE_BASE/api/v1/statuses/$BE_REPLY_ID" "$ALICE_TOKEN" 200 >/dev/null
poll_wafrn_database \
    "select count(*) from posts where id = '$WAFRN_BE_REPLY_ID' and \"isDeleted\" = false" \
    0 \
    "wafrn retained the deleted Unfathomably reply"

log "Testing Unfathomably post delivery and wafrn engagement"
BE_POST_TEXT="Unfathomably to wafrn $(basename "$WORK_DIR")"
BE_POST="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 "status=$BE_POST_TEXT")"
BE_POST_ID="$(json_get "$BE_POST" id)"
BE_POST_URI="$(json_get "$BE_POST" uri)"
WAFRN_BE_POST_ID="$(poll_wafrn_remote_post_id "$BE_POST_URI" \
    "wafrn did not receive the Unfathomably post")"

wafrn_request POST /api/like "$WAFRN_TOKEN" 200 \
    "{\"postId\":\"$WAFRN_BE_POST_ID\"}" >/dev/null
poll_status_count "$BE_BASE" "$ALICE_TOKEN" "$BE_POST_ID" \
    'int(data.get("favourites_count") or 0) >= 1' \
    "Unfathomably did not receive the wafrn Like"
wafrn_request POST /api/unlike "$WAFRN_TOKEN" 200 \
    "{\"postId\":\"$WAFRN_BE_POST_ID\"}" >/dev/null
poll_status_count "$BE_BASE" "$ALICE_TOKEN" "$BE_POST_ID" \
    'int(data.get("favourites_count") or 0) == 0' \
    "Unfathomably did not receive the wafrn Undo Like"

WAFRN_REPLY_TEXT="wafrn reply to Unfathomably $(basename "$WORK_DIR")"
WAFRN_REPLY="$(wafrn_create_post "$WAFRN_REPLY_TEXT" "$WAFRN_BE_POST_ID")"
WAFRN_REPLY_ID="$(json_get "$WAFRN_REPLY" id)"
WAFRN_REPLY_URI="https://$GTS_HOST/fediverse/post/$WAFRN_REPLY_ID"
poll_context_status_by_text "$BE_BASE" "$ALICE_TOKEN" "$BE_POST_ID" \
    "$WAFRN_REPLY_TEXT" \
    "Unfathomably did not receive the wafrn reply"
BE_WAFRN_REPLY_ID="$(resolve_status_id "$BE_BASE" "$ALICE_TOKEN" "$WAFRN_REPLY_URI" \
    "Unfathomably could not resolve the wafrn reply")"
wafrn_request DELETE "/api/deletePost?id=$WAFRN_REPLY_ID" "$WAFRN_TOKEN" 200 >/dev/null
poll_status_missing "$BE_BASE" "$ALICE_TOKEN" "$BE_WAFRN_REPLY_ID" \
    "Unfathomably retained the deleted wafrn reply"

wafrn_request DELETE "/api/deletePost?id=$WAFRN_POST_ID" "$WAFRN_TOKEN" 200 >/dev/null
poll_status_missing "$BE_BASE" "$ALICE_TOKEN" "$BE_VIEW_ID" \
    "Unfathomably retained the deleted wafrn post"
http_form DELETE "$BE_BASE/api/v1/statuses/$BE_POST_ID" "$ALICE_TOKEN" 200 >/dev/null
poll_wafrn_database \
    "select count(*) from posts where id = '$WAFRN_BE_POST_ID' and \"isDeleted\" = false" \
    0 \
    "wafrn retained the deleted Unfathomably top-level post"

log "Testing unfollows, Blocks, and local server blocking"
wafrn_request POST /api/unfollow "$WAFRN_TOKEN" 200 \
    "{\"userId\":\"$WAFRN_BE_GROUP_ID\"}" >/dev/null
wafrn_request POST /api/unfollow "$WAFRN_TOKEN" 200 \
    "{\"userId\":\"$WAFRN_BE_USER_ID\"}" >/dev/null
poll_be_followed_by False "Unfathomably retained the wafrn follow after Undo Follow"

http_form POST "$BE_BASE/api/v1/accounts/$WAFRN_ACCOUNT_ID/unfollow" "$ALICE_TOKEN" 200 >/dev/null
poll_wafrn_database \
    "select count(*) from follows f join users u on u.id = f.\"followerId\" where u.\"remoteId\" = '$BE_ALICE_ACTOR'" \
    0 \
    "wafrn retained the Unfathomably follower after Undo Follow"

wafrn_request POST /api/block "$WAFRN_TOKEN" 200 \
    "{\"userId\":\"$WAFRN_BE_USER_ID\",\"reason\":\"federation smoke\"}" >/dev/null
poll_wafrn_database \
    "select count(*) from blocks where \"blockerId\" = (select id from users where url = '$GTS_USERNAME') and \"blockedId\" = '$WAFRN_BE_USER_ID'" \
    1 \
    "wafrn did not retain its local user block"
WAFRN_LOCAL_BLOCK_RELATIONSHIP="$(http_form GET "$BE_BASE/api/v1/accounts/relationships?id[]=$WAFRN_ACCOUNT_ID" "$ALICE_TOKEN" 200)"
json_assert "$WAFRN_LOCAL_BLOCK_RELATIONSHIP" \
    'len(data) == 1 and data[0].get("blocked_by") is False' \
    "Unfathomably incorrectly inferred a remote block from wafrn local state"
wafrn_request POST /api/unblock "$WAFRN_TOKEN" 200 \
    "{\"userId\":\"$WAFRN_BE_USER_ID\"}" >/dev/null
poll_wafrn_database \
    "select count(*) from blocks where \"blockerId\" = (select id from users where url = '$GTS_USERNAME') and \"blockedId\" = '$WAFRN_BE_USER_ID'" \
    0 \
    "wafrn retained its local user block after unblock"

BE_BLOCK="$(http_form POST "$BE_BASE/api/v1/accounts/$WAFRN_ACCOUNT_ID/block" "$ALICE_TOKEN" 200)"
json_assert "$BE_BLOCK" 'data.get("blocking") is True' \
    "Unfathomably did not retain its wafrn block"
poll_wafrn_database \
    "select count(*) from blocks where \"blockerId\" = '$WAFRN_BE_USER_ID' and \"blockedId\" = (select id from users where url = '$GTS_USERNAME')" \
    1 \
    "wafrn did not register the Unfathomably Block"
http_form POST "$BE_BASE/api/v1/accounts/$WAFRN_ACCOUNT_ID/unblock" "$ALICE_TOKEN" 200 >/dev/null
poll_wafrn_database \
    "select count(*) from blocks where \"blockerId\" = '$WAFRN_BE_USER_ID' and \"blockedId\" = (select id from users where url = '$GTS_USERNAME')" \
    0 \
    "wafrn retained the Unfathomably Block after Undo"

wafrn_request POST /api/blockUserServer "$WAFRN_TOKEN" 200 \
    "{\"userId\":\"$WAFRN_BE_USER_ID\"}" >/dev/null
poll_wafrn_database \
    "select count(*) from \"serverBlocks\" where \"userBlockerId\" = (select id from users where url = '$GTS_USERNAME')" \
    1 \
    "wafrn did not retain its local server block"
wafrn_request POST /api/unblockUserServer "$WAFRN_TOKEN" 200 \
    "{\"userId\":\"$WAFRN_BE_USER_ID\"}" >/dev/null

check_logs "$BE_CONTAINER" "Unfathomably"
check_logs "$GTS_CONTAINER" "wafrn"

cat <<EOF

wafrn federation smoke passed.

Covered against stock wafrn:
* supported: bidirectional Person follows and unfollows
* supported: wafrn follows and unfollows an Unfathomably Group actor
* supported: posts, replies, Likes, and Undo Likes in both directions
* supported: wafrn post and reply Deletes reach Unfathomably
* supported: Unfathomably post and reply Deletes reach wafrn
* supported: Unfathomably ActivityPub Block and Undo Block reach wafrn
* supported: wafrn retains and clears an explicit local user block
* supported: wafrn retains and clears an explicit local server block
* not_supported: wafrn publishes Person actors, not a native Group actor
* not_supported: wafrn local user blocks are not sent as ActivityPub Block activities
* not_supported: wafrn cannot report that a remote domain has privately defederated it
EOF

# end of build_scripts/unfathomably-wafrn-smoke.sh
