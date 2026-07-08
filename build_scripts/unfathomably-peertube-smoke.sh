#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-peertube-smoke.sh
#
# Purpose:
#
#   Start a clean Unfathomably backend and a clean PeerTube
#   instance on the same Docker network, then prove the parts of
#   channel/video federation that PeerTube supports in the wild.
#
# Responsibilities:
#
#   * boot an unmodified PeerTube image with PostgreSQL, Redis, and nginx
#   * advertise HTTPS actor URLs through disposable local TLS proxies
#   * create a PeerTube channel and upload a small local video
#   * exercise channel follow, video resolution, like, unlike, comment,
#     comment delete, video delete, and follow cleanup paths
#   * record PeerTube stock limitations around non-video group posts
#   * fail loudly if either server logs obvious 500/crash output
#
# This file intentionally does NOT contain:
#
#   * production deployment logic
#   * persistent PeerTube database management
#   * public DNS or ACME certificate provisioning
#   * patches to PeerTube itself
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PREFIX="${SMOKE_PREFIX:-unfathomably-peertube-smoke}"
NETWORK="${SMOKE_NETWORK:-$PREFIX-net}"

DB_CONTAINER="${DB_CONTAINER:-$PREFIX-db}"
REDIS_CONTAINER="${REDIS_CONTAINER:-$PREFIX-redis}"
BE_CONTAINER="${BE_CONTAINER:-$PREFIX-be}"
BE_PROXY_CONTAINER="${BE_PROXY_CONTAINER:-$PREFIX-be-proxy}"
PEERTUBE_CONTAINER="${PEERTUBE_CONTAINER:-$PREFIX-peertube}"
PEERTUBE_PROXY_CONTAINER="${PEERTUBE_PROXY_CONTAINER:-$PREFIX-peertube-proxy}"

BE_HOST="${BE_HOST:-unfathomably-peertube.test}"
BE_APP_HOST="${BE_APP_HOST:-unfathomably-peertube-app}"
PEERTUBE_HOST="${PEERTUBE_HOST:-peertube-ref.test}"
PEERTUBE_APP_HOST="${PEERTUBE_APP_HOST:-peertube-app}"

BE_PORT="${BE_PORT:-4661}"
PEERTUBE_PORT="${PEERTUBE_PORT:-4662}"

IMAGE="${SMOKE_IMAGE:-unfathomably-elixir-smoke:otp28}"
PEERTUBE_IMAGE="${PEERTUBE_IMAGE:-chocobozzz/peertube:production}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:17-alpine}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:8-alpine}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.27-alpine}"

PASSWORD="${SMOKE_USER_PASSWORD:-SmokeTest_01}"
DB_PASSWORD="${SMOKE_DB_PASSWORD:-postgres}"
PEERTUBE_DB_NAME="${PEERTUBE_DB_NAME:-peertube_smoke}"
BE_DB_NAME="${BE_DB_NAME:-unfathomably_peertube_smoke_be}"
KEEP_SMOKE="${KEEP_SMOKE:-0}"
POLL_ATTEMPTS="${SMOKE_POLL_ATTEMPTS:-100}"

WORK_DIR="${SMOKE_WORK_DIR:-}"
if [ -z "$WORK_DIR" ]; then
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/unfathomably-peertube-smoke.XXXXXX")"
fi

BE_BASE="http://127.0.0.1:$BE_PORT"
PEERTUBE_BASE="http://127.0.0.1:$PEERTUBE_PORT"

BE_SECRET="$WORK_DIR/be/dev.secret.exs"
BE_NGINX_CONF="$WORK_DIR/be-nginx/default.conf"
BE_CERT_DIR="$WORK_DIR/be-certs"
PEERTUBE_ENV="$WORK_DIR/peertube/.env"
PEERTUBE_NGINX_CONF="$WORK_DIR/peertube-nginx/default.conf"
PEERTUBE_CERT_DIR="$WORK_DIR/peertube-certs"
PEERTUBE_DATA_DIR="$WORK_DIR/peertube-data"
PEERTUBE_CONFIG_DIR="$WORK_DIR/peertube-config"

log() {
    printf '\n==> %s\n' "$*"
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    dump_logs
    exit 1
}

dump_logs() {
    for container in \
        "$BE_CONTAINER" \
        "$BE_PROXY_CONTAINER" \
        "$PEERTUBE_CONTAINER" \
        "$PEERTUBE_PROXY_CONTAINER" \
        "$DB_CONTAINER" \
        "$REDIS_CONTAINER"; do
        if docker inspect "$container" >/dev/null 2>&1; then
            printf '\n--- docker logs --tail 180 %s ---\n' "$container" >&2
            docker logs --tail 180 "$container" >&2 || true
        fi
    done
}

cleanup() {
    if [ "$KEEP_SMOKE" = "1" ]; then
        cat <<EOF

Smoke containers preserved because KEEP_SMOKE=1.
Unfathomably: $BE_BASE      (federated host: $BE_HOST)
PeerTube:      $PEERTUBE_BASE  (federated host: $PEERTUBE_HOST)
Work dir:      $WORK_DIR
EOF
        return
    fi

    docker rm -f \
        "$PEERTUBE_PROXY_CONTAINER" \
        "$PEERTUBE_CONTAINER" \
        "$BE_PROXY_CONTAINER" \
        "$BE_CONTAINER" \
        "$REDIS_CONTAINER" \
        "$DB_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true

    if ! rm -rf "$WORK_DIR" >/dev/null 2>&1; then
        docker run --rm \
            -v "$WORK_DIR:/work" \
            --entrypoint sh \
            "$NGINX_IMAGE" \
            -c 'find /work -mindepth 1 -exec rm -rf {} +' >/dev/null 2>&1 || true
        rmdir "$WORK_DIR" >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT

random_hex() {
    openssl rand -hex "$1"
}

urlencode() {
    python3 - "$1" <<'PY'
import sys
import urllib.parse

print(urllib.parse.quote(sys.argv[1], safe=""))
PY
}

json_get() {
    local json="$1"
    local path="$2"

    JSON_PAYLOAD="$json" python3 - "$path" <<'PY'
import json
import os
import sys

data = json.loads(os.environ["JSON_PAYLOAD"])
value = data

for part in sys.argv[1].split("."):
    if part == "":
        continue

    if isinstance(value, list):
        value = value[int(part)]
    else:
        value = value[part]

if isinstance(value, (dict, list)):
    print(json.dumps(value))
elif value is None:
    print("")
else:
    print(value)
PY
}

json_get_optional() {
    local json="$1"
    local path="$2"

    JSON_PAYLOAD="$json" python3 - "$path" <<'PY'
import json
import os
import sys

try:
    data = json.loads(os.environ["JSON_PAYLOAD"])
    value = data

    for part in sys.argv[1].split("."):
        if part == "":
            continue

        if isinstance(value, list):
            value = value[int(part)]
        else:
            value = value[part]
except Exception:
    value = ""

if isinstance(value, (dict, list)):
    print(json.dumps(value))
elif value is None:
    print("")
else:
    print(value)
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

    if ! json_matches "$json" "$expr" >/dev/null 2>&1; then
        printf '%s\n' "$json" >&2
        fail "$message"
    fi
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

http_status() {
    local method="$1"
    local url="$2"
    local token="$3"
    local expected="$4"

    local tmp code
    tmp="$(mktemp)"

    local args=(-sS -X "$method" -o "$tmp" -w "%{http_code}")
    if [ -n "$token" ]; then
        args+=(-H "Authorization: Bearer $token")
    fi
    args+=("$url")

    code="$(curl "${args[@]}")" || code="000"

    if [ "$code" != "$expected" ]; then
        cat "$tmp" >&2 || true
        rm -f "$tmp"
        return 1
    fi

    rm -f "$tmp"
    return 0
}

peertube_request() {
    local method="$1"
    local path="$2"
    local token="$3"
    local expected="$4"
    local body="${5:-}"

    local tmp code
    tmp="$(mktemp)"

    local args=(
        -sS
        -X "$method"
        -H "Host: $PEERTUBE_HOST"
        -H "Content-Type: application/json"
        -o "$tmp"
        -w "%{http_code}"
    )

    if [ -n "$token" ]; then
        args+=(-H "Authorization: Bearer $token")
    fi

    if [ -n "$body" ]; then
        args+=(-d "$body")
    fi

    args+=("$PEERTUBE_BASE$path")

    code="$(curl "${args[@]}")" || {
        cat "$tmp" >&2 || true
        rm -f "$tmp"
        fail "curl failed for PeerTube $method $path"
    }

    if [ "$code" != "$expected" ]; then
        cat "$tmp" >&2 || true
        rm -f "$tmp"
        fail "Unexpected PeerTube HTTP $code for $method $path (expected $expected)"
    fi

    cat "$tmp"
    rm -f "$tmp"
}

peertube_try_request() {
    local method="$1"
    local path="$2"
    local token="$3"
    local body="${4:-}"

    local tmp code
    tmp="$(mktemp)"

    local args=(
        -sS
        -X "$method"
        -H "Host: $PEERTUBE_HOST"
        -H "Content-Type: application/json"
        -o "$tmp"
        -w "%{http_code}"
    )

    if [ -n "$token" ]; then
        args+=(-H "Authorization: Bearer $token")
    fi

    if [ -n "$body" ]; then
        args+=(-d "$body")
    fi

    args+=("$PEERTUBE_BASE$path")

    code="$(curl "${args[@]}")" || code="000"
    printf '%s\n' "$code"
    cat "$tmp"
    rm -f "$tmp"
}

peertube_form() {
    local path="$1"
    local expected="$2"
    shift 2

    local tmp code
    tmp="$(mktemp)"

    local args=(
        -sS
        -X POST
        -H "Host: $PEERTUBE_HOST"
        -o "$tmp"
        -w "%{http_code}"
    )

    for field in "$@"; do
        args+=(--data-urlencode "$field")
    done

    args+=("$PEERTUBE_BASE$path")

    code="$(curl "${args[@]}")" || {
        cat "$tmp" >&2 || true
        rm -f "$tmp"
        fail "curl failed for PeerTube POST $path"
    }

    if [ "$code" != "$expected" ]; then
        cat "$tmp" >&2 || true
        rm -f "$tmp"
        fail "Unexpected PeerTube HTTP $code for POST $path (expected $expected)"
    fi

    cat "$tmp"
    rm -f "$tmp"
}

peertube_upload() {
    local file="$1"
    local channel_id="$2"
    local name="$3"

    local tmp code
    tmp="$(mktemp)"

    code="$(
        curl -sS \
            -X POST \
            -H "Host: $PEERTUBE_HOST" \
            -H "Authorization: Bearer $PEERTUBE_TOKEN" \
            -o "$tmp" \
            -w "%{http_code}" \
            -F "videofile=@$file;type=video/mp4" \
            -F "channelId=$channel_id" \
            -F "name=$name" \
            -F "privacy=1" \
            "$PEERTUBE_BASE/api/v1/videos/upload"
    )" || {
        cat "$tmp" >&2 || true
        rm -f "$tmp"
        fail "curl failed for PeerTube upload"
    }

    if [ "$code" != "200" ]; then
        cat "$tmp" >&2 || true
        rm -f "$tmp"
        fail "Unexpected PeerTube HTTP $code for video upload"
    fi

    cat "$tmp"
    rm -f "$tmp"
}

poll_json_assert() {
    local method="$1"
    local url="$2"
    local token="$3"
    local expected="$4"
    local expr="$5"
    local message="$6"
    local attempts="${7:-$POLL_ATTEMPTS}"
    local delay="${8:-2}"
    local result=""

    for _ in $(seq 1 "$attempts"); do
        result="$(http_form "$method" "$url" "$token" "$expected" || true)"

        if [ -n "$result" ] && json_matches "$result" "$expr" >/dev/null 2>&1; then
            printf '%s\n' "$result"
            return 0
        fi

        sleep "$delay"
    done

    printf '%s\n' "$result" >&2
    fail "Polling timed out: $message"
}

poll_peertube_json_assert() {
    local method="$1"
    local path="$2"
    local token="$3"
    local expected="$4"
    local expr="$5"
    local message="$6"
    local attempts="${7:-$POLL_ATTEMPTS}"
    local delay="${8:-2}"
    local body="${9:-}"
    local result=""

    for _ in $(seq 1 "$attempts"); do
        result="$(peertube_request "$method" "$path" "$token" "$expected" "$body" || true)"

        if [ -n "$result" ] && json_matches "$result" "$expr" >/dev/null 2>&1; then
            printf '%s\n' "$result"
            return 0
        fi

        sleep "$delay"
    done

    printf '%s\n' "$result" >&2
    fail "Polling timed out: $message"
}

poll_http_status() {
    local method="$1"
    local url="$2"
    local token="$3"
    local expected="$4"
    local message="$5"
    local attempts="${6:-$POLL_ATTEMPTS}"
    local delay="${7:-2}"

    for _ in $(seq 1 "$attempts"); do
        if http_status "$method" "$url" "$token" "$expected" >/dev/null 2>&1; then
            return 0
        fi

        sleep "$delay"
    done

    fail "Polling timed out: $message"
}

poll_peertube_comment_id_by_text() {
    local video_uuid="$1"
    local text="$2"
    local message="$3"
    local result id

    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        result="$(peertube_request GET "/api/v1/videos/$video_uuid/comment-threads" "$PEERTUBE_TOKEN" 200 || true)"

        id="$(
            JSON_PAYLOAD="$result" MATCH_TEXT="$text" python3 - <<'PY' || true
import json
import os

data = json.loads(os.environ["JSON_PAYLOAD"])
needle = os.environ["MATCH_TEXT"]

def visit(comment):
    if not comment:
        return None

    if not comment.get("isDeleted") and needle in json.dumps(comment, sort_keys=True):
        return comment.get("id")

    return None

for item in data.get("data", []):
    result = visit(item)
    if result:
        print(result)
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

poll_peertube_comment_absent_or_deleted() {
    local video_uuid="$1"
    local comment_id="$2"
    local message="$3"
    local result ok

    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        result="$(peertube_request GET "/api/v1/videos/$video_uuid/comment-threads" "$PEERTUBE_TOKEN" 200 || true)"

        ok="$(
            JSON_PAYLOAD="$result" COMMENT_ID="$comment_id" python3 - <<'PY' || true
import json
import os

data = json.loads(os.environ["JSON_PAYLOAD"])
comment_id = str(os.environ["COMMENT_ID"])

for item in data.get("data", []):
    if str(item.get("id")) == comment_id:
        if item.get("isDeleted"):
            print("ok")
            raise SystemExit(0)

        raise SystemExit(1)

print("ok")
PY
        )"

        if [ "$ok" = "ok" ]; then
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

resolve_be_status_id() {
    local uri="$1"
    local token="$2"
    local message="$3"
    local result

    result="$(
        poll_json_assert GET \
            "$BE_BASE/api/v2/search?resolve=true&type=statuses&q=$(urlencode "$uri")" \
            "$token" \
            200 \
            'len(data.get("statuses", [])) >= 1' \
            "$message" \
            120 \
            2
    )"

    json_get "$result" statuses.0.id
}

resolve_be_context_status_id() {
    local parent_id="$1"
    local uri="$2"
    local token="$3"
    local message="$4"
    local result id

    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        result="$(http_form GET "$BE_BASE/api/v1/statuses/$parent_id/context" "$token" 200 || true)"

        id="$(
            JSON_PAYLOAD="$result" TARGET_URI="$uri" python3 - <<'PY' || true
import json
import os

data = json.loads(os.environ["JSON_PAYLOAD"])
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

write_tls_cert() {
    local host="$1"
    local key="$2"
    local cert="$3"

    openssl req \
        -x509 \
        -nodes \
        -newkey rsa:2048 \
        -keyout "$key" \
        -out "$cert" \
        -days 2 \
        -subj "/CN=$host" \
        -addext "subjectAltName=DNS:$host" \
        >/dev/null 2>&1
}

write_be_secret() {
    local secret_key_base signing_salt

    secret_key_base="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(96))
PY
)"
    signing_salt="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(12))
PY
)"

    mkdir -p "$(dirname "$BE_SECRET")" "$WORK_DIR/be/uploads" "$WORK_DIR/be/static"

    cat >"$BE_SECRET" <<EOF
import Config

config :pleroma, Pleroma.Web.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000, protocol_options: [max_request_line_length: 8192]],
  url: [scheme: "https", host: "$BE_HOST", port: 443],
  secret_key_base: "$secret_key_base",
  live_view: [signing_salt: "$signing_salt"],
  code_reloader: false,
  live_reload: false,
  watchers: [],
  server: true

config :pleroma, :instance,
  name: "Unfathomably PeerTube Smoke",
  email: "admin@$BE_HOST",
  notify_email: "admin@$BE_HOST",
  limit: 5000,
  registrations_open: true,
  public: true

config :pleroma, Pleroma.Repo,
  username: "postgres",
  password: "$DB_PASSWORD",
  hostname: "$DB_CONTAINER",
  database: "$BE_DB_NAME",
  pool_size: 10

config :pleroma, :media_proxy, enabled: false
config :pleroma, Pleroma.Uploaders.Local, uploads: "$WORK_DIR/be/uploads"
config :pleroma, :instance, static_dir: "$WORK_DIR/be/static"
config :pleroma, :http,
  adapter: [
    insecure: true,
    ssl_options: [
      insecure: true,
      verify: :verify_none
    ]
  ]
config :pleroma, :frontend_configurations, soapbox_fe: %{}
config :pleroma, :database, rum_enabled: false
config :pleroma, configurable_from_database: false
config :pleroma, :rate_limit, nil
config :pleroma, :modules, runtime_dir: "$WORK_DIR/runtime-$BE_HOST"
config :pleroma, Pleroma.ScheduledActivity, daily_user_limit: 1000, total_user_limit: 10000
EOF
}

write_be_proxy_config() {
    mkdir -p "$(dirname "$BE_NGINX_CONF")" "$BE_CERT_DIR"
    write_tls_cert "$BE_HOST" "$BE_CERT_DIR/be.key" "$BE_CERT_DIR/be.crt"

    cat >"$BE_NGINX_CONF" <<EOF
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://$BE_APP_HOST:4000;
        proxy_set_header Host $BE_HOST;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Ssl on;
    }
}

server {
    listen 443 ssl;
    server_name _;

    ssl_certificate /etc/nginx/certs/be.crt;
    ssl_certificate_key /etc/nginx/certs/be.key;

    location / {
        proxy_pass http://$BE_APP_HOST:4000;
        proxy_set_header Host $BE_HOST;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Ssl on;
    }
}
EOF
}

write_peertube_files() {
    mkdir -p "$(dirname "$PEERTUBE_ENV")" "$(dirname "$PEERTUBE_NGINX_CONF")" "$PEERTUBE_CERT_DIR" "$PEERTUBE_DATA_DIR" "$PEERTUBE_CONFIG_DIR"
    chmod 777 "$PEERTUBE_DATA_DIR" "$PEERTUBE_CONFIG_DIR"
    write_tls_cert "$PEERTUBE_HOST" "$PEERTUBE_CERT_DIR/peertube.key" "$PEERTUBE_CERT_DIR/peertube.crt"

    cat >"$PEERTUBE_ENV" <<EOF
PEERTUBE_LISTEN_HOSTNAME=0.0.0.0
PEERTUBE_LISTEN_PORT=9000
PEERTUBE_WEBSERVER_HOSTNAME=$PEERTUBE_HOST
PEERTUBE_WEBSERVER_PORT=443
PEERTUBE_WEBSERVER_HTTPS=true
PEERTUBE_TRUST_PROXY=["127.0.0.1","loopback","172.16.0.0/12"]
PEERTUBE_SECRET=$(random_hex 32)
PEERTUBE_ADMIN_EMAIL=admin@$PEERTUBE_HOST

PEERTUBE_DB_HOSTNAME=$DB_CONTAINER
PEERTUBE_DB_NAME=$PEERTUBE_DB_NAME
PEERTUBE_DB_USERNAME=postgres
PEERTUBE_DB_PASSWORD=$DB_PASSWORD
PEERTUBE_DB_SSL=false

PEERTUBE_REDIS_HOSTNAME=$REDIS_CONTAINER
PEERTUBE_REDIS_PORT=6379

PEERTUBE_SMTP_HOSTNAME=localhost
PEERTUBE_SMTP_PORT=25
PEERTUBE_SMTP_FROM=noreply@$PEERTUBE_HOST
PEERTUBE_SMTP_TLS=false
PEERTUBE_SMTP_DISABLE_STARTTLS=true

PEERTUBE_SIGNUP_ENABLED=false
PEERTUBE_FEDERATION_ENABLED=true
PEERTUBE_FEDERATION_PREVENT_SSRF=false
PEERTUBE_FEDERATION_VIDEOS_FEDERATE_UNLISTED=true
PEERTUBE_PEERTUBE_CHECK_LATEST_VERSION_ENABLED=false
PEERTUBE_TRANSCODING_ENABLED=false
PEERTUBE_TRANSCODING_WEB_VIDEOS_ENABLED=false
PEERTUBE_TRANSCODING_HLS_ENABLED=false
PEERTUBE_LIVE_ENABLED=false
PEERTUBE_CONTACT_FORM_ENABLED=false
PEERTUBE_USER_VIDEO_QUOTA=-1
PEERTUBE_LOG_LEVEL=info
EOF

    cat >"$PEERTUBE_NGINX_CONF" <<EOF
server {
    listen 80;
    server_name _;
    client_max_body_size 50m;

    location / {
        proxy_pass http://$PEERTUBE_APP_HOST:9000;
        proxy_http_version 1.1;
        proxy_set_header Host $PEERTUBE_HOST;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Ssl on;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}

server {
    listen 443 ssl;
    server_name _;
    client_max_body_size 50m;

    ssl_certificate /etc/nginx/certs/peertube.crt;
    ssl_certificate_key /etc/nginx/certs/peertube.key;

    location / {
        proxy_pass http://$PEERTUBE_APP_HOST:9000;
        proxy_http_version 1.1;
        proxy_set_header Host $PEERTUBE_HOST;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Ssl on;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
}

docker_run_mix() {
    local name="$1"
    shift

    local log_file="$WORK_DIR/$name.log"

    if ! docker run --rm \
        --name "$name" \
        --network "$NETWORK" \
        -e MIX_ENV=dev \
        -e MIX_HOME=/tmp/mix \
        -e HEX_HOME=/tmp/hex \
        -v "$BE_ROOT:/work" \
        -v "$BE_SECRET:/work/config/dev.secret.exs:ro" \
        "$IMAGE" \
        bash -lc "set -euo pipefail; cd /work; git config --global --add safe.directory /work >/dev/null 2>&1 || true; mix local.hex --force >/dev/null; mix local.rebar --force >/dev/null; mix deps.get >/dev/null; $*" \
        >"$log_file" 2>&1; then
        cat "$log_file" >&2 || true
        fail "mix command failed in $name"
    fi
}

prepare_database() {
    local database="$1"

    docker exec "$DB_CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 \
        -c "CREATE DATABASE $database;" >/dev/null
}

create_be_user() {
    local nickname="$1"
    local email="$2"

    docker_run_mix "${PREFIX}-user-$nickname" \
        "mix pleroma.user new '$nickname' '$email' --password '$PASSWORD' --assume-yes >/dev/null && mix run -e \"alias Pleroma.{Repo, User}; User.get_by_nickname(\\\"$nickname\\\") |> Ecto.Changeset.change(is_discoverable: true) |> Repo.update!()\" >/dev/null"
}

create_be_token() {
    local username="$1"
    local app token client_id client_secret

    app="$(
        http_form POST "$BE_BASE/api/v1/apps" "" 200 \
            "client_name=peertube-smoke-$username" \
            "redirect_uris=urn:ietf:wg:oauth:2.0:oob" \
            "scopes=read write follow push admin"
    )"
    client_id="$(json_get "$app" client_id)"
    client_secret="$(json_get "$app" client_secret)"

    token="$(
        http_form POST "$BE_BASE/oauth/token" "" 200 \
            "grant_type=password" \
            "username=$username" \
            "password=$PASSWORD" \
            "client_id=$client_id" \
            "client_secret=$client_secret" \
            "scope=read write follow push admin"
    )"

    json_get "$token" access_token
}

wait_postgres() {
    local stable=0

    for _ in $(seq 1 80); do
        if docker exec "$DB_CONTAINER" psql -U postgres -d postgres -Atc "select 1" >/dev/null 2>&1; then
            stable=$((stable + 1))

            if [ "$stable" -ge 3 ]; then
                return 0
            fi
        else
            stable=0
        fi

        sleep 1
    done

    fail "PostgreSQL did not become ready"
}

wait_be() {
    for _ in $(seq 1 120); do
        if curl -fsS "$BE_BASE/api/v1/instance" >/dev/null 2>&1; then
            return 0
        fi

        sleep 1
    done

    fail "Timed out waiting for Unfathomably at $BE_BASE"
}

wait_peertube() {
    for _ in $(seq 1 180); do
        if curl -fsS -H "Host: $PEERTUBE_HOST" "$PEERTUBE_BASE/api/v1/config" >/dev/null 2>&1; then
            return 0
        fi

        sleep 2
    done

    fail "Timed out waiting for PeerTube at $PEERTUBE_BASE"
}

peertube_root_password() {
    local password

    for _ in $(seq 1 120); do
        password="$(
            docker logs "$PEERTUBE_CONTAINER" 2>&1 |
                sed -n 's/.*User password: //p' |
                tail -1
        )"

        if [ -n "$password" ]; then
            printf '%s\n' "$password"
            return 0
        fi

        sleep 2
    done

    fail "Could not find PeerTube root password in container logs"
}

create_peertube_token() {
    local root_password="$1"
    local client token client_id client_secret

    client="$(peertube_request GET /api/v1/oauth-clients/local "" 200)"
    client_id="$(json_get "$client" client_id)"
    client_secret="$(json_get "$client" client_secret)"

    token="$(
        peertube_form /api/v1/users/token 200 \
            "client_id=$client_id" \
            "client_secret=$client_secret" \
            "grant_type=password" \
            "response_type=code" \
            "username=root" \
            "password=$root_password"
    )"

    json_get "$token" access_token
}

start_be() {
    docker run -d \
        --name "$BE_CONTAINER" \
        --hostname "$BE_APP_HOST" \
        --network "$NETWORK" \
        --network-alias "$BE_APP_HOST" \
        -e MIX_ENV=dev \
        -e MIX_HOME=/tmp/mix \
        -e HEX_HOME=/tmp/hex \
        -v "$BE_ROOT:/work" \
        -v "$BE_SECRET:/work/config/dev.secret.exs:ro" \
        "$IMAGE" \
        bash -lc 'set -euo pipefail; cd /work; git config --global --add safe.directory /work >/dev/null 2>&1 || true; mix local.hex --force >/dev/null; mix local.rebar --force >/dev/null; mix deps.get >/dev/null; exec mix phx.server' \
        >/dev/null
}

start_be_proxy() {
    docker run -d \
        --name "$BE_PROXY_CONTAINER" \
        --hostname "$BE_PROXY_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$BE_HOST" \
        -p "127.0.0.1:$BE_PORT:80" \
        -v "$BE_NGINX_CONF:/etc/nginx/conf.d/default.conf:ro" \
        -v "$BE_CERT_DIR:/etc/nginx/certs:ro" \
        "$NGINX_IMAGE" >/dev/null
}

start_peertube() {
    docker run -d \
        --name "$PEERTUBE_CONTAINER" \
        --hostname "$PEERTUBE_APP_HOST" \
        --network "$NETWORK" \
        --network-alias "$PEERTUBE_APP_HOST" \
        --env-file "$PEERTUBE_ENV" \
        -e NODE_EXTRA_CA_CERTS=/certs/unfathomably-be-smoke.crt \
        -e SSL_CERT_FILE=/certs/unfathomably-be-smoke.crt \
        -v "$PEERTUBE_DATA_DIR:/data" \
        -v "$PEERTUBE_CONFIG_DIR:/config" \
        -v "$BE_CERT_DIR/be.crt:/certs/unfathomably-be-smoke.crt:ro" \
        "$PEERTUBE_IMAGE" >/dev/null

    docker run -d \
        --name "$PEERTUBE_PROXY_CONTAINER" \
        --hostname "$PEERTUBE_PROXY_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$PEERTUBE_HOST" \
        -p "127.0.0.1:$PEERTUBE_PORT:80" \
        -v "$PEERTUBE_NGINX_CONF:/etc/nginx/conf.d/default.conf:ro" \
        -v "$PEERTUBE_CERT_DIR:/etc/nginx/certs:ro" \
        "$NGINX_IMAGE" >/dev/null
}

create_smoke_video_file() {
    local file="$PEERTUBE_DATA_DIR/smoke.mp4"

    docker exec "$PEERTUBE_CONTAINER" \
        ffmpeg \
        -y \
        -f lavfi \
        -i testsrc=size=160x90:rate=1:duration=1 \
        -f lavfi \
        -i anullsrc=channel_layout=mono:sample_rate=8000 \
        -shortest \
        -c:v libx264 \
        -pix_fmt yuv420p \
        -c:a aac \
        /data/smoke.mp4 >/dev/null 2>&1 || fail "Could not generate PeerTube smoke video"

    if [ ! -s "$file" ]; then
        fail "PeerTube smoke video was not generated at $file"
    fi

    printf '%s\n' "$file"
}

try_peertube_follow_be_group() {
    local handle="$1"
    local result code body

    result="$(peertube_try_request POST /api/v1/server/following "$PEERTUBE_TOKEN" "{\"handles\":[\"$handle\"]}")"
    code="$(printf '%s\n' "$result" | head -1)"
    body="$(printf '%s\n' "$result" | tail -n +2)"

    if [ "$code" = "204" ]; then
        printf 'followed\n'
        return 0
    fi

    printf 'unsupported\n'
    printf 'PeerTube did not follow Unfathomably Group handle %s through the stock server-follow API. HTTP %s: %s\n' "$handle" "$code" "$body" >&2
    return 0
}

log "Cleaning any previous PeerTube smoke containers"
cleanup

log "Preparing smoke working directories and configs"
mkdir -p "$WORK_DIR"
write_be_secret
write_be_proxy_config
write_peertube_files

log "Creating Docker network, PostgreSQL, and Redis"
docker network create "$NETWORK" >/dev/null

docker run -d \
    --name "$DB_CONTAINER" \
    --network "$NETWORK" \
    -e POSTGRES_PASSWORD="$DB_PASSWORD" \
    "$POSTGRES_IMAGE" >/dev/null

docker run -d \
    --name "$REDIS_CONTAINER" \
    --network "$NETWORK" \
    "$REDIS_IMAGE" >/dev/null

wait_postgres
prepare_database "$BE_DB_NAME"
prepare_database "$PEERTUBE_DB_NAME"

log "Migrating and starting Unfathomably"
docker_run_mix "${PREFIX}-migrate-be" "mix ecto.migrate"
create_be_user alice "alice@$BE_HOST"
start_be
start_be_proxy
wait_be

log "Starting stock PeerTube"
start_peertube
wait_peertube

log "Creating API credentials"
ALICE_TOKEN="$(create_be_token alice)"
PEERTUBE_ROOT_PASSWORD="$(peertube_root_password)"
PEERTUBE_TOKEN="$(create_peertube_token "$PEERTUBE_ROOT_PASSWORD")"

log "Creating local Unfathomably group and PeerTube channel"
BE_GROUP_NAME="unfathomably_peertube_smoke"
BE_GROUP="$(
    http_form POST "$BE_BASE/api/v1/groups" "$ALICE_TOKEN" 200 \
        "display_name=Unfathomably PeerTube Smoke" \
        "name=$BE_GROUP_NAME" \
        "note=Open group used by the PeerTube bidirectional smoke harness." \
        "locked=false"
)"
BE_GROUP_ID="$(json_get "$BE_GROUP" id)"
BE_GROUP_AP_ID="$(json_get_optional "$BE_GROUP" ap_id)"
if [ -z "$BE_GROUP_AP_ID" ]; then
    BE_GROUP_AP_ID="$(json_get "$BE_GROUP" url)"
fi

PEERTUBE_CHANNEL_NAME="smokechannel$(date +%s)"
PEERTUBE_CHANNEL="$(
    peertube_request POST /api/v1/video-channels "$PEERTUBE_TOKEN" 200 \
        "{\"name\":\"$PEERTUBE_CHANNEL_NAME\",\"displayName\":\"PeerTube Smoke Channel\"}"
)"
PEERTUBE_CHANNEL_ID="$(json_get "$PEERTUBE_CHANNEL" videoChannel.id)"
PEERTUBE_CHANNEL_AP_ID="https://$PEERTUBE_HOST/video-channels/$PEERTUBE_CHANNEL_NAME"

log "Following PeerTube channel from Unfathomably"
BE_REMOTE_PEERTUBE_GROUP="$(
    http_form GET "$BE_BASE/api/v1/groups/lookup?uri=$(urlencode "$PEERTUBE_CHANNEL_AP_ID")" \
        "$ALICE_TOKEN" \
        200
)"
BE_REMOTE_PEERTUBE_GROUP_ID="$(json_get "$BE_REMOTE_PEERTUBE_GROUP" id)"
BE_JOIN_PEERTUBE="$(
    http_form POST "$BE_BASE/api/v1/groups/$BE_REMOTE_PEERTUBE_GROUP_ID/join" \
        "$ALICE_TOKEN" \
        200
)"
json_assert "$BE_JOIN_PEERTUBE" 'data.get("member") is True or data.get("requested") is True' \
    "Unfathomably could not follow the PeerTube channel actor"

log "Trying PeerTube follow of Unfathomably Group actor"
PEERTUBE_FOLLOWED_BE_GROUP="$(try_peertube_follow_be_group "$BE_GROUP_NAME@$BE_HOST")"

log "Uploading PeerTube video and resolving it in Unfathomably"
SMOKE_VIDEO_FILE="$(create_smoke_video_file)"
PEERTUBE_VIDEO_NAME="PeerTube to Unfathomably smoke $(basename "$WORK_DIR")"
PEERTUBE_UPLOAD="$(peertube_upload "$SMOKE_VIDEO_FILE" "$PEERTUBE_CHANNEL_ID" "$PEERTUBE_VIDEO_NAME")"
PEERTUBE_VIDEO_ID="$(json_get "$PEERTUBE_UPLOAD" video.id)"
PEERTUBE_VIDEO_UUID="$(json_get "$PEERTUBE_UPLOAD" video.uuid)"
PEERTUBE_VIDEO_AP_ID="https://$PEERTUBE_HOST/videos/watch/$PEERTUBE_VIDEO_UUID"

poll_peertube_json_assert GET \
    "/api/v1/videos/$PEERTUBE_VIDEO_UUID" \
    "$PEERTUBE_TOKEN" \
    200 \
    'data.get("uuid") == "'$PEERTUBE_VIDEO_UUID'"' \
    "PeerTube video becomes available" >/dev/null

BE_VIEW_OF_PEERTUBE_VIDEO_ID="$(
    resolve_be_status_id "$PEERTUBE_VIDEO_AP_ID" "$ALICE_TOKEN" "Unfathomably resolves PeerTube video"
)"

log "Testing Unfathomably like and unlike of PeerTube video"
BE_LIKE_PEERTUBE="$(
    http_form POST "$BE_BASE/api/v1/statuses/$BE_VIEW_OF_PEERTUBE_VIDEO_ID/favourite" "$ALICE_TOKEN" 200
)"
json_assert "$BE_LIKE_PEERTUBE" 'data.get("favourited") is True' "Unfathomably could not like PeerTube video"
poll_peertube_json_assert GET \
    "/api/v1/videos/$PEERTUBE_VIDEO_UUID" \
    "$PEERTUBE_TOKEN" \
    200 \
    'int(data.get("likes") or 0) >= 1' \
    "PeerTube sees Unfathomably like on video" >/dev/null

BE_UNLIKE_PEERTUBE="$(
    http_form POST "$BE_BASE/api/v1/statuses/$BE_VIEW_OF_PEERTUBE_VIDEO_ID/unfavourite" "$ALICE_TOKEN" 200
)"
json_assert "$BE_UNLIKE_PEERTUBE" 'data.get("favourited") is False' "Unfathomably could not unlike PeerTube video"
poll_peertube_json_assert GET \
    "/api/v1/videos/$PEERTUBE_VIDEO_UUID" \
    "$PEERTUBE_TOKEN" \
    200 \
    'int(data.get("likes") or 0) == 0' \
    "PeerTube sees Unfathomably unlike on video" >/dev/null

log "Testing Unfathomably comment delivery into PeerTube"
BE_REPLY_TEXT="Unfathomably comment to PeerTube $(basename "$WORK_DIR")"
BE_REPLY="$(
    http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$BE_REPLY_TEXT" \
        "in_reply_to_id=$BE_VIEW_OF_PEERTUBE_VIDEO_ID"
)"
BE_REPLY_ID="$(json_get "$BE_REPLY" id)"
BE_REPLY_PEERTUBE_COMMENT_ID="$(
    poll_peertube_comment_id_by_text \
        "$PEERTUBE_VIDEO_UUID" \
        "$BE_REPLY_TEXT" \
        "PeerTube sees Unfathomably comment on video"
)"

http_form DELETE "$BE_BASE/api/v1/statuses/$BE_REPLY_ID" "$ALICE_TOKEN" 200 >/dev/null
poll_peertube_comment_absent_or_deleted \
    "$PEERTUBE_VIDEO_UUID" \
    "$BE_REPLY_PEERTUBE_COMMENT_ID" \
    "PeerTube sees deleted Unfathomably comment"

log "Testing PeerTube comment delivery into Unfathomably"
PEERTUBE_COMMENT_TEXT="PeerTube comment to Unfathomably $(basename "$WORK_DIR")"
PEERTUBE_COMMENT="$(
    peertube_request POST \
        "/api/v1/videos/$PEERTUBE_VIDEO_UUID/comment-threads" \
        "$PEERTUBE_TOKEN" \
        200 \
        "{\"text\":\"$PEERTUBE_COMMENT_TEXT\"}"
)"
PEERTUBE_COMMENT_ID="$(json_get "$PEERTUBE_COMMENT" comment.id)"
PEERTUBE_COMMENT_URL="$(json_get "$PEERTUBE_COMMENT" comment.url)"
BE_VIEW_OF_PEERTUBE_COMMENT_ID="$(
    resolve_be_context_status_id \
        "$BE_VIEW_OF_PEERTUBE_VIDEO_ID" \
        "$PEERTUBE_COMMENT_URL" \
        "$ALICE_TOKEN" \
        "Unfathomably receives PeerTube comment under PeerTube video"
)"

peertube_request DELETE "/api/v1/videos/$PEERTUBE_VIDEO_UUID/comments/$PEERTUBE_COMMENT_ID" "$PEERTUBE_TOKEN" 204 >/dev/null
poll_http_status GET \
    "$BE_BASE/api/v1/statuses/$BE_VIEW_OF_PEERTUBE_COMMENT_ID" \
    "$ALICE_TOKEN" \
    404 \
    "Unfathomably sees PeerTube deleted comment"

log "Testing PeerTube delete of uploaded video"
peertube_request DELETE "/api/v1/videos/$PEERTUBE_VIDEO_UUID" "$PEERTUBE_TOKEN" 204 >/dev/null
poll_http_status GET \
    "$BE_BASE/api/v1/statuses/$BE_VIEW_OF_PEERTUBE_VIDEO_ID" \
    "$ALICE_TOKEN" \
    404 \
    "Unfathomably sees PeerTube deleted video"

log "Cleaning up follows"
BE_LEAVE_PEERTUBE="$(
    http_form POST "$BE_BASE/api/v1/groups/$BE_REMOTE_PEERTUBE_GROUP_ID/leave" "$ALICE_TOKEN" 200
)"
json_assert "$BE_LEAVE_PEERTUBE" 'data.get("member") is False and data.get("requested") is False' \
    "Unfathomably could not unfollow the PeerTube channel"

if [ "$PEERTUBE_FOLLOWED_BE_GROUP" = "followed" ]; then
    PEERTUBE_UNFOLLOW_BE_GROUP="$(
        peertube_try_request DELETE "/api/v1/server/following/$BE_GROUP_NAME@$BE_HOST" "$PEERTUBE_TOKEN"
    )"
    PEERTUBE_UNFOLLOW_BE_GROUP_CODE="$(printf '%s\n' "$PEERTUBE_UNFOLLOW_BE_GROUP" | head -1)"

    case "$PEERTUBE_UNFOLLOW_BE_GROUP_CODE" in
        204|404)
            ;;
        *)
            printf '%s\n' "$PEERTUBE_UNFOLLOW_BE_GROUP" >&2
            fail "Unexpected PeerTube HTTP $PEERTUBE_UNFOLLOW_BE_GROUP_CODE while cleaning up Unfathomably Group follow"
            ;;
    esac

    log "PeerTube followed and unfollowed the Unfathomably Group actor, but stock PeerTube has no text group-post surface to validate imported non-video posts"
else
    log "Skipping PeerTube remote text group post checks: stock PeerTube did not follow the non-PeerTube Group actor through its server-follow API"
fi

log "Checking logs for obvious crashes"
for container in "$BE_CONTAINER" "$BE_PROXY_CONTAINER" "$PEERTUBE_CONTAINER" "$PEERTUBE_PROXY_CONTAINER"; do
    if docker logs "$container" 2>&1 |
        grep -E "status=500|Internal Server Error|UnhandledPromiseRejection|uncaughtException|GenServer terminating|FunctionClauseError|UndefinedFunctionError|Protocol\\.UndefinedError|panic|FATAL" >/dev/null; then
        docker logs --tail 260 "$container" >&2
        fail "$container logged errors during PeerTube smoke run"
    fi
done

cat <<EOF

Unfathomably/PeerTube federation smoke test passed.

Covered:
  * clean stock PeerTube Docker boot with PostgreSQL, Redis, and HTTPS proxy
  * HTTPS-advertised Unfathomably actor URLs through a disposable proxy
  * Unfathomably follow of a PeerTube channel Group actor
  * PeerTube video upload and Unfathomably video resolution
  * Unfathomably like and unlike of PeerTube video
  * Unfathomably comment delivery to PeerTube and comment delete cleanup
  * PeerTube comment delivery to Unfathomably and comment delete cleanup
  * PeerTube video delete propagation to Unfathomably
  * PeerTube stock limitation reporting for non-video text Group post import
  * Unfathomably unfollow of the PeerTube channel actor
  * basic log scan for 500/crash output

Run with KEEP_SMOKE=1 to leave both servers available for manual browser/API work.
EOF

# end of unfathomably-peertube-smoke.sh
