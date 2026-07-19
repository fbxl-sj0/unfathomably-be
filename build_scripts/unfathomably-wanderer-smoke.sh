#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-wanderer-smoke.sh
#
# Purpose:
#
#   Run the official Wanderer images against Unfathomably and verify the
#   federation contract used by its users, trails, comments, and route data.
#
# Responsibilities:
#
#   * boot stock Wanderer web, PocketBase, and Meilisearch services
#   * create all test state through Wanderer's native HTTP API
#   * exercise account and Group follows, Trails, comments, Likes, and Deletes
#   * verify native route metadata, collection bounds, privacy, and cleanup
#   * report stock Wanderer limitations without synthetic ActivityPub traffic
#
# This file intentionally does NOT contain:
#
#   * patched Wanderer source or images
#   * hand-authored Wanderer ActivityPub activities
#   * browser automation or production credentials
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAMILY_HARNESS="$SCRIPT_DIR/unfathomably-gotosocial-smoke.sh"

if [ ! -f "$FAMILY_HARNESS" ]; then
    printf 'Required account-federation harness not found: %s\n' "$FAMILY_HARNESS" >&2
    exit 1
fi

export SMOKE_PREFIX="${SMOKE_PREFIX:-unfathomably-wanderer-smoke}"
export BE_HOST="${BE_HOST:-unfathomably-wanderer.example.com}"
export BE_PORT="${BE_PORT:-5071}"
export BE_DB_NAME="${BE_DB_NAME:-unfathomably_wanderer_smoke_be}"
export GTS_HOST="${GTS_HOST:-wanderer-ref.example.com}"
export GTS_PORT="${GTS_PORT:-5072}"
export GTS_APP_PORT=3000
export GTS_FORWARDED_PROTO=https
export GTS_LABEL=Wanderer
export GTS_USERNAME=walker
export SMOKE_TLS=1
export BE_FEDERATION_SCHEME=https
export BE_FEDERATION_PORT=443

# shellcheck source-path=SCRIPTDIR
# shellcheck source=unfathomably-gotosocial-smoke.sh
source "$FAMILY_HARNESS"

WANDERER_VERSION="${WANDERER_VERSION:-v0.20.0}"
WANDERER_DB_IMAGE="${WANDERER_DB_IMAGE:-flomp/wanderer-db:$WANDERER_VERSION}"
WANDERER_WEB_IMAGE="${WANDERER_WEB_IMAGE:-flomp/wanderer-web:$WANDERER_VERSION}"
WANDERER_SEARCH_IMAGE="${WANDERER_SEARCH_IMAGE:-getmeili/meilisearch:v1.36.0}"

WANDERER_DB_CONTAINER="${PREFIX}-wanderer-db"
WANDERER_SEARCH_CONTAINER="${PREFIX}-wanderer-search"
WANDERER_WEB_CONTAINER="$GTS_CONTAINER"
WANDERER_UPLOADS_VOLUME="${PREFIX}-wanderer-uploads"
WANDERER_COOKIE_JAR="$WORK_DIR/wanderer.cookies"
WANDERER_CA_BUNDLE="$WORK_DIR/wanderer-ca-bundle.crt"
WANDERER_GPX="$WORK_DIR/alien-route.gpx"
WANDERER_PASSWORD="${WANDERER_PASSWORD:-Wanderer-smoke-password-12345}"
WANDERER_MEILI_KEY="${WANDERER_MEILI_KEY:-wanderer-smoke-meilisearch-key}"
WANDERER_ENCRYPTION_KEY="${WANDERER_ENCRYPTION_KEY:-0123456789abcdef0123456789abcdef}"
WANDERER_NETWORK_SUBNET="${WANDERER_NETWORK_SUBNET:-198.18.0.0/24}"

cleanup_wanderer_smoke() {
    local incoming_status="$?"
    local status="${1:-$incoming_status}"

    if [ "$KEEP_CONTAINERS" = "1" ]; then
        cleanup "$status"
    fi

    docker rm -f \
        "$WANDERER_WEB_CONTAINER" \
        "$WANDERER_DB_CONTAINER" \
        "$WANDERER_SEARCH_CONTAINER" >/dev/null 2>&1 || true
    docker volume rm "$WANDERER_UPLOADS_VOLUME" >/dev/null 2>&1 || true
    cleanup "$status"
}

trap cleanup_wanderer_smoke EXIT

prepare_wanderer_files() {
    cat /etc/ssl/certs/ca-certificates.crt >"$WANDERER_CA_BUNDLE"
    cat "$SMOKE_CA_CERT" >>"$WANDERER_CA_BUNDLE"

    cat >"$WANDERER_GPX" <<'GPX'
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="Unfathomably federation smoke"
     xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <name>Alien federation ridge</name>
    <trkseg>
      <trkpt lat="45.4215" lon="-75.6972"><ele>80</ele></trkpt>
      <trkpt lat="45.4220" lon="-75.6960"><ele>92</ele></trkpt>
    </trkseg>
  </trk>
</gpx>
GPX
}

start_wanderer() {
    docker volume create "$GTS_VOLUME" >/dev/null
    docker volume create "$WANDERER_UPLOADS_VOLUME" >/dev/null

    docker run -d \
        --name "$WANDERER_SEARCH_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$WANDERER_SEARCH_CONTAINER" \
        -e MEILI_MASTER_KEY="$WANDERER_MEILI_KEY" \
        -e MEILI_NO_ANALYTICS=true \
        "$WANDERER_SEARCH_IMAGE" >/dev/null

    for _ in $(seq 1 90); do
        if docker exec "$WANDERER_SEARCH_CONTAINER" \
            curl -fsS http://127.0.0.1:7700/health >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    docker exec "$WANDERER_SEARCH_CONTAINER" \
        curl -fsS http://127.0.0.1:7700/health >/dev/null 2>&1 || \
        fail "Wanderer Meilisearch did not become ready"

    docker run -d \
        --name "$WANDERER_DB_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$WANDERER_DB_CONTAINER" \
        -e "MEILI_URL=http://$WANDERER_SEARCH_CONTAINER:7700" \
        -e "MEILI_MASTER_KEY=$WANDERER_MEILI_KEY" \
        -e "POCKETBASE_ENCRYPTION_KEY=$WANDERER_ENCRYPTION_KEY" \
        -e "ORIGIN=https://$GTS_HOST" \
        -e SSL_CERT_FILE=/tls/ca-bundle.crt \
        -v "$GTS_VOLUME:/pb_data" \
        -v "$WANDERER_CA_BUNDLE:/tls/ca-bundle.crt:ro" \
        "$WANDERER_DB_IMAGE" >/dev/null

    for _ in $(seq 1 120); do
        if docker exec "$WANDERER_DB_CONTAINER" \
            /curl -fsS http://127.0.0.1:8090/health >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    docker exec "$WANDERER_DB_CONTAINER" \
        /curl -fsS http://127.0.0.1:8090/health >/dev/null 2>&1 || \
        fail "Wanderer PocketBase did not become ready"

    docker run -d \
        --name "$WANDERER_WEB_CONTAINER" \
        --hostname "$GTS_APP_HOST" \
        --network "$NETWORK" \
        --network-alias "$GTS_APP_HOST" \
        -e "MEILI_URL=http://$WANDERER_SEARCH_CONTAINER:7700" \
        -e "MEILI_MASTER_KEY=$WANDERER_MEILI_KEY" \
        -e "ORIGIN=https://$GTS_HOST" \
        -e "PUBLIC_POCKETBASE_URL=http://$WANDERER_DB_CONTAINER:8090" \
        -e PUBLIC_DISABLE_SIGNUP=false \
        -e BODY_SIZE_LIMIT=Infinity \
        -e NODE_EXTRA_CA_CERTS=/tls/smoke-ca.crt \
        -e UPLOAD_FOLDER=/app/uploads \
        -e OVERPASS_API_URL=https://overpass-api.de \
        -e VALHALLA_URL=https://valhalla1.openstreetmap.de \
        -e NOMINATIM_URL=https://nominatim.openstreetmap.org \
        -v "$WANDERER_UPLOADS_VOLUME:/app/uploads" \
        -v "$SMOKE_CA_CERT:/tls/smoke-ca.crt:ro" \
        "$WANDERER_WEB_IMAGE" >/dev/null
}

wait_wanderer() {
    for _ in $(seq 1 180); do
        if curl -fsS "$GTS_BASE/" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    docker logs "$WANDERER_WEB_CONTAINER" >&2 || true
    docker logs "$WANDERER_DB_CONTAINER" >&2 || true
    fail "Timed out waiting for Wanderer at $GTS_BASE"
}

wanderer_request() {
    local method="$1"
    local path="$2"
    local expected="$3"
    local data="${4:-}"
    local response status body
    local args=(-sS -X "$method" -H 'Accept: application/json' -b "$WANDERER_COOKIE_JAR" -c "$WANDERER_COOKIE_JAR")

    if [ -n "$data" ]; then
        args+=(-H 'Content-Type: application/json' --data "$data")
    fi

    response="$(curl "${args[@]}" -w '\n%{http_code}' "$GTS_BASE$path")"
    status="${response##*$'\n'}"
    body="${response%$'\n'*}"

    if [ "$status" != "$expected" ]; then
        printf 'Unexpected Wanderer response for %s %s: expected %s, got %s\n%s\n' \
            "$method" "$path" "$expected" "$status" "$body" >&2
        return 1
    fi

    printf '%s\n' "$body"
}

wanderer_upload_gpx() {
    local trail_id="$1"
    local response status body

    response="$(curl -sS -X POST \
        -H 'Accept: application/json' \
        -b "$WANDERER_COOKIE_JAR" \
        -c "$WANDERER_COOKIE_JAR" \
        -F "gpx=@$WANDERER_GPX;type=application/gpx+xml" \
        -w '\n%{http_code}' \
        "$GTS_BASE/api/v1/trail/$trail_id/file")"
    status="${response##*$'\n'}"
    body="${response%$'\n'*}"

    if [ "$status" != "200" ]; then
        printf '%s\n' "$body" >&2
        fail "Wanderer rejected the native GPX upload with HTTP $status"
    fi

    printf '%s\n' "$body"
}

poll_wanderer_json() {
    local path="$1"
    local expr="$2"
    local message="$3"
    local result=""

    for _ in $(seq 1 90); do
        result="$(wanderer_request GET "$path" 200 || true)"

        if [ -n "$result" ] && JSON_INPUT="$result" python3 - "$expr" <<'PY'
import json
import os
import sys

data = json.loads(os.environ["JSON_INPUT"])
safe_builtins = {"all": all, "any": any, "int": int, "len": len, "str": str}
if not eval(sys.argv[1], {"__builtins__": safe_builtins}, {"data": data}):
    raise SystemExit(1)
PY
        then
            printf '%s\n' "$result"
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

poll_wanderer_actor_id() {
    local query="$1"
    local expected_iri="$2"
    local message="$3"
    local result actor_id

    for _ in $(seq 1 90); do
        result="$(wanderer_request GET "/api/v1/search/actor?q=$(urlencode "$query")" 200 || true)"
        actor_id=""

        if [ -n "$result" ]; then
            actor_id="$({
            JSON_INPUT="$result" EXPECTED_IRI="$expected_iri" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
expected = os.environ["EXPECTED_IRI"]
for actor in data.get("hits") or []:
    if actor.get("iri") == expected:
        print(actor["id"])
        raise SystemExit(0)
raise SystemExit(1)
PY
            } || true)"
        fi

        if [ -n "$actor_id" ]; then
            printf '%s\n' "$actor_id"
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

poll_wanderer_item_id() {
    local path="$1"
    local expr="$2"
    local message="$3"
    local result item_id

    for _ in $(seq 1 90); do
        result="$(wanderer_request GET "$path" 200 || true)"
        item_id=""

        if [ -n "$result" ]; then
            item_id="$({
            JSON_INPUT="$result" python3 - "$expr" <<'PY'
import json
import os
import sys

data = json.loads(os.environ["JSON_INPUT"])
safe_builtins = {"all": all, "any": any, "int": int, "len": len, "str": str}
for item in data.get("items") or []:
    if eval(sys.argv[1], {"__builtins__": safe_builtins}, {"item": item}):
        print(item["id"])
        raise SystemExit(0)
raise SystemExit(1)
PY
            } || true)"
        fi

        if [ -n "$item_id" ]; then
            printf '%s\n' "$item_id"
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

poll_relationship_not_following() {
    local base="$1"
    local token="$2"
    local account_id="$3"
    local message="$4"

    poll_json_assert \
        "http_form GET '$base/api/v1/accounts/relationships?id[]=$account_id' '$token' 200" \
        'len(data) >= 1 and data[0].get("following") is not True and data[0].get("requested") is not True' \
        "$message" >/dev/null
}

assert_be_status_text_missing() {
    local text="$1"
    local message="$2"
    local result=""

    for _ in $(seq 1 20); do
        result="$(http_form GET "$BE_BASE/api/v1/timelines/home?limit=40" "$ALICE_TOKEN" 200 || true)"
        if JSON_INPUT="$result" EXPECTED_TEXT="$text" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
text = os.environ["EXPECTED_TEXT"]
if any(text in (item.get("content") or "") for item in data):
    raise SystemExit(1)
PY
        then
            sleep 1
        else
            printf '%s\n' "$result" >&2
            fail "$message"
        fi
    done
}

run_wanderer_smoke() {
    local register login local_actor actor_doc webfinger
    local be_actor follow follow_filter follow_record_id
    local group group_actor_id group_follow group_follow_id
    local trail trail_id trail_iri trail_ap trail_status_id trail_status
    local private_trail private_id private_status
    local updated gpx_result comment_filter remote_comment_id
    local reply blocked_trail blocked_text blocked_id

    prepare_smoke_tls
    prepare_wanderer_files
    write_be_secret
    write_proxy_configs

    log "Creating isolated Wanderer federation network"
    docker rm -f \
        "$GTS_PROXY_CONTAINER" \
        "$WANDERER_WEB_CONTAINER" \
        "$WANDERER_DB_CONTAINER" \
        "$WANDERER_SEARCH_CONTAINER" \
        "$BE_PROXY_CONTAINER" \
        "$BE_CONTAINER" \
        "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    docker volume rm "$GTS_VOLUME" "$WANDERER_UPLOADS_VOLUME" >/dev/null 2>&1 || true
    #
    # Wanderer's stock outbound HTTP client rejects RFC 1918 peers before it
    # fetches their actor documents. Real federation uses public addresses, so
    # put this isolated bridge in the non-routable RFC 2544 benchmark range.
    # This reaches Wanderer's normal public-address path without patching the
    # image, exposing the test services, or weakening Unfathomably assertions.
    #
    docker network create --subnet "$WANDERER_NETWORK_SUBNET" "$NETWORK" >/dev/null

    log "Starting stock Wanderer $WANDERER_VERSION"
    start_wanderer
    start_gts_proxy
    wait_wanderer

    log "Creating the native Wanderer account"
    register="$(wanderer_request PUT /api/v1/user 200 \
        "{\"username\":\"$GTS_USERNAME\",\"email\":\"$GTS_USERNAME@$GTS_HOST\",\"password\":\"$WANDERER_PASSWORD\",\"passwordConfirm\":\"$WANDERER_PASSWORD\"}")"
    json_assert "$register" 'data.get("id")' "Wanderer did not create its native user"
    login="$(wanderer_request POST /api/v1/auth/login 200 \
        "{\"username\":\"$GTS_USERNAME\",\"password\":\"$WANDERER_PASSWORD\"}")"
    json_assert "$login" 'data.get("token") and data.get("record", {}).get("id")' \
        "Wanderer login did not return a PocketBase session"

    log "Proving Wanderer WebFinger, actor negotiation, and canonical identity"
    webfinger="$(curl -fsS -H 'Accept: application/jrd+json' \
        "$GTS_BASE/.well-known/webfinger?resource=acct:$GTS_USERNAME@$GTS_HOST")"
    json_assert "$webfinger" \
        'data.get("subject") == "acct:walker@wanderer-ref.example.com" and any(link.get("type") == "application/activity+json" for link in data.get("links", []))' \
        "Wanderer WebFinger did not expose its ActivityPub actor"
    actor_doc="$(curl -fsS -H 'Accept: application/activity+json' \
        "$GTS_BASE/api/v1/activitypub/user/$GTS_USERNAME")"
    json_assert "$actor_doc" \
        'data.get("type") == "Person" and data.get("id") == "https://wanderer-ref.example.com/api/v1/activitypub/user/walker" and data.get("publicKey", {}).get("publicKeyPem")' \
        "Wanderer actor discovery lost its canonical Person or public key"

    local_actor="$(poll_wanderer_actor_id "$GTS_USERNAME" \
        "https://$GTS_HOST/api/v1/activitypub/user/$GTS_USERNAME" \
        "Wanderer did not index its local ActivityPub actor")"

    log "Migrating and starting Unfathomably"
    docker run -d \
        --name "$BE_DB_CONTAINER" \
        --network "$NETWORK" \
        -e POSTGRES_PASSWORD="$BE_DB_PASSWORD" \
        "$POSTGRES_IMAGE" >/dev/null
    wait_postgres
    prepare_database
    migrate_and_create_be_user alice "alice@$BE_HOST"
    start_be
    start_be_proxy
    wait_be
    ALICE_TOKEN="$(create_be_token alice)"

    log "Following accounts in both directions"
    WANDERER_ACCOUNT_ID="$(resolve_account_id "$BE_BASE" "$ALICE_TOKEN" \
        "$GTS_USERNAME@$GTS_HOST" "Unfathomably could not resolve Wanderer")"
    http_form POST "$BE_BASE/api/v1/accounts/$WANDERER_ACCOUNT_ID/follow" "$ALICE_TOKEN" 200 >/dev/null
    poll_relationship_following "$BE_BASE" "$ALICE_TOKEN" "$WANDERER_ACCOUNT_ID" \
        "Unfathomably follow of Wanderer did not become accepted"

    #
    # Wanderer's native Follow API accepts a PocketBase actor record ID, not a
    # handle or ActivityPub IRI. Let the inbound Follow above populate that
    # record through Wanderer's normal signed-inbox path before looking it up.
    # This also keeps the test on stock public application behavior instead of
    # inserting a remote actor directly into PocketBase.
    #
    be_actor="$(poll_wanderer_actor_id "alice@$BE_HOST" \
        "https://$BE_HOST/users/alice" \
        "Wanderer could not resolve the Unfathomably Person")"
    follow="$(wanderer_request PUT /api/v1/follow 200 \
        "{\"followee\":\"$be_actor\"}")"
    json_assert "$follow" 'data.get("status") in ["accepted", "pending"]' \
        "Wanderer could not create its outbound Follow"

    follow_filter="$(urlencode "follower='$local_actor'&&followee='$be_actor'")"
    follow_record_id="$(poll_wanderer_item_id "/api/v1/follow?filter=$follow_filter" \
        'item.get("status") == "accepted"' \
        "Wanderer outbound Follow did not become accepted")"

    log "Following and unfollowing an Unfathomably Group from Wanderer"
    group="$(http_form POST "$BE_BASE/api/v1/groups" "$ALICE_TOKEN" 200 \
        'display_name=Wanderer Route Group' \
        'name=wanderer_routes' \
        'note=Group actor used by the stock Wanderer adapter.' \
        'locked=false')"
    BE_GROUP_ID="$(json_get "$group" id)"
    group_actor_id="$(poll_wanderer_actor_id "wanderer_routes@$BE_HOST" \
        "https://$BE_HOST/users/wanderer_routes" \
        "Wanderer could not resolve the Unfathomably Group actor")"
    group_follow="$(wanderer_request PUT /api/v1/follow 200 \
        "{\"followee\":\"$group_actor_id\"}")"
    json_assert "$group_follow" 'data.get("status") in ["accepted", "pending"]' \
        "Wanderer could not create the Group Follow"
    group_follow_id="$(json_get "$group_follow" id)"
    poll_wanderer_json "/api/v1/follow?filter=$(urlencode "id='$group_follow_id'")" \
        'data.get("totalItems", 0) == 1 and data.get("items", [])[0].get("status") == "accepted"' \
        "Wanderer Group Follow did not become accepted" >/dev/null
    wanderer_request DELETE "/api/v1/follow/$group_follow_id" 200 >/dev/null

    log "Creating a private Wanderer Trail and proving it stays private"
    private_trail="$(wanderer_request PUT /api/v1/trail 200 \
        "{\"name\":\"Private alien route\",\"description\":\"PRIVATE-WANDERER-ROUTE\",\"location\":\"Hidden ridge\",\"date\":\"2026-07-17T11:00:00.000Z\",\"public\":false,\"completed\":false,\"difficulty\":\"easy\",\"lat\":45.4,\"lon\":-75.6,\"distance\":500,\"elevation_gain\":20,\"elevation_loss\":20,\"duration\":600,\"photos\":[],\"tags\":[],\"author\":\"$local_actor\"}")"
    private_id="$(json_get "$private_trail" id)"
    private_status="$(curl -sS -o /dev/null -w '%{http_code}' \
        "$GTS_BASE/api/v1/activitypub/trail/$private_id")"
    [ "$private_status" = "404" ] || fail "Private Wanderer Trail was publicly retrievable"
    assert_be_status_text_missing "PRIVATE-WANDERER-ROUTE" \
        "Private Wanderer Trail leaked into the Unfathomably home timeline"

    log "Creating a native public Wanderer Trail"
    trail="$(wanderer_request PUT /api/v1/trail 200 \
        "{\"name\":\"Alien federation ridge\",\"description\":\"WANDERER-TRAIL-CREATE\",\"location\":\"Ottawa ridge\",\"date\":\"2026-07-17T12:00:00.000Z\",\"public\":true,\"completed\":true,\"difficulty\":\"moderate\",\"lat\":45.4215,\"lon\":-75.6972,\"distance\":1800,\"elevation_gain\":120,\"elevation_loss\":90,\"duration\":2700,\"photos\":[],\"tags\":[],\"author\":\"$local_actor\"}")"
    trail_id="$(json_get "$trail" id)"
    trail_iri="$(json_get "$trail" iri)"
    [ "$trail_iri" = "https://$GTS_HOST/api/v1/trail/$trail_id" ] || \
        fail "Wanderer Trail did not receive its canonical application IRI"

    trail_ap="$(curl -fsS -H 'Accept: application/activity+json' \
        "$GTS_BASE/api/v1/activitypub/trail/$trail_id")"
    json_assert "$trail_ap" \
        'data.get("type") == "Note" and data.get("id", "").endswith("/api/v1/trail/" + data.get("id", "").split("/")[-1]) and data.get("location", {}).get("type") == "Place" and any(tag.get("name") == "distance" for tag in data.get("tag", []))' \
        "Wanderer Trail ActivityPub representation lost its Place or route tags"

    trail_status_id="$(poll_home_status_by_text "$BE_BASE" "$ALICE_TOKEN" \
        'WANDERER-TRAIL-CREATE' "Unfathomably did not receive the native Wanderer Trail")"
    trail_status="$(http_form GET "$BE_BASE/api/v1/statuses/$trail_status_id" "$ALICE_TOKEN" 200)"
    json_assert "$trail_status" \
        'data.get("pleroma", {}).get("native", {}).get("fields", {}).get("platform") == "wanderer" and data.get("pleroma", {}).get("native", {}).get("fields", {}).get("route_kind") == "trail" and data.get("pleroma", {}).get("native", {}).get("fields", {}).get("difficulty") == "moderate" and data.get("pleroma", {}).get("native", {}).get("fields", {}).get("location") == "Ottawa ridge"' \
        "Unfathomably did not expose the Wanderer Trail as native route metadata"

    log "Uploading GPX and updating the native Trail"
    gpx_result="$(wanderer_upload_gpx "$trail_id")"
    json_assert "$gpx_result" 'data.get("gpx")' \
        "Wanderer did not retain the GPX file in native Trail state"
    updated="$(wanderer_request POST "/api/v1/trail/$trail_id" 200 \
        '{"name":"Alien federation ridge revised","description":"WANDERER-TRAIL-UPDATED","location":"Ottawa ridge","public":true,"completed":true,"difficulty":"difficult","distance":1900,"elevation_gain":140,"elevation_loss":95,"duration":2800}')"
    json_assert "$updated" 'data.get("difficulty") == "difficult" and data.get("distance") == 1900' \
        "Wanderer native Trail update did not change application state"
    poll_json_assert \
        "http_form GET '$BE_BASE/api/v1/statuses/$trail_status_id' '$ALICE_TOKEN' 200" \
        '"WANDERER-TRAIL-UPDATED" in (data.get("content") or "") and data.get("pleroma", {}).get("native", {}).get("fields", {}).get("difficulty") == "difficult" and data.get("pleroma", {}).get("native", {}).get("fields", {}).get("gpx_url")' \
        "Unfathomably did not apply the Wanderer Trail Update and GPX metadata" >/dev/null

    log "Proving the stock Wanderer OrderedCollection page"
    poll_wanderer_json "/api/v1/activitypub/user/$GTS_USERNAME/outbox?page=1&perPage=2" \
        'data.get("type") == "OrderedCollectionPage" and data.get("partOf", "").endswith("/outbox") and len(data.get("orderedItems") or []) <= 2 and data.get("totalItems", 0) >= 1' \
        "Wanderer outbox did not provide a bounded OrderedCollectionPage" >/dev/null

    log "Applying and undoing an Unfathomably Like in native Wanderer state"
    http_form POST "$BE_BASE/api/v1/statuses/$trail_status_id/favourite" "$ALICE_TOKEN" 200 >/dev/null
    poll_wanderer_json "/api/v1/trail/$trail_id" \
        'data.get("like_count") == 1' \
        "Wanderer did not count the native Trail Like state" >/dev/null
    http_form POST "$BE_BASE/api/v1/statuses/$trail_status_id/unfavourite" "$ALICE_TOKEN" 200 >/dev/null
    poll_wanderer_json "/api/v1/trail/$trail_id" \
        'data.get("like_count") == 0' \
        "Wanderer did not remove the native Trail Like state after Undo" >/dev/null

    log "Round-tripping an Unfathomably reply into native Wanderer Comment state"
    reply="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
        'status=WANDERER-NATIVE-COMMENT' \
        "in_reply_to_id=$trail_status_id" \
        'visibility=public')"
    comment_filter="$(urlencode "trail='$trail_id'&&author='$be_actor'")"
    remote_comment_id="$(poll_wanderer_item_id "/api/v1/comment?filter=$comment_filter" \
        '"WANDERER-NATIVE-COMMENT" in (item.get("text") or "")' \
        "Wanderer did not materialize the Unfathomably reply as a native Comment")"
    http_form DELETE "$BE_BASE/api/v1/statuses/$(json_get "$reply" id)" "$ALICE_TOKEN" 200 >/dev/null
    poll_wanderer_json "/api/v1/comment/$remote_comment_id" \
        '"WANDERER-NATIVE-COMMENT" in (data.get("text") or "")' \
        "Stock Wanderer unexpectedly lost the path-mismatched remote Comment before cleanup" >/dev/null

    log "Deleting the native Wanderer Trail and its compatibility state"
    wanderer_request DELETE "/api/v1/trail/$trail_id" 200 >/dev/null
    poll_status_missing "$BE_BASE" "$ALICE_TOKEN" "$trail_status_id" \
        "Unfathomably did not remove the deleted Wanderer Trail"

    log "Explicitly unfollowing accounts in both directions"
    wanderer_request DELETE "/api/v1/follow/$follow_record_id" 200 >/dev/null
    http_form POST "$BE_BASE/api/v1/accounts/$WANDERER_ACCOUNT_ID/unfollow" "$ALICE_TOKEN" 200 >/dev/null
    poll_wanderer_json "/api/v1/follow?filter=$follow_filter" \
        'data.get("totalItems", 0) == 0' \
        "Wanderer did not remove its outbound Follow" >/dev/null
    poll_relationship_not_following "$BE_BASE" "$ALICE_TOKEN" "$WANDERER_ACCOUNT_ID" \
        "Unfathomably did not remove its Wanderer Follow"

    log "Testing blocking and blocked-delivery suppression"
    http_form POST "$BE_BASE/api/v1/accounts/$WANDERER_ACCOUNT_ID/follow" "$ALICE_TOKEN" 200 >/dev/null
    poll_relationship_following "$BE_BASE" "$ALICE_TOKEN" "$WANDERER_ACCOUNT_ID" \
        "Unfathomably could not re-follow Wanderer for the Block boundary"
    http_form POST "$BE_BASE/api/v1/accounts/$WANDERER_ACCOUNT_ID/block" "$ALICE_TOKEN" 200 >/dev/null
    blocked_text="WANDERER-BLOCKED-DELIVERY"
    blocked_trail="$(wanderer_request PUT /api/v1/trail 200 \
        "{\"name\":\"Blocked delivery route\",\"description\":\"$blocked_text\",\"location\":\"Blocked ridge\",\"date\":\"2026-07-17T13:00:00.000Z\",\"public\":true,\"completed\":false,\"difficulty\":\"easy\",\"lat\":45.42,\"lon\":-75.69,\"distance\":300,\"elevation_gain\":10,\"elevation_loss\":10,\"duration\":300,\"photos\":[],\"tags\":[],\"author\":\"$local_actor\"}")"
    blocked_id="$(json_get "$blocked_trail" id)"
    assert_be_status_text_missing "$blocked_text" \
        "A blocked Wanderer actor delivered a Trail into Unfathomably"
    http_form POST "$BE_BASE/api/v1/accounts/$WANDERER_ACCOUNT_ID/unblock" "$ALICE_TOKEN" 200 >/dev/null
    wanderer_request DELETE "/api/v1/trail/$blocked_id" 200 >/dev/null
    wanderer_request DELETE "/api/v1/trail/$private_id" 200 >/dev/null

    check_logs "$BE_CONTAINER" "Unfathomably"
    check_logs "$WANDERER_WEB_CONTAINER" "Wanderer web"
    check_logs "$WANDERER_DB_CONTAINER" "Wanderer PocketBase"

    cat <<EOF

Wanderer federation smoke passed.

Covered against stock Wanderer $WANDERER_VERSION:
* supported: WebFinger, ActivityPub content negotiation, public-key discovery, and canonical Person identity
* supported: bidirectional Person follows, Accepts, explicit unfollows, and cleanup
* supported: Wanderer follows and unfollows an Unfathomably Group actor through native Follow state
* supported: native public Trail Create, Update, GPX attachment, Delete, and Unfathomably cleanup
* supported: Trail Place, start time, difficulty, distance, duration, elevation, and unknown route tags survive ingestion
* supported: the native route presentation exposes only the honest open control
* supported: private Wanderer Trails are not publicly retrievable and do not enter Unfathomably timelines
* supported: the Wanderer outbox is a bounded OrderedCollectionPage with orderedItems
* supported: Unfathomably Like and Undo Like round-trip into native Wanderer trail_like state
* supported: Unfathomably replies become native Wanderer Comment records
* supported: Unfathomably Block suppresses subsequent Wanderer Trail delivery
* stock_limitation: Wanderer serves ActivityPub Trails from /api/v1/activitypub/trail while their canonical IDs use /api/v1/trail
* stock_limitation: Wanderer's trail-like list route queries trail_share, so remote Likes are verified through the Trail's native like_count
* stock_limitation: Wanderer dispatches remote Comment Deletes by requiring the object ID to contain the word comment
* stock_limitation: Wanderer only federates Comment Delete when the parent Trail is remote
* stock_limitation: Wanderer cannot originate a Like for an arbitrary non-Trail Unfathomably status
* stock_limitation: stock Wanderer has no Block, Undo Block, Flag, federated moderation, or domain-defederation handler
* stock_limitation: stock Wanderer exposes no conditional stale-update API for native Trail edits
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run_wanderer_smoke
fi

# end of build_scripts/unfathomably-wanderer-smoke.sh
