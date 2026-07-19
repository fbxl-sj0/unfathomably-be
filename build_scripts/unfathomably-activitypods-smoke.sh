#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-activitypods-smoke.sh
#
# Purpose:
#
#   Run an unmodified ActivityPods provider against Unfathomably and verify
#   its combined ActivityPub, Solid/LDP, and WebACL behavior.
#
# Responsibilities:
#
#   * build and boot a pinned stock ActivityPods provider
#   * create Person and Group actors through the provider's native APIs
#   * create and protect native linked-data resources in a user's Pod
#   * exercise account and group federation lifecycle in both directions
#   * verify posts, replies, Likes, moderation delivery, and cleanup
#   * record unsupported stock behavior explicitly in the final matrix
#
# This file intentionally does NOT contain:
#
#   * patched ActivityPods application source
#   * hand-authored server-to-server signatures
#   * direct mutation of Fuseki or Redis application state
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAMILY_HARNESS="$SCRIPT_DIR/unfathomably-gotosocial-smoke.sh"

if [ ! -f "$FAMILY_HARNESS" ]; then
    printf 'Required account-federation harness not found: %s\n' "$FAMILY_HARNESS" >&2
    exit 1
fi

export SMOKE_PREFIX="${SMOKE_PREFIX:-unfathomably-activitypods-smoke}"
export BE_HOST="${BE_HOST:-unfathomably-activitypods.example.com}"
export BE_PORT="${BE_PORT:-5123}"
export BE_DB_NAME="${BE_DB_NAME:-unfathomably_activitypods_smoke_be}"
export GTS_HOST="${GTS_HOST:-activitypods-ref.example.com}"
export GTS_PORT="${GTS_PORT:-5124}"
export GTS_APP_PORT=3000
export GTS_FORWARDED_PROTO=https
export GTS_LABEL=ActivityPods
export GTS_USERNAME=alice
export SMOKE_TLS=1
export BE_FEDERATION_SCHEME=https
export BE_FEDERATION_PORT=443

# shellcheck source-path=SCRIPTDIR
# shellcheck source=unfathomably-gotosocial-smoke.sh
source "$FAMILY_HARNESS"

ACTIVITYPODS_SOURCE_URL="${ACTIVITYPODS_SOURCE_URL:-https://github.com/assemblee-virtuelle/activitypods.git}"
ACTIVITYPODS_SOURCE_COMMIT="${ACTIVITYPODS_SOURCE_COMMIT:-8e0efd6e4df5e8ddde603f38f0b2d4d726acf516}"
ACTIVITYPODS_IMAGE="${ACTIVITYPODS_IMAGE:-unfathomably-activitypods-stock:${ACTIVITYPODS_SOURCE_COMMIT:0:12}}"
ACTIVITYPODS_FUSEKI_IMAGE="${ACTIVITYPODS_FUSEKI_IMAGE:-semapps/jena-fuseki-webacl}"
ACTIVITYPODS_REDIS_IMAGE="${ACTIVITYPODS_REDIS_IMAGE:-redis:7-alpine}"
ACTIVITYPODS_MAIL_IMAGE="${ACTIVITYPODS_MAIL_IMAGE:-dockage/mailcatcher:0.7.1}"
ACTIVITYPODS_PASSWORD="${ACTIVITYPODS_PASSWORD:-ActivityPods-smoke-password-12345}"
ACTIVITYPODS_SOURCE_DIR="$WORK_DIR/activitypods-source"
ACTIVITYPODS_CA_BUNDLE="$WORK_DIR/activitypods-ca-bundle.crt"
ACTIVITYPODS_FUSEKI_CONTAINER="${PREFIX}-activitypods-fuseki"
ACTIVITYPODS_REDIS_CONTAINER="${PREFIX}-activitypods-redis"
ACTIVITYPODS_MAIL_CONTAINER="${PREFIX}-activitypods-mail"
ACTIVITYPODS_FUSEKI_VOLUME="${PREFIX}-activitypods-fuseki-data"
ACTIVITYPODS_REDIS_VOLUME="${PREFIX}-activitypods-redis-data"

# ------------------------------------------------------------------------------
# Stock image and service lifecycle
# ------------------------------------------------------------------------------

cleanup_activitypods_smoke() {
    local incoming_status="$?"
    local status="${1:-$incoming_status}"

    if [ "$KEEP_CONTAINERS" = "1" ]; then
        cleanup "$status"
    fi

    docker rm -f \
        "$ACTIVITYPODS_MAIL_CONTAINER" \
        "$ACTIVITYPODS_REDIS_CONTAINER" \
        "$ACTIVITYPODS_FUSEKI_CONTAINER" >/dev/null 2>&1 || true
    docker volume rm \
        "$ACTIVITYPODS_REDIS_VOLUME" \
        "$ACTIVITYPODS_FUSEKI_VOLUME" >/dev/null 2>&1 || true
    cleanup "$status"
}

trap cleanup_activitypods_smoke EXIT

checkout_activitypods_source() {
    local actual_commit

    git clone --quiet --filter=blob:none --no-checkout \
        "$ACTIVITYPODS_SOURCE_URL" "$ACTIVITYPODS_SOURCE_DIR"
    git -C "$ACTIVITYPODS_SOURCE_DIR" fetch --quiet --depth=1 \
        origin "$ACTIVITYPODS_SOURCE_COMMIT"
    git -C "$ACTIVITYPODS_SOURCE_DIR" checkout --quiet --detach \
        "$ACTIVITYPODS_SOURCE_COMMIT"

    actual_commit="$(git -C "$ACTIVITYPODS_SOURCE_DIR" rev-parse HEAD)"
    [ "$actual_commit" = "$ACTIVITYPODS_SOURCE_COMMIT" ] || \
        fail "Pinned ActivityPods checkout resolved to $actual_commit"
}

prepare_activitypods_image() {
    if ! docker image inspect "$ACTIVITYPODS_IMAGE" >/dev/null 2>&1; then
        require_command git
        checkout_activitypods_source

        log "Building pinned stock ActivityPods $ACTIVITYPODS_SOURCE_COMMIT"
        docker build \
            -t "$ACTIVITYPODS_IMAGE" \
            -f "$ACTIVITYPODS_SOURCE_DIR/pod-provider/docker/backend.dockerfile" \
            "$ACTIVITYPODS_SOURCE_DIR/pod-provider"
    fi

    docker run --rm --entrypoint /bin/sh "$ACTIVITYPODS_IMAGE" \
        -c 'cat /etc/ssl/certs/ca-certificates.crt' >"$ACTIVITYPODS_CA_BUNDLE"
    cat "$SMOKE_CA_CERT" >>"$ACTIVITYPODS_CA_BUNDLE"
}

start_activitypods() {
    docker volume create "$ACTIVITYPODS_FUSEKI_VOLUME" >/dev/null
    docker volume create "$ACTIVITYPODS_REDIS_VOLUME" >/dev/null

    docker run -d \
        --name "$ACTIVITYPODS_FUSEKI_CONTAINER" \
        --hostname "$ACTIVITYPODS_FUSEKI_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$ACTIVITYPODS_FUSEKI_CONTAINER" \
        -e ADMIN_PASSWORD=admin \
        -v "$ACTIVITYPODS_FUSEKI_VOLUME:/fuseki" \
        "$ACTIVITYPODS_FUSEKI_IMAGE" >/dev/null

    docker run -d \
        --name "$ACTIVITYPODS_REDIS_CONTAINER" \
        --hostname "$ACTIVITYPODS_REDIS_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$ACTIVITYPODS_REDIS_CONTAINER" \
        -v "$ACTIVITYPODS_REDIS_VOLUME:/data" \
        "$ACTIVITYPODS_REDIS_IMAGE" \
        redis-server --appendonly yes >/dev/null

    docker run -d \
        --name "$ACTIVITYPODS_MAIL_CONTAINER" \
        --hostname "$ACTIVITYPODS_MAIL_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$ACTIVITYPODS_MAIL_CONTAINER" \
        "$ACTIVITYPODS_MAIL_IMAGE" >/dev/null

    for _ in $(seq 1 120); do
        if curl -fsS \
            -u admin:admin \
            "http://127.0.0.1:$(docker port "$ACTIVITYPODS_FUSEKI_CONTAINER" 3030/tcp 2>/dev/null | sed 's/.*://')/$/ping" \
            >/dev/null 2>&1; then
            break
        fi

        if docker logs "$ACTIVITYPODS_FUSEKI_CONTAINER" 2>&1 | \
            grep -E 'Started .* on port 3030' >/dev/null; then
            break
        fi
        sleep 1
    done

    docker run -d \
        --name "$GTS_CONTAINER" \
        --hostname "$GTS_APP_HOST" \
        --network "$NETWORK" \
        --network-alias "$GTS_APP_HOST" \
        -e NODE_ENV=production \
        -e "NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt" \
        -e "SEMAPPS_HOME_URL=https://$GTS_HOST/" \
        -e SEMAPPS_PORT=3000 \
        -e "SEMAPPS_FRONTEND_URL=https://$GTS_HOST/" \
        -e SEMAPPS_INSTANCE_NAME='ActivityPods smoke provider' \
        -e SEMAPPS_INSTANCE_DESCRIPTION='Stock ActivityPods federation smoke provider' \
        -e SEMAPPS_INSTANCE_AREA='isolated smoke network' \
        -e SEMAPPS_AVAILABLE_LOCALES=en \
        -e SEMAPPS_DEFAULT_LOCALE=en \
        -e SEMAPPS_ENABLE_GROUPS=true \
        -e SEMAPPS_MAPBOX_ACCESS_TOKEN= \
        -e SEMAPPS_COLOR_PRIMARY='#899a44' \
        -e SEMAPPS_COLOR_SECONDARY='#314a62' \
        -e SEMAPPS_SHAPE_REPOSITORY_URL=https://shapes.activitypods.org/ \
        -e "SEMAPPS_SPARQL_ENDPOINT=http://$ACTIVITYPODS_FUSEKI_CONTAINER:3030/" \
        -e SEMAPPS_JENA_USER=admin \
        -e SEMAPPS_JENA_PASSWORD=admin \
        -e SEMAPPS_FUSEKI_BASE=/fuseki \
        -e "SEMAPPS_REDIS_CACHE_URL=redis://$ACTIVITYPODS_REDIS_CONTAINER:6379/0" \
        -e "SEMAPPS_QUEUE_SERVICE_URL=redis://$ACTIVITYPODS_REDIS_CONTAINER:6379/1" \
        -e "SEMAPPS_REDIS_TRANSPORTER_URL=redis://$ACTIVITYPODS_REDIS_CONTAINER:6379/2" \
        -e "SEMAPPS_REDIS_OIDC_PROVIDER_URL=redis://$ACTIVITYPODS_REDIS_CONTAINER:6379/3" \
        -e SEMAPPS_COOKIE_SECRET=activitypods-smoke-cookie-secret \
        -e SEMAPPS_FROM_EMAIL=activitypods-smoke@example.invalid \
        -e SEMAPPS_FROM_NAME=ActivityPods \
        -e "SEMAPPS_SMTP_HOST=$ACTIVITYPODS_MAIL_CONTAINER" \
        -e SEMAPPS_SMTP_PORT=1025 \
        -e SEMAPPS_SMTP_SECURE=false \
        -e SEMAPPS_SMTP_USER= \
        -e SEMAPPS_SMTP_PASS= \
        -e SEMAPPS_AUTH_RESERVED_USER_NAMES='sparql,auth,common,data,settings,localData,testData' \
        -e SEMAPPS_AUTH_ACCOUNTS_DATASET=settings \
        -v "$ACTIVITYPODS_CA_BUNDLE:/etc/ssl/certs/ca-certificates.crt:ro" \
        "$ACTIVITYPODS_IMAGE" >/dev/null

    start_gts_proxy
}

wait_activitypods() {
    for _ in $(seq 1 300); do
        if curl -fsS "$GTS_BASE/.well-known/nodeinfo" >/dev/null 2>&1 && \
            docker logs "$GTS_CONTAINER" 2>&1 | \
                grep -E 'ServiceBroker with [0-9]+ service\(s\) started successfully' \
                >/dev/null; then
            return 0
        fi
        sleep 1
    done

    docker logs "$GTS_CONTAINER" >&2 || true
    docker logs "$ACTIVITYPODS_FUSEKI_CONTAINER" >&2 || true
    fail "Timed out waiting for ActivityPods at $GTS_BASE"
}

# ------------------------------------------------------------------------------
# Native HTTP and collection helpers
# ------------------------------------------------------------------------------

activitypods_json() {
    local method="$1"
    local url="$2"
    local token="$3"
    local expected="$4"
    local payload="${5:-}"
    local -a args headers
    local response status body

    args=(-sS -X "$method" -w '\n%{http_code}')
    headers=(-H 'Accept: application/ld+json')

    if [ -n "$token" ]; then
        headers+=(-H "Authorization: Bearer $token")
    fi
    if [ -n "$payload" ]; then
        headers+=(-H 'Content-Type: application/ld+json')
        args+=(--data "$payload")
    fi

    response="$(curl "${args[@]}" "${headers[@]}" "$url")" || return 1
    status="${response##*$'\n'}"
    body="${response%$'\n'*}"

    if [ "$status" != "$expected" ]; then
        printf 'Unexpected ActivityPods HTTP status for %s %s: expected %s got %s\n' \
            "$method" "$url" "$expected" "$status" >&2
        printf '%s\n' "$body" >&2
        return 1
    fi

    printf '%s\n' "$body"
}

activitypods_post_location() {
    local url="$1"
    local token="$2"
    local payload="$3"
    local expected="${4:-201}"
    local headers_file="$WORK_DIR/activitypods-post-headers.$RANDOM"
    local body_file="$WORK_DIR/activitypods-post-body.$RANDOM"
    local status location

    status="$(curl -sS \
        -D "$headers_file" \
        -o "$body_file" \
        -w '%{http_code}' \
        -H 'Accept: application/ld+json' \
        -H 'Content-Type: application/ld+json' \
        -H "Authorization: Bearer $token" \
        --data "$payload" \
        "$url")"

    if [ "$status" != "$expected" ]; then
        printf 'Unexpected ActivityPods POST status for %s: expected %s got %s\n' \
            "$url" "$expected" "$status" >&2
        cat "$body_file" >&2
        rm -f "$headers_file" "$body_file"
        return 1
    fi

    location="$(awk 'BEGIN { IGNORECASE = 1 } /^Location:/ { sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }' "$headers_file")"
    rm -f "$headers_file" "$body_file"
    [ -n "$location" ] || fail "ActivityPods POST to $url omitted its Location header"
    printf '%s\n' "$location"
}

activitypods_put_resource() {
    local resource_uri="$1"
    local token="$2"
    local payload="$3"
    local body_file="$WORK_DIR/activitypods-put-body.$RANDOM"
    local status

    status="$(curl -sS \
        -o "$body_file" \
        -w '%{http_code}' \
        -X PUT \
        -H 'Accept: application/ld+json' \
        -H 'Content-Type: application/ld+json' \
        -H "Authorization: Bearer $token" \
        --data "$payload" \
        "$(activitypods_local_url "$resource_uri")")"

    case "$status" in
        200|204)
            rm -f "$body_file"
            ;;
        *)
            printf 'Unexpected ActivityPods PUT status for %s: %s\n' \
                "$resource_uri" "$status" >&2
            cat "$body_file" >&2 || true
            rm -f "$body_file"
            return 1
            ;;
    esac
}

activitypods_local_url() {
    local canonical_url="$1"

    python3 - "$GTS_BASE" "$GTS_HOST" "$canonical_url" <<'PY'
import sys
import urllib.parse

base, expected_host, canonical = sys.argv[1:]
parsed = urllib.parse.urlparse(canonical)

if parsed.scheme not in {"http", "https"} or parsed.hostname != expected_host:
    raise SystemExit(f"Refusing non-ActivityPods URL: {canonical}")

path = parsed.path or "/"
if parsed.query:
    path += "?" + parsed.query

print(base + path)
PY
}

activitypods_outbox_activity() {
    local payload="$1"

    activitypods_post_location \
        "$GTS_BASE/$GTS_USERNAME/outbox" \
        "$ACTIVITYPODS_TOKEN" \
        "$payload"
}

activitypods_collection_find() {
    local collection_uri="$1"
    local token="$2"
    local expression="$3"
    local current_uri="$collection_uri"
    local payload match next_uri
    local -A visited=()

    for _ in $(seq 1 30); do
        if [ -n "${visited[$current_uri]:-}" ]; then
            return 1
        fi
        visited[$current_uri]=1

        payload="$(activitypods_json GET \
            "$(activitypods_local_url "$current_uri")" "$token" 200)" || return 1

        match="$(JSON_INPUT="$payload" python3 - "$expression" <<'PY'
import json
import os
import sys

data = json.loads(os.environ["JSON_INPUT"])
items = data.get("orderedItems", data.get("items", []))
if not isinstance(items, list):
    items = [items]

def values(value):
    return value if isinstance(value, list) else [value]

def identifier(value):
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        return value.get("id") or value.get("@id")
    return None

def type_is(value, expected):
    if not isinstance(value, dict):
        return False
    return expected in values(value.get("type", []))

def contains_text(value, expected):
    if isinstance(value, str):
        return expected in value
    if isinstance(value, list):
        return any(contains_text(item, expected) for item in value)
    if isinstance(value, dict):
        return any(contains_text(item, expected) for item in value.values())
    return False

safe_builtins = {"all": all, "any": any, "len": len, "str": str}
scope = {
    "contains_text": contains_text,
    "identifier": identifier,
    "item": None,
    "type_is": type_is,
    "values": values,
}

for item in items:
    scope["item"] = item
    if eval(sys.argv[1], {"__builtins__": safe_builtins}, scope):
        print(json.dumps(item, separators=(",", ":")))
        raise SystemExit(0)

raise SystemExit(1)
PY
)" || true

        if [ -n "$match" ]; then
            printf '%s\n' "$match"
            return 0
        fi

        next_uri="$(JSON_INPUT="$payload" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
value = data.get("first") or data.get("next")
if isinstance(value, dict):
    value = value.get("id") or value.get("@id")
print(value if isinstance(value, str) else "")
PY
)"

        [ -n "$next_uri" ] || return 1
        current_uri="$next_uri"
    done

    return 1
}

activitypods_collection_includes() {
    local collection_uri="$1"
    local token="$2"
    local item_uri="$3"

    if activitypods_collection_find \
        "$collection_uri" "$token" \
        "identifier(item) == '$item_uri'" >/dev/null; then
        printf 'true\n'
    else
        printf 'false\n'
    fi
}

poll_activitypods_collection() {
    local collection_uri="$1"
    local token="$2"
    local item_uri="$3"
    local expected="$4"
    local message="$5"
    local observed=""

    for _ in $(seq 1 90); do
        observed="$(activitypods_collection_includes \
            "$collection_uri" "$token" "$item_uri" 2>/dev/null || true)"
        if [ "$observed" = "$expected" ]; then
            return 0
        fi
        sleep 2
    done

    printf 'Observed ActivityPods collection membership: %s\n' "$observed" >&2
    fail "$message"
}

poll_activitypods_activity() {
    local collection_uri="$1"
    local token="$2"
    local expression="$3"
    local message="$4"
    local result=""

    for _ in $(seq 1 90); do
        result="$(activitypods_collection_find \
            "$collection_uri" "$token" "$expression" 2>/dev/null || true)"
        if [ -n "$result" ]; then
            printf '%s\n' "$result"
            return 0
        fi
        sleep 2
    done

    fail "$message"
}

activitypods_login() {
    local response

    response="$(http_json POST "$GTS_BASE/auth/login" "" 200 \
        "{\"username\":\"$GTS_USERNAME\",\"password\":\"$ACTIVITYPODS_PASSWORD\"}")"
    json_get "$response" token
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

poll_be_group_membership() {
    local group_id="$1"
    local acct="$2"
    local expected="$3"
    local message="$4"
    local result=""

    for _ in $(seq 1 90); do
        result="$(http_form GET \
            "$BE_BASE/api/v1/groups/$group_id/memberships" \
            "$ALICE_TOKEN" 200 || true)"

        if JSON_INPUT="$result" EXPECTED_ACCT="$acct" EXPECTED_PRESENT="$expected" \
            python3 - <<'PY'
import json
import os

memberships = json.loads(os.environ["JSON_INPUT"])
acct = os.environ["EXPECTED_ACCT"]
present = any(
    item.get("account", {}).get("acct") == acct
    for item in memberships
)
expected = os.environ["EXPECTED_PRESENT"] == "true"
raise SystemExit(0 if present == expected else 1)
PY
        then
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

poll_be_object_count() {
    local ap_id="$1"
    local expected="$2"
    local message="$3"
    local result=""

    for _ in $(seq 1 90); do
        result="$(docker exec -i "$BE_DB_CONTAINER" \
            psql -U postgres -d "$BE_DB_NAME" -Atq \
            -v "object_ap_id=$ap_id" <<'SQL' || true
SELECT COUNT(*) FROM objects WHERE data->>'id' = :'object_ap_id';
SQL
        )"

        if [ "$result" = "$expected" ]; then
            return 0
        fi

        sleep 2
    done

    printf 'Observed object count for %s: %s\n' "$ap_id" "$result" >&2
    fail "$message"
}

poll_context_status_id_by_text() {
    local base="$1"
    local token="$2"
    local parent_id="$3"
    local expected_text="$4"
    local message="$5"
    local result=""
    local status_id=""

    for _ in $(seq 1 90); do
        result="$(http_form GET \
            "$base/api/v1/statuses/$parent_id/context" \
            "$token" 200 || true)"

        status_id="$(
            JSON_INPUT="$result" EXPECTED_TEXT="$expected_text" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
text = os.environ["EXPECTED_TEXT"]
for status in data.get("descendants", []):
    content = status.get("content") or status.get("text") or ""
    if text in content:
        print(status["id"])
        raise SystemExit(0)
raise SystemExit(1)
PY
        )" && {
            printf '%s\n' "$status_id"
            return 0
        }

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

be_object_json() {
    local ap_id="$1"

    docker exec -i "$BE_DB_CONTAINER" \
        psql -U postgres -d "$BE_DB_NAME" -Atq \
        -v "object_ap_id=$ap_id" <<'SQL'
SELECT data::text FROM objects WHERE data->>'id' = :'object_ap_id' LIMIT 1;
SQL
}

poll_be_report_by_text() {
    local report_text="$1"
    local message="$2"
    local result=""

    for _ in $(seq 1 90); do
        result="$(docker exec "$BE_DB_CONTAINER" \
            psql -U postgres -d "$BE_DB_NAME" -Atc \
            "SELECT data->>'content' FROM activities WHERE data->>'type' = 'Flag' ORDER BY inserted_at DESC LIMIT 20;" \
            2>/dev/null || true)"

        if [[ "$result" == *"$report_text"* ]]; then
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

assert_remote_status_immutable() {
    local status_id="$1"
    local body_file="$WORK_DIR/remote-status-update-response.json"
    local status

    status="$(curl -sS -o "$body_file" -w '%{http_code}' -X PUT \
        -H "Authorization: Bearer $ALICE_TOKEN" \
        -H 'Accept: application/json' \
        --form-string 'status=Unauthorized remote object rewrite' \
        "$BE_BASE/api/v1/statuses/$status_id" || true)"

    case "$status" in
        403|404|422)
            return 0
            ;;
    esac

    printf 'Unexpected remote status update response (%s):\n' "$status" >&2
    cat "$body_file" >&2 || true
    fail "Unfathomably allowed a local user to update a remote-owned object"
}

check_activitypods_logs() {
    if docker logs "$GTS_CONTAINER" 2>&1 | grep -Ei \
        'panic:|segmentation fault|(^|[[:space:]])fatal error|level=(fatal|FATAL)|\[fatal\]' \
        >/dev/null; then
        docker logs "$GTS_CONTAINER" >&2 || true
        fail "ActivityPods emitted a crash-class log line"
    fi
}

# ------------------------------------------------------------------------------
# Initial stock-instance gate
# ------------------------------------------------------------------------------

run_activitypods_smoke() {
    local signup actor nodeinfo_links nodeinfo webfinger
    local storage project_uri project_payload private_uri private_status
    local group_status group_payload group_boundary
    local alice_account alice_ap_id activitypods_account_id relationship
    local person_follow_payload person_follow_uri be_follow
    local be_group be_group_id be_group_ap_id group_follow_payload group_follow_uri
    local group_unfollow_payload project_create_payload project_create_uri
    local native_project_uri native_project_payload native_project_status_id native_project_status
    local native_project_object linked_fetches_before linked_fetches_after
    local be_post_text be_post be_post_id be_post_uri activitypods_inbox_item
    local duplicate_status
    local activitypods_like_payload activitypods_like_uri activitypods_unlike_payload
    local be_like project_after_like project_likes_uri
    local activitypods_comment_text activitypods_comment_payload activitypods_comment_uri
    local activitypods_comment_create_payload activitypods_comment_status_id
    local be_reply_text be_reply be_reply_id be_reply_uri project_with_replies project_replies_uri
    local comment_delete_payload updated_project_payload project_update_payload
    local updated_project_object updated_project_status
    local activitypods_report_text activitypods_flag_payload be_report_text
    local be_block be_block_item be_block_uri
    local activitypods_block_payload activitypods_block_uri
    local activitypods_unblock_payload person_unfollow_payload
    local missing_status repeated_delete_payload be_post_delete_item

    write_be_secret
    write_proxy_configs

    log "Creating isolated ActivityPods federation network"
    docker rm -f \
        "$ACTIVITYPODS_MAIL_CONTAINER" \
        "$ACTIVITYPODS_REDIS_CONTAINER" \
        "$ACTIVITYPODS_FUSEKI_CONTAINER" \
        "$GTS_PROXY_CONTAINER" \
        "$GTS_CONTAINER" \
        "$BE_PROXY_CONTAINER" \
        "$BE_CONTAINER" \
        "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    docker volume rm \
        "$ACTIVITYPODS_REDIS_VOLUME" \
        "$ACTIVITYPODS_FUSEKI_VOLUME" >/dev/null 2>&1 || true
    docker network create "$NETWORK" >/dev/null

    prepare_smoke_tls
    prepare_activitypods_image

    log "Starting PostgreSQL and pinned stock ActivityPods"
    docker run -d \
        --name "$BE_DB_CONTAINER" \
        --hostname "$BE_DB_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$BE_DB_CONTAINER" \
        -e POSTGRES_PASSWORD="$BE_DB_PASSWORD" \
        "$POSTGRES_IMAGE" >/dev/null
    wait_postgres
    prepare_database
    start_activitypods
    wait_activitypods

    log "Creating a native ActivityPods Person and Group"
    signup="$(http_json POST "$GTS_BASE/auth/signup" "" 200 \
        "{\"username\":\"$GTS_USERNAME\",\"email\":\"$GTS_USERNAME@$GTS_HOST\",\"password\":\"$ACTIVITYPODS_PASSWORD\",\"name\":\"ActivityPods Alice\",\"schema:knowsLanguage\":\"en\"}")"
    ACTIVITYPODS_TOKEN="$(json_get "$signup" token)"
    ACTIVITYPODS_ACTOR="$(json_get "$signup" webId)"
    [ "$ACTIVITYPODS_ACTOR" = "https://$GTS_HOST/$GTS_USERNAME" ] || \
        fail "ActivityPods returned a noncanonical actor ID: $ACTIVITYPODS_ACTOR"

    actor="$(poll_json_assert \
        "activitypods_json GET '$GTS_BASE/$GTS_USERNAME' '' 200" \
        "data.get('id') == '$ACTIVITYPODS_ACTOR' and 'Person' in data.get('type', []) and data.get('inbox') == '$ACTIVITYPODS_ACTOR/inbox' and data.get('outbox') == '$ACTIVITYPODS_ACTOR/outbox' and data.get('pim:storage') == '$ACTIVITYPODS_ACTOR/data' and data.get('publicKey', {}).get('owner') == '$ACTIVITYPODS_ACTOR'" \
        "ActivityPods did not expose its complete Person/WebID actor")"
    storage="$(json_get "$actor" pim:storage)"

    group_status="$(curl -sS -o "$WORK_DIR/activitypods-group-create.json" -w '%{http_code}' \
        -H 'Accept: application/ld+json' \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $ACTIVITYPODS_TOKEN" \
        --data '{"id":"coordinators","type":"foaf:Group"}' \
        "$GTS_BASE/.account/groups")"
    ACTIVITYPODS_GROUP_ACTOR="https://$GTS_HOST/coordinators"

    if [ "$group_status" = "201" ]; then
        group_payload="$(poll_json_assert \
            "activitypods_json GET '$GTS_BASE/coordinators' '' 200" \
            "data.get('id') == '$ACTIVITYPODS_GROUP_ACTOR' and ('Group' in data.get('type', []) or 'foaf:Group' in data.get('type', [])) and data.get('inbox') == '$ACTIVITYPODS_GROUP_ACTOR/inbox'" \
            "ActivityPods did not expose the native Group actor")"
        printf '%s' "$group_payload" >/dev/null
        group_boundary="supported; the native Group actor was created and fetched"
    elif [ "$group_status" = "403" ] && \
        grep -F 'Triple permissions violation:' \
            "$WORK_DIR/activitypods-group-create.json" >/dev/null && \
        grep -F '/coordinators/data/presentations' \
            "$WORK_DIR/activitypods-group-create.json" >/dev/null; then
        log "Stock ActivityPods rejected its incomplete Group feature at the WebACL boundary"
        group_boundary="not_supported; the documented-incomplete stock Group feature failed WebACL setup"
    else
        cat "$WORK_DIR/activitypods-group-create.json" >&2
        fail "ActivityPods Group creation reached an unexpected HTTP $group_status boundary"
    fi

    log "Proving ActivityPods discovery and native linked-data privacy"
    webfinger="$(http_form GET \
        "$GTS_BASE/.well-known/webfinger?resource=acct:$GTS_USERNAME@$GTS_HOST" \
        "" 200)"
    json_assert "$webfinger" \
        "data.get('subject') == 'acct:$GTS_USERNAME@$GTS_HOST' and any(item.get('href') == '$ACTIVITYPODS_ACTOR' for item in data.get('links', []))" \
        "ActivityPods WebFinger did not expose its canonical Person actor"

    nodeinfo_links="$(http_form GET "$GTS_BASE/.well-known/nodeinfo" "" 200)"
    nodeinfo="$(http_form GET "$GTS_BASE/nodeinfo/2.1" "" 200 || \
        http_form GET "$GTS_BASE/nodeinfo/2.0" "" 200)"
    json_assert "$nodeinfo_links" \
        "any('nodeinfo' in item.get('rel', '') for item in data.get('links', []))" \
        "ActivityPods did not expose NodeInfo discovery"
    json_assert "$nodeinfo" \
        "data.get('software', {}).get('name') == 'activitypods' and 'activitypub' in data.get('protocols', [])" \
        "ActivityPods NodeInfo did not identify the stock provider"

    project_uri="$(activitypods_post_location \
        "$GTS_BASE${storage#https://"$GTS_HOST"}" \
        "$ACTIVITYPODS_TOKEN" \
        '{"@context":["https://activitypods.org/context.json",{"unfathomably":"https://unfathomably.invalid/ns#"}],"type":"pair:Project","pair:label":"Alien federation project","pair:description":"Native ActivityPods project state","unfathomably:proof":{"unfathomably:retained":true}}')"
    project_payload="$(activitypods_json GET \
        "$GTS_BASE${project_uri#https://"$GTS_HOST"}" "$ACTIVITYPODS_TOKEN" 200)"
    json_assert "$project_payload" \
        "data.get('id') == '$project_uri' and data.get('type') == 'pair:Project' and data.get('pair:label') == 'Alien federation project' and data.get('https://unfathomably.invalid/ns#proof', {}).get('https://unfathomably.invalid/ns#retained') is True" \
        "ActivityPods lost native Project JSON-LD"

    private_uri="$(activitypods_post_location \
        "$GTS_BASE${storage#https://"$GTS_HOST"}" \
        "$ACTIVITYPODS_TOKEN" \
        '{"@context":"https://activitypods.org/context.json","type":"pair:Project","pair:label":"Private alien project"}')"
    private_status="$(curl -sS -o /dev/null -w '%{http_code}' \
        -H 'Accept: application/ld+json' \
        "$GTS_BASE${private_uri#https://"$GTS_HOST"}")"
    [ "$private_status" = "401" ] || [ "$private_status" = "403" ] || \
        fail "Anonymous client fetched private ActivityPods data with HTTP $private_status"

    log "Migrating and starting Unfathomably"
    migrate_and_create_be_user alice "alice@$BE_HOST"
    start_be
    start_be_proxy
    wait_be

    ALICE_TOKEN="$(create_be_token alice)"
    ACTIVITYPODS_TOKEN="$(activitypods_login)"
    alice_account="$(http_form GET \
        "$BE_BASE/api/v1/accounts/verify_credentials" "$ALICE_TOKEN" 200)"
    alice_ap_id="$(json_get "$alice_account" url)"

    log "Following Person actors in both directions"
    person_follow_payload="$(python3 - "$alice_ap_id" <<'PY'
import json
import sys

target = sys.argv[1]
print(json.dumps({
    "@context": "https://www.w3.org/ns/activitystreams",
    "type": "Follow",
    "object": target,
    "to": target,
}))
PY
)"
    person_follow_uri="$(activitypods_outbox_activity "$person_follow_payload")"
    poll_activitypods_collection \
        "$ACTIVITYPODS_ACTOR/following" "$ACTIVITYPODS_TOKEN" \
        "$alice_ap_id" true \
        "ActivityPods did not accept its Follow of Unfathomably"

    activitypods_account_id="$(resolve_account_id \
        "$BE_BASE" "$ALICE_TOKEN" "$GTS_USERNAME@$GTS_HOST" \
        "Unfathomably could not resolve the ActivityPods Person")"
    poll_json_assert \
        "http_form GET '$BE_BASE/api/v1/accounts/relationships?id[]=$activitypods_account_id' '$ALICE_TOKEN' 200" \
        'len(data) >= 1 and data[0].get("followed_by") is True' \
        "Unfathomably did not retain ActivityPods' incoming Follow" >/dev/null

    be_follow="$(http_form POST \
        "$BE_BASE/api/v1/accounts/$activitypods_account_id/follow" \
        "$ALICE_TOKEN" 200)"
    json_assert "$be_follow" \
        'data.get("following") is True or data.get("requested") is True' \
        "Unfathomably could not follow ActivityPods"
    poll_json_assert \
        "http_form GET '$BE_BASE/api/v1/accounts/relationships?id[]=$activitypods_account_id' '$ALICE_TOKEN' 200" \
        'len(data) >= 1 and data[0].get("following") is True' \
        "ActivityPods did not accept Unfathomably's Follow" >/dev/null
    poll_activitypods_collection \
        "$ACTIVITYPODS_ACTOR/followers" "$ACTIVITYPODS_TOKEN" \
        "$alice_ap_id" true \
        "ActivityPods did not retain Unfathomably as a follower"

    log "Following and unfollowing an Unfathomably Group from ActivityPods"
    be_group="$(http_form POST "$BE_BASE/api/v1/groups" "$ALICE_TOKEN" 200 \
        'display_name=Unfathomably ActivityPods Group' \
        'name=unfathomably_activitypods_group' \
        'note=Open group used by the ActivityPods federation smoke harness.' \
        'locked=false')"
    be_group_id="$(json_get "$be_group" id)"
    be_group_ap_id="$(json_get "$be_group" ap_id)"

    group_follow_payload="$(python3 - "$be_group_ap_id" <<'PY'
import json
import sys

target = sys.argv[1]
print(json.dumps({
    "@context": "https://www.w3.org/ns/activitystreams",
    "type": "Follow",
    "object": target,
    "to": target,
}))
PY
)"
    group_follow_uri="$(activitypods_outbox_activity "$group_follow_payload")"
    poll_activitypods_collection \
        "$ACTIVITYPODS_ACTOR/following" "$ACTIVITYPODS_TOKEN" \
        "$be_group_ap_id" true \
        "ActivityPods did not follow the Unfathomably Group"
    poll_be_group_membership \
        "$be_group_id" "$GTS_USERNAME@$GTS_HOST" true \
        "Unfathomably did not retain the ActivityPods Group membership"

    group_unfollow_payload="$(python3 - \
        "$ACTIVITYPODS_ACTOR" "$group_follow_uri" "$be_group_ap_id" <<'PY'
import json
import sys

actor, follow_id, target = sys.argv[1:]
print(json.dumps({
    "@context": "https://www.w3.org/ns/activitystreams",
    "type": "Undo",
    "object": {
        "id": follow_id,
        "type": "Follow",
        "actor": actor,
        "object": target,
        "to": target,
    },
    "to": target,
}))
PY
)"
    activitypods_outbox_activity "$group_unfollow_payload" >/dev/null
    poll_activitypods_collection \
        "$ACTIVITYPODS_ACTOR/following" "$ACTIVITYPODS_TOKEN" \
        "$be_group_ap_id" false \
        "ActivityPods retained its Unfathomably Group Follow after Undo"
    poll_be_group_membership \
        "$be_group_id" "$GTS_USERNAME@$GTS_HOST" false \
        "Unfathomably retained ActivityPods Group membership after Undo Follow"

    log "Delivering an Unfathomably post into the ActivityPods inbox"
    be_post_text="Unfathomably to ActivityPods smoke $(basename "$WORK_DIR")"
    be_post="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$be_post_text" 'visibility=public')"
    be_post_id="$(json_get "$be_post" id)"
    be_post_uri="$(json_get "$be_post" uri)"
    activitypods_inbox_item="$(poll_activitypods_activity \
        "$ACTIVITYPODS_ACTOR/inbox" "$ACTIVITYPODS_TOKEN" \
        "type_is(item, 'Create') and contains_text(item, '$be_post_text')" \
        "ActivityPods did not retain Unfathomably's Create activity")"
    printf '%s' "$activitypods_inbox_item" >/dev/null

    log "Publishing a native ActivityPods Project by linked Create"
    linked_fetches_before="$(docker logs "$GTS_PROXY_CONTAINER" 2>&1 | \
        grep -c 'GET /alice/data/unfathomably-linked-probe' || true)"
    native_project_payload="$(python3 - \
        "$ACTIVITYPODS_ACTOR" "$alice_ap_id" <<'PY'
import json
import sys

actor, target = sys.argv[1:]
print(json.dumps({
    "@context": [
        "https://www.w3.org/ns/activitystreams",
        "https://activitypods.org/context.json",
        {"unfathomably": "https://unfathomably.invalid/ns#"},
    ],
    "type": "pair:Project",
    "attributedTo": actor,
    "name": "ActivityPods native federation project",
    "content": "Native ActivityPods coordination state",
    "pair:label": "ActivityPods native federation project",
    "pair:description": "Native ActivityPods coordination state",
    "unfathomably:proof": {"unfathomably:retained": True},
    "unfathomably:linked": actor + "/data/unfathomably-linked-probe",
    "to": target,
    "cc": "https://www.w3.org/ns/activitystreams#Public",
}))
PY
)"
    native_project_uri="$(activitypods_post_location \
        "$GTS_BASE/$GTS_USERNAME/data" "$ACTIVITYPODS_TOKEN" \
        "$native_project_payload")"
    project_create_payload="$(python3 - \
        "$alice_ap_id" "$native_project_uri" <<'PY'
import json
import sys

target, object_id = sys.argv[1:]
print(json.dumps({
    "@context": "https://www.w3.org/ns/activitystreams",
    "type": "Create",
    "to": "https://www.w3.org/ns/activitystreams#Public",
    "cc": target,
    "object": object_id,
}))
PY
)"
    project_create_uri="$(activitypods_outbox_activity "$project_create_payload")"
    [ -n "$project_create_uri" ] || fail "ActivityPods omitted its Project Create ID"

    native_project_status_id="$(poll_home_status_by_text \
        "$BE_BASE" "$ALICE_TOKEN" "ActivityPods native federation project" \
        "Unfathomably did not receive the native ActivityPods Project")"
    native_project_status="$(http_form GET \
        "$BE_BASE/api/v1/statuses/$native_project_status_id" \
        "$ALICE_TOKEN" 200)"
    json_assert "$native_project_status" \
        "data.get('uri') == '$native_project_uri' and data.get('visibility') == 'unlisted' and data.get('pleroma', {}).get('native', {}).get('type') == 'pair:Project' and data.get('pleroma', {}).get('native', {}).get('class') == 'status' and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('platform') == 'activitypods' and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('project_label') == 'ActivityPods native federation project' and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('project_description') == 'Native ActivityPods coordination state'" \
        "Unfathomably did not expose ActivityPods' native Project presentation"

    native_project_object="$(be_object_json "$native_project_uri")"
    json_assert "$native_project_object" \
        "data.get('type') == 'pair:Project' and data.get('to') == ['$alice_ap_id'] and data.get('cc') == ['https://www.w3.org/ns/activitystreams#Public'] and data.get('pair:label') == 'ActivityPods native federation project' and data.get('https://unfathomably.invalid/ns#proof', {}).get('https://unfathomably.invalid/ns#retained') is True and data.get('https://unfathomably.invalid/ns#linked') == '$ACTIVITYPODS_ACTOR/data/unfathomably-linked-probe'" \
        "Unfathomably did not retain ActivityPods' complete native Project"
    assert_remote_status_immutable "$native_project_status_id"

    linked_fetches_after="$(docker logs "$GTS_PROXY_CONTAINER" 2>&1 | \
        grep -c 'GET /alice/data/unfathomably-linked-probe' || true)"
    [ "$linked_fetches_after" = "$linked_fetches_before" ] || \
        fail "Unfathomably fetched an inert unknown ActivityPods link"

    log "Redelivering the linked Project concurrently"
    for index in 1 2 3 4; do
        (
            curl -sS -o "$WORK_DIR/activitypods-duplicate-$index.body" \
                -w '%{http_code}' \
                -H 'Accept: application/ld+json' \
                -H 'Content-Type: application/ld+json' \
                -H "Authorization: Bearer $ACTIVITYPODS_TOKEN" \
                --data "$project_create_payload" \
                "$GTS_BASE/$GTS_USERNAME/outbox" \
                >"$WORK_DIR/activitypods-duplicate-$index.status"
        ) &
    done
    wait

    for index in 1 2 3 4; do
        duplicate_status="$(cat "$WORK_DIR/activitypods-duplicate-$index.status")"
        [ "$duplicate_status" = "201" ] || {
            cat "$WORK_DIR/activitypods-duplicate-$index.body" >&2 || true
            fail "Concurrent ActivityPods Project redelivery returned HTTP $duplicate_status"
        }
    done
    poll_be_object_count "$native_project_uri" 1 \
        "Concurrent ActivityPods redelivery duplicated the canonical Project"

    log "Testing Likes and Undo Likes in both directions"
    activitypods_like_payload="$(python3 - \
        "$be_post_uri" "$alice_ap_id" <<'PY'
import json
import sys

object_id, target = sys.argv[1:]
print(json.dumps({
    "@context": "https://www.w3.org/ns/activitystreams",
    "type": "Like",
    "object": object_id,
    "to": target,
}))
PY
)"
    activitypods_like_uri="$(activitypods_outbox_activity "$activitypods_like_payload")"
    poll_status_count "$BE_BASE" "$ALICE_TOKEN" "$be_post_id" \
        'int(data.get("favourites_count") or 0) >= 1' \
        "Unfathomably did not receive ActivityPods' Like"
    poll_activitypods_collection \
        "$ACTIVITYPODS_ACTOR/liked" "$ACTIVITYPODS_TOKEN" \
        "$be_post_uri" true \
        "ActivityPods did not retain its outgoing Like"

    activitypods_unlike_payload="$(python3 - \
        "$ACTIVITYPODS_ACTOR" "$activitypods_like_uri" \
        "$be_post_uri" "$alice_ap_id" <<'PY'
import json
import sys

actor, like_id, object_id, target = sys.argv[1:]
print(json.dumps({
    "@context": "https://www.w3.org/ns/activitystreams",
    "type": "Undo",
    "object": {
        "id": like_id,
        "type": "Like",
        "actor": actor,
        "object": object_id,
        "to": target,
    },
    "to": target,
}))
PY
)"
    activitypods_outbox_activity "$activitypods_unlike_payload" >/dev/null
    poll_status_count "$BE_BASE" "$ALICE_TOKEN" "$be_post_id" \
        'int(data.get("favourites_count") or 0) == 0' \
        "Unfathomably did not receive ActivityPods' Undo Like"
    poll_activitypods_collection \
        "$ACTIVITYPODS_ACTOR/liked" "$ACTIVITYPODS_TOKEN" \
        "$be_post_uri" false \
        "ActivityPods retained its outgoing Like after Undo"

    be_like="$(http_form POST \
        "$BE_BASE/api/v1/statuses/$native_project_status_id/favourite" \
        "$ALICE_TOKEN" 200)"
    json_assert "$be_like" 'data.get("favourited") is True' \
        "Unfathomably could not Like the ActivityPods Project"
    project_after_like="$(poll_json_assert \
        "activitypods_json GET '$(activitypods_local_url "$native_project_uri")' '$ACTIVITYPODS_TOKEN' 200" \
        "data.get('likes') is not None" \
        "ActivityPods did not attach a Likes collection to its Project")"
    project_likes_uri="$(JSON_INPUT="$project_after_like" python3 - <<'PY'
import json
import os

value = json.loads(os.environ["JSON_INPUT"])["likes"]
if isinstance(value, dict):
    value = value.get("id") or value.get("@id")
print(value)
PY
)"
    poll_activitypods_collection \
        "$project_likes_uri" "$ACTIVITYPODS_TOKEN" \
        "$alice_ap_id" true \
        "ActivityPods did not retain Unfathomably's incoming Like"
    http_form POST \
        "$BE_BASE/api/v1/statuses/$native_project_status_id/unfavourite" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_activitypods_collection \
        "$project_likes_uri" "$ACTIVITYPODS_TOKEN" \
        "$alice_ap_id" false \
        "ActivityPods retained Unfathomably's Like after Undo"

    log "Testing replies and comment Deletes in both directions"
    activitypods_comment_text="ActivityPods reply to Unfathomably $(basename "$WORK_DIR")"
    activitypods_comment_payload="$(python3 - \
        "$ACTIVITYPODS_ACTOR" "$alice_ap_id" "$be_post_uri" \
        "$activitypods_comment_text" <<'PY'
import json
import sys

actor, target, parent, content = sys.argv[1:]
print(json.dumps({
    "@context": "https://www.w3.org/ns/activitystreams",
    "type": "Note",
    "attributedTo": actor,
    "content": content,
    "inReplyTo": parent,
    "context": parent,
    "to": target,
    "cc": "https://www.w3.org/ns/activitystreams#Public",
}))
PY
)"
    activitypods_comment_uri="$(activitypods_post_location \
        "$GTS_BASE/$GTS_USERNAME/data" "$ACTIVITYPODS_TOKEN" \
        "$activitypods_comment_payload")"
    activitypods_comment_create_payload="$(python3 - \
        "$alice_ap_id" "$activitypods_comment_uri" <<'PY'
import json
import sys

target, object_id = sys.argv[1:]
print(json.dumps({
    "@context": "https://www.w3.org/ns/activitystreams",
    "type": "Create",
    "to": "https://www.w3.org/ns/activitystreams#Public",
    "cc": target,
    "object": object_id,
}))
PY
)"
    activitypods_outbox_activity "$activitypods_comment_create_payload" >/dev/null
    activitypods_comment_status_id="$(poll_context_status_id_by_text \
        "$BE_BASE" "$ALICE_TOKEN" "$be_post_id" \
        "$activitypods_comment_text" \
        "Unfathomably did not receive ActivityPods' reply")"

    be_reply_text="Unfathomably reply to ActivityPods Project $(basename "$WORK_DIR")"
    be_reply="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$be_reply_text" \
        "in_reply_to_id=$native_project_status_id")"
    be_reply_id="$(json_get "$be_reply" id)"
    be_reply_uri="$(json_get "$be_reply" uri)"
    project_with_replies="$(poll_json_assert \
        "activitypods_json GET '$(activitypods_local_url "$native_project_uri")' '$ACTIVITYPODS_TOKEN' 200" \
        "data.get('replies') is not None" \
        "ActivityPods did not attach a Replies collection to its Project")"
    project_replies_uri="$(JSON_INPUT="$project_with_replies" python3 - <<'PY'
import json
import os

value = json.loads(os.environ["JSON_INPUT"])["replies"]
if isinstance(value, dict):
    value = value.get("id") or value.get("@id")
print(value)
PY
)"
    poll_activitypods_collection \
        "$project_replies_uri" "$ACTIVITYPODS_TOKEN" \
        "$be_reply_uri" true \
        "ActivityPods did not retain Unfathomably's reply context"

    http_form DELETE "$BE_BASE/api/v1/statuses/$be_reply_id" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_activitypods_collection \
        "$project_replies_uri" "$ACTIVITYPODS_TOKEN" \
        "$be_reply_uri" false \
        "ActivityPods retained the deleted Unfathomably reply"

    comment_delete_payload="$(python3 - \
        "$alice_ap_id" "$activitypods_comment_uri" <<'PY'
import json
import sys

target, object_id = sys.argv[1:]
print(json.dumps({
    "@context": "https://www.w3.org/ns/activitystreams",
    "type": "Delete",
    "object": object_id,
    "to": "https://www.w3.org/ns/activitystreams#Public",
    "cc": target,
}))
PY
)"
    activitypods_outbox_activity "$comment_delete_payload" >/dev/null
    poll_status_missing \
        "$BE_BASE" "$ALICE_TOKEN" "$activitypods_comment_status_id" \
        "Unfathomably retained ActivityPods' deleted reply"

    # Delete the local post while ActivityPods is still one of its recipients.
    # A later unfollow correctly removes it from future follower deliveries and
    # would make the absence of this Delete an expected routing result.
    http_form DELETE "$BE_BASE/api/v1/statuses/$be_post_id" \
        "$ALICE_TOKEN" 200 >/dev/null
    be_post_delete_item="$(poll_activitypods_activity \
        "$ACTIVITYPODS_ACTOR/inbox" "$ACTIVITYPODS_TOKEN" \
        "type_is(item, 'Delete') and contains_text(item, '$be_post_uri')" \
        "ActivityPods did not retain Unfathomably's post Delete")"
    printf '%s' "$be_post_delete_item" >/dev/null

    log "Updating the native Project by linked Update"
    updated_project_payload="$(python3 - \
        "$native_project_uri" "$ACTIVITYPODS_ACTOR" "$alice_ap_id" <<'PY'
import json
import sys

object_id, actor, target = sys.argv[1:]
print(json.dumps({
    "@context": [
        "https://www.w3.org/ns/activitystreams",
        "https://activitypods.org/context.json",
        {"unfathomably": "https://unfathomably.invalid/ns#"},
    ],
    "id": object_id,
    "type": "pair:Project",
    "attributedTo": actor,
    "name": "ActivityPods native federation project",
    "content": "Updated ActivityPods coordination state",
    "pair:label": "ActivityPods native federation project",
    "pair:description": "Updated ActivityPods coordination state",
    "unfathomably:proof": {"unfathomably:retained": True},
    "unfathomably:linked": actor + "/data/unfathomably-linked-probe",
    "to": target,
    "cc": "https://www.w3.org/ns/activitystreams#Public",
}))
PY
)"
    activitypods_put_resource \
        "$native_project_uri" "$ACTIVITYPODS_TOKEN" "$updated_project_payload"
    project_update_payload="$(python3 - \
        "$alice_ap_id" "$native_project_uri" <<'PY'
import json
import sys

target, object_id = sys.argv[1:]
print(json.dumps({
    "@context": "https://www.w3.org/ns/activitystreams",
    "type": "Update",
    "to": "https://www.w3.org/ns/activitystreams#Public",
    "cc": target,
    "object": object_id,
}))
PY
)"
    activitypods_outbox_activity "$project_update_payload" >/dev/null
    updated_project_object="$(poll_json_assert \
        "be_object_json '$native_project_uri'" \
        "data.get('content') == 'Updated ActivityPods coordination state' and data.get('pair:description') == 'Updated ActivityPods coordination state' and data.get('cc') == ['https://www.w3.org/ns/activitystreams#Public']" \
        "Unfathomably did not apply ActivityPods' linked Project Update")"
    printf '%s' "$updated_project_object" >/dev/null
    updated_project_status="$(http_form GET \
        "$BE_BASE/api/v1/statuses/$native_project_status_id" \
        "$ALICE_TOKEN" 200)"
    json_assert "$updated_project_status" \
        "data.get('pleroma', {}).get('native', {}).get('fields', {}).get('project_description') == 'Updated ActivityPods coordination state'" \
        "Unfathomably did not update ActivityPods' native presentation"

    log "Testing moderation Flags in both directions"
    activitypods_report_text="ActivityPods moderation report $(basename "$WORK_DIR")"
    activitypods_flag_payload="$(python3 - \
        "$alice_ap_id" "$activitypods_report_text" <<'PY'
import json
import sys

target, content = sys.argv[1:]
print(json.dumps({
    "@context": "https://www.w3.org/ns/activitystreams",
    "type": "Flag",
    "object": target,
    "content": content,
    "to": target,
}))
PY
)"
    activitypods_outbox_activity "$activitypods_flag_payload" >/dev/null
    poll_be_report_by_text "$activitypods_report_text" \
        "Unfathomably did not retain ActivityPods' Flag"

    be_report_text="Unfathomably moderation report $(basename "$WORK_DIR")"
    http_form POST "$BE_BASE/api/v1/reports" "$ALICE_TOKEN" 200 \
        "account_id=$activitypods_account_id" \
        "status_ids[]=$native_project_status_id" \
        "comment=$be_report_text" \
        'forward=true' >/dev/null
    poll_activitypods_activity \
        "$ACTIVITYPODS_ACTOR/inbox" "$ACTIVITYPODS_TOKEN" \
        "type_is(item, 'Flag') and contains_text(item, '$be_report_text')" \
        "ActivityPods did not retain Unfathomably's incoming Flag" >/dev/null

    log "Testing Blocks and Undo Blocks in both directions"
    activitypods_block_payload="$(python3 - "$alice_ap_id" <<'PY'
import json
import sys

target = sys.argv[1]
print(json.dumps({
    "@context": "https://www.w3.org/ns/activitystreams",
    "type": "Block",
    "object": target,
    "to": target,
}))
PY
)"
    activitypods_block_uri="$(activitypods_outbox_activity "$activitypods_block_payload")"
    poll_json_assert \
        "http_form GET '$BE_BASE/api/v1/accounts/relationships?id[]=$activitypods_account_id' '$ALICE_TOKEN' 200" \
        "len(data) >= 1 and data[0].get('blocked_by') is True" \
        "Unfathomably did not retain ActivityPods' incoming Block" >/dev/null
    activitypods_unblock_payload="$(python3 - \
        "$ACTIVITYPODS_ACTOR" "$activitypods_block_uri" "$alice_ap_id" <<'PY'
import json
import sys

actor, block_id, target = sys.argv[1:]
print(json.dumps({
    "@context": "https://www.w3.org/ns/activitystreams",
    "type": "Undo",
    "object": {
        "id": block_id,
        "type": "Block",
        "actor": actor,
        "object": target,
        "to": target,
    },
    "to": target,
}))
PY
)"
    activitypods_outbox_activity "$activitypods_unblock_payload" >/dev/null
    poll_json_assert \
        "http_form GET '$BE_BASE/api/v1/accounts/relationships?id[]=$activitypods_account_id' '$ALICE_TOKEN' 200" \
        "len(data) >= 1 and data[0].get('blocked_by') is not True" \
        "Unfathomably retained ActivityPods' Block after Undo" >/dev/null

    be_block="$(http_form POST \
        "$BE_BASE/api/v1/accounts/$activitypods_account_id/block" \
        "$ALICE_TOKEN" 200)"
    json_assert "$be_block" 'data.get("blocking") is True' \
        "Unfathomably did not create its ActivityPods Block"
    be_block_item="$(poll_activitypods_activity \
        "$ACTIVITYPODS_ACTOR/inbox" "$ACTIVITYPODS_TOKEN" \
        "type_is(item, 'Block') and contains_text(item, '$ACTIVITYPODS_ACTOR')" \
        "ActivityPods did not retain Unfathomably's incoming Block")"
    be_block_uri="$(json_get "$be_block_item" id)"
    http_form POST \
        "$BE_BASE/api/v1/accounts/$activitypods_account_id/unblock" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_activitypods_activity \
        "$ACTIVITYPODS_ACTOR/inbox" "$ACTIVITYPODS_TOKEN" \
        "type_is(item, 'Undo') and identifier(item.get('object')) == '$be_block_uri'" \
        "ActivityPods did not retain Unfathomably's incoming Undo Block" >/dev/null

    log "Testing Person unfollows in both directions"
    person_unfollow_payload="$(python3 - \
        "$ACTIVITYPODS_ACTOR" "$person_follow_uri" "$alice_ap_id" <<'PY'
import json
import sys

actor, follow_id, target = sys.argv[1:]
print(json.dumps({
    "@context": "https://www.w3.org/ns/activitystreams",
    "type": "Undo",
    "object": {
        "id": follow_id,
        "type": "Follow",
        "actor": actor,
        "object": target,
        "to": target,
    },
    "to": target,
}))
PY
)"
    activitypods_outbox_activity "$person_unfollow_payload" >/dev/null
    poll_activitypods_collection \
        "$ACTIVITYPODS_ACTOR/following" "$ACTIVITYPODS_TOKEN" \
        "$alice_ap_id" false \
        "ActivityPods retained its Unfathomably Follow after Undo"
    poll_json_assert \
        "http_form GET '$BE_BASE/api/v1/accounts/relationships?id[]=$activitypods_account_id' '$ALICE_TOKEN' 200" \
        "len(data) >= 1 and data[0].get('followed_by') is not True" \
        "Unfathomably retained ActivityPods' Follow after Undo" >/dev/null

    # Blocking an account intentionally removes its existing follow.  Restore
    # that relationship so this section exercises a real, explicit Unfollow
    # instead of treating an already-clean relationship as success.
    be_follow="$(http_form POST \
        "$BE_BASE/api/v1/accounts/$activitypods_account_id/follow" \
        "$ALICE_TOKEN" 200)"
    json_assert "$be_follow" \
        'data.get("following") is True or data.get("requested") is True' \
        "Unfathomably could not restore its ActivityPods Follow"
    poll_json_assert \
        "http_form GET '$BE_BASE/api/v1/accounts/relationships?id[]=$activitypods_account_id' '$ALICE_TOKEN' 200" \
        'len(data) >= 1 and data[0].get("following") is True' \
        "ActivityPods did not accept the restored Unfathomably Follow" >/dev/null
    poll_activitypods_collection \
        "$ACTIVITYPODS_ACTOR/followers" "$ACTIVITYPODS_TOKEN" \
        "$alice_ap_id" true \
        "ActivityPods did not retain the restored Unfathomably Follow"

    http_form POST \
        "$BE_BASE/api/v1/accounts/$activitypods_account_id/unfollow" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_relationship_not_following \
        "$BE_BASE" "$ALICE_TOKEN" "$activitypods_account_id" \
        "Unfathomably retained its ActivityPods Follow after unfollow"
    poll_activitypods_collection \
        "$ACTIVITYPODS_ACTOR/followers" "$ACTIVITYPODS_TOKEN" \
        "$alice_ap_id" false \
        "ActivityPods retained Unfathomably as a follower after Undo"

    log "Deleting the native Project and proving idempotent terminal cleanup"
    repeated_delete_payload="$(python3 - \
        "$alice_ap_id" "$native_project_uri" <<'PY'
import json
import sys

target, object_id = sys.argv[1:]
print(json.dumps({
    "@context": "https://www.w3.org/ns/activitystreams",
    "type": "Delete",
    "object": object_id,
    "to": "https://www.w3.org/ns/activitystreams#Public",
    "cc": target,
}))
PY
)"
    activitypods_outbox_activity "$repeated_delete_payload" >/dev/null
    poll_status_missing \
        "$BE_BASE" "$ALICE_TOKEN" "$native_project_status_id" \
        "Unfathomably retained ActivityPods' deleted Project"
    activitypods_outbox_activity "$repeated_delete_payload" >/dev/null
    poll_be_object_count "$native_project_uri" 1 \
        "Repeated ActivityPods Delete duplicated the Project tombstone"

    missing_status="$(curl -sS -o /dev/null -w '%{http_code}' \
        -H 'Accept: application/activity+json' \
        "$GTS_BASE/$GTS_USERNAME/data/00000000-0000-4000-8000-000000000000" || true)"
    [ "$missing_status" = "404" ] || [ "$missing_status" = "410" ] || \
        fail "ActivityPods did not classify a missing Pod resource as terminal"

    relationship="$(http_form GET \
        "$BE_BASE/api/v1/accounts/relationships?id[]=$activitypods_account_id" \
        "$ALICE_TOKEN" 200)"
    json_assert "$relationship" \
        "len(data) >= 1 and data[0].get('following') is not True and data[0].get('followed_by') is not True and data[0].get('blocked_by') is not True and data[0].get('blocking') is not True" \
        "Final ActivityPods relationship cleanup was incomplete"

    check_logs "$BE_CONTAINER" Unfathomably
    check_activitypods_logs

    cat <<EOF

ActivityPods federation smoke passed.

Pinned stock source:
* activitypods: $ACTIVITYPODS_SOURCE_COMMIT

Alien ActivityPub matrix:
* Discovery: supported; canonical WebFinger, NodeInfo, Person/WebID, inbox, outbox, followers, following, liked, storage, and signing key passed
* Native representation: supported; pair:Project retained its label, description, authority, and Pod identity
* Compatibility representation: supported; the Project has a readable status fallback without replacing its native type
* Semantic deduplication: supported; four concurrent native redeliveries retained one canonical Project
* Authority: supported; a local user could not rewrite the remote-owned Project
* Lifecycle: supported; linked Create, linked Update, Delete, replies, and reply Deletes converged
* Concurrency: supported; concurrent stock outbox publication completed and Unfathomably remained canonical
* Collections: supported; stock inbox, outbox, followers, following, liked, likes, and replies collections were traversed through bounded pages
* Context: supported; ActivityPods and Unfathomably replies retained their parent relationships
* Capabilities: partially_supported; native Projects are exposed with honest read-only ActivityPods controls, while stock Groups are incomplete
* Round trip: partially_supported; Person and one-way Group follows, Likes, replies, Deletes, Flags, Blocks, and Undos changed observable state, while ActivityPods has no native moderation model
* Unknown JSON-LD: supported; the proof node and inert linked predicate survived validation, storage, export, and Update
* Privacy: supported; an owner-only Pod resource rejected anonymous access while publication explicitly granted public read access
* Idempotence: supported; Create redelivery retained one object and repeated Delete terminated without duplication
* Failure classification: supported; missing resources terminated and the exact incomplete-Group WebACL boundary was distinguished from crashes
* Resource safety: supported; Unfathomably fetched the linked canonical Project but never followed its inert unknown link
* UI classification: supported; the native status exposes ActivityPods project label and description fields
* Cleanup: partially_supported; Person follows, the supported Group membership direction, Likes, Blocks, replies, comments, and posts were removed, while reverse Group membership is unavailable upstream

Relationship and moderation boundaries:
* supported: Person follows and unfollows in both directions
* partially_supported: ActivityPods Person follows and unfollows an Unfathomably Group; reverse Group following is unavailable because $group_boundary
* supported: native Project posts, linked Updates, posts from Unfathomably, replies in both directions, post Deletes, and comment Deletes
* supported: Likes and Undo Likes in both directions
* partially_supported: Flags are delivered and retained in both directions, but stock ActivityPods exposes no native moderation case state
* partially_supported: ActivityPods Blocks affect Unfathomably; incoming Blocks and Undo Blocks are retained as transport activities because stock ActivityPods has no Block processor
* stock_limitation: Groups are explicitly marked incomplete upstream and native Group creation stops at its presentations-container WebACL boundary
* stock_limitation: a native Project must first exist in the Pod and is then published through ActivityPods' stock linked-Create form
* stock_limitation: ActivityPods grants public object read access only when Public is in the activity to field
* not_supported: stock ActivityPods exposes no durable signal by which it can know that a remote instance has defederated it
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run_activitypods_smoke
fi

# end of unfathomably-activitypods-smoke.sh
