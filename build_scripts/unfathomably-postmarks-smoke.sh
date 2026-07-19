#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-postmarks-smoke.sh
#
# Purpose:
#
#   Run a stock Postmarks link blog against Unfathomably over the HTTPS
#   federation layout shared by the account-federation smoke tests.
#
# Responsibilities:
#
#   * build and configure an isolated upstream Postmarks instance
#   * test bidirectional follows, Group follows, posts, comments, and deletes
#   * test local blocking on both peers
#   * distinguish Postmarks limitations from Unfathomably failures
#
# This file intentionally does NOT contain:
#
#   * patched Postmarks source
#   * production Postmarks configuration
#   * claims that Postmarks implements reactions or federated Block
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAMILY_HARNESS="$SCRIPT_DIR/unfathomably-gotosocial-smoke.sh"

if [ ! -f "$FAMILY_HARNESS" ]; then
    printf 'Required account-federation harness not found: %s\n' "$FAMILY_HARNESS" >&2
    exit 1
fi

export SMOKE_PREFIX="${SMOKE_PREFIX:-unfathomably-postmarks-smoke}"
export BE_HOST="${BE_HOST:-unfathomably-postmarks.test}"
export BE_PORT="${BE_PORT:-5013}"
export BE_DB_NAME="${BE_DB_NAME:-unfathomably_postmarks_smoke_be}"
export GTS_HOST="${GTS_HOST:-postmarks-ref.test}"
export GTS_PORT="${GTS_PORT:-5014}"
export GTS_APP_PORT="${GTS_APP_PORT:-3000}"
export GTS_LABEL=Postmarks
export GTS_USERNAME="${POSTMARKS_USERNAME:-bookmarks}"
export GTS_IMAGE="${POSTMARKS_IMAGE:-unfathomably-postmarks-smoke:node20}"
export SMOKE_TLS=1
export BE_FEDERATION_SCHEME=https
export BE_FEDERATION_PORT=443
export GTS_FORWARDED_PROTO=https

# shellcheck source=unfathomably-gotosocial-smoke.sh
source "$FAMILY_HARNESS"

POSTMARKS_GIT_URL="${POSTMARKS_GIT_URL:-https://github.com/ckolderup/postmarks.git}"
POSTMARKS_GIT_REF="${POSTMARKS_GIT_REF:-main}"
POSTMARKS_ADMIN_KEY="${POSTMARKS_ADMIN_KEY:-postmarks-smoke-admin}"
POSTMARKS_COOKIE_JAR="$WORK_DIR/postmarks.cookies"
POSTMARKS_ACCOUNT_FILE="$WORK_DIR/postmarks/account.json"
POSTMARKS_ACTOR="https://$GTS_HOST/u/$GTS_USERNAME"

ensure_postmarks_image() {
    if docker image inspect "$GTS_IMAGE" >/dev/null 2>&1; then
        return 0
    fi

    log "Building stock Postmarks image from $POSTMARKS_GIT_URL#$POSTMARKS_GIT_REF"

    # The upstream Dockerfile tracks node:alpine.  Node 26 is not compatible
    # with the connect-sqlite3 version in Postmarks and fails before the HTTP
    # server starts.  Pin the runtime while building the unmodified upstream
    # source and its committed dependency lock.
    docker build -t "$GTS_IMAGE" -f- "$POSTMARKS_GIT_URL#$POSTMARKS_GIT_REF" <<'DOCKERFILE'
FROM node:20-alpine

WORKDIR /app
COPY package.json package-lock.json /app/
RUN npm ci

COPY public /app/public
COPY server.js /app/server.js
COPY src /app/src

EXPOSE 3000
ENTRYPOINT ["npm", "run", "start"]
DOCKERFILE
}

write_postmarks_account() {
    mkdir -p "$(dirname "$POSTMARKS_ACCOUNT_FILE")"

    cat >"$POSTMARKS_ACCOUNT_FILE" <<EOF
{
  "username": "$GTS_USERNAME",
  "avatar": "https://$GTS_HOST/postmarks-logo-white-small.png",
  "displayName": "Unfathomably Postmarks Smoke",
  "description": "Disposable Postmarks federation compatibility peer"
}
EOF
}

start_postmarks() {
    ensure_postmarks_image
    docker volume create "$GTS_VOLUME" >/dev/null

    # The stock trust-proxy list excludes Docker's default 172/16 bridge, so
    # its production redirect cannot observe TLS termination at the test
    # proxy.  Actor URLs still use the configured HTTPS public host.
    docker run -d \
        --name "$GTS_CONTAINER" \
        --hostname "$GTS_APP_HOST" \
        --network "$NETWORK" \
        --network-alias "$GTS_APP_HOST" \
        -e ADMIN_KEY="$POSTMARKS_ADMIN_KEY" \
        -e DATA_DIR=/app/.data \
        -e ENVIRONMENT=development \
        -e HOST=0.0.0.0 \
        -e NODE_EXTRA_CA_CERTS=/tls/ca.crt \
        -e PORT="$GTS_APP_PORT" \
        -e PUBLIC_BASE_URL="$GTS_HOST" \
        -e SESSION_SECRET=unfathomably-postmarks-smoke-session-secret \
        -v "$GTS_VOLUME:/app/.data" \
        -v "$POSTMARKS_ACCOUNT_FILE:/app/account.json:ro" \
        -v "$SMOKE_CA_CERT:/tls/ca.crt:ro" \
        "$GTS_IMAGE" >/dev/null
}

wait_postmarks() {
    for _ in $(seq 1 90); do
        if curl -fsS \
            -H 'Accept: application/activity+json' \
            "$GTS_BASE/u/$GTS_USERNAME" >/dev/null 2>&1; then
            return 0
        fi

        sleep 2
    done

    docker logs "$GTS_CONTAINER" >&2 || true
    fail "Timed out waiting for Postmarks at $GTS_BASE"
}

postmarks_form() {
    local method="$1"
    local path="$2"
    local expected="$3"
    shift 3

    local args=(-sS -X "$method" -w '\n%{http_code}' -b "$POSTMARKS_COOKIE_JAR")
    local field response status body

    for field in "$@"; do
        args+=(--data-urlencode "$field")
    done

    response="$(curl "${args[@]}" "$GTS_BASE$path")" || return 1
    status="${response##*$'\n'}"
    body="${response%$'\n'*}"

    if [ "$status" != "$expected" ]; then
        printf 'Unexpected Postmarks HTTP status for %s %s: expected %s got %s\n' \
            "$method" "$path" "$expected" "$status" >&2
        printf '%s\n' "$body" >&2
        return 1
    fi

    printf '%s\n' "$body"
}

login_postmarks() {
    local response status

    response="$(curl -sS -X POST -c "$POSTMARKS_COOKIE_JAR" \
        --data-urlencode "password=$POSTMARKS_ADMIN_KEY" \
        --data-urlencode 'sendTo=/admin' \
        -w '\n%{http_code}' "$GTS_BASE/login")"
    status="${response##*$'\n'}"

    if [ "$status" != "302" ]; then
        printf '%s\n' "${response%$'\n'*}" >&2
        fail "Postmarks administrator login failed with HTTP $status"
    fi
}

postmarks_database_scalar() {
    local database="$1"
    local sql="$2"
    local snapshot="$WORK_DIR/postmarks-${database}.sqlite"

    curl -fsS -b "$POSTMARKS_COOKIE_JAR" \
        "$GTS_BASE/admin/$database.db" \
        -o "$snapshot"

    python3 - "$snapshot" "$sql" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
row = connection.execute(sys.argv[2]).fetchone()
connection.close()

if row is not None and row[0] is not None:
    print(row[0])
PY
}

postmarks_account_array_contains() {
    local column="$1"
    local actor="$2"
    local present="$3"
    local message="$4"
    local value=""

    for _ in $(seq 1 90); do
        value="$(postmarks_database_scalar activitypub "select $column from accounts limit 1" || true)"

        if POSTMARKS_VALUE="$value" POSTMARKS_ACTOR="$actor" POSTMARKS_PRESENT="$present" python3 - <<'PY'
import json
import os

try:
    values = json.loads(os.environ.get("POSTMARKS_VALUE") or "[]")
except json.JSONDecodeError:
    values = []

found = os.environ["POSTMARKS_ACTOR"] in values
expected = os.environ["POSTMARKS_PRESENT"] == "1"
raise SystemExit(0 if found == expected else 1)
PY
        then
            return 0
        fi

        sleep 2
    done

    printf 'Last Postmarks %s value: %s\n' "$column" "$value" >&2
    fail "$message"
}

reset_postmarks_delivery_health() {
    # Stock Postmarks changes its following table when it receives Accept, but
    # its handler only calls res.status(200).  Express does not finish the HTTP
    # response in that form, so a correct delivery reaches Postmarks and then
    # times out from the sender's point of view.  Repeated operations would
    # consequently put this disposable peer into Unfathomably's normal
    # exponential delivery backoff and hide later activities from this test.
    #
    # Wait for the currently executing request to reach its bounded timeout,
    # then discard only its retry in this disposable database.  Otherwise that
    # old request can recreate the health row just after it is cleared and race
    # the next activity in the sequence.
    local active_jobs=""

    case "$GTS_HOST" in
        ""|*[!A-Za-z0-9._-]*)
            fail "Unsafe Postmarks hostname in delivery-health reset: $GTS_HOST"
            ;;
    esac

    for _ in $(seq 1 30); do
        active_jobs="$(
            docker exec "$BE_DB_CONTAINER" \
                psql -U postgres -d "$BE_DB_NAME" -At \
                -c "SELECT count(*) FROM oban_jobs
                    WHERE worker = 'Pleroma.Workers.PublisherWorker'
                      AND state = 'executing'
                      AND args::text LIKE '%$GTS_HOST%';"
        )"

        if [ "$active_jobs" = "0" ]; then
            break
        fi

        sleep 1
    done

    if [ "$active_jobs" != "0" ]; then
        fail "Timed out settling Postmarks' deliberately open delivery response"
    fi

    # Clear only this isolated peer's pending retries and health row before an
    # operation whose arrival the script verifies independently in Postmarks'
    # own database.  Production retry and health behavior remains covered by
    # its focused test suite.
    docker exec "$BE_DB_CONTAINER" \
        psql -U postgres -d "$BE_DB_NAME" -v ON_ERROR_STOP=1 -q \
        -c "DELETE FROM oban_jobs
              WHERE worker = 'Pleroma.Workers.PublisherWorker'
                AND state IN ('available', 'scheduled', 'retryable')
                AND args::text LIKE '%$GTS_HOST%';
            DELETE FROM instances WHERE host = '$GTS_HOST';" >/dev/null
}

postmarks_comment_present() {
    local comment_url="$1"
    local expected="$2"
    local message="$3"
    local count=""

    for _ in $(seq 1 90); do
        count="$(postmarks_database_scalar bookmarks \
            "select count(*) from comments where url = '$comment_url'" || true)"

        if [ "$count" = "$expected" ]; then
            return 0
        fi

        sleep 2
    done

    fail "$message; last matching comment count was ${count:-unknown}"
}

poll_be_followed_by() {
    local account_id="$1"
    local expected="$2"
    local message="$3"

    poll_json_assert \
        "http_form GET '$BE_BASE/api/v1/accounts/relationships?id[]=$account_id' '$ALICE_TOKEN' 200" \
        "len(data) == 1 and data[0].get('followed_by') is $expected" \
        "$message" >/dev/null
}

prepare_smoke_tls
write_be_secret
write_proxy_configs
write_postmarks_account

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

log "Starting database and stock Postmarks"
docker run -d \
    --name "$BE_DB_CONTAINER" \
    --network "$NETWORK" \
    -e POSTGRES_PASSWORD="$BE_DB_PASSWORD" \
    "$POSTGRES_IMAGE" >/dev/null

wait_postgres
prepare_database
start_postmarks
start_gts_proxy
wait_postmarks
login_postmarks

log "Migrating and starting Unfathomably"
migrate_and_create_be_user alice "alice@$BE_HOST"
start_be
start_be_proxy
wait_be
ALICE_TOKEN="$(create_be_token alice)"

log "Creating the Unfathomably Group actor"
BE_GROUP="$(http_form POST "$BE_BASE/api/v1/groups" "$ALICE_TOKEN" 200 \
    'display_name=Unfathomably Postmarks Smoke' \
    'name=unfathomably_postmarks_smoke' \
    'note=Open group used by the Postmarks federation smoke.' \
    'locked=false')"
BE_GROUP_ID="$(json_get "$BE_GROUP" id)"
BE_GROUP_ACTOR="https://$BE_HOST/users/unfathomably_postmarks_smoke"

log "Following Postmarks from Unfathomably"
POSTMARKS_ACCOUNT_ID="$(resolve_account_id "$BE_BASE" "$ALICE_TOKEN" "$POSTMARKS_ACTOR" \
    "Unfathomably could not resolve the Postmarks actor")"
BE_FOLLOW="$(http_form POST "$BE_BASE/api/v1/accounts/$POSTMARKS_ACCOUNT_ID/follow" "$ALICE_TOKEN" 200)"
json_assert "$BE_FOLLOW" \
    'data.get("following") is True or data.get("requested") is True' \
    "Unfathomably could not follow Postmarks"
postmarks_account_array_contains followers "https://$BE_HOST/users/alice" 1 \
    "Postmarks did not register the Unfathomably follower"

log "Testing Postmarks bookmark, comment, and delete delivery"
POSTMARKS_TITLE="Postmarks to Unfathomably $(basename "$WORK_DIR")"
POSTMARKS_BOOKMARK="$(postmarks_form POST '/bookmark?raw=1' 200 \
    'url=https://example.com/unfathomably-postmarks-smoke' \
    "title=$POSTMARKS_TITLE" \
    'description=Postmarks federation smoke bookmark.' \
    'tags=%5B%22federation-smoke%22%5D' \
    'allowed=' \
    'blocked=')"
POSTMARKS_BOOKMARK_ID="$(json_get "$POSTMARKS_BOOKMARK" bookmarks.id)"
BE_VIEW_ID="$(poll_home_status_by_text "$BE_BASE" "$ALICE_TOKEN" "$POSTMARKS_TITLE" \
    "Unfathomably did not receive the Postmarks bookmark")"

BE_REPLY_TEXT="Unfathomably reply to Postmarks $(basename "$WORK_DIR")"
reset_postmarks_delivery_health
BE_REPLY="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
    "status=$BE_REPLY_TEXT" \
    "in_reply_to_id=$BE_VIEW_ID")"
BE_REPLY_ID="$(json_get "$BE_REPLY" id)"
BE_REPLY_URI="$(json_get "$BE_REPLY" uri)"
postmarks_comment_present "$BE_REPLY_URI" 1 \
    "Postmarks did not store the Unfathomably comment"

http_form DELETE "$BE_BASE/api/v1/statuses/$BE_REPLY_ID" "$ALICE_TOKEN" 200 >/dev/null

# Postmarks accepts the Delete activity but does not remove the matching row
# from its comments database.  Verify that stock behavior explicitly so the
# matrix does not turn a retained deleted comment into a false success.
postmarks_comment_present "$BE_REPLY_URI" 1 \
    "Postmarks unexpectedly lost the retained comment used to document its Delete limitation"

postmarks_form POST "/bookmark/$POSTMARKS_BOOKMARK_ID/delete?raw=1" 200 >/dev/null
poll_status_missing "$BE_BASE" "$ALICE_TOKEN" "$BE_VIEW_ID" \
    "Unfathomably retained the deleted Postmarks bookmark"

log "Testing Postmarks outbound Person and Group follows"
reset_postmarks_delivery_health
postmarks_form POST /admin/following/follow 302 "actor=@alice@$BE_HOST" >/dev/null
postmarks_account_array_contains following "https://$BE_HOST/users/alice" 1 \
    "Postmarks did not retain its Unfathomably Person follow"
poll_be_followed_by "$POSTMARKS_ACCOUNT_ID" True \
    "Unfathomably did not register the Postmarks Person follow"

reset_postmarks_delivery_health
postmarks_form POST /admin/following/follow 302 \
    "actor=@unfathomably_postmarks_smoke@$BE_HOST" >/dev/null
postmarks_account_array_contains following "$BE_GROUP_ACTOR" 1 \
    "Postmarks did not retain its Unfathomably Group follow"

postmarks_form POST /admin/following/unfollow 302 "actor=$BE_GROUP_ACTOR" >/dev/null
postmarks_account_array_contains following "$BE_GROUP_ACTOR" 0 \
    "Postmarks retained its local Group follow after unfollow"

log "Testing unfollow and local blocking on both peers"
reset_postmarks_delivery_health
http_form POST "$BE_BASE/api/v1/accounts/$POSTMARKS_ACCOUNT_ID/unfollow" "$ALICE_TOKEN" 200 >/dev/null
postmarks_account_array_contains followers "https://$BE_HOST/users/alice" 0 \
    "Postmarks retained the Unfathomably follower after Undo Follow"

reset_postmarks_delivery_health
http_form POST "$BE_BASE/api/v1/accounts/$POSTMARKS_ACCOUNT_ID/follow" "$ALICE_TOKEN" 200 >/dev/null
postmarks_account_array_contains followers "https://$BE_HOST/users/alice" 1 \
    "Postmarks did not restore the Unfathomably follower"
postmarks_form POST /admin/followers/block 302 \
    "actor=https://$BE_HOST/users/alice" >/dev/null
postmarks_account_array_contains blocks "https://$BE_HOST/users/alice" 1 \
    "Postmarks did not retain its local Unfathomably block"
postmarks_account_array_contains followers "https://$BE_HOST/users/alice" 0 \
    "Postmarks retained the blocked Unfathomably follower"

BE_BLOCK="$(http_form POST "$BE_BASE/api/v1/accounts/$POSTMARKS_ACCOUNT_ID/block" "$ALICE_TOKEN" 200)"
json_assert "$BE_BLOCK" 'data.get("blocking") is True' \
    "Unfathomably did not retain its Postmarks block"
http_form POST "$BE_BASE/api/v1/accounts/$POSTMARKS_ACCOUNT_ID/unblock" "$ALICE_TOKEN" 200 >/dev/null

check_logs "$BE_CONTAINER" "Unfathomably"
check_logs "$GTS_CONTAINER" "Postmarks"

cat <<EOF

Postmarks federation smoke passed.

Covered against stock Postmarks:
* supported: bidirectional Person follows from Postmarks and Unfathomably
* supported: Unfathomably unfollows Postmarks and Postmarks removes the follower
* supported: Postmarks follows an Unfathomably Group and clears its local follow
* supported: Postmarks publishes and deletes a bookmark received by Unfathomably
* supported: Unfathomably creates a comment stored by Postmarks
* supported: both peers retain their own local account-block state
* not_supported: Postmarks does not implement Like or Undo Like
* not_supported: Postmarks accepts but does not apply Delete for a remote comment
* not_supported: Postmarks does not send a valid interoperable Undo Follow
* not_supported: Postmarks does not send or receive ActivityPub Block
* not_supported: Postmarks cannot report that a remote domain defederated it
EOF

# end of build_scripts/unfathomably-postmarks-smoke.sh
