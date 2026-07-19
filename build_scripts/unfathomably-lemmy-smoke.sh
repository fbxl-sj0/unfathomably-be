#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-lemmy-smoke.sh
#
# Purpose:
#
#   Start a clean Unfathomably smoke instance and a clean Lemmy
#   instance on the same Docker network, then prove that group-style
#   federation works between them.
#
# Responsibilities:
#
#   * boot a reproducible Lemmy server with PostgreSQL, pict-rs, and a
#     small internal HTTP reverse proxy
#   * reuse the existing two-instance Unfathomably smoke bootstrap so
#     the backend is known-good before Lemmy-specific checks begin
#   * exercise follow, unfollow, post, comment, like, unlike, and delete
#     paths across the Unfathomably/Lemmy boundary
#   * fail loudly if either server logs obvious 500/crash output
#
# This file intentionally does NOT contain:
#
#   * production deployment logic
#   * TLS certificate provisioning
#   * frontend/browser automation
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE="${SMOKE_IMAGE:-unfathomably-elixir-smoke:otp28}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16-alpine}"
LEMMY_VERSION="${LEMMY_VERSION:-0.19.18}"
LEMMY_DEBUG_IMAGE="${LEMMY_DEBUG_IMAGE:-unfathomably-lemmy-debug:$LEMMY_VERSION}"
LEMMY_IMAGE="${LEMMY_IMAGE:-$LEMMY_DEBUG_IMAGE}"
PICTRS_IMAGE="${PICTRS_IMAGE:-asonix/pictrs:0.5}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.27-alpine}"

PREFIX="${SMOKE_PREFIX:-unfathomably-lemmy-smoke}"
NETWORK="${SMOKE_NETWORK:-$PREFIX-net}"
BE_PREFIX="$PREFIX-be"

A_HOST="${SMOKE_A_HOST:-smoke-a}"
B_HOST="${SMOKE_B_HOST:-smoke-b}"
A_PORT="${SMOKE_A_PORT:-4631}"
B_PORT="${SMOKE_B_PORT:-4632}"
LEMMY_HOST="${LEMMY_HOST:-lemmy-smoke}"
LEMMY_PORT="${LEMMY_PORT:-4633}"

PASSWORD="${SMOKE_USER_PASSWORD:-SmokeTest_01}"
DB_PASSWORD="${SMOKE_DB_PASSWORD:-postgres}"
KEEP_SMOKE="${KEEP_SMOKE:-0}"

WORK_DIR="${SMOKE_WORK_DIR:-}"
if [ -z "$WORK_DIR" ]; then
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/unfathomably-lemmy-smoke.XXXXXX")"
fi

BASE_URL="http://127.0.0.1:$A_PORT"
LEMMY_URL="http://127.0.0.1:$LEMMY_PORT"

log() {
    printf '\n==> %s\n' "$*"
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2

    for container in \
        "$PREFIX-lemmy" \
        "$PREFIX-lemmy-proxy" \
        "$PREFIX-pictrs" \
        "$PREFIX-lemmy-db" \
        "$BE_PREFIX-a" \
        "$BE_PREFIX-b" \
        "$BE_PREFIX-db"; do
        if docker inspect "$container" >/dev/null 2>&1; then
            printf '\n--- docker logs --tail 160 %s ---\n' "$container" >&2
            docker logs --tail 160 "$container" >&2 || true
        fi
    done

    exit 1
}

cleanup() {
    if [ "$KEEP_SMOKE" = "1" ]; then
        cat <<EOF

Smoke containers preserved because KEEP_SMOKE=1.
Unfathomably: $BASE_URL
Lemmy:         $LEMMY_URL
Work dir:      $WORK_DIR
EOF
        return
    fi

    docker rm -f \
        "$PREFIX-lemmy-proxy" \
        "$PREFIX-lemmy" \
        "$PREFIX-pictrs" \
        "$PREFIX-lemmy-db" \
        "$BE_PREFIX-a" \
        "$BE_PREFIX-b" \
        "$BE_PREFIX-db" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR"
}

trap cleanup EXIT

ensure_lemmy_image() {
    if [ "$LEMMY_IMAGE" != "$LEMMY_DEBUG_IMAGE" ]; then
        return
    fi

    if docker image inspect "$LEMMY_IMAGE" >/dev/null 2>&1; then
        return
    fi

    log "Building Lemmy debug image $LEMMY_IMAGE"

    docker build \
        -f "$SCRIPT_DIR/Dockerfile.lemmy-debug" \
        --build-arg "LEMMY_REF=$LEMMY_VERSION" \
        -t "$LEMMY_IMAGE" \
        "$SCRIPT_DIR"
}

urlencode() {
    python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

json_get() {
    local json="$1"
    local path="$2"

    JSON_PAYLOAD="$json" python3 - "$path" <<'PY'
import json
import os
import sys

path = sys.argv[1].split(".")
data = json.loads(os.environ["JSON_PAYLOAD"])

for part in path:
    if isinstance(data, list):
        data = data[int(part)]
    else:
        data = data[part]

if isinstance(data, (dict, list)):
    print(json.dumps(data))
elif data is None:
    print("")
else:
    print(data)
PY
}

json_assert() {
    local json="$1"
    local expr="$2"
    local message="$3"

    json_matches "$json" "$expr" || fail "$message"
}

json_matches() {
    local json="$1"
    local expr="$2"

    JSON_PAYLOAD="$json" python3 - "$expr" <<'PY'
import json
import os
import sys

expr = sys.argv[1]
data = json.loads(os.environ["JSON_PAYLOAD"])
helpers = {"any": any, "all": all, "len": len, "str": str, "int": int}

if not eval(expr, {"__builtins__": {}}, {"data": data, **helpers}):
    raise SystemExit(1)
PY
}

http_form() {
    local method="$1"
    local url="$2"
    local token="$3"
    local expected="$4"
    shift 4

    local tmp code
    tmp="$(mktemp)"

    local args=(-sS -X "$method" -o "$tmp" -w "%{http_code}")
    if [ -n "$token" ]; then
        args+=(-H "Authorization: Bearer $token")
    fi
    for field in "$@"; do
        args+=(--data-urlencode "$field")
    done
    args+=("$url")

    code="$(curl "${args[@]}")" || {
        cat "$tmp" >&2 || true
        rm -f "$tmp"
        fail "curl failed for $method $url"
    }

    if [ "$code" != "$expected" ]; then
        cat "$tmp" >&2 || true
        rm -f "$tmp"
        fail "Unexpected HTTP $code for $method $url (expected $expected)"
    fi

    cat "$tmp"
    rm -f "$tmp"
}

http_json() {
    local method="$1"
    local url="$2"
    local expected="$3"
    local body="$4"
    local token="${5:-}"

    local tmp code
    tmp="$(mktemp)"

    local args=(-sS -X "$method" -H "Content-Type: application/json" -o "$tmp" -w "%{http_code}")
    if [ -n "$token" ]; then
        args+=(-H "Authorization: Bearer $token")
    fi
    args+=(-d "$body" "$url")

    code="$(curl "${args[@]}")" || {
        cat "$tmp" >&2 || true
        rm -f "$tmp"
        fail "curl failed for $method $url"
    }

    if [ "$code" != "$expected" ]; then
        cat "$tmp" >&2 || true
        rm -f "$tmp"
        fail "Unexpected HTTP $code for $method $url (expected $expected)"
    fi

    cat "$tmp"
    rm -f "$tmp"
}

http_get() {
    local url="$1"
    local expected="$2"

    local tmp code
    tmp="$(mktemp)"

    code="$(curl -sS -o "$tmp" -w "%{http_code}" "$url")" || {
        cat "$tmp" >&2 || true
        rm -f "$tmp"
        fail "curl failed for GET $url"
    }

    if [ "$code" != "$expected" ]; then
        cat "$tmp" >&2 || true
        rm -f "$tmp"
        fail "Unexpected HTTP $code for GET $url (expected $expected)"
    fi

    cat "$tmp"
    rm -f "$tmp"
}

poll_http_status() {
    local method="$1"
    local url="$2"
    local token="$3"
    local expected="$4"
    local message="$5"
    local attempts="${6:-80}"
    local delay="${7:-2}"
    local tmp code

    tmp="$(mktemp)"

    for _ in $(seq 1 "$attempts"); do
        local args=(-sS -X "$method" -o "$tmp" -w "%{http_code}")
        if [ -n "$token" ]; then
            args+=(-H "Authorization: Bearer $token")
        fi
        args+=("$url")

        code="$(curl "${args[@]}")" || code="000"

        if [ "$code" = "$expected" ]; then
            rm -f "$tmp"
            return 0
        fi

        sleep "$delay"
    done

    cat "$tmp" >&2 || true
    rm -f "$tmp"
    fail "Polling timed out: $message stayed at HTTP $code instead of $expected"
}

poll_json_assert() {
    local method="$1"
    local url="$2"
    local token="$3"
    local expected="$4"
    local expr="$5"
    local message="$6"
    local attempts="${7:-80}"
    local delay="${8:-2}"
    local body="${9:-}"
    local result

    for _ in $(seq 1 "$attempts"); do
        if [ "$method" = "GET" ]; then
            result="$(http_form GET "$url" "$token" "$expected" || true)"
        elif [ -n "$body" ]; then
            result="$(http_json "$method" "$url" "$expected" "$body" || true)"
        else
            result="$(http_form "$method" "$url" "$token" "$expected" || true)"
        fi

        if [ -n "$result" ] && json_matches "$result" "$expr" >/dev/null 2>&1; then
            printf '%s\n' "$result"
            return 0
        fi

        sleep "$delay"
    done

    printf '%s\n' "$result" >&2
    fail "Polling timed out: $message"
}

poll_json_assert_optional() {
    local method="$1"
    local url="$2"
    local token="$3"
    local expected="$4"
    local expr="$5"
    local attempts="${6:-30}"
    local delay="${7:-2}"
    local result

    for _ in $(seq 1 "$attempts"); do
        result="$(http_form "$method" "$url" "$token" "$expected" || true)"

        if [ -n "$result" ] && json_matches "$result" "$expr" >/dev/null 2>&1; then
            return 0
        fi

        sleep "$delay"
    done

    return 1
}

wait_http() {
    local url="$1"
    local name="$2"

    for _ in $(seq 1 120); do
        if curl -fsS "$url" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    fail "Timed out waiting for $name at $url"
}

be_token() {
    local username="$1"
    local app token client_id client_secret

    app="$(
        http_form POST "$BASE_URL/api/v1/apps" "" 200 \
            "client_name=lemmy-smoke" \
            "redirect_uris=urn:ietf:wg:oauth:2.0:oob" \
            "scopes=read write follow push"
    )"
    client_id="$(json_get "$app" client_id)"
    client_secret="$(json_get "$app" client_secret)"

    token="$(
        http_form POST "$BASE_URL/oauth/token" "" 200 \
            "grant_type=password" \
            "username=$username" \
            "password=$PASSWORD" \
            "client_id=$client_id" \
            "client_secret=$client_secret" \
            "scope=read write follow push"
    )"

    json_get "$token" access_token
}

lemmy_post() {
    local path="$1"
    local body="$2"

    http_json POST "$LEMMY_URL/api/v3/$path" 200 "$body" "$LEMMY_JWT"
}

lemmy_get_auth() {
    local path="$1"
    local separator="?"

    case "$path" in
        *\?*) separator="&" ;;
    esac

    http_form GET "$LEMMY_URL/api/v3/$path" "$LEMMY_JWT" 200
}

resolve_be_status_id() {
    local uri="$1"
    local token="$2"
    local message="$3"
    local result

    result="$(
        poll_json_assert GET \
            "$BASE_URL/api/v2/search?resolve=true&type=statuses&q=$(urlencode "$uri")" \
            "$token" \
            200 \
            'len(data.get("statuses", [])) >= 1' \
            "$message" \
            90 \
            2
    )"

    json_get "$result" statuses.0.id
}

resolve_be_context_status_id() {
    local parent_id="$1"
    local uri="$2"
    local token="$3"
    local message="$4"
    local result
    local id

    for _ in $(seq 1 90); do
        result="$(
            http_form GET \
                "$BASE_URL/api/v1/statuses/$parent_id/context" \
                "$token" \
                200 || true
        )"

        id="$(
            JSON_PAYLOAD="$result" TARGET_URI="$uri" python3 - <<'PY' || true
import json
import os
import sys

try:
    data = json.loads(os.environ["JSON_PAYLOAD"])
except json.JSONDecodeError:
    raise SystemExit(1)

target = os.environ["TARGET_URI"]

for status in data.get("ancestors", []) + data.get("descendants", []):
    if status.get("uri") == target or status.get("url") == target:
        print(status["id"])
        raise SystemExit(0)

raise SystemExit(1)
PY
        )"

        if [ -n "$id" ]; then
            printf '%s\n' "$id"
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

resolve_lemmy_object() {
    local uri="$1"
    local message="$2"

    poll_json_assert GET \
        "$LEMMY_URL/api/v3/resolve_object?q=$(urlencode "$uri")" \
        "$LEMMY_JWT" \
        200 \
        '(data.get("post") is not None) or (data.get("comment") is not None) or (data.get("community") is not None)' \
        "$message" \
        90 \
        2
}

write_lemmy_config() {
    if [ "${LEMMY_IMAGE##*:}" = "dev" ]; then
        lemmy_database_config=$(cat <<EOF
  database: {
    connection: "postgres://lemmy:$DB_PASSWORD@$PREFIX-lemmy-db:5432/lemmy"
    pool_size: 5
  }
EOF
)
        lemmy_federation_config=$(cat <<EOF
  federation: {
    concurrent_sends_per_instance: 1
  }
EOF
)
    else
        lemmy_database_config=$(cat <<EOF
  database: {
    database: "lemmy"
    user: "lemmy"
    password: "$DB_PASSWORD"
    host: "$PREFIX-lemmy-db"
    port: 5432
    pool_size: 5
  }
EOF
)
        lemmy_federation_config=$(cat <<EOF
  federation: {
    enabled: true
    debug: true
    concurrent_sends_per_instance: 1
  }
EOF
)
    fi

    cat >"$WORK_DIR/lemmy.hjson" <<EOF
{
  setup: {
    admin_username: "lemmyadmin"
    admin_password: "$PASSWORD"
    site_name: "Lemmy Smoke"
  }
  hostname: "$LEMMY_HOST"
  bind: "0.0.0.0"
  port: 8536
  tls_enabled: false
  pictrs: {
    url: "http://$PREFIX-pictrs:8080/"
    api_key: "lemmy-smoke-pictrs-key"
    image_mode: "None"
  }
$lemmy_database_config
$lemmy_federation_config
}
EOF

    cat >"$WORK_DIR/nginx.conf" <<EOF
events {}
http {
  server {
    listen 80;
    client_max_body_size 20m;

    location / {
      proxy_pass http://$PREFIX-lemmy:8536;
      proxy_http_version 1.1;
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto http;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection "upgrade";
    }
  }
}
EOF
}

start_lemmy() {
    write_lemmy_config

    docker rm -f \
        "$PREFIX-lemmy-proxy" \
        "$PREFIX-lemmy" \
        "$PREFIX-pictrs" \
        "$PREFIX-lemmy-db" >/dev/null 2>&1 || true

    docker run -d \
        --name "$PREFIX-lemmy-db" \
        --network "$NETWORK" \
        -e POSTGRES_USER=lemmy \
        -e POSTGRES_PASSWORD="$DB_PASSWORD" \
        -e POSTGRES_DB=lemmy \
        "$POSTGRES_IMAGE" >/dev/null

    for _ in $(seq 1 80); do
        if docker exec "$PREFIX-lemmy-db" pg_isready -U lemmy >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    docker run -d \
        --name "$PREFIX-pictrs" \
        --network "$NETWORK" \
        -e PICTRS__API_KEY=lemmy-smoke-pictrs-key \
        "$PICTRS_IMAGE" >/dev/null

    docker run -d \
        --name "$PREFIX-lemmy" \
        --network "$NETWORK" \
        -e RUST_LOG=warn \
        -e LEMMY_TEST_FAST_FEDERATION=1 \
        -e LEMMY_CONFIG_LOCATION=/config/config.hjson \
        -v "$WORK_DIR/lemmy.hjson:/config/config.hjson:ro" \
        "$LEMMY_IMAGE" >/dev/null

    docker run -d \
        --name "$PREFIX-lemmy-proxy" \
        --network "$NETWORK" \
        --network-alias "$LEMMY_HOST" \
        -p "127.0.0.1:$LEMMY_PORT:80" \
        -v "$WORK_DIR/nginx.conf:/etc/nginx/nginx.conf:ro" \
        "$NGINX_IMAGE" >/dev/null

    wait_http "$LEMMY_URL/api/v3/site" "Lemmy"
}

prepare_lemmy_smoke_auth() {
    docker exec "$PREFIX-lemmy-db" psql -U lemmy -d lemmy -v ON_ERROR_STOP=1 -c "
        update local_user set accepted_application = true where admin = true;
        update local_site set registration_mode = 'Open';
    " >/dev/null
}

sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

poll_be_object_unliked() {
    local object_ap_id="$1"
    local actor_ap_id="$2"
    local message="$3"
    local object_sql actor_sql result

    object_sql="$(sql_escape "$object_ap_id")"
    actor_sql="$(sql_escape "$actor_ap_id")"

    for _ in $(seq 1 90); do
        result="$(
            docker exec "$BE_PREFIX-db" psql -U postgres -d pleroma_smoke_a -Atc "
                select case
                    when coalesce((data->>'like_count')::int, 0) = 0
                         and not (coalesce(data->'likes', '[]'::jsonb) ? '$actor_sql')
                    then 'ok'
                    else coalesce(data->>'like_count', 'null') || ' ' || coalesce((data->'likes')::text, 'null')
                end
                from objects
                where data->>'id' = '$object_sql';
            "
        )"

        if [ "$result" = "ok" ]; then
            return 0
        fi

        sleep 2
    done

    fail "$message: backend object still shows like state $result"
}

docker rm -f \
    "$PREFIX-lemmy-proxy" \
    "$PREFIX-lemmy" \
    "$PREFIX-pictrs" \
    "$PREFIX-lemmy-db" >/dev/null 2>&1 || true

log "Bootstrapping Unfathomably smoke pair"
KEEP_SMOKE=1 \
SMOKE_PREFIX="$BE_PREFIX" \
SMOKE_NETWORK="$NETWORK" \
SMOKE_A_HOST="$A_HOST" \
SMOKE_B_HOST="$B_HOST" \
SMOKE_A_PORT="$A_PORT" \
SMOKE_B_PORT="$B_PORT" \
SMOKE_IMAGE="$IMAGE" \
SMOKE_USER_PASSWORD="$PASSWORD" \
bash build_scripts/two-instance-federation-smoke.sh >/tmp/unfathomably-lemmy-bootstrap.log 2>&1 || {
    cat /tmp/unfathomably-lemmy-bootstrap.log >&2 || true
    fail "Unfathomably bootstrap smoke failed"
}

# The baseline needs two Unfathomably instances, but the Lemmy phase only uses
# instance A. Releasing instance B here leaves enough memory for a cold Lemmy
# image build without weakening any of the peer-specific checks below.
docker stop -t 15 "$BE_PREFIX-b" >/dev/null 2>&1 || true

log "Starting Lemmy"
ensure_lemmy_image
start_lemmy

log "Creating API credentials"
ALICE_TOKEN="$(be_token alice)"
prepare_lemmy_smoke_auth

LEMMY_LOGIN="$(
    http_json POST "$LEMMY_URL/api/v3/user/login" 200 \
        "{\"username_or_email\":\"lemmyadmin\",\"password\":\"$PASSWORD\"}"
)"
LEMMY_JWT="$(json_get "$LEMMY_LOGIN" jwt)"

log "Creating local group and Lemmy community"
BE_GROUP="$(
    http_form POST "$BASE_URL/api/v1/groups" "$ALICE_TOKEN" 200 \
        "display_name=Unfathomably Lemmy Smoke" \
        "name=unfathomably_lemmy_smoke"
)"
BE_GROUP_ID="$(json_get "$BE_GROUP" id)"
BE_GROUP_AP_ID="$(json_get "$BE_GROUP" ap_id)"

LEMMY_COMMUNITY="$(
    lemmy_post community \
        '{"name":"lemmy_smoke","title":"Lemmy Smoke","description":"Smoke test community","nsfw":false}'
)"
LEMMY_COMMUNITY_ID="$(json_get "$LEMMY_COMMUNITY" community_view.community.id)"
LEMMY_COMMUNITY_AP_ID="$(json_get "$LEMMY_COMMUNITY" community_view.community.actor_id)"

log "Following groups in both directions"
BE_REMOTE_LEMMY_GROUP="$(
    http_form GET "$BASE_URL/api/v1/groups/lookup?uri=$(urlencode "$LEMMY_COMMUNITY_AP_ID")" \
        "$ALICE_TOKEN" \
        200
)"
BE_REMOTE_LEMMY_GROUP_ID="$(json_get "$BE_REMOTE_LEMMY_GROUP" id)"
BE_JOIN_LEMMY="$(
    http_form POST "$BASE_URL/api/v1/groups/$BE_REMOTE_LEMMY_GROUP_ID/join" \
        "$ALICE_TOKEN" \
        200
)"
json_assert "$BE_JOIN_LEMMY" 'data.get("member") is True or data.get("requested") is True' \
    "Unfathomably could not follow the Lemmy community"

LEMMY_REMOTE_BE_GROUP="$(resolve_lemmy_object "$BE_GROUP_AP_ID" "Lemmy resolves the Unfathomably group")"
LEMMY_REMOTE_BE_GROUP_ID="$(json_get "$LEMMY_REMOTE_BE_GROUP" community.community.id)"
LEMMY_FOLLOW_BE="$(
    lemmy_post community/follow \
        "{\"community_id\":$LEMMY_REMOTE_BE_GROUP_ID,\"follow\":true}"
)"
json_assert "$LEMMY_FOLLOW_BE" 'data.get("community_view", {}).get("subscribed") in ["Subscribed", "Pending"]' \
    "Lemmy could not follow the Unfathomably group"

log "Testing Lemmy post delivery into Unfathomably"
LEMMY_TO_BE_TITLE="Lemmy to Unfathomably post $(basename "$WORK_DIR")"
LEMMY_TO_BE_COMMENT="Lemmy top-level body $(basename "$WORK_DIR")"
LEMMY_POST="$(
    lemmy_post post \
        "{\"community_id\":$LEMMY_REMOTE_BE_GROUP_ID,\"name\":\"$LEMMY_TO_BE_TITLE\",\"body\":\"$LEMMY_TO_BE_COMMENT\"}"
)"
LEMMY_POST_ID="$(json_get "$LEMMY_POST" post_view.post.id)"
LEMMY_POST_AP_ID="$(json_get "$LEMMY_POST" post_view.post.ap_id)"
BE_VIEW_OF_LEMMY_POST_ID="$(resolve_be_status_id "$LEMMY_POST_AP_ID" "$ALICE_TOKEN" "Unfathomably resolves Lemmy group post")"

BE_LIKE_LEMMY="$(
    http_form POST "$BASE_URL/api/v1/statuses/$BE_VIEW_OF_LEMMY_POST_ID/favourite" "$ALICE_TOKEN" 200
)"
json_assert "$BE_LIKE_LEMMY" 'data.get("favourited") is True' "Unfathomably could not like Lemmy post"
poll_json_assert GET \
    "$LEMMY_URL/api/v3/post?id=$LEMMY_POST_ID" \
    "$LEMMY_JWT" \
    200 \
    'int(data.get("post_view", {}).get("counts", {}).get("score") or 0) >= 2' \
    "Lemmy sees Unfathomably like on Lemmy post" \
    90 \
    2 >/dev/null

BE_UNLIKE_LEMMY="$(
    http_form POST "$BASE_URL/api/v1/statuses/$BE_VIEW_OF_LEMMY_POST_ID/unfavourite" "$ALICE_TOKEN" 200
)"
json_assert "$BE_UNLIKE_LEMMY" 'data.get("favourited") is False' "Unfathomably could not unlike Lemmy post"
poll_json_assert GET \
    "$LEMMY_URL/api/v3/post?id=$LEMMY_POST_ID" \
    "$LEMMY_JWT" \
    200 \
    'int(data.get("post_view", {}).get("counts", {}).get("score") or 0) == 1' \
    "Lemmy sees Unfathomably unlike on Lemmy post" \
    90 \
    2 >/dev/null

BE_DISLIKE_LEMMY="$(
    http_form POST "$BASE_URL/api/friendica/statuses/$BE_VIEW_OF_LEMMY_POST_ID/dislike" "$ALICE_TOKEN" 200
)"
json_assert "$BE_DISLIKE_LEMMY" 'data.get("disliked") is True and int(data.get("dislikes_count") or 0) >= 1' \
    "Unfathomably could not dislike Lemmy post"
poll_json_assert GET \
    "$LEMMY_URL/api/v3/post?id=$LEMMY_POST_ID" \
    "$LEMMY_JWT" \
    200 \
    'int(data.get("post_view", {}).get("counts", {}).get("downvotes") or 0) >= 1' \
    "Lemmy sees Unfathomably dislike on Lemmy post" \
    90 \
    2 >/dev/null

BE_UNDISLIKE_LEMMY="$(
    http_form POST "$BASE_URL/api/friendica/statuses/$BE_VIEW_OF_LEMMY_POST_ID/undislike" "$ALICE_TOKEN" 200
)"
json_assert "$BE_UNDISLIKE_LEMMY" 'data.get("disliked") is False and int(data.get("dislikes_count") or 0) == 0' \
    "Unfathomably could not remove dislike from Lemmy post"
poll_json_assert GET \
    "$LEMMY_URL/api/v3/post?id=$LEMMY_POST_ID" \
    "$LEMMY_JWT" \
    200 \
    'int(data.get("post_view", {}).get("counts", {}).get("downvotes") or 0) == 0' \
    "Lemmy sees Unfathomably remove dislike from Lemmy post" \
    90 \
    2 >/dev/null

BE_REPLY_TEXT="Unfathomably reply to Lemmy $(basename "$WORK_DIR")"
BE_REPLY="$(
    http_form POST "$BASE_URL/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$BE_REPLY_TEXT" \
        "in_reply_to_id=$BE_VIEW_OF_LEMMY_POST_ID"
)"
BE_REPLY_ID="$(json_get "$BE_REPLY" id)"
BE_REPLY_AP_ID="$(json_get "$BE_REPLY" uri)"
LEMMY_VIEW_OF_BE_REPLY="$(resolve_lemmy_object "$BE_REPLY_AP_ID" "Lemmy resolves Unfathomably reply")"
LEMMY_VIEW_OF_BE_REPLY_ID="$(json_get "$LEMMY_VIEW_OF_BE_REPLY" comment.comment.id)"

http_form DELETE "$BASE_URL/api/v1/statuses/$BE_REPLY_ID" "$ALICE_TOKEN" 200 >/dev/null
poll_json_assert GET \
    "$LEMMY_URL/api/v3/comment?id=$LEMMY_VIEW_OF_BE_REPLY_ID" \
    "$LEMMY_JWT" \
    200 \
    'data.get("comment_view", {}).get("comment", {}).get("deleted") is True' \
    "Lemmy sees Unfathomably deleted reply" \
    90 \
    2 >/dev/null

log "Testing Unfathomably post delivery into Lemmy"
BE_TO_LEMMY_TEXT="Unfathomably to Lemmy post $(basename "$WORK_DIR")"
BE_TO_LEMMY_POST="$(
    http_form POST "$BASE_URL/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$BE_TO_LEMMY_TEXT" \
        "group_id=$BE_REMOTE_LEMMY_GROUP_ID"
)"
BE_TO_LEMMY_POST_ID="$(json_get "$BE_TO_LEMMY_POST" id)"
BE_TO_LEMMY_POST_AP_ID="$(json_get "$BE_TO_LEMMY_POST" uri)"
LEMMY_VIEW_OF_BE_POST="$(resolve_lemmy_object "$BE_TO_LEMMY_POST_AP_ID" "Lemmy resolves Unfathomably group post")"
LEMMY_VIEW_OF_BE_POST_ID="$(json_get "$LEMMY_VIEW_OF_BE_POST" post.post.id)"

LEMMY_COMMENT_TEXT="Lemmy reply to Unfathomably $(basename "$WORK_DIR")"
LEMMY_COMMENT="$(
    lemmy_post comment \
        "{\"post_id\":$LEMMY_VIEW_OF_BE_POST_ID,\"content\":\"$LEMMY_COMMENT_TEXT\"}"
)"
LEMMY_COMMENT_ID="$(json_get "$LEMMY_COMMENT" comment_view.comment.id)"
LEMMY_COMMENT_AP_ID="$(json_get "$LEMMY_COMMENT" comment_view.comment.ap_id)"
BE_VIEW_OF_LEMMY_COMMENT_ID="$(
    resolve_be_context_status_id \
        "$BE_TO_LEMMY_POST_ID" \
        "$LEMMY_COMMENT_AP_ID" \
        "$ALICE_TOKEN" \
        "Unfathomably receives Lemmy reply under Unfathomably post"
)"
poll_json_assert GET \
    "$BASE_URL/api/v1/statuses/$BE_TO_LEMMY_POST_ID/context" \
    "$ALICE_TOKEN" \
    200 \
    "'$LEMMY_COMMENT_TEXT' in str(data)" \
    "Unfathomably sees Lemmy comment under Unfathomably post" \
    90 \
    2 >/dev/null

lemmy_post comment/delete "{\"comment_id\":$LEMMY_COMMENT_ID,\"deleted\":true}" >/dev/null
poll_http_status GET \
    "$BASE_URL/api/v1/statuses/$BE_VIEW_OF_LEMMY_COMMENT_ID" \
    "$ALICE_TOKEN" \
    404 \
    "Unfathomably sees Lemmy deleted reply" \
    90 \
    2

LEMMY_LIKE_BE="$(
    lemmy_post post/like \
        "{\"post_id\":$LEMMY_VIEW_OF_BE_POST_ID,\"score\":1}"
)"
json_assert "$LEMMY_LIKE_BE" 'int(data.get("post_view", {}).get("counts", {}).get("score") or 0) >= 2' \
    "Lemmy could not like Unfathomably post"
poll_json_assert GET \
    "$BASE_URL/api/v1/statuses/$BE_TO_LEMMY_POST_ID" \
    "$ALICE_TOKEN" \
    200 \
    'int(data.get("favourites_count") or 0) >= 1' \
    "Unfathomably sees Lemmy like on Unfathomably post" \
    90 \
    2 >/dev/null

LEMMY_UNLIKE_BE="$(
    lemmy_post post/like \
        "{\"post_id\":$LEMMY_VIEW_OF_BE_POST_ID,\"score\":0}"
)"
json_assert "$LEMMY_UNLIKE_BE" 'int(data.get("post_view", {}).get("counts", {}).get("score") or 0) == 1' \
    "Lemmy could not unlike Unfathomably post"
poll_be_object_unliked \
    "$BE_TO_LEMMY_POST_AP_ID" \
    "http://$LEMMY_HOST/u/lemmyadmin" \
    "Unfathomably sees Lemmy unlike on Unfathomably post"

LEMMY_DISLIKE_BE="$(
    lemmy_post post/like \
        "{\"post_id\":$LEMMY_VIEW_OF_BE_POST_ID,\"score\":-1}"
)"
json_assert "$LEMMY_DISLIKE_BE" 'int(data.get("post_view", {}).get("counts", {}).get("downvotes") or 0) >= 1' \
    "Lemmy could not dislike Unfathomably post"
poll_json_assert GET \
    "$BASE_URL/api/v1/statuses/$BE_TO_LEMMY_POST_ID" \
    "$ALICE_TOKEN" \
    200 \
    'int(data.get("dislikes_count") or 0) >= 1 and data.get("disliked") is False' \
    "Unfathomably sees Lemmy dislike on Unfathomably post" \
    90 \
    2 >/dev/null

LEMMY_UNDISLIKE_BE="$(
    lemmy_post post/like \
        "{\"post_id\":$LEMMY_VIEW_OF_BE_POST_ID,\"score\":0}"
)"
json_assert "$LEMMY_UNDISLIKE_BE" 'int(data.get("post_view", {}).get("counts", {}).get("downvotes") or 0) == 0' \
    "Lemmy could not remove dislike from Unfathomably post"

LEMMY_REMOTE_UNDISLIKE_COVERAGE="  * supported: Lemmy-to-Unfathomably dislike removal"

if ! poll_json_assert_optional GET \
    "$BASE_URL/api/v1/statuses/$BE_TO_LEMMY_POST_ID" \
    "$ALICE_TOKEN" \
    200 \
    'int(data.get("dislikes_count") or 0) == 0' \
    30 \
    2; then
    LEMMY_REMOTE_UNDISLIKE_COVERAGE="  * not_supported: stock Lemmy removed its downvote locally but emitted no federated Undo for Unfathomably to consume"
    printf 'not_supported: stock Lemmy removed its downvote locally but emitted no federated Undo for Unfathomably to consume\n'
fi

log "Deleting posts and unfollowing groups"
lemmy_post post/delete "{\"post_id\":$LEMMY_POST_ID,\"deleted\":true}" >/dev/null
poll_http_status GET \
    "$BASE_URL/api/v1/statuses/$BE_VIEW_OF_LEMMY_POST_ID" \
    "$ALICE_TOKEN" \
    404 \
    "Unfathomably sees deleted Lemmy post" \
    90 \
    2

http_form DELETE "$BASE_URL/api/v1/statuses/$BE_TO_LEMMY_POST_ID" "$ALICE_TOKEN" 200 >/dev/null
poll_json_assert GET \
    "$LEMMY_URL/api/v3/post?id=$LEMMY_VIEW_OF_BE_POST_ID" \
    "$LEMMY_JWT" \
    200 \
    'data.get("post_view", {}).get("post", {}).get("deleted") is True' \
    "Lemmy sees deleted Unfathomably post" \
    90 \
    2 >/dev/null

BE_LEAVE_LEMMY="$(
    http_form POST "$BASE_URL/api/v1/groups/$BE_REMOTE_LEMMY_GROUP_ID/leave" "$ALICE_TOKEN" 200
)"
json_assert "$BE_LEAVE_LEMMY" 'data.get("member") is False and data.get("requested") is False' \
    "Unfathomably could not unfollow Lemmy community"

LEMMY_UNFOLLOW_BE="$(
    lemmy_post community/follow \
        "{\"community_id\":$LEMMY_REMOTE_BE_GROUP_ID,\"follow\":false}"
)"
json_assert "$LEMMY_UNFOLLOW_BE" 'data.get("community_view", {}).get("subscribed") in ["NotSubscribed", "NotSubscribedPending"]' \
    "Lemmy could not unfollow Unfathomably group"

log "Checking logs for obvious crashes"
for container in "$PREFIX-lemmy" "$PREFIX-lemmy-proxy" "$BE_PREFIX-a"; do
    if docker logs "$container" 2>&1 |
        grep -E "status=500|Internal Server Error|panicked at|thread '.*' panicked|GenServer terminating|FunctionClauseError|UndefinedFunctionError|Protocol\\.UndefinedError" >/dev/null; then
        docker logs --tail 240 "$container" >&2
        fail "$container logged errors during Lemmy smoke run"
    fi
done

cat <<EOF

Unfathomably/Lemmy federation smoke test passed.

Covered:
  * supported: clean Lemmy Docker boot with PostgreSQL, pict-rs, and internal proxy
  * supported: Unfathomably follow of a Lemmy community
  * supported: Lemmy follow of an Unfathomably group
  * supported: group posts, replies, and reply deletion in both directions
  * supported: Unfathomably-to-Lemmy like, unlike, dislike, and undislike
  * supported: Lemmy-to-Unfathomably like, unlike, and dislike
$LEMMY_REMOTE_UNDISLIKE_COVERAGE
  * supported: post deletion propagation both directions
  * supported: group unfollow both directions
  * supported: basic log scan for 500/crash output

Run with KEEP_SMOKE=1 to leave both servers available for manual browser/API work.
EOF

# end of unfathomably-lemmy-smoke.sh
