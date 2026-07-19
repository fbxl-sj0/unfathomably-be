#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-gancio-smoke.sh
#
# Purpose:
#
#   Run a stock Gancio Application actor against Unfathomably and exercise
#   Gancio's Event-oriented federation contract.
#
# Responsibilities:
#
#   * configure a disposable Gancio instance and administrator
#   * test Person and Group follows initiated by Gancio
#   * test Event delivery, Like and Undo Like, Note replies, and Delete
#   * test Gancio resource and actor moderation state
#   * report stock operations that are not implemented
#
# This file intentionally does NOT contain:
#
#   * Mastodon API assumptions for Gancio
#   * patched Gancio source or images
#   * production deployment settings
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAMILY_HARNESS="$SCRIPT_DIR/unfathomably-gotosocial-smoke.sh"

if [ ! -f "$FAMILY_HARNESS" ]; then
    printf 'Required account-federation harness not found: %s\n' "$FAMILY_HARNESS" >&2
    exit 1
fi

export SMOKE_PREFIX="${SMOKE_PREFIX:-unfathomably-gancio-smoke}"
export BE_HOST="${BE_HOST:-unfathomably-gancio.test}"
export BE_PORT="${BE_PORT:-5009}"
export BE_DB_NAME="${BE_DB_NAME:-unfathomably_gancio_smoke_be}"
export GTS_HOST="${GTS_HOST:-gancio-ref.test}"
export GTS_PORT="${GTS_PORT:-5010}"
export GTS_APP_PORT="${GTS_APP_PORT:-13120}"
export GTS_LABEL=Gancio
export GTS_USERNAME=relay
export GTS_IMAGE="${GANCIO_IMAGE:-cisti/gancio:beta}"

# shellcheck source=unfathomably-gotosocial-smoke.sh
source "$FAMILY_HARNESS"

GANCIO_ADMIN_EMAIL="${GANCIO_ADMIN_EMAIL:-admin@gancio-smoke.test}"
GANCIO_SESSION_PASSWORD="${GANCIO_SESSION_PASSWORD:-0123456789abcdef0123456789abcdef}"
GANCIO_ACTOR="http://$GTS_HOST/federation/u/$GTS_USERNAME"

gancio_json() {
    local method="$1"
    local path="$2"
    local token="$3"
    local expected="$4"
    local payload="${5:-}"

    if [ -z "$payload" ]; then
        payload='{}'
    fi

    http_json "$method" "$GTS_BASE$path" "$token" "$expected" "$payload"
}

wait_gancio() {
    for _ in $(seq 1 90); do
        if curl -fsS "$GTS_BASE/api/settings" >/dev/null 2>&1; then
            return 0
        fi

        sleep 2
    done

    docker logs "$GTS_CONTAINER" >&2 || true
    fail "Timed out waiting for Gancio at $GTS_BASE"
}

run_gancio_container() {
    docker run -d \
        --name "$GTS_CONTAINER" \
        --hostname "$GTS_APP_HOST" \
        --network "$NETWORK" \
        --network-alias "$GTS_APP_HOST" \
        -e BASEURL="http://$GTS_HOST" \
        -e GANCIO_HOST=0.0.0.0 \
        -e GANCIO_PORT="$GTS_APP_PORT" \
        -e GANCIO_DB_DIALECT=sqlite \
        -e GANCIO_DB_STORAGE=/app/data/gancio.sqlite \
        -e LOG_PATH=/app/data/logs \
        -e UPLOAD_PATH=/app/data/uploads \
        -e USER_LOCALE=/app/data/user_locale \
        -e NUXT_SESSION_PASSWORD="$GANCIO_SESSION_PASSWORD" \
        -v "$GTS_VOLUME:/app/data" \
        "$GTS_IMAGE" >/dev/null
}

repair_gancio_first_start_key_pair() {
    # Gancio generates its federation keypair during first startup.  The beta
    # image can run that initialization concurrently and persist a public key
    # from one pair beside the private key from another.  Treat the stored
    # private key as authoritative and replace only the derived public key
    # before any federation traffic is sent.
    docker exec -i "$GTS_CONTAINER" node --input-type=module - <<'NODE'
import { createPublicKey } from "node:crypto";
import { DatabaseSync } from "node:sqlite";

const database = new DatabaseSync("/app/data/gancio.sqlite");
database.exec("PRAGMA busy_timeout = 30000");

let privateRow;

/*
 * The HTTP surface becomes ready before the beta image's asynchronous key
 * initialization commits.  Wait for the authoritative private key instead of
 * racing that first-start transaction.
 */
for (let attempt = 0; attempt < 90; attempt += 1) {
    privateRow = database
        .prepare("SELECT value FROM settings WHERE key = 'privateKey'")
        .get();

    if (privateRow && typeof privateRow.value === "string") {
        break;
    }

    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1000);
}

if (!privateRow || typeof privateRow.value !== "string") {
    throw new Error("Gancio did not persist its private federation key");
}

const privateKey = JSON.parse(privateRow.value);
const publicKey = createPublicKey(privateKey).export({
    type: "spki",
    format: "pem",
});

const now = new Date().toISOString();
const update = database.prepare(`
    INSERT INTO settings (key, value, is_secret, createdAt, updatedAt)
    VALUES ('publicKey', ?, 0, ?, ?)
    ON CONFLICT(key) DO UPDATE SET
        value = excluded.value,
        updatedAt = excluded.updatedAt
`).run(JSON.stringify(publicKey), now, now);

if (update.changes !== 1) {
    throw new Error("Gancio did not persist its public federation key");
}

database.close();
NODE
}

enable_gancio_resource_moderation() {
    # The beta image's settings CLI opens a separate ORM process for each
    # setting.  During first-start initialization, a later CLI process can
    # overwrite the row written by the first one.  Persist both settings in
    # one checked transaction so the restarted server sees one complete state.
    docker exec -i "$GTS_CONTAINER" node --input-type=module - <<'NODE'
import { DatabaseSync } from "node:sqlite";

const database = new DatabaseSync("/app/data/gancio.sqlite");
database.exec("PRAGMA busy_timeout = 30000");
database.exec("BEGIN IMMEDIATE");

const now = new Date().toISOString();
const upsert = database.prepare(`
    INSERT INTO settings (key, value, is_secret, createdAt, updatedAt)
    VALUES (?, ?, 0, ?, ?)
    ON CONFLICT(key) DO UPDATE SET
        value = excluded.value,
        updatedAt = excluded.updatedAt
`);

for (const key of ["enable_resources", "enable_moderation"]) {
    upsert.run(key, JSON.stringify(true), now, now);
}

for (const key of ["enable_resources", "enable_moderation"]) {
    const row = database
        .prepare("SELECT value FROM settings WHERE key = ?")
        .get(key);

    if (!row || JSON.parse(row.value) !== true) {
        database.exec("ROLLBACK");
        throw new Error(`Gancio did not persist ${key}`);
    }
}

database.exec("COMMIT");
database.close();
NODE
}

start_gancio() {
    docker volume create "$GTS_VOLUME" >/dev/null

    # The production image runs as uid 1000. Docker creates a named volume as
    # root, so first startup cannot create SQLite or config files until the
    # volume ownership matches the image user.
    docker run --rm -v "$GTS_VOLUME:/data" alpine:3.21 chown -R 1000:1000 /data
    run_gancio_container
    start_gts_proxy
    wait_gancio

    repair_gancio_first_start_key_pair
    enable_gancio_resource_moderation
    docker restart "$GTS_CONTAINER" >/dev/null
    wait_gancio

    local settings
    settings="$(gancio_json GET /api/settings "" 200 '{}')"
    json_assert "$settings" \
        "data.get('enable_resources') is True and data.get('enable_moderation') is True" \
        "Gancio did not load resource moderation settings after restart"
}

create_gancio_token() {
    local register_payload login_payload token

    register_payload="$(GANCIO_EMAIL="$GANCIO_ADMIN_EMAIL" GANCIO_PASSWORD="$PASSWORD" python3 - <<'PY'
import json
import os

print(json.dumps({
    "email": os.environ["GANCIO_EMAIL"],
    "password": os.environ["GANCIO_PASSWORD"],
}))
PY
)"
    gancio_json POST /api/user/register "" 200 "$register_payload" >/dev/null

    login_payload="$register_payload"
    token="$(gancio_json POST /api/login/token "" 200 "$login_payload")"
    json_get "$token" access_token
}

poll_gancio_actor() {
    local expression="$1"
    local message="$2"

    poll_json_assert \
        "gancio_json GET /api/ap_actors '$GANCIO_TOKEN' 200 '{}'" \
        "$expression" \
        "$message" >/dev/null
}

poll_gancio_event() {
    local event_id="$1"
    local expression="$2"
    local message="$3"

    poll_json_assert \
        "gancio_json GET /api/event/detail/$event_id '' 200 '{}'" \
        "$expression" \
        "$message" >/dev/null
}

poll_gancio_resources() {
    local event_id="$1"
    local expression="$2"
    local message="$3"

    poll_json_assert \
        "gancio_json GET /api/resources/list/$event_id '' 200 '{}'" \
        "$expression" \
        "$message" >/dev/null
}

poll_be_group_follow() {
    local expected="$1"
    local message="$2"
    local count=""

    for _ in $(seq 1 90); do
        count="$(docker exec "$BE_DB_CONTAINER" psql -U postgres -d "$BE_DB_NAME" -Atc \
            "SELECT count(*) FROM following_relationships relationship JOIN users follower ON follower.id = relationship.follower_id JOIN users followed ON followed.id = relationship.following_id WHERE follower.ap_id = '$GANCIO_ACTOR' AND followed.ap_id = '$BE_GROUP_ACTOR' AND relationship.state = 2;" || true)"

        if [ "$count" = "$expected" ]; then
            return 0
        fi

        sleep 2
    done

    printf 'Observed Group follow count: %s\n' "$count" >&2
    fail "$message"
}

poll_home_event_by_name() {
    local event_name="$1"
    local message="$2"
    local result=""
    local id=""

    for _ in $(seq 1 90); do
        result="$(http_form GET "$BE_BASE/api/v1/timelines/home?limit=40" "$ALICE_TOKEN" 200 || true)"

        id="$(
            JSON_INPUT="$result" EXPECTED_NAME="$event_name" python3 - <<'PY'
import json
import os

for status in json.loads(os.environ["JSON_INPUT"]):
    event = (status.get("pleroma") or {}).get("event") or {}

    if event.get("name") == os.environ["EXPECTED_NAME"]:
        print(status["id"])
        raise SystemExit(0)

raise SystemExit(1)
PY
        )" && {
            printf '%s\n' "$id"
            return 0
        }

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

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

log "Starting database and stock Gancio"
docker run -d \
    --name "$BE_DB_CONTAINER" \
    --network "$NETWORK" \
    -e POSTGRES_PASSWORD="$BE_DB_PASSWORD" \
    "$POSTGRES_IMAGE" >/dev/null

wait_postgres
prepare_database
start_gancio
GANCIO_TOKEN="$(create_gancio_token)"

log "Migrating and starting Unfathomably"
migrate_and_create_be_user alice "alice@$BE_HOST"
start_be
start_be_proxy
wait_be
ALICE_TOKEN="$(create_be_token alice)"

log "Creating Unfathomably Group actor"
BE_GROUP="$(http_form POST "$BE_BASE/api/v1/groups" "$ALICE_TOKEN" 200 \
    'display_name=Unfathomably Gancio Smoke' \
    'name=unfathomably_gancio_smoke' \
    'note=Open group used by the Gancio federation smoke.' \
    'locked=false')"
BE_GROUP_ID="$(json_get "$BE_GROUP" id)"
BE_GROUP_ACTOR="http://$BE_HOST/users/unfathomably_gancio_smoke"

log "Following Gancio from Unfathomably"
GANCIO_ACCOUNT_ID="$(resolve_account_id "$BE_BASE" "$ALICE_TOKEN" "$GANCIO_ACTOR" "Unfathomably could not resolve the Gancio actor")"
BE_FOLLOW_GANCIO="$(http_form POST "$BE_BASE/api/v1/accounts/$GANCIO_ACCOUNT_ID/follow" "$ALICE_TOKEN" 200)"
json_assert "$BE_FOLLOW_GANCIO" 'data.get("following") is True or data.get("requested") is True' "Unfathomably could not follow Gancio"
poll_gancio_actor \
    "any(item.get('ap_id') == 'http://$BE_HOST/users/alice' and item.get('follower') is True for item in data)" \
    "Gancio did not register the Unfathomably follower"

log "Testing Gancio Event delivery, Like, reply, and Delete"
EVENT_TITLE="Gancio Event to Unfathomably $(basename "$WORK_DIR")"
EVENT_PAYLOAD="$(EVENT_TITLE="$EVENT_TITLE" python3 - <<'PY'
import json
import os
import time

print(json.dumps({
    "title": os.environ["EVENT_TITLE"],
    "description": "Event-oriented federation smoke test",
    "place_name": "Federation Test Place",
    "place_address": "1 ActivityPub Way",
    "tags": ["federation-smoke"],
    "start_datetime": int(time.time()) + 3600,
}))
PY
)"
GANCIO_EVENT="$(gancio_json POST /api/events "$GANCIO_TOKEN" 200 "$EVENT_PAYLOAD")"
GANCIO_EVENT_ID="$(json_get "$GANCIO_EVENT" id)"
BE_EVENT_STATUS_ID="$(poll_home_event_by_name "$EVENT_TITLE" "Unfathomably did not receive the Gancio Event")"
BE_EVENT_STATUS="$(http_form GET "$BE_BASE/api/v1/statuses/$BE_EVENT_STATUS_ID" "$ALICE_TOKEN" 200)"
GANCIO_EVENT_URI="$(json_get "$BE_EVENT_STATUS" uri)"

BE_LIKE="$(http_form POST "$BE_BASE/api/v1/statuses/$BE_EVENT_STATUS_ID/favourite" "$ALICE_TOKEN" 200)"
json_assert "$BE_LIKE" 'data.get("favourited") is True' "Unfathomably could not Like the Gancio Event"
poll_gancio_event "$GANCIO_EVENT_ID" \
    "'http://$BE_HOST/users/alice' in data.get('likes', [])" \
    "Gancio did not record the Unfathomably Like"

BE_UNLIKE="$(http_form POST "$BE_BASE/api/v1/statuses/$BE_EVENT_STATUS_ID/unfavourite" "$ALICE_TOKEN" 200)"
json_assert "$BE_UNLIKE" 'data.get("favourited") is False' "Unfathomably could not Undo Like on the Gancio Event"
poll_gancio_event "$GANCIO_EVENT_ID" \
    "'http://$BE_HOST/users/alice' not in data.get('likes', [])" \
    "Gancio retained the Unfathomably Like after Undo"

BE_REPLY_TEXT="Unfathomably reply to Gancio Event $(basename "$WORK_DIR")"
BE_REPLY="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
    "status=$BE_REPLY_TEXT" \
    "in_reply_to_id=$BE_EVENT_STATUS_ID" \
    "visibility=public")"
BE_REPLY_ID="$(json_get "$BE_REPLY" id)"
BE_REPLY_URI="$(json_get "$BE_REPLY" uri)"
poll_gancio_resources "$GANCIO_EVENT_ID" \
    "any(item.get('activitypub_id') == '$BE_REPLY_URI' and '$BE_REPLY_TEXT' in item.get('data', {}).get('content', '') for item in data)" \
    "Gancio did not store the Unfathomably Note reply"

log "Testing Gancio resource moderation"
ADMIN_RESOURCES="$(gancio_json GET "/api/resources/list?page=1&pageSize=15" "$GANCIO_TOKEN" 200 '{}')"
RESOURCE_ID="$(JSON_INPUT="$ADMIN_RESOURCES" EXPECTED_URI="$BE_REPLY_URI" python3 - <<'PY'
import json
import os

for resource in json.loads(os.environ["JSON_INPUT"]).get("data", []):
    if resource.get("activitypub_id") == os.environ["EXPECTED_URI"]:
        # Gancio's Resource model uses activitypub_id as its primary key. The
        # update endpoint calls that value "id", even though list responses
        # retain the model field name.
        print(resource.get("activitypub_id", ""))
        break
PY
)"

if [ -z "$RESOURCE_ID" ]; then
    fail "Gancio admin resource list omitted the federated reply"
fi

gancio_json PUT /api/resources "$GANCIO_TOKEN" 204 \
    "{\"id\":\"$RESOURCE_ID\",\"hidden\":true}" >/dev/null
poll_gancio_resources "$GANCIO_EVENT_ID" \
    "not any(item.get('activitypub_id') == '$BE_REPLY_URI' for item in data)" \
    "Gancio public resource list retained a hidden reply"

http_form DELETE "$BE_BASE/api/v1/statuses/$BE_REPLY_ID" "$ALICE_TOKEN" 200 >/dev/null
poll_json_assert \
    "gancio_json GET '/api/resources/list?page=1&pageSize=15' '$GANCIO_TOKEN' 200 '{}'" \
    "not any(item.get('activitypub_id') == '$BE_REPLY_URI' for item in data.get('data', []))" \
    "Gancio did not remove the deleted Unfathomably reply" >/dev/null

log "Testing Gancio-initiated Person follow and unfollow"
TRUSTED_ALICE="$(gancio_json POST /api/ap_actors/add_trust "$GANCIO_TOKEN" 200 \
    "{\"url\":\"http://$BE_HOST/users/alice\"}")"
json_assert "$TRUSTED_ALICE" "data.get('ap_id') == 'http://$BE_HOST/users/alice'" "Gancio could not trust the Unfathomably Person actor"
poll_gancio_actor \
    "any(item.get('ap_id') == 'http://$BE_HOST/users/alice' and item.get('following') is True for item in data)" \
    "Gancio did not follow the Unfathomably Person actor"
poll_json_assert \
    "http_form GET '$BE_BASE/api/v1/accounts/relationships?id[]=$GANCIO_ACCOUNT_ID' '$ALICE_TOKEN' 200" \
    "len(data) == 1 and data[0].get('followed_by') is True" \
    "Unfathomably did not accept the Gancio Person follow" >/dev/null

gancio_json PUT /api/ap_actors/follow "$GANCIO_TOKEN" 200 \
    "{\"ap_id\":\"http://$BE_HOST/users/alice\"}" >/dev/null
poll_json_assert \
    "http_form GET '$BE_BASE/api/v1/accounts/relationships?id[]=$GANCIO_ACCOUNT_ID' '$ALICE_TOKEN' 200" \
    "len(data) == 1 and data[0].get('followed_by') is False" \
    "Unfathomably retained the Gancio Person follow after Undo" >/dev/null

log "Testing Gancio-initiated Group follow and group unfollow"
TRUSTED_GROUP="$(gancio_json POST /api/ap_actors/add_trust "$GANCIO_TOKEN" 200 \
    "{\"url\":\"$BE_GROUP_ACTOR\"}")"
json_assert "$TRUSTED_GROUP" "data.get('ap_id') == '$BE_GROUP_ACTOR'" "Gancio could not trust the Unfathomably Group actor"
poll_gancio_actor \
    "any(item.get('ap_id') == '$BE_GROUP_ACTOR' and item.get('following') is True for item in data)" \
    "Gancio did not follow the Unfathomably Group actor"

poll_be_group_follow 1 "Unfathomably Group did not accept the Gancio follow"
gancio_json PUT /api/ap_actors/follow "$GANCIO_TOKEN" 200 \
    "{\"ap_id\":\"$BE_GROUP_ACTOR\"}" >/dev/null
poll_be_group_follow 0 "Unfathomably Group retained the Gancio follow after Undo"

log "Testing local actor blocks"
gancio_json PUT /api/ap_actors/toggle_block "$GANCIO_TOKEN" 204 \
    "{\"ap_id\":\"http://$BE_HOST/users/alice\"}" >/dev/null
poll_gancio_actor \
    "any(item.get('ap_id') == 'http://$BE_HOST/users/alice' and item.get('blocked') is True for item in data)" \
    "Gancio did not retain its Unfathomably actor block"

BE_BLOCK="$(http_form POST "$BE_BASE/api/v1/accounts/$GANCIO_ACCOUNT_ID/block" "$ALICE_TOKEN" 200)"
json_assert "$BE_BLOCK" 'data.get("blocking") is True' "Unfathomably did not retain its Gancio block"
http_form POST "$BE_BASE/api/v1/accounts/$GANCIO_ACCOUNT_ID/unblock" "$ALICE_TOKEN" 200 >/dev/null

check_logs "$BE_CONTAINER" "Unfathomably"
check_logs "$GTS_CONTAINER" "Gancio"

cat <<EOF

Gancio federation smoke passed.

Covered against stock Gancio:
* supported: Unfathomably follows the Gancio Application actor
* supported: Gancio follows and unfollows an Unfathomably Person actor
* supported: Gancio follows and unfollows an Unfathomably Group actor
* supported: Gancio Event delivery into Unfathomably
* supported: Gancio receives Like and Undo Like on its Event
* supported: Gancio stores an Unfathomably Note reply to its Event
* supported: Gancio removes the reply after Unfathomably sends Delete
* supported: Gancio hides a remote reply through its moderation API
* supported: Gancio and Unfathomably retain local actor-block state
* not_supported: Gancio users cannot publish general Note posts or replies
* not_supported: Gancio local Event deletion does not federate Delete
* not_supported: Gancio local blocks do not send ActivityPub Block notices
* not_supported: Gancio cannot report that a remote server defederated it
* event URI verified by Unfathomably: $GANCIO_EVENT_URI
EOF

# end of build_scripts/unfathomably-gancio-smoke.sh
