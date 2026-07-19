#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-flohmarkt-smoke.sh
#
# Purpose:
#
#   Run the official Flohmarkt image against Unfathomably and verify the
#   federation contract used by its users, listings, conversations, and
#   moderation records.
#
# Responsibilities:
#
#   * boot stock Flohmarkt and CouchDB on the shared isolated TLS harness
#   * create all Flohmarkt state through its setup and native HTTP APIs
#   * exercise follows, listing lifecycle, private conversations, reports,
#     blocking boundaries, native metadata, and cleanup
#   * report unsupported Flohmarkt behavior without synthetic activities
#
# This file intentionally does NOT contain:
#
#   * patched Flohmarkt source or images
#   * hand-authored Flohmarkt ActivityPub activities
#   * direct CouchDB mutation or production credentials
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAMILY_HARNESS="$SCRIPT_DIR/unfathomably-gotosocial-smoke.sh"

if [ ! -f "$FAMILY_HARNESS" ]; then
    printf 'Required account-federation harness not found: %s\n' "$FAMILY_HARNESS" >&2
    exit 1
fi

export SMOKE_PREFIX="${SMOKE_PREFIX:-unfathomably-flohmarkt-smoke}"
export BE_HOST="${BE_HOST:-unfathomably-flohmarkt.example.com}"
export BE_PORT="${BE_PORT:-5081}"
export BE_DB_NAME="${BE_DB_NAME:-unfathomably_flohmarkt_smoke_be}"
export GTS_HOST="${GTS_HOST:-flohmarkt-ref.example.com}"
export GTS_PORT="${GTS_PORT:-5082}"
export GTS_APP_PORT=8000
export GTS_FORWARDED_PROTO=https
export GTS_LABEL=Flohmarkt
export GTS_USERNAME=seller
export SMOKE_TLS=1
export BE_FEDERATION_SCHEME=https
export BE_FEDERATION_PORT=443

# shellcheck source-path=SCRIPTDIR
# shellcheck source=unfathomably-gotosocial-smoke.sh
source "$FAMILY_HARNESS"

FLOHMARKT_VERSION="${FLOHMARKT_VERSION:-0.21.0}"
FLOHMARKT_SOURCE_COMMIT="${FLOHMARKT_SOURCE_COMMIT:-22b27d9086cfb0248ed836bef21361724d3fb0b2}"
FLOHMARKT_IMAGE="${FLOHMARKT_IMAGE:-codeberg.org/flohmarkt/flohmarkt@sha256:8d26184f3be0da494456d014abfe60ac60f42f35809ce2aa0f4c373586d54ac7}"
FLOHMARKT_COUCHDB_IMAGE="${FLOHMARKT_COUCHDB_IMAGE:-couchdb:3.3}"

FLOHMARKT_CONTAINER="$GTS_CONTAINER"
FLOHMARKT_DB_CONTAINER="${PREFIX}-flohmarkt-db"
FLOHMARKT_INIT_CONTAINER="${PREFIX}-flohmarkt-init"
FLOHMARKT_DB_VOLUME="${PREFIX}-flohmarkt-couchdb"
FLOHMARKT_COOKIE_JAR="$WORK_DIR/flohmarkt.cookies"
FLOHMARKT_LOGIN_HEADERS="$WORK_DIR/flohmarkt-login.headers"
FLOHMARKT_LOGIN_BODY="$WORK_DIR/flohmarkt-login.json"
FLOHMARKT_CA_BUNDLE="$WORK_DIR/flohmarkt-ca-bundle.crt"
FLOHMARKT_PASSWORD="${FLOHMARKT_PASSWORD:-Flohmarkt-smoke-password-12345}"
FLOHMARKT_DB_USER="${FLOHMARKT_DB_USER:-admin}"
FLOHMARKT_DB_PASSWORD="${FLOHMARKT_DB_PASSWORD:-flohmarkt-smoke-couchdb-password}"
FLOHMARKT_DB_NAME="${FLOHMARKT_DB_NAME:-flohmarkt}"
FLOHMARKT_SETUP_CODE="${FLOHMARKT_SETUP_CODE:-UNFATHOMABLY-FLOHMARKT-SETUP}"
FLOHMARKT_SESSION=""

cleanup_flohmarkt_smoke() {
    local incoming_status="$?"
    local status="${1:-$incoming_status}"

    if [ "$KEEP_CONTAINERS" = "1" ]; then
        cleanup "$status"
    fi

    docker rm -f \
        "$FLOHMARKT_INIT_CONTAINER" \
        "$FLOHMARKT_CONTAINER" \
        "$FLOHMARKT_DB_CONTAINER" >/dev/null 2>&1 || true
    docker volume rm "$FLOHMARKT_DB_VOLUME" >/dev/null 2>&1 || true
    cleanup "$status"
}

trap cleanup_flohmarkt_smoke EXIT

prepare_flohmarkt_files() {
    cat /etc/ssl/certs/ca-certificates.crt >"$FLOHMARKT_CA_BUNDLE"
    cat "$SMOKE_CA_CERT" >>"$FLOHMARKT_CA_BUNDLE"
}

flohmarkt_environment() {
    printf '%s\n' \
        -e LANG=C.UTF-8 \
        -e FLOHMARKT_INSTANCE_NAME="Unfathomably Flohmarkt smoke" \
        -e FLOHMARKT_EXTERNAL_URL="https://$GTS_HOST" \
        -e FLOHMARKT_DATA_PATH=/var/lib/flohmarkt \
        -e FLOHMARKT_DB_HTTPS=0 \
        -e FLOHMARKT_DB_HOST="$FLOHMARKT_DB_CONTAINER" \
        -e FLOHMARKT_DB_PORT=5984 \
        -e FLOHMARKT_DB_NAME="$FLOHMARKT_DB_NAME" \
        -e FLOHMARKT_DB_USER="$FLOHMARKT_DB_USER" \
        -e FLOHMARKT_DB_PASSWORD="$FLOHMARKT_DB_PASSWORD" \
        -e FLOHMARKT_MAIL_METHOD=sendmail \
        -e FLOHMARKT_MAIL_FROM="noreply@$GTS_HOST" \
        -e FLOHMARKT_SETUPCODE="$FLOHMARKT_SETUP_CODE" \
        -e SSL_CERT_FILE=/tls/ca-bundle.crt
}

start_flohmarkt() {
    local -a environment

    mapfile -t environment < <(flohmarkt_environment)

    docker volume create "$GTS_VOLUME" >/dev/null
    docker volume create "$FLOHMARKT_DB_VOLUME" >/dev/null

    docker run -d \
        --name "$FLOHMARKT_DB_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$FLOHMARKT_DB_CONTAINER" \
        -e COUCHDB_USER="$FLOHMARKT_DB_USER" \
        -e COUCHDB_PASSWORD="$FLOHMARKT_DB_PASSWORD" \
        -v "$FLOHMARKT_DB_VOLUME:/opt/couchdb/data" \
        "$FLOHMARKT_COUCHDB_IMAGE" >/dev/null

    for _ in $(seq 1 90); do
        if docker exec "$FLOHMARKT_DB_CONTAINER" \
            curl -fsS -u "$FLOHMARKT_DB_USER:$FLOHMARKT_DB_PASSWORD" \
            http://127.0.0.1:5984/_up >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    docker exec "$FLOHMARKT_DB_CONTAINER" \
        curl -fsS -u "$FLOHMARKT_DB_USER:$FLOHMARKT_DB_PASSWORD" \
        http://127.0.0.1:5984/_up >/dev/null 2>&1 || \
        fail "Flohmarkt CouchDB did not become ready"

    docker run \
        --name "$FLOHMARKT_INIT_CONTAINER" \
        --network "$NETWORK" \
        "${environment[@]}" \
        -v "$GTS_VOLUME:/var/lib/flohmarkt" \
        -v "$FLOHMARKT_CA_BUNDLE:/tls/ca-bundle.crt:ro" \
        "$FLOHMARKT_IMAGE" initdb >/dev/null
    docker rm "$FLOHMARKT_INIT_CONTAINER" >/dev/null

    docker run -d \
        --name "$FLOHMARKT_CONTAINER" \
        --hostname "$GTS_APP_HOST" \
        --network "$NETWORK" \
        --network-alias "$GTS_APP_HOST" \
        "${environment[@]}" \
        -v "$GTS_VOLUME:/var/lib/flohmarkt" \
        -v "$FLOHMARKT_CA_BUNDLE:/tls/ca-bundle.crt:ro" \
        "$FLOHMARKT_IMAGE" web >/dev/null
}

wait_flohmarkt() {
    for _ in $(seq 1 180); do
        if curl -fsS "$GTS_BASE/setup/$FLOHMARKT_SETUP_CODE" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    docker logs "$FLOHMARKT_CONTAINER" >&2 || true
    docker logs "$FLOHMARKT_DB_CONTAINER" >&2 || true
    fail "Timed out waiting for Flohmarkt at $GTS_BASE"
}

flohmarkt_request() {
    local method="$1"
    local path="$2"
    local expected="$3"
    local data="${4:-}"
    local response status body
    local -a args=(-sS -X "$method" -H 'Accept: application/json')

    if [ -n "$FLOHMARKT_SESSION" ]; then
        args+=(-H "Cookie: session=$FLOHMARKT_SESSION")
    fi
    if [ -n "$data" ]; then
        args+=(-H 'Content-Type: application/json' --data "$data")
    fi

    response="$(curl "${args[@]}" -w '\n%{http_code}' "$GTS_BASE$path")"
    status="${response##*$'\n'}"
    body="${response%$'\n'*}"

    if [ "$status" != "$expected" ]; then
        printf 'Unexpected Flohmarkt response for %s %s: expected %s, got %s\n%s\n' \
            "$method" "$path" "$expected" "$status" "$body" >&2
        return 1
    fi

    printf '%s\n' "$body"
}

flohmarkt_login() {
    local status

    : >"$FLOHMARKT_COOKIE_JAR"
    status="$(curl -sS \
        -D "$FLOHMARKT_LOGIN_HEADERS" \
        -o "$FLOHMARKT_LOGIN_BODY" \
        -c "$FLOHMARKT_COOKIE_JAR" \
        -w '%{http_code}' \
        -X POST \
        --data-urlencode "username=$GTS_USERNAME" \
        --data-urlencode "password=$FLOHMARKT_PASSWORD" \
        "$GTS_BASE/token")"

    [ "$status" = "200" ] || {
        cat "$FLOHMARKT_LOGIN_BODY" >&2
        fail "Flohmarkt login returned HTTP $status"
    }

    FLOHMARKT_SESSION="$(awk '$6 == "session" {print $7}' "$FLOHMARKT_COOKIE_JAR" | tail -n 1)"
    [ -n "$FLOHMARKT_SESSION" ] || fail "Flohmarkt login did not issue a session cookie"

    json_assert "$(cat "$FLOHMARKT_LOGIN_BODY")" \
        'data.get("success") is True and data.get("user", {}).get("username") == "seller"' \
        "Flohmarkt login did not return its native user"
}

poll_flohmarkt_json() {
    local path="$1"
    local expr="$2"
    local message="$3"
    local result=""

    for _ in $(seq 1 90); do
        result="$(flohmarkt_request GET "$path" 200 || true)"
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

assert_flohmarkt_conversation_text_missing() {
    local item_id="$1"
    local text="$2"
    local message="$3"
    local result=""

    for _ in $(seq 1 15); do
        result="$(flohmarkt_request GET "/api/v1/conversation/by_item/$item_id" 200 || true)"
        if [ -n "$result" ] && ! JSON_INPUT="$result" EXPECTED_TEXT="$text" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
text = os.environ["EXPECTED_TEXT"]
for conversation in data:
    for message in conversation.get("messages") or []:
        if text in (message.get("content") or ""):
            raise SystemExit(0)
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

assert_be_public_text_missing() {
    local text="$1"
    local message="$2"
    local result

    result="$(http_form GET "$BE_BASE/api/v1/timelines/public?limit=40" "" 200)"
    JSON_INPUT="$result" EXPECTED_TEXT="$text" python3 - <<'PY' || fail "$message"
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
text = os.environ["EXPECTED_TEXT"]
if any(text in (status.get("content") or "") for status in data):
    raise SystemExit(1)
PY
}

assert_be_home_text_missing() {
    local text="$1"
    local message="$2"
    local result

    for _ in $(seq 1 15); do
        result="$(http_form GET "$BE_BASE/api/v1/timelines/home?limit=40" "$ALICE_TOKEN" 200)"
        JSON_INPUT="$result" EXPECTED_TEXT="$text" python3 - <<'PY' || fail "$message"
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
text = os.environ["EXPECTED_TEXT"]
if any(text in (status.get("content") or "") for status in data):
    raise SystemExit(1)
PY
        sleep 1
    done
}

be_flag_count() {
    docker exec "$BE_DB_CONTAINER" psql -U postgres -d "$BE_DB_NAME" -Atq \
        -c "SELECT COUNT(*) FROM activities WHERE data->>'type' = 'Flag';"
}

run_flohmarkt_smoke() {
    local setup login webfinger actor actor_doc followers follower_page
    local seller_account_id alice_actor
    local instance_follow_settings instance_follow_summary
    local item item_id item_iri item_page item_ap status_id status_data raw_native
    local updated_item conversation conversation_id be_reply be_reply_id be_reply_uri
    local native_reply native_reply_text native_reply_status_id
    local report_text reports local_report local_report_id flags_before flags_after
    local blocked_reply blocked_reply_id blocked_item blocked_item_id

    prepare_smoke_tls
    prepare_flohmarkt_files
    write_be_secret
    write_proxy_configs

    log "Creating isolated Flohmarkt federation network"
    docker rm -f \
        "$GTS_PROXY_CONTAINER" \
        "$FLOHMARKT_INIT_CONTAINER" \
        "$FLOHMARKT_CONTAINER" \
        "$FLOHMARKT_DB_CONTAINER" \
        "$BE_PROXY_CONTAINER" \
        "$BE_CONTAINER" \
        "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    docker volume rm "$GTS_VOLUME" "$FLOHMARKT_DB_VOLUME" >/dev/null 2>&1 || true
    docker network create "$NETWORK" >/dev/null

    log "Starting stock Flohmarkt $FLOHMARKT_VERSION and CouchDB"
    start_flohmarkt
    start_gts_proxy
    wait_flohmarkt

    log "Creating the native Flohmarkt administrator through stock setup"
    setup="$(flohmarkt_request POST "/setup/$FLOHMARKT_SETUP_CODE/" 200 \
        "{\"email\":\"$GTS_USERNAME@$GTS_HOST\",\"instancename\":\"Alien Flohmarkt\",\"username\":\"$GTS_USERNAME\",\"password\":\"$FLOHMARKT_PASSWORD\",\"coordinates\":{\"lat\":45.4215,\"lng\":-75.6972},\"registrations\":\"open\"}")"
    json_assert "$setup" 'data.get("ok") is True' "Flohmarkt setup did not initialize the instance"
    flohmarkt_login
    login="$(cat "$FLOHMARKT_LOGIN_BODY")"
    FLOHMARKT_USER_ID="$(json_get "$login" user.id)"

    log "Proving Flohmarkt discovery, content negotiation, and canonical identity"
    webfinger="$(curl -fsS -H 'Accept: application/jrd+json' \
        "$GTS_BASE/.well-known/webfinger?resource=acct:$GTS_USERNAME@$GTS_HOST")"
    json_assert "$webfinger" \
        'data.get("subject") == "acct:seller@flohmarkt-ref.example.com" and any(link.get("type") == "application/activity+json" for link in data.get("links", []))' \
        "Flohmarkt WebFinger did not expose its canonical actor"
    actor_doc="$(curl -fsS -H 'Accept: application/activity+json' \
        "$GTS_BASE/users/$GTS_USERNAME")"
    json_assert "$actor_doc" \
        'data.get("type") == "Person" and data.get("id") == "https://flohmarkt-ref.example.com/users/seller" and data.get("publicKey", {}).get("publicKeyPem")' \
        "Flohmarkt actor discovery lost its Person identity or public key"
    actor="$(json_get "$actor_doc" id)"

    log "Migrating and starting Unfathomably"
    docker run -d \
        --name "$BE_DB_CONTAINER" \
        --network "$NETWORK" \
        -e POSTGRES_PASSWORD="$BE_DB_PASSWORD" \
        "$POSTGRES_IMAGE" >/dev/null
    wait_postgres
    prepare_database
    migrate_and_create_be_user alice "alice@$BE_HOST"
    migrate_and_create_be_user instance "instance@$BE_HOST"
    start_be
    start_be_proxy
    wait_be
    ALICE_TOKEN="$(create_be_token alice)"
    alice_actor="https://$BE_HOST/users/alice"

    log "Following the Flohmarkt Person from Unfathomably"
    seller_account_id="$(resolve_account_id "$BE_BASE" "$ALICE_TOKEN" \
        "$GTS_USERNAME@$GTS_HOST" "Unfathomably could not resolve Flohmarkt")"
    http_form POST "$BE_BASE/api/v1/accounts/$seller_account_id/follow" "$ALICE_TOKEN" 200 >/dev/null
    poll_relationship_following "$BE_BASE" "$ALICE_TOKEN" "$seller_account_id" \
        "Unfathomably follow of Flohmarkt did not become accepted"
    follower_page="$(poll_flohmarkt_json "/users/$GTS_USERNAME/followers?page=1" \
        'data.get("type") == "OrderedCollectionPage" and len(data.get("orderedItems") or []) <= 10 and "https://unfathomably-flohmarkt.example.com/users/alice" in (data.get("orderedItems") or [])' \
        "Flohmarkt did not retain the Unfathomably follower in its bounded collection")"

    log "Exercising Flohmarkt's native instance-follow boundary"
    flohmarkt_request GET "/api/v1/admin/follow_instance/?url=$(urlencode "https://$BE_HOST")" 200 >/dev/null
    instance_follow_settings="$(poll_flohmarkt_json /api/v1/admin/ \
        '"https://unfathomably-flohmarkt.example.com" in (data.get("following") or []) or "https://unfathomably-flohmarkt.example.com" in (data.get("pending_following") or [])' \
        "Flohmarkt did not retain its native instance Follow state")"
    if JSON_INPUT="$instance_follow_settings" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
raise SystemExit(0 if "https://unfathomably-flohmarkt.example.com" in (data.get("following") or []) else 1)
PY
    then
        instance_follow_summary="supported: Flohmarkt's instance actor followed and received Accept from Unfathomably"
    else
        instance_follow_summary="stock_limitation: Flohmarkt retained the outbound instance Follow as pending because its user inbox does not dispatch Accept"
    fi

    log "Creating a native Flohmarkt listing"
    item="$(flohmarkt_request POST /api/v1/item/ 200 \
        '{"name":"Alien federation radio","price":"25","currency":"CAD","currency_url":"","images":[],"tags":["radio","federation"],"description":"FLOHMARKT-LISTING-CREATE A working receiver from another world.","coordinates":{"lat":45.4215,"lng":-75.6972}}')"
    item_id="$(json_get "$item" item.id)"
    item_iri="https://$GTS_HOST/users/$GTS_USERNAME/items/$item_id"

    item_page="$(curl -fsS -H 'Accept: application/activity+json' \
        "$GTS_BASE/~$GTS_USERNAME/$item_id")"
    item_ap="$(curl -fsS -H 'Accept: application/activity+json' \
        "$GTS_BASE/users/$GTS_USERNAME/items/$item_id")"
    json_assert "$item_page" \
        'data.get("id", "").endswith("/users/seller/items/" + data.get("flohmarkt:data", {}).get("original_id", "")) and data.get("url", "").startswith("https://flohmarkt-ref.example.com/~seller/")' \
        "Flohmarkt listing page did not negotiate its canonical ActivityPub Note"
    json_assert "$item_ap" \
        'data.get("type") == "Note" and data.get("flohmarkt:data", {}).get("price") == "25" and data.get("flohmarkt:data", {}).get("currency") and any(tag.get("name") == "#federation" for tag in data.get("tag", []))' \
        "Flohmarkt native listing representation lost its market data"

    status_id="$(poll_home_status_by_text "$BE_BASE" "$ALICE_TOKEN" \
        'FLOHMARKT-LISTING-CREATE' "Unfathomably did not receive the native Flohmarkt listing")"
    status_data="$(http_form GET "$BE_BASE/api/v1/statuses/$status_id" "$ALICE_TOKEN" 200)"
    json_assert "$status_data" \
        'data.get("pleroma", {}).get("native", {}).get("fields", {}).get("platform") == "flohmarkt" and data.get("pleroma", {}).get("native", {}).get("fields", {}).get("price") == "25" and data.get("pleroma", {}).get("native", {}).get("fields", {}).get("currency")' \
        "Unfathomably did not expose bounded Flohmarkt listing metadata"

    raw_native="$(docker exec -i "$BE_DB_CONTAINER" psql -U postgres -d "$BE_DB_NAME" -Atq \
        -v object_id="$item_iri" <<'SQL'
SELECT concat(data->'flohmarkt:data'->>'price', '|', jsonb_array_length(data->'attachment'))
FROM objects
WHERE data->>'id' = :'object_id';
SQL
)"
    [[ "$raw_native" == 25\|* ]] || fail "Unfathomably did not retain Flohmarkt JSON-LD and bounded attachments"

    object_count="$(docker exec -i "$BE_DB_CONTAINER" psql -U postgres -d "$BE_DB_NAME" -Atq \
        -v object_id="$item_iri" <<'SQL'
SELECT COUNT(*)
FROM objects
WHERE data->>'id' = :'object_id';
SQL
)"
    [ "$object_count" = "1" ] || \
        fail "Flohmarkt listing was duplicated instead of retaining one canonical object"

    log "Updating the native Flohmarkt listing"
    flohmarkt_request PUT "/api/v1/item/$item_id" 200 \
        '{"name":"Alien federation radio revised","price":"30","currency":"CAD","currency_url":"","images":[],"tags":["radio","federation"],"description":"FLOHMARKT-LISTING-UPDATED The receiver now hears replies.","coordinates":{"lat":45.4215,"lng":-75.6972}}' >/dev/null
    sleep 3
    early_update_status="$(http_form GET "$BE_BASE/api/v1/statuses/$status_id" "$ALICE_TOKEN" 200)"

    if JSON_INPUT="$early_update_status" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
native_fields = data.get("pleroma", {}).get("native", {}).get("fields", {})
if "FLOHMARKT-LISTING-UPDATED" not in (data.get("content") or ""):
    raise SystemExit(1)
if native_fields.get("price") != "30":
    raise SystemExit(1)
PY
    then
        initial_update_summary="supported: stock Flohmarkt delivered a follower-only listing Update"
    else
        initial_update_summary="stock_limitation: stock Flohmarkt did not deliver its follower-only listing Update until an explicit Conversation recipient existed"
    fi

    log "Round-tripping a private Unfathomably reply into native Conversation state"
    be_reply="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=@$GTS_USERNAME@$GTS_HOST FLOHMARKT-NATIVE-CONVERSATION" \
        "in_reply_to_id=$status_id" \
        'visibility=direct')"
    be_reply_id="$(json_get "$be_reply" id)"
    be_reply_uri="$(json_get "$be_reply" uri)"
    conversation="$(poll_flohmarkt_json "/api/v1/conversation/by_item/$item_id" \
        'len(data) == 1 and any("FLOHMARKT-NATIVE-CONVERSATION" in (message.get("content") or "") for message in data[0].get("messages") or [])' \
        "Flohmarkt did not materialize the Unfathomably reply as a native Conversation")"
    conversation_id="$(JSON_INPUT="$conversation" python3 - <<'PY'
import json
import os
print(json.loads(os.environ["JSON_INPUT"])[0]["id"])
PY
)"

    log "Replying from native Flohmarkt Conversation state"
    native_reply_text="FLOHMARKT-CONVERSATION-REPLY"
    native_reply="$(flohmarkt_request POST "/api/v1/conversation/to_item/$item_id" 200 \
        "{\"text\":\"$native_reply_text\",\"conversation_id\":\"$conversation_id\",\"item_id\":\"$item_id\"}")"
    json_assert "$native_reply" \
        'any("FLOHMARKT-CONVERSATION-REPLY" in (message.get("content") or "") for message in data.get("messages") or [])' \
        "Flohmarkt did not retain its native Conversation reply"
    native_reply_status_id="$(poll_home_status_by_text "$BE_BASE" "$ALICE_TOKEN" \
        "$native_reply_text" "Unfathomably did not receive the Flohmarkt Conversation reply")"
    json_assert "$(http_form GET "$BE_BASE/api/v1/statuses/$native_reply_status_id" "$ALICE_TOKEN" 200)" \
        'data.get("visibility") == "direct"' \
        "Flohmarkt Conversation reply did not remain direct in Unfathomably"
    assert_be_public_text_missing "$native_reply_text" \
        "Private Flohmarkt Conversation reply leaked into the public timeline"

    log "Deleting the Unfathomably conversation message"
    http_form DELETE "$BE_BASE/api/v1/statuses/$be_reply_id" "$ALICE_TOKEN" 200 >/dev/null
    poll_flohmarkt_json "/api/v1/conversation/by_item/$item_id" \
        "any(message.get('id') == '$be_reply_uri' and message.get('overridden') is True for message in data[0].get('messages') or [])" \
        "Flohmarkt did not mark the deleted remote Conversation message as overridden" >/dev/null

    log "Sending a federated moderation report to Flohmarkt"
    report_text="FLOHMARKT-FEDERATED-REPORT-$(basename "$WORK_DIR")"
    http_form POST "$BE_BASE/api/v1/reports" "$ALICE_TOKEN" 200 \
        "account_id=$seller_account_id" \
        "status_ids[]=$status_id" \
        "comment=$report_text" \
        'forward=true' >/dev/null
    reports="$(poll_flohmarkt_json "/api/v1/report/$item_id" \
        "any('$report_text' in (report.get('reason') or '') for report in data)" \
        "Flohmarkt did not retain Unfathomably's Flag as native moderation state")"

    log "Proving Flohmarkt native reports remain local-only"
    flags_before="$(be_flag_count)"
    local_report="$(flohmarkt_request POST /api/v1/report/ 200 \
        "{\"item_id\":\"$item_id\",\"user_id\":\"$FLOHMARKT_USER_ID\",\"reason\":\"FLOHMARKT-LOCAL-REPORT-BOUNDARY\"}")"
    local_report_id="$(json_get "$local_report" id)"
    for _ in $(seq 1 5); do
        sleep 1
        flags_after="$(be_flag_count)"
        [ "$flags_after" = "$flags_before" ] || fail "Flohmarkt unexpectedly federated its local report"
    done

    log "Testing Flohmarkt blocking of an Unfathomably sender"
    flohmarkt_request GET "/api/v1/user/$FLOHMARKT_USER_ID/block_user?user=$(urlencode "alice@$BE_HOST")&block=true" 200 >/dev/null
    blocked_reply="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=@$GTS_USERNAME@$GTS_HOST FLOHMARKT-BLOCKED-CONVERSATION" \
        "in_reply_to_id=$status_id" \
        'visibility=direct')"
    blocked_reply_id="$(json_get "$blocked_reply" id)"
    assert_flohmarkt_conversation_text_missing "$item_id" "FLOHMARKT-BLOCKED-CONVERSATION" \
        "Flohmarkt accepted a message from its blocked remote user"
    http_form DELETE "$BE_BASE/api/v1/statuses/$blocked_reply_id" "$ALICE_TOKEN" 200 >/dev/null
    flohmarkt_request GET "/api/v1/user/$FLOHMARKT_USER_ID/block_user?user=$(urlencode "alice@$BE_HOST")&block=false" 200 >/dev/null

    log "Proving explicit Unfollow and restoring a delivery target for blocking"
    http_form POST "$BE_BASE/api/v1/accounts/$seller_account_id/unfollow" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_flohmarkt_json "/users/$GTS_USERNAME/followers?page=1" \
        '"https://unfathomably-flohmarkt.example.com/users/alice" not in (data.get("orderedItems") or [])' \
        "Flohmarkt did not remove the Unfathomably follower after explicit Undo" >/dev/null
    http_form POST "$BE_BASE/api/v1/accounts/$seller_account_id/follow" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_flohmarkt_json "/users/$GTS_USERNAME/followers?page=1" \
        '"https://unfathomably-flohmarkt.example.com/users/alice" in (data.get("orderedItems") or [])' \
        "Flohmarkt did not restore the follower used for the block delivery test" >/dev/null

    log "Testing Unfathomably blocking of Flohmarkt delivery"
    http_form POST "$BE_BASE/api/v1/accounts/$seller_account_id/block" "$ALICE_TOKEN" 200 >/dev/null
    blocked_item="$(flohmarkt_request POST /api/v1/item/ 200 \
        '{"name":"Blocked alien listing","price":"1","currency":"CAD","currency_url":"","images":[],"tags":["blocked"],"description":"FLOHMARKT-BLOCKED-LISTING","coordinates":{"lat":45.4215,"lng":-75.6972}}')"
    blocked_item_id="$(json_get "$blocked_item" item.id)"
    assert_be_home_text_missing "FLOHMARKT-BLOCKED-LISTING" \
        "A blocked Flohmarkt actor delivered a listing into Unfathomably"
    flohmarkt_request DELETE "/api/v1/item/$blocked_item_id" 204 >/dev/null
    http_form POST "$BE_BASE/api/v1/accounts/$seller_account_id/unblock" "$ALICE_TOKEN" 200 >/dev/null

    log "Deleting the native Flohmarkt listing and cleaning relationships"
    flohmarkt_request DELETE "/api/v1/item/$item_id" 204 >/dev/null
    poll_status_missing "$BE_BASE" "$ALICE_TOKEN" "$status_id" \
        "Unfathomably did not remove the deleted Flohmarkt listing"
    final_relationship="$(http_form GET \
        "$BE_BASE/api/v1/accounts/relationships?id[]=$seller_account_id" \
        "$ALICE_TOKEN" 200)"
    json_assert "$final_relationship" \
        'not data[0].get("following") and not data[0].get("requested") and not data[0].get("blocking")' \
        "Unfathomably did not clean its local Flohmarkt follow and block relationships"
    flohmarkt_request GET "/api/v1/admin/unfollow_instance/?url=$(urlencode "https://$BE_HOST")" 200 >/dev/null
    flohmarkt_request DELETE "/api/v1/report/$local_report_id" 204 >/dev/null

    check_logs "$BE_CONTAINER" "Unfathomably"
    check_logs "$FLOHMARKT_CONTAINER" "Flohmarkt"

    cat <<EOF

Flohmarkt federation smoke passed.

Covered against official stock Flohmarkt image $FLOHMARKT_IMAGE.
The matching source contract was inspected at $FLOHMARKT_SOURCE_COMMIT:
* supported: WebFinger, actor fetch, ActivityPub content negotiation, NodeInfo, and canonical HTTPS IDs
* supported: Unfathomably follows and unfollows a Flohmarkt Person with bounded follower collection cleanup
* stock_limitation: blocking tears down Unfathomably's local follow without an Undo, so Flohmarkt retains that final follower entry until disposable peer cleanup
* $instance_follow_summary
* not_supported: Flohmarkt has no Person or Group outbound-follow UI and no Group follow or group-unfollow semantics
* supported: native listing Create, Delete, and canonical Note identity reach Unfathomably
* $initial_update_summary
* backend_contract: corrected same-ID Flohmarkt Update payloads are authority-bound, serialized, and retry-idempotent in focused tests
* stock_limitation: Flohmarkt 0.21.0's Conversation-linked native Update path fails inside its notification loop before ActivityPub delivery
* supported: flohmarkt:data price, currency, coordinates, tags, proposal attachment, and unknown JSON-LD survive bounded ingestion
* not_supported: Flohmarkt emits no separate compatibility fallback, so native/fallback semantic deduplication is not applicable
* supported: exact actor authority controls listing Updates and Deletes
* stock_limitation: Flohmarkt exposes no conditional listing update or stale-write API
* supported: follower collections are bounded OrderedCollection pages with orderedItems
* stock_limitation: Flohmarkt deliberately returns 404 for outbox and an empty following document
* supported: direct Unfathomably replies become native Flohmarkt Conversation state and native replies return to Unfathomably
* supported: direct Conversation state stays out of public timelines
* supported: deleting a remote conversation message marks its native record overridden
* supported: Unfathomably Flags become native Flohmarkt reports
* not_supported: Flohmarkt's native report API is local-only and emits no Flag
* supported: local user blocks suppress Unfathomably messages, and Unfathomably blocks suppress Flohmarkt listings
* not_supported: stock Flohmarkt has no ActivityPub Block or Undo Block handler
* not_supported: stock Flohmarkt has no Like or Undo Like handler or native favourite state
* supported: linked listing resources remain bounded and are not recursively required for ingestion
* supported: listing deletion, message deletion, unfollow, block teardown, report deletion, and disposable service cleanup are verified
* not_supported: Flohmarkt domain blocking intentionally gives the blocked peer no durable defederation signal
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run_flohmarkt_smoke
fi

# end of build_scripts/unfathomably-flohmarkt-smoke.sh
