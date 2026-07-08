#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-piefed-smoke.sh
#
# Purpose:
#
#   Start a clean Unfathomably smoke instance and a clean PieFed
#   instance on the same Docker network, then prove that group-style
#   federation works between them.
#
# Responsibilities:
#
#   * build or reuse a local PieFed Docker image from the upstream
#     pyfedi source tree
#   * boot PieFed with PostgreSQL, Redis, Celery, and a small internal
#     HTTP reverse proxy
#   * reuse the existing two-instance Unfathomably smoke bootstrap so
#     the backend is known-good before PieFed-specific checks begin
#   * exercise follow, unfollow, post, comment, like, unlike, and delete
#     paths across the Unfathomably/PieFed boundary
#   * fail loudly if either server logs obvious 500/crash output
#
# This file intentionally does NOT contain:
#
#   * production deployment logic
#   * TLS certificate provisioning
#   * frontend/browser automation
#

set -euo pipefail

IMAGE="${SMOKE_IMAGE:-unfathomably-elixir-smoke:otp28}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16-alpine}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.27-alpine}"
PIEFED_IMAGE="${PIEFED_IMAGE:-unfathomably-piefed-smoke:http-ap-v1}"
PIEFED_REPO="${PIEFED_REPO:-https://codeberg.org/rimu/pyfedi.git}"
PIEFED_REF="${PIEFED_REF:-main}"
PIEFED_REBUILD="${PIEFED_REBUILD:-0}"

PREFIX="${SMOKE_PREFIX:-unfathomably-piefed-smoke}"
NETWORK="${SMOKE_NETWORK:-$PREFIX-net}"
BE_PREFIX="$PREFIX-be"

A_HOST="${SMOKE_A_HOST:-smoke-a.test}"
B_HOST="${SMOKE_B_HOST:-smoke-b.test}"
A_PORT="${SMOKE_A_PORT:-4631}"
B_PORT="${SMOKE_B_PORT:-4632}"
PIEFED_HOST="${PIEFED_HOST:-piefed-smoke.test}"
PIEFED_PORT="${PIEFED_PORT:-4634}"

PASSWORD="${SMOKE_USER_PASSWORD:-SmokeTest_01}"
DB_PASSWORD="${SMOKE_DB_PASSWORD:-postgres}"
KEEP_SMOKE="${KEEP_SMOKE:-0}"
PIEFED_QUEUE_DRAIN_TIMEOUT="${PIEFED_QUEUE_DRAIN_TIMEOUT:-8}"

WORK_DIR="${SMOKE_WORK_DIR:-}"
if [ -z "$WORK_DIR" ]; then
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/unfathomably-piefed-smoke.XXXXXX")"
fi

BASE_URL="http://127.0.0.1:$A_PORT"
PIEFED_URL="http://127.0.0.1:$PIEFED_PORT"

log() {
    printf '\n==> %s\n' "$*"
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2

    for container in \
        "$PREFIX-piefed-proxy" \
        "$PREFIX-piefed-web" \
        "$PREFIX-piefed-celery" \
        "$PREFIX-piefed-redis" \
        "$PREFIX-piefed-db" \
        "$BE_PREFIX-a" \
        "$BE_PREFIX-b" \
        "$BE_PREFIX-db"; do
        if docker inspect "$container" >/dev/null 2>&1; then
            printf '\n--- docker logs --tail 180 %s ---\n' "$container" >&2
            docker logs --tail 180 "$container" >&2 || true
        fi
    done

    exit 1
}

cleanup() {
    if [ "$KEEP_SMOKE" = "1" ]; then
        cat <<EOF

Smoke containers preserved because KEEP_SMOKE=1.
Unfathomably: $BASE_URL
PieFed:        $PIEFED_URL
Work dir:      $WORK_DIR
EOF
        return
    fi

    docker rm -f \
        "$PREFIX-piefed-proxy" \
        "$PREFIX-piefed-web" \
        "$PREFIX-piefed-celery" \
        "$PREFIX-piefed-redis" \
        "$PREFIX-piefed-db" \
        "$BE_PREFIX-a" \
        "$BE_PREFIX-b" \
        "$BE_PREFIX-db" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR"
}

trap cleanup EXIT

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

json_assert() {
    local json="$1"
    local expr="$2"
    local message="$3"

    json_matches "$json" "$expr" || fail "$message"
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

poll_http_status() {
    local method="$1"
    local url="$2"
    local token="$3"
    local expected="$4"
    local message="$5"
    local attempts="${6:-90}"
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
    local attempts="${7:-90}"
    local delay="${8:-2}"
    local body="${9:-}"
    local result

    for _ in $(seq 1 "$attempts"); do
        if [ "$method" = "GET" ]; then
            result="$(http_form GET "$url" "$token" "$expected" || true)"
        elif [ -n "$body" ]; then
            result="$(http_json "$method" "$url" "$expected" "$body" "$token" || true)"
        else
            result="$(http_json "$method" "$url" "$expected" '{}' "$token" || true)"
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

wait_http() {
    local url="$1"
    local name="$2"

    for _ in $(seq 1 150); do
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
            "client_name=piefed-smoke" \
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

piefed_json() {
    local method="$1"
    local path="$2"
    local body="$3"

    http_json "$method" "$PIEFED_URL/api/alpha/$path" 200 "$body" "$PIEFED_JWT"
}

piefed_get_auth() {
    local path="$1"

    http_form GET "$PIEFED_URL/api/alpha/$path" "$PIEFED_JWT" 200
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

resolve_piefed_object() {
    local uri="$1"
    local message="$2"

    poll_json_assert GET \
        "$PIEFED_URL/api/alpha/resolve_object?q=$(urlencode "$uri")" \
        "$PIEFED_JWT" \
        200 \
        '(data.get("post") is not None) or (data.get("comment") is not None) or (data.get("community") is not None)' \
        "$message" \
        100 \
        2
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

patch_piefed_source_for_smoke() {
    python3 - "$WORK_DIR/pyfedi-src" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
replacements = (
    (
        "'https://' + current_app.config['SERVER_NAME']",
        "current_app.config['HTTP_PROTOCOL'] + '://' + current_app.config['SERVER_NAME']",
    ),
    (
        'https://{current_app.config["SERVER_NAME"]}',
        '{current_app.config["HTTP_PROTOCOL"]}://{current_app.config["SERVER_NAME"]}',
    ),
    (
        "https://{current_app.config['SERVER_NAME']}",
        "{current_app.config['HTTP_PROTOCOL']}://{current_app.config['SERVER_NAME']}",
    ),
    (
        'f"https://{server}',
        'f"{current_app.config[\'HTTP_PROTOCOL\']}://{server}',
    ),
    (
        "f'https://{server}",
        "f'{current_app.config[\"HTTP_PROTOCOL\"]}://{server}",
    ),
    (
        "    if current_app.debug:\n        return False",
        "    if current_app.debug or os.environ.get('PIEFED_SMOKE_ALLOW_PRIVATE_HTTP') == '1':\n"
        "        return False",
    ),
)

changed = []
for path in root.rglob("*.py"):
    text = path.read_text(encoding="utf-8")
    new_text = text
    for old, new in replacements:
        new_text = new_text.replace(old, new)
    if new_text != text:
        path.write_text(new_text, encoding="utf-8")
        changed.append(path.relative_to(root).as_posix())

if not changed:
    raise SystemExit("PieFed HTTP ActivityPub source patch did not touch any files")

print("patched PieFed source files:")
for name in changed:
    print(f"  {name}")
PY
}

ensure_piefed_image() {
    if docker image inspect "$PIEFED_IMAGE" >/dev/null 2>&1; then
        if [ "$PIEFED_REBUILD" != "1" ]; then
            return
        fi

        docker image rm -f "$PIEFED_IMAGE" >/dev/null
    fi

    log "Building PieFed image $PIEFED_IMAGE"

    git clone --depth 1 --branch "$PIEFED_REF" "$PIEFED_REPO" "$WORK_DIR/pyfedi-src"
    patch_piefed_source_for_smoke

    #
    # PieFed's Dockerfile uses BuildKit cache mounts for pip, so generate an
    # equivalent smoke Dockerfile that performs normal COPY/RUN steps instead.
    # This keeps the smoke portable without carrying a fork of PieFed here.
    #
    cat >"$WORK_DIR/pyfedi-src/Dockerfile.smoke-legacy" <<'EOF'
FROM python:3.13-alpine AS builder

RUN adduser -D python

RUN apk add --no-cache pkgconfig gcc python3-dev musl-dev tesseract-ocr tesseract-ocr-data-eng postgresql-client bash

COPY requirements.txt /tmp/requirements.txt
RUN pip3 install --no-cache-dir -r /tmp/requirements.txt
RUN pip3 install --no-cache-dir gunicorn

COPY --chown=python:python . /app

WORKDIR /app

RUN pybabel compile -d app/translations || true

RUN chmod u+x ./entrypoint.sh
RUN chmod u+x ./entrypoint_celery.sh
RUN chmod u+x ./entrypoint_async.sh

USER python
ENTRYPOINT ["./entrypoint.sh"]
EOF

    docker build -f "$WORK_DIR/pyfedi-src/Dockerfile.smoke-legacy" -t "$PIEFED_IMAGE" "$WORK_DIR/pyfedi-src"
}

write_piefed_proxy_config() {
    cat >"$WORK_DIR/piefed-nginx.conf" <<EOF
events {}
http {
  server {
    listen 80;
    client_max_body_size 20m;

    location / {
      proxy_pass http://$PREFIX-piefed-web:5000;
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

piefed_env_args() {
    printf '%s\n' \
        -e "SERVER_NAME=$PIEFED_HOST" \
        -e "HTTP_PROTOCOL=http" \
        -e "SECRET_KEY=piefed-smoke-secret-key" \
        -e "DATABASE_URL=postgresql+psycopg2://piefed:$DB_PASSWORD@$PREFIX-piefed-db:5432/piefed" \
        -e "CACHE_TYPE=RedisCache" \
        -e "CACHE_REDIS_URL=redis://$PREFIX-piefed-redis:6379/1" \
        -e "CELERY_BROKER_URL=redis://$PREFIX-piefed-redis:6379/0" \
        -e "RESULT_BACKEND=redis://$PREFIX-piefed-redis:6379/0" \
        -e "ENABLE_ALPHA_API=true" \
        -e "PIEFED_SMOKE_ALLOW_PRIVATE_HTTP=1" \
        -e "SKIP_RATE_LIMIT_IPS=127.0.0.1" \
        -e "SESSION_COOKIE_SECURE=0" \
        -e "FULL_AP_CONTEXT=0" \
        -e "LOG_ACTIVITYPUB_TO_DB=1" \
        -e "LOG_ACTIVITYPUB_TO_FILE=0" \
        -e "MAIL_FROM=noreply@$PIEFED_HOST"
}

start_piefed() {
    write_piefed_proxy_config

    docker rm -f \
        "$PREFIX-piefed-proxy" \
        "$PREFIX-piefed-web" \
        "$PREFIX-piefed-celery" \
        "$PREFIX-piefed-redis" \
        "$PREFIX-piefed-db" >/dev/null 2>&1 || true

    docker run -d \
        --name "$PREFIX-piefed-db" \
        --network "$NETWORK" \
        -e POSTGRES_USER=piefed \
        -e POSTGRES_PASSWORD="$DB_PASSWORD" \
        -e POSTGRES_DB=piefed \
        "$POSTGRES_IMAGE" >/dev/null

    for _ in $(seq 1 90); do
        if docker exec "$PREFIX-piefed-db" pg_isready -U piefed >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    docker run -d \
        --name "$PREFIX-piefed-redis" \
        --network "$NETWORK" \
        "$REDIS_IMAGE" >/dev/null

    docker run -d \
        --name "$PREFIX-piefed-web" \
        --network "$NETWORK" \
        --entrypoint sh \
        $(piefed_env_args) \
        "$PIEFED_IMAGE" \
        -c "export FLASK_APP=pyfedi.py; flask db upgrade && printf 'piefedadmin\nadmin@$PIEFED_HOST\n$PASSWORD\n' | flask init-db && flask populate_community_search && gunicorn -w 2 -b 0.0.0.0:5000 'pyfedi:app'" >/dev/null

    docker run -d \
        --name "$PREFIX-piefed-celery" \
        --network "$NETWORK" \
        --entrypoint sh \
        $(piefed_env_args) \
        "$PIEFED_IMAGE" \
        -c "sleep 20; celery -A celery_worker_docker.celery worker --loglevel=INFO --concurrency=2 --queues=celery,background,send" >/dev/null

    docker run -d \
        --name "$PREFIX-piefed-proxy" \
        --network "$NETWORK" \
        --network-alias "$PIEFED_HOST" \
        -p "127.0.0.1:$PIEFED_PORT:80" \
        -v "$WORK_DIR/piefed-nginx.conf:/etc/nginx/nginx.conf:ro" \
        "$NGINX_IMAGE" >/dev/null

    wait_http "$PIEFED_URL/api/alpha/site/version" "PieFed"
}

drain_piefed_queue() {
    timeout "${PIEFED_QUEUE_DRAIN_TIMEOUT}s" \
        docker exec "$PREFIX-piefed-web" \
        sh -c 'export FLASK_APP=pyfedi.py; flask send-queue' >/dev/null 2>&1 || true
}

run_piefed_queue_until() {
    local attempts="${1:-1}"

    for _ in $(seq 1 "$attempts"); do
        drain_piefed_queue
        sleep 2
    done
}

docker rm -f \
    "$PREFIX-piefed-proxy" \
    "$PREFIX-piefed-web" \
    "$PREFIX-piefed-celery" \
    "$PREFIX-piefed-redis" \
    "$PREFIX-piefed-db" >/dev/null 2>&1 || true

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
build_scripts/two-instance-federation-smoke.sh >/tmp/unfathomably-piefed-bootstrap.log 2>&1 || {
    cat /tmp/unfathomably-piefed-bootstrap.log >&2 || true
    fail "Unfathomably bootstrap smoke failed"
}

log "Starting PieFed"
ensure_piefed_image
start_piefed

log "Creating API credentials"
ALICE_TOKEN="$(be_token alice)"

PIEFED_LOGIN="$(
    http_json POST "$PIEFED_URL/api/alpha/user/login" 200 \
        "{\"username\":\"piefedadmin\",\"password\":\"$PASSWORD\"}"
)"
PIEFED_JWT="$(json_get "$PIEFED_LOGIN" jwt)"

log "Creating local group and PieFed community"
BE_GROUP="$(
    http_form POST "$BASE_URL/api/v1/groups" "$ALICE_TOKEN" 200 \
        "display_name=Unfathomably PieFed Smoke" \
        "name=unfathomably_piefed_smoke"
)"
BE_GROUP_ID="$(json_get "$BE_GROUP" id)"
BE_GROUP_AP_ID="$(json_get "$BE_GROUP" ap_id)"

PIEFED_COMMUNITY="$(
    piefed_json POST community \
        '{"name":"piefed_smoke","title":"PieFed Smoke","description":"Smoke test community","nsfw":false,"local_only":false}'
)"
PIEFED_COMMUNITY_ID="$(json_get "$PIEFED_COMMUNITY" community_view.community.id)"
PIEFED_COMMUNITY_AP_ID="$(json_get "$PIEFED_COMMUNITY" community_view.community.actor_id)"

log "Following groups in both directions"
BE_REMOTE_PIEFED_GROUP="$(
    http_form GET "$BASE_URL/api/v1/groups/lookup?uri=$(urlencode "$PIEFED_COMMUNITY_AP_ID")" \
        "$ALICE_TOKEN" \
        200
)"
BE_REMOTE_PIEFED_GROUP_ID="$(json_get "$BE_REMOTE_PIEFED_GROUP" id)"
BE_JOIN_PIEFED="$(
    http_form POST "$BASE_URL/api/v1/groups/$BE_REMOTE_PIEFED_GROUP_ID/join" \
        "$ALICE_TOKEN" \
        200
)"
json_assert "$BE_JOIN_PIEFED" 'data.get("member") is True or data.get("requested") is True' \
    "Unfathomably could not follow the PieFed community"
run_piefed_queue_until

PIEFED_REMOTE_BE_GROUP="$(resolve_piefed_object "$BE_GROUP_AP_ID" "PieFed resolves the Unfathomably group")"
PIEFED_REMOTE_BE_GROUP_ID="$(json_get "$PIEFED_REMOTE_BE_GROUP" community.community.id)"
PIEFED_FOLLOW_BE="$(
    piefed_json POST community/follow \
        "{\"community_id\":$PIEFED_REMOTE_BE_GROUP_ID,\"follow\":true}"
)"
json_assert "$PIEFED_FOLLOW_BE" 'data.get("community_view", {}).get("subscribed") in ["Subscribed", "Pending"]' \
    "PieFed could not follow the Unfathomably group"
run_piefed_queue_until

log "Testing PieFed post delivery into Unfathomably"
PIEFED_TO_BE_TITLE="PieFed to Unfathomably post $(basename "$WORK_DIR")"
PIEFED_TO_BE_COMMENT="PieFed top-level body $(basename "$WORK_DIR")"
PIEFED_POST="$(
    piefed_json POST post \
        "{\"community_id\":$PIEFED_REMOTE_BE_GROUP_ID,\"title\":\"$PIEFED_TO_BE_TITLE\",\"body\":\"$PIEFED_TO_BE_COMMENT\"}"
)"
PIEFED_POST_ID="$(json_get "$PIEFED_POST" post_view.post.id)"
PIEFED_POST_AP_ID="$(json_get "$PIEFED_POST" post_view.post.ap_id)"
run_piefed_queue_until
BE_VIEW_OF_PIEFED_POST_ID="$(resolve_be_status_id "$PIEFED_POST_AP_ID" "$ALICE_TOKEN" "Unfathomably resolves PieFed group post")"

BE_LIKE_PIEFED="$(
    http_form POST "$BASE_URL/api/v1/statuses/$BE_VIEW_OF_PIEFED_POST_ID/favourite" "$ALICE_TOKEN" 200
)"
json_assert "$BE_LIKE_PIEFED" 'data.get("favourited") is True' "Unfathomably could not like PieFed post"
run_piefed_queue_until
poll_json_assert GET \
    "$PIEFED_URL/api/alpha/post?id=$PIEFED_POST_ID" \
    "$PIEFED_JWT" \
    200 \
    'int(data.get("post_view", {}).get("counts", {}).get("score") or 0) >= 2' \
    "PieFed sees Unfathomably like on PieFed post" \
    90 \
    2 >/dev/null

BE_UNLIKE_PIEFED="$(
    http_form POST "$BASE_URL/api/v1/statuses/$BE_VIEW_OF_PIEFED_POST_ID/unfavourite" "$ALICE_TOKEN" 200
)"
json_assert "$BE_UNLIKE_PIEFED" 'data.get("favourited") is False' "Unfathomably could not unlike PieFed post"
run_piefed_queue_until
poll_json_assert GET \
    "$PIEFED_URL/api/alpha/post?id=$PIEFED_POST_ID" \
    "$PIEFED_JWT" \
    200 \
    'int(data.get("post_view", {}).get("counts", {}).get("score") or 0) == 1' \
    "PieFed sees Unfathomably unlike on PieFed post" \
    90 \
    2 >/dev/null

BE_REPLY_TEXT="Unfathomably reply to PieFed $(basename "$WORK_DIR")"
BE_REPLY="$(
    http_form POST "$BASE_URL/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$BE_REPLY_TEXT" \
        "in_reply_to_id=$BE_VIEW_OF_PIEFED_POST_ID"
)"
BE_REPLY_ID="$(json_get "$BE_REPLY" id)"
BE_REPLY_AP_ID="$(json_get "$BE_REPLY" uri)"
run_piefed_queue_until
PIEFED_VIEW_OF_BE_REPLY="$(resolve_piefed_object "$BE_REPLY_AP_ID" "PieFed resolves Unfathomably reply")"
PIEFED_VIEW_OF_BE_REPLY_ID="$(json_get "$PIEFED_VIEW_OF_BE_REPLY" comment.comment.id)"

http_form DELETE "$BASE_URL/api/v1/statuses/$BE_REPLY_ID" "$ALICE_TOKEN" 200 >/dev/null
run_piefed_queue_until
poll_json_assert GET \
    "$PIEFED_URL/api/alpha/comment?id=$PIEFED_VIEW_OF_BE_REPLY_ID" \
    "$PIEFED_JWT" \
    200 \
    'data.get("comment_view", {}).get("comment", {}).get("deleted") is True' \
    "PieFed sees Unfathomably deleted reply" \
    90 \
    2 >/dev/null

log "Testing Unfathomably post delivery into PieFed"
BE_TO_PIEFED_TEXT="Unfathomably to PieFed post $(basename "$WORK_DIR")"
BE_TO_PIEFED_POST="$(
    http_form POST "$BASE_URL/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$BE_TO_PIEFED_TEXT" \
        "group_id=$BE_REMOTE_PIEFED_GROUP_ID"
)"
BE_TO_PIEFED_POST_ID="$(json_get "$BE_TO_PIEFED_POST" id)"
BE_TO_PIEFED_POST_AP_ID="$(json_get "$BE_TO_PIEFED_POST" uri)"
run_piefed_queue_until
PIEFED_VIEW_OF_BE_POST="$(resolve_piefed_object "$BE_TO_PIEFED_POST_AP_ID" "PieFed resolves Unfathomably group post")"
PIEFED_VIEW_OF_BE_POST_ID="$(json_get "$PIEFED_VIEW_OF_BE_POST" post.post.id)"

PIEFED_COMMENT_TEXT="PieFed reply to Unfathomably $(basename "$WORK_DIR")"
PIEFED_COMMENT="$(
    piefed_json POST comment \
        "{\"post_id\":$PIEFED_VIEW_OF_BE_POST_ID,\"body\":\"$PIEFED_COMMENT_TEXT\"}"
)"
PIEFED_COMMENT_ID="$(json_get "$PIEFED_COMMENT" comment_view.comment.id)"
PIEFED_COMMENT_AP_ID="$(json_get "$PIEFED_COMMENT" comment_view.comment.ap_id)"
run_piefed_queue_until
BE_VIEW_OF_PIEFED_COMMENT_ID="$(
    resolve_be_context_status_id \
        "$BE_TO_PIEFED_POST_ID" \
        "$PIEFED_COMMENT_AP_ID" \
        "$ALICE_TOKEN" \
        "Unfathomably receives PieFed reply under Unfathomably post"
)"
poll_json_assert GET \
    "$BASE_URL/api/v1/statuses/$BE_TO_PIEFED_POST_ID/context" \
    "$ALICE_TOKEN" \
    200 \
    "'$PIEFED_COMMENT_TEXT' in str(data)" \
    "Unfathomably sees PieFed comment under Unfathomably post" \
    90 \
    2 >/dev/null

piefed_json POST comment/delete "{\"comment_id\":$PIEFED_COMMENT_ID,\"deleted\":true}" >/dev/null
run_piefed_queue_until
poll_http_status GET \
    "$BASE_URL/api/v1/statuses/$BE_VIEW_OF_PIEFED_COMMENT_ID" \
    "$ALICE_TOKEN" \
    404 \
    "Unfathomably sees PieFed deleted reply" \
    90 \
    2

PIEFED_LIKE_BE="$(
    piefed_json POST post/like \
        "{\"post_id\":$PIEFED_VIEW_OF_BE_POST_ID,\"score\":1}"
)"
json_assert "$PIEFED_LIKE_BE" 'int(data.get("post_view", {}).get("counts", {}).get("score") or 0) >= 2' \
    "PieFed could not like Unfathomably post"
run_piefed_queue_until
poll_json_assert GET \
    "$BASE_URL/api/v1/statuses/$BE_TO_PIEFED_POST_ID" \
    "$ALICE_TOKEN" \
    200 \
    'int(data.get("favourites_count") or 0) >= 1' \
    "Unfathomably sees PieFed like on Unfathomably post" \
    90 \
    2 >/dev/null

PIEFED_UNLIKE_BE="$(
    piefed_json POST post/like \
        "{\"post_id\":$PIEFED_VIEW_OF_BE_POST_ID,\"score\":0}"
)"
json_assert "$PIEFED_UNLIKE_BE" 'int(data.get("post_view", {}).get("counts", {}).get("score") or 0) == 1' \
    "PieFed could not unlike Unfathomably post"
run_piefed_queue_until
poll_be_object_unliked \
    "$BE_TO_PIEFED_POST_AP_ID" \
    "http://$PIEFED_HOST/u/piefedadmin" \
    "Unfathomably sees PieFed unlike on Unfathomably post"

log "Deleting posts and unfollowing groups"
piefed_json POST post/delete "{\"post_id\":$PIEFED_POST_ID,\"deleted\":true}" >/dev/null
run_piefed_queue_until
poll_http_status GET \
    "$BASE_URL/api/v1/statuses/$BE_VIEW_OF_PIEFED_POST_ID" \
    "$ALICE_TOKEN" \
    404 \
    "Unfathomably sees deleted PieFed post" \
    90 \
    2

http_form DELETE "$BASE_URL/api/v1/statuses/$BE_TO_PIEFED_POST_ID" "$ALICE_TOKEN" 200 >/dev/null
run_piefed_queue_until
poll_json_assert GET \
    "$PIEFED_URL/api/alpha/post?id=$PIEFED_VIEW_OF_BE_POST_ID" \
    "$PIEFED_JWT" \
    200 \
    'data.get("post_view", {}).get("post", {}).get("deleted") is True' \
    "PieFed sees deleted Unfathomably post" \
    90 \
    2 >/dev/null

BE_LEAVE_PIEFED="$(
    http_form POST "$BASE_URL/api/v1/groups/$BE_REMOTE_PIEFED_GROUP_ID/leave" "$ALICE_TOKEN" 200
)"
json_assert "$BE_LEAVE_PIEFED" 'data.get("member") is False and data.get("requested") is False' \
    "Unfathomably could not unfollow PieFed community"
run_piefed_queue_until

PIEFED_UNFOLLOW_BE="$(
    piefed_json POST community/follow \
        "{\"community_id\":$PIEFED_REMOTE_BE_GROUP_ID,\"follow\":false}"
)"
json_assert "$PIEFED_UNFOLLOW_BE" 'data.get("community_view", {}).get("subscribed") in ["NotSubscribed", "NotSubscribedPending"]' \
    "PieFed could not unfollow Unfathomably group"

log "Checking logs for obvious crashes"
for container in "$PREFIX-piefed-web" "$PREFIX-piefed-celery" "$PREFIX-piefed-proxy" "$BE_PREFIX-a"; do
    if docker logs "$container" 2>&1 |
        grep -E "status=500|Internal Server Error|Traceback \\(most recent call last\\)|Exception on /|GenServer terminating|FunctionClauseError|UndefinedFunctionError|Protocol\\.UndefinedError" >/dev/null; then
        docker logs --tail 260 "$container" >&2
        fail "$container logged errors during PieFed smoke run"
    fi
done

cat <<EOF

Unfathomably/PieFed federation smoke test passed.

Covered:
  * clean PieFed Docker boot with PostgreSQL, Redis, Celery, and internal proxy
  * Unfathomably follow of a PieFed community
  * PieFed follow of an Unfathomably group
  * PieFed-to-Unfathomably group post, like, unlike, reply, reply delete
  * Unfathomably-to-PieFed group post, like, unlike, reply, reply delete
  * post deletion propagation both directions
  * group unfollow both directions
  * basic log scan for 500/crash output

Run with KEEP_SMOKE=1 to leave both servers available for manual browser/API work.
EOF

# end of unfathomably-piefed-smoke.sh
