#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-gotosocial-smoke.sh
#
# Purpose:
#
#   Run a local stock GoToSocial federation peer against Unfathomably and prove
#   the account-style federation operations GoToSocial can actually perform.
#
# Responsibilities:
#
#   * boot isolated Unfathomably, GoToSocial, database, and proxy containers
#   * create local test accounts and OAuth tokens on both peers
#   * exercise bidirectional follow, post, reply, favourite, unfavourite,
#     delete, and unfollow behavior
#   * probe Unfathomably Group actor handling from GoToSocial and report stock
#     GoToSocial limitations explicitly
#
# This file intentionally does NOT contain:
#
#   * production deployment logic
#   * patched GoToSocial binaries
#   * hidden success for unsupported Group actor semantics
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BE_ROOT="${BE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

PREFIX="${SMOKE_PREFIX:-unfathomably-gotosocial-smoke}"
NETWORK="${PREFIX}-net"

BE_DB_CONTAINER="${PREFIX}-be-db"
BE_CONTAINER="${PREFIX}-be"
BE_PROXY_CONTAINER="${PREFIX}-be-proxy"
BE_APP_HOST="${PREFIX}-be-app"
BE_HOST="${BE_HOST:-unfathomably-gotosocial.test}"
BE_PORT="${BE_PORT:-4971}"
BE_BASE="http://127.0.0.1:$BE_PORT"
BE_DB_NAME="${BE_DB_NAME:-unfathomably_gotosocial_smoke_be}"
BE_DB_PASSWORD="${BE_DB_PASSWORD:-postgres}"

GTS_CONTAINER="${PREFIX}-gts"
GTS_PROXY_CONTAINER="${PREFIX}-gts-proxy"
GTS_APP_HOST="${PREFIX}-gts-app"
GTS_HOST="${GTS_HOST:-gotosocial-ref.test}"
GTS_PORT="${GTS_PORT:-4972}"
GTS_BASE="http://127.0.0.1:$GTS_PORT"
GTS_FORWARDED_PROTO="${GTS_FORWARDED_PROTO:-http}"
GTS_PROXY_USER_AGENT="${GTS_PROXY_USER_AGENT:-}"
GTS_VOLUME="${PREFIX}-gts-storage"
GTS_APP_PORT="${GTS_APP_PORT:-8080}"
GTS_LABEL="${GTS_LABEL:-GoToSocial}"
GTS_USERNAME="${GTS_USERNAME:-gts}"
GTS_GROUP_NAME="${GTS_GROUP_NAME:-unfathomably_gotosocial_smoke}"
GTS_SEARCH_WITH_ACCOUNT_TYPE="${GTS_SEARCH_WITH_ACCOUNT_TYPE:-1}"
GTS_SEARCH_WITH_STATUS_TYPE="${GTS_SEARCH_WITH_STATUS_TYPE:-1}"
GTS_LOOKUP_BE_BY_ACTOR_URL="${GTS_LOOKUP_BE_BY_ACTOR_URL:-0}"
GTS_EMPTY_POST_JSON="${GTS_EMPTY_POST_JSON:-0}"
GTS_FORM_URLENCODE="${GTS_FORM_URLENCODE:-0}"
SMOKE_TLS="${SMOKE_TLS:-0}"
BE_FEDERATION_SCHEME="${BE_FEDERATION_SCHEME:-http}"
BE_FEDERATION_PORT="${BE_FEDERATION_PORT:-80}"

IMAGE="${UNFATHOMABLY_SMOKE_IMAGE:-unfathomably-elixir-smoke:otp28}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:15-alpine}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.27-alpine}"
GTS_IMAGE="${GTS_IMAGE:-superseriousbusiness/gotosocial:latest}"
PASSWORD="${SMOKE_PASSWORD:-correct horse battery staple 12345}"
KEEP_CONTAINERS="${KEEP_CONTAINERS:-0}"
WORK_DIR="${SMOKE_WORK_DIR:-}"

if [ -z "$WORK_DIR" ]; then
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/unfathomably-gotosocial-smoke.XXXXXX")"
fi

SMOKE_TLS_DIR="${SMOKE_TLS_DIR:-$WORK_DIR/tls}"
SMOKE_CA_CERT="${SMOKE_CA_CERT:-$SMOKE_TLS_DIR/ca.crt}"

BE_SECRET="$WORK_DIR/be/dev.secret.exs"
BE_UPLOADS="$WORK_DIR/be/uploads"
BE_STATIC="$WORK_DIR/be/static"
BE_NGINX_CONF="$WORK_DIR/be-nginx/default.conf"
GTS_NGINX_CONF="$WORK_DIR/gts-nginx/default.conf"

log() {
    printf '\n==> %s\n' "$*"
}

fail() {
    printf '\nERROR: %s\n' "$*" >&2
    printf 'Work directory: %s\n' "$WORK_DIR" >&2
    exit 1
}

cleanup() {
    local incoming_status="$?"
    local status="${1:-$incoming_status}"

    if [ "$KEEP_CONTAINERS" = "1" ]; then
        printf '\nKEEP_CONTAINERS=1, leaving containers and work directory in place.\n' >&2
        exit "$status"
    fi

    docker rm -f \
        "$GTS_PROXY_CONTAINER" \
        "$GTS_CONTAINER" \
        "$BE_PROXY_CONTAINER" \
        "$BE_CONTAINER" \
        "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    docker volume rm "$GTS_VOLUME" >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR"
    exit "$status"
}

trap cleanup EXIT

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

require_command curl
require_command docker
require_command python3

json_get() {
    local json="$1"
    local key="$2"

    JSON_INPUT="$json" python3 - "$key" <<'PY'
import json
import os
import sys

value = json.loads(os.environ["JSON_INPUT"])
for part in sys.argv[1].split("."):
    if isinstance(value, list):
        value = value[int(part)]
    else:
        value = value[part]

if value is None:
    print("")
elif isinstance(value, (dict, list)):
    print(json.dumps(value))
else:
    print(value)
PY
}

json_get_optional() {
    local json="$1"
    local key="$2"

    JSON_INPUT="$json" python3 - "$key" <<'PY'
import json
import os
import sys

try:
    value = json.loads(os.environ["JSON_INPUT"])
    for part in sys.argv[1].split("."):
        if isinstance(value, list):
            value = value[int(part)]
        else:
            value = value.get(part)
        if value is None:
            print("")
            raise SystemExit(0)
    if isinstance(value, (dict, list)):
        print(json.dumps(value))
    else:
        print(value)
except Exception:
    print("")
PY
}

json_assert() {
    local json="$1"
    local expr="$2"
    local message="$3"

    if ! JSON_INPUT="$json" python3 - "$expr" <<'PY'
import json
import os
import sys

data = json.loads(os.environ["JSON_INPUT"])
expr = sys.argv[1]
safe_builtins = {"all": all, "any": any, "int": int, "len": len, "str": str}
if not eval(expr, {"__builtins__": safe_builtins}, {"data": data}):
    raise SystemExit(1)
PY
    then
        printf '%s\n' "$json" >&2
        fail "$message"
    fi
}

urlencode() {
    python3 - "$1" <<'PY'
import sys
import urllib.parse

print(urllib.parse.quote(sys.argv[1], safe=""))
PY
}

http_form() {
    local method="$1"
    local url="$2"
    local token="$3"
    local expected="$4"
    shift 4

    local headers=(-H 'Accept: application/json')
    local args=(-sS -X "$method" -w '\n%{http_code}')

    if [ -n "$token" ]; then
        headers+=(-H "Authorization: Bearer $token")
    fi

    if [ "$#" -eq 0 ] && [ "$method" = "POST" ] && \
        [ "$GTS_EMPTY_POST_JSON" = "1" ] && [[ "$url" == "$GTS_BASE"/* ]]; then
        headers+=(-H 'Content-Type: application/json')
        args+=(--data '{}')
    fi

    for field in "$@"; do
        if [ "$GTS_FORM_URLENCODE" = "1" ] && \
            [ "$method" = "POST" ] && [ "$url" = "$GTS_BASE/api/v1/statuses" ]; then
            args+=(--data-urlencode "$field")
        else
            # These harnesses pass text fields, not upload specifications.
            # --form-string keeps leading @ and < characters literal instead
            # of asking curl to open a local file.
            args+=(--form-string "$field")
        fi
    done

    local response status body
    response="$(curl "${args[@]}" "${headers[@]}" "$url")" || return 1
    status="${response##*$'\n'}"
    body="${response%$'\n'*}"

    if [ "$status" != "$expected" ]; then
        printf 'Unexpected HTTP status for %s %s: expected %s got %s\n' \
            "$method" "$url" "$expected" "$status" >&2
        printf '%s\n' "$body" >&2
        return 1
    fi

    printf '%s\n' "$body"
}

http_json() {
    local method="$1"
    local url="$2"
    local token="$3"
    local expected="$4"
    local payload="$5"

    local headers=(-H 'Accept: application/json' -H 'Content-Type: application/json')
    local args=(-sS -X "$method" -w '\n%{http_code}' --data "$payload")

    if [ -n "$token" ]; then
        headers+=(-H "Authorization: Bearer $token")
    fi

    local response status body
    response="$(curl "${args[@]}" "${headers[@]}" "$url")" || return 1
    status="${response##*$'\n'}"
    body="${response%$'\n'*}"

    if [ "$status" != "$expected" ]; then
        printf 'Unexpected HTTP status for %s %s: expected %s got %s\n' \
            "$method" "$url" "$expected" "$status" >&2
        printf '%s\n' "$body" >&2
        return 1
    fi

    printf '%s\n' "$body"
}

poll_json_assert() {
    local command="$1"
    local expr="$2"
    local message="$3"
    local result=""

    for _ in $(seq 1 90); do
        result="$(eval "$command" 2>/dev/null || true)"

        if [ -n "$result" ] && JSON_INPUT="$result" python3 - "$expr" <<'PY'
import json
import os
import sys

data = json.loads(os.environ["JSON_INPUT"])
expr = sys.argv[1]
safe_builtins = {"all": all, "any": any, "int": int, "len": len, "str": str}
if not eval(expr, {"__builtins__": safe_builtins}, {"data": data}):
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

prepare_smoke_tls() {
    if [ "$SMOKE_TLS" != "1" ]; then
        return 0
    fi

    require_command openssl
    mkdir -p "$SMOKE_TLS_DIR"

    cat >"$SMOKE_TLS_DIR/server.ext" <<EOF
subjectAltName=DNS:$BE_HOST,DNS:$GTS_HOST
extendedKeyUsage=serverAuth
keyUsage=digitalSignature,keyEncipherment
EOF

    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$SMOKE_TLS_DIR/ca.key" \
        -out "$SMOKE_CA_CERT" \
        -subj '/CN=Unfathomably federation smoke CA' \
        -addext 'basicConstraints=critical,CA:TRUE' \
        -addext 'keyUsage=critical,keyCertSign,cRLSign' \
        -addext 'subjectKeyIdentifier=hash' \
        -days 2 >/dev/null 2>&1
    openssl req -newkey rsa:2048 -nodes \
        -keyout "$SMOKE_TLS_DIR/server.key" \
        -out "$SMOKE_TLS_DIR/server.csr" \
        -subj "/CN=$BE_HOST" >/dev/null 2>&1
    openssl x509 -req \
        -in "$SMOKE_TLS_DIR/server.csr" \
        -CA "$SMOKE_CA_CERT" \
        -CAkey "$SMOKE_TLS_DIR/ca.key" \
        -CAcreateserial \
        -out "$SMOKE_TLS_DIR/server.crt" \
        -extfile "$SMOKE_TLS_DIR/server.ext" \
        -days 2 >/dev/null 2>&1
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

    mkdir -p "$(dirname "$BE_SECRET")" "$BE_UPLOADS" "$BE_STATIC"

    cat >"$BE_SECRET" <<EOF
import Config

config :pleroma, Pleroma.Web.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000, protocol_options: [max_request_line_length: 8192]],
  url: [scheme: "$BE_FEDERATION_SCHEME", host: "$BE_HOST", port: $BE_FEDERATION_PORT],
  secret_key_base: "$secret_key_base",
  live_view: [signing_salt: "$signing_salt"],
  code_reloader: false,
  live_reload: false,
  watchers: [],
  server: true

config :pleroma, :instance,
  name: "Unfathomably $GTS_LABEL Smoke",
  email: "admin@$BE_HOST",
  notify_email: "admin@$BE_HOST",
  limit: 5000,
  registrations_open: true,
  public: true

config :pleroma, Pleroma.Repo,
  username: "postgres",
  password: "$BE_DB_PASSWORD",
  hostname: "$BE_DB_CONTAINER",
  database: "$BE_DB_NAME",
  pool_size: 10

config :pleroma, :media_proxy, enabled: false
config :pleroma, Pleroma.Uploaders.Local, uploads: "$BE_UPLOADS"
config :pleroma, :instance, static_dir: "$BE_STATIC"
config :pleroma, :frontend_configurations, soapbox_fe: %{}
config :pleroma, :database, rum_enabled: false
config :pleroma, configurable_from_database: false
config :pleroma, :rate_limit, nil
config :pleroma, :modules, runtime_dir: "$WORK_DIR/runtime-$BE_HOST"
config :pleroma, Pleroma.ScheduledActivity, daily_user_limit: 1000, total_user_limit: 10000
EOF
}

write_proxy_configs() {
    local gts_user_agent_header=""

    if [ -n "$GTS_PROXY_USER_AGENT" ]; then
        gts_user_agent_header="        proxy_set_header User-Agent \"$GTS_PROXY_USER_AGENT\";"
    fi

    mkdir -p "$(dirname "$BE_NGINX_CONF")" "$(dirname "$GTS_NGINX_CONF")"

    cat >"$BE_NGINX_CONF" <<EOF
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://$BE_APP_HOST:4000;
        proxy_set_header Host $BE_HOST;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
    }
}
EOF

    if [ "$SMOKE_TLS" = "1" ]; then
        cat >>"$BE_NGINX_CONF" <<EOF

server {
    listen 443 ssl;
    server_name $BE_HOST;
    ssl_certificate /etc/nginx/tls/server.crt;
    ssl_certificate_key /etc/nginx/tls/server.key;

    location / {
        proxy_pass http://$BE_APP_HOST:4000;
        proxy_set_header Host $BE_HOST;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF
    fi

    cat >"$GTS_NGINX_CONF" <<EOF
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://$GTS_APP_HOST:$GTS_APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host $GTS_HOST;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$http_connection;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $GTS_FORWARDED_PROTO;
$gts_user_agent_header
    }
}
EOF

    if [ "$SMOKE_TLS" = "1" ]; then
        cat >>"$GTS_NGINX_CONF" <<EOF

server {
    listen 443 ssl;
    server_name $GTS_HOST;
    ssl_certificate /etc/nginx/tls/server.crt;
    ssl_certificate_key /etc/nginx/tls/server.key;

    location / {
        proxy_pass http://$GTS_APP_HOST:$GTS_APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host $GTS_HOST;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$http_connection;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
$gts_user_agent_header
    }
}
EOF
    fi
}

docker_run_mix() {
    local name="$1"
    shift

    local log_file="$WORK_DIR/$name.log"
    local tls_setup=""
    local tls_args=()

    if [ "$SMOKE_TLS" = "1" ]; then
        tls_args+=(
            -e SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
            -v "$SMOKE_CA_CERT:/usr/local/share/ca-certificates/unfathomably-smoke.crt:ro"
        )
        tls_setup='update-ca-certificates >/dev/null; '
    fi

    if ! docker run --rm \
        --name "$name" \
        --network "$NETWORK" \
        -e MIX_ENV=dev \
        -e MIX_HOME=/tmp/mix \
        -e HEX_HOME=/tmp/hex \
        "${tls_args[@]}" \
        -v "$BE_ROOT:/work" \
        -v "$BE_SECRET:/work/config/dev.secret.exs:ro" \
        "$IMAGE" \
        bash -lc "set -euo pipefail; ${tls_setup}cd /work; git config --global --add safe.directory /work >/dev/null 2>&1 || true; mix local.hex --force >/dev/null; mix local.rebar --force >/dev/null; mix deps.get >/dev/null; $*" \
        >"$log_file" 2>&1; then
        cat "$log_file" >&2 || true
        fail "mix command failed in $name"
    fi
}

wait_postgres() {
    local stable=0

    for _ in $(seq 1 80); do
        if docker exec "$BE_DB_CONTAINER" psql -U postgres -d postgres -Atc "select 1" >/dev/null 2>&1; then
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

prepare_database() {
    docker exec "$BE_DB_CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 \
        -c "CREATE DATABASE $BE_DB_NAME;" >/dev/null
}

start_be() {
    local tls_setup=""
    local tls_args=()

    if [ "$SMOKE_TLS" = "1" ]; then
        tls_args+=(
            -e SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
            -v "$SMOKE_CA_CERT:/usr/local/share/ca-certificates/unfathomably-smoke.crt:ro"
        )
        tls_setup='update-ca-certificates >/dev/null; '
    fi

    docker run -d \
        --name "$BE_CONTAINER" \
        --hostname "$BE_APP_HOST" \
        --network "$NETWORK" \
        --network-alias "$BE_APP_HOST" \
        -e MIX_ENV=dev \
        -e MIX_HOME=/tmp/mix \
        -e HEX_HOME=/tmp/hex \
        "${tls_args[@]}" \
        -v "$BE_ROOT:/work" \
        -v "$BE_SECRET:/work/config/dev.secret.exs:ro" \
        "$IMAGE" \
        bash -lc "set -euo pipefail; ${tls_setup}cd /work; git config --global --add safe.directory /work >/dev/null 2>&1 || true; mix local.hex --force >/dev/null; mix local.rebar --force >/dev/null; mix deps.get >/dev/null; exec mix phx.server" \
        >/dev/null
}

start_be_proxy() {
    local tls_args=()

    if [ "$SMOKE_TLS" = "1" ]; then
        tls_args+=(-v "$SMOKE_TLS_DIR:/etc/nginx/tls:ro")
    fi

    docker run -d \
        --name "$BE_PROXY_CONTAINER" \
        --hostname "$BE_PROXY_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$BE_HOST" \
        -p "127.0.0.1:$BE_PORT:80" \
        "${tls_args[@]}" \
        -v "$BE_NGINX_CONF:/etc/nginx/conf.d/default.conf:ro" \
        "$NGINX_IMAGE" >/dev/null
}

wait_be() {
    for _ in $(seq 1 140); do
        if curl -fsS "$BE_BASE/api/v1/instance" >/dev/null 2>&1; then
            return 0
        fi

        sleep 1
    done

    docker logs "$BE_CONTAINER" >&2 || true
    fail "Timed out waiting for Unfathomably at $BE_BASE"
}

set_be_user_discoverable() {
    local nickname="$1"
    local updated_id

    case "$nickname" in
        ""|*[!a-zA-Z0-9_]*)
            fail "Unsafe Unfathomably nickname passed to database bootstrap: $nickname"
            ;;
    esac

    # Starting the complete application a second time merely to update this
    # column can exhaust the small disposable database pool while supervisors
    # are also starting. The user task has already validated and inserted the
    # account, so make this deterministic bootstrap-only change in PostgreSQL.
    updated_id="$(
        docker exec "$BE_DB_CONTAINER" psql -U postgres -d "$BE_DB_NAME" \
            -Atq -v ON_ERROR_STOP=1 \
            -c "UPDATE users SET is_discoverable = TRUE WHERE local = TRUE AND nickname = '$nickname' RETURNING id;"
    )"

    [ -n "$updated_id" ] || fail "Could not mark Unfathomably user $nickname discoverable"
}

create_be_user() {
    local nickname="$1"
    local email="$2"

    docker_run_mix "${PREFIX}-user-$nickname" \
        "mix pleroma.user new '$nickname' '$email' --password '$PASSWORD' --assume-yes >/dev/null"
    set_be_user_discoverable "$nickname"
}

migrate_and_create_be_user() {
    local nickname="$1"
    local email="$2"

    # A fresh dev configuration makes Mix perform its startup checks for every
    # container. Keeping migration and user bootstrap in one invocation avoids
    # paying that cost twice for each isolated peer run.
    docker_run_mix "${PREFIX}-prepare-be" \
        "mix ecto.migrate && mix pleroma.user new '$nickname' '$email' --password '$PASSWORD' --assume-yes >/dev/null"
    set_be_user_discoverable "$nickname"
}

create_be_token() {
    local username="$1"
    local app token client_id client_secret

    app="$(
        http_form POST "$BE_BASE/api/v1/apps" "" 200 \
            "client_name=${PREFIX}-$username" \
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

start_gotosocial() {
    docker volume create "$GTS_VOLUME" >/dev/null

    # Docker selects an available private subnet for each isolated test
    # network. Permit all RFC 1918 ranges so GoToSocial can dereference its
    # disposable peer regardless of the host daemon's chosen pool.
    docker run -d \
        --name "$GTS_CONTAINER" \
        --hostname "$GTS_APP_HOST" \
        --network "$NETWORK" \
        --network-alias "$GTS_APP_HOST" \
        -e GTS_LOG_LEVEL=info \
        -e GTS_HOST="$GTS_HOST" \
        -e GTS_ACCOUNT_DOMAIN="$GTS_HOST" \
        -e GTS_PROTOCOL=http \
        -e GTS_BIND_ADDRESS=0.0.0.0 \
        -e GTS_PORT=8080 \
        -e GTS_TRUSTED_PROXIES=127.0.0.1/32,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16 \
        -e GTS_HTTP_CLIENT_ALLOW_IPS=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16 \
        -e GTS_HTTP_CLIENT_INSECURE_OUTGOING=true \
        -e GTS_DB_TYPE=sqlite \
        -e GTS_DB_ADDRESS=/gotosocial/storage/sqlite.db \
        -e GTS_STORAGE_BACKEND=local \
        -e GTS_STORAGE_LOCAL_BASE_PATH=/gotosocial/storage \
        -e GTS_LETSENCRYPT_ENABLED=false \
        -e GTS_ACCOUNTS_REGISTRATION_OPEN=false \
        -v "$GTS_VOLUME:/gotosocial/storage" \
        "$GTS_IMAGE" >/dev/null
}

start_gts_proxy() {
    local tls_args=()

    if [ "$SMOKE_TLS" = "1" ]; then
        tls_args+=(-v "$SMOKE_TLS_DIR:/etc/nginx/tls:ro")
    fi

    docker run -d \
        --name "$GTS_PROXY_CONTAINER" \
        --hostname "$GTS_PROXY_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$GTS_HOST" \
        -p "127.0.0.1:$GTS_PORT:80" \
        "${tls_args[@]}" \
        -v "$GTS_NGINX_CONF:/etc/nginx/conf.d/default.conf:ro" \
        "$NGINX_IMAGE" >/dev/null
}

wait_gotosocial() {
    for _ in $(seq 1 180); do
        if curl -fsS "$GTS_BASE/api/v1/instance" >/dev/null 2>&1; then
            return 0
        fi

        sleep 1
    done

    docker logs "$GTS_CONTAINER" >&2 || true
    fail "Timed out waiting for $GTS_LABEL at $GTS_BASE"
}

gts_cli() {
    if docker exec "$GTS_CONTAINER" gotosocial "$@" >/dev/null 2>&1; then
        return 0
    fi

    docker exec "$GTS_CONTAINER" /gotosocial/gotosocial "$@" >/dev/null
}

create_gts_user() {
    gts_cli admin account create \
        --username "$1" \
        --email "$2" \
        --password "$PASSWORD"
}

create_gts_token() {
    local username="$1"
    local email="$2"

    python3 - "$GTS_BASE" "$username" "$email" "$PASSWORD" <<'PY'
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

base, username, email, password = sys.argv[1:]
scope = "read write follow"
redirect_uri = "urn:ietf:wg:oauth:2.0:oob"

class NoUrnRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

def post_json(opener, url, payload):
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Accept": "application/json", "Content-Type": "application/json"},
        method="POST",
    )
    with opener.open(req, timeout=45) as response:
        return json.loads(response.read().decode())

def request(url, data=None, cookie=""):
    headers = {"Accept": "text/html,application/json"}
    method = "GET"

    if cookie:
        headers["Cookie"] = cookie

    if data is not None:
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        method = "POST"

    return urllib.request.Request(url, data=data, headers=headers, method=method)

def open_request(opener, req):
    try:
        with opener.open(req, timeout=45) as response:
            return response.status, dict(response.headers), response.read().decode(errors="replace")
    except urllib.error.HTTPError as error:
        return error.code, dict(error.headers), error.read().decode(errors="replace")

def post_form(opener, url, fields, cookie=""):
    req = urllib.request.Request(
        url,
        data=urllib.parse.urlencode(fields).encode(),
        headers={
            "Accept": "text/html,application/json",
            "Content-Type": "application/x-www-form-urlencoded",
            "Cookie": cookie,
        },
        method="POST",
    )
    return opener.open(req, timeout=45)

def extract_code(value):
    value = value.replace("&amp;", "&")
    for pattern in (
        r"[?&]code=([A-Za-z0-9._~-]+)",
        r"out-of-band token[^A-Za-z0-9._~-]+([A-Za-z0-9._~-]{16,})",
        r"authorization code[^A-Za-z0-9._~-]+([A-Za-z0-9._~-]{16,})",
        r"<code[^>]*>([A-Za-z0-9._~-]{16,})</code>",
    ):
        match = re.search(pattern, value, re.IGNORECASE)
        if match:
            return match.group(1)
    return ""

def cookie_from(headers):
    set_cookie = headers.get("Set-Cookie", "")
    if not set_cookie:
        return ""
    return set_cookie.split(";", 1)[0]

opener = urllib.request.build_opener(NoUrnRedirect)
app = post_json(opener, base + "/api/v1/apps", {
    "client_name": "unfathomably-gotosocial-smoke-" + username,
    "redirect_uris": redirect_uri,
    "scopes": scope,
})
client_id = app["client_id"]
client_secret = app["client_secret"]

query = urllib.parse.urlencode({
    "response_type": "code",
    "client_id": client_id,
    "redirect_uri": redirect_uri,
    "scope": scope,
})
authorize_url = base + "/oauth/authorize?" + query

for login_name in (email, username):
    status, headers, body = open_request(opener, request(authorize_url))
    cookie = cookie_from(headers)

    if status not in (200, 302, 303):
        continue

    status, headers, body = open_request(
        opener,
        request(
            base + "/auth/sign_in",
            urllib.parse.urlencode({"username": login_name, "password": password}).encode(),
            cookie,
        ),
    )
    cookie = cookie_from(headers) or cookie

    if status not in (200, 302, 303) or not cookie:
        continue

    status, headers, body = open_request(opener, request(authorize_url, cookie=cookie))
    cookie = cookie_from(headers) or cookie

    if status != 200:
        continue

    status, headers, body = open_request(opener, request(base + "/oauth/authorize", b"", cookie))
    code = extract_code(headers.get("Location", "")) or extract_code(body)

    if not code:
        continue

    token = post_json(opener, base + "/oauth/token", {
        "redirect_uri": redirect_uri,
        "client_id": client_id,
        "client_secret": client_secret,
        "grant_type": "authorization_code",
        "code": code,
    })
    print(token["access_token"])
    raise SystemExit(0)

sys.stderr.write(body[-2000:] + "\n")
raise SystemExit("could not automate GoToSocial OAuth")
PY
}

resolve_account_id() {
    local base="$1"
    local token="$2"
    local acct="$3"
    local message="$4"
    local result id query type_query

    if [ "$base" = "$GTS_BASE" ] && declare -F resolve_gts_be_account_id >/dev/null; then
        resolve_gts_be_account_id "$acct"
        return
    fi

    query="$acct"
    type_query="&type=accounts"

    if [ "$base" = "$GTS_BASE" ] && [ "$GTS_SEARCH_WITH_ACCOUNT_TYPE" = "0" ]; then
        type_query=""
    fi

    if [ "$base" = "$GTS_BASE" ] && [ "$GTS_LOOKUP_BE_BY_ACTOR_URL" = "1" ]; then
        query="http://$BE_HOST/users/${acct%%@*}"
        type_query=""
    fi

    for _ in $(seq 1 90); do
        result="$(http_form GET "$base/api/v2/search?q=$(urlencode "$query")&resolve=true${type_query}&limit=5" "$token" 200 || true)"
        id="$(json_get_optional "$result" accounts.0.id)"

        if [ -n "$id" ]; then
            printf '%s\n' "$id"
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

resolve_status_id() {
    local base="$1"
    local token="$2"
    local uri="$3"
    local message="$4"
    local result id type_query

    if [ "$base" = "$GTS_BASE" ] && declare -F resolve_gts_be_status_id >/dev/null; then
        resolve_gts_be_status_id "$token" "$uri" "$message"
        return
    fi

    type_query="&type=statuses"

    if [ "$base" = "$GTS_BASE" ] && [ "$GTS_SEARCH_WITH_STATUS_TYPE" = "0" ]; then
        type_query=""
    fi

    for _ in $(seq 1 90); do
        result="$(http_form GET "$base/api/v2/search?q=$(urlencode "$uri")&resolve=true${type_query}&limit=5" "$token" 200 || true)"
        id="$(json_get_optional "$result" statuses.0.id)"

        if [ -n "$id" ]; then
            printf '%s\n' "$id"
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

poll_context_status_by_text() {
    local base="$1"
    local token="$2"
    local parent_id="$3"
    local text="$4"
    local message="$5"
    local result=""

    for _ in $(seq 1 90); do
        result="$(http_form GET "$base/api/v1/statuses/$parent_id/context" "$token" 200 || true)"

        if [ -n "$result" ] && JSON_INPUT="$result" EXPECTED_TEXT="$text" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
text = os.environ["EXPECTED_TEXT"]
for status in data.get("descendants", []):
    content = status.get("content") or status.get("text") or ""
    if text in content:
        raise SystemExit(0)
raise SystemExit(1)
PY
        then
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

poll_home_status_by_text() {
    local base="$1"
    local token="$2"
    local text="$3"
    local message="$4"
    local result=""
    local id=""

    for _ in $(seq 1 90); do
        result="$(http_form GET "$base/api/v1/timelines/home?limit=40" "$token" 200 || true)"

        id="$(
            JSON_INPUT="$result" EXPECTED_TEXT="$text" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
text = os.environ["EXPECTED_TEXT"]
for status in data:
    content = status.get("content") or status.get("text") or ""
    if text in content:
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

poll_account_status_by_text() {
    local base="$1"
    local token="$2"
    local account_id="$3"
    local text="$4"
    local message="$5"
    local result=""
    local id=""

    for _ in $(seq 1 90); do
        result="$(http_form GET "$base/api/v1/accounts/$account_id/statuses?limit=40" \
            "$token" 200 || true)"

        id="$(
            JSON_INPUT="$result" EXPECTED_TEXT="$text" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
text = os.environ["EXPECTED_TEXT"]
for status in data:
    content = status.get("content") or status.get("text") or ""
    if text in content:
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

poll_status_count() {
    poll_json_assert \
        "http_form GET '$1/api/v1/statuses/$3' '$2' 200" \
        "$4" \
        "$5" >/dev/null
}

poll_relationship_following() {
    local base="$1"
    local token="$2"
    local account_id="$3"
    local message="$4"

    poll_json_assert \
        "http_form GET '$base/api/v1/accounts/relationships?id[]=$account_id' '$token' 200" \
        'len(data) >= 1 and data[0].get("following") is True and data[0].get("requested") is not True' \
        "$message" >/dev/null
}

poll_status_missing() {
    local base="$1"
    local token="$2"
    local status_id="$3"
    local message="$4"
    local status

    for _ in $(seq 1 60); do
        status="$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" -H 'Accept: application/json' "$base/api/v1/statuses/$status_id" || true)"

        if [ "$status" = "404" ] || [ "$status" = "410" ]; then
            return 0
        fi

        sleep 2
    done

    fail "$message"
}

probe_gts_group_actor() {
    local token="$1"
    local group_acct="$2"
    local group_id="$3"
    local result account_id follow_result post text be_id query type_query

    query="$group_acct"
    type_query="&type=accounts"

    if [ "$GTS_SEARCH_WITH_ACCOUNT_TYPE" = "0" ]; then
        type_query=""
    fi

    if [ "$GTS_LOOKUP_BE_BY_ACTOR_URL" = "1" ]; then
        query="http://$BE_HOST/users/${group_acct%%@*}"
        type_query=""
    fi

    result="$(http_form GET "$GTS_BASE/api/v2/search?q=$(urlencode "$query")&resolve=true${type_query}&limit=5" "$token" 200 || true)"
    account_id="$(json_get_optional "$result" accounts.0.id)"

    if [ -z "$account_id" ]; then
        printf 'not_supported: stock %s did not import Unfathomably Group actor %s as a followable account\n' "$GTS_LABEL" "$group_acct"
        return 0
    fi

    follow_result="$(http_form POST "$GTS_BASE/api/v1/accounts/$account_id/follow" "$token" 200 || true)"
    if ! JSON_INPUT="$follow_result" python3 - <<'PY'
import json
import os

try:
    data = json.loads(os.environ["JSON_INPUT"])
except Exception:
    raise SystemExit(1)
if not (data.get("following") or data.get("requested")):
    raise SystemExit(1)
PY
    then
        printf 'not_supported: stock %s resolved Group actor %s but did not follow it\n' "$GTS_LABEL" "$group_acct"
        return 0
    fi

    text="$GTS_LABEL mention into Unfathomably group $(basename "$WORK_DIR")"
    post="$(http_form POST "$GTS_BASE/api/v1/statuses" "$token" 200 \
        "status=$text @$group_acct" \
        "visibility=public")"
    be_id="$(resolve_status_id "$BE_BASE" "$ALICE_TOKEN" "$(json_get "$post" uri)" "Unfathomably could not resolve $GTS_LABEL group mention post")"

    local found=0

    for _ in $(seq 1 90); do
        result="$(http_form GET "$BE_BASE/api/v1/groups/$group_id/statuses?limit=20" "$ALICE_TOKEN" 200 || true)"

        if [ -n "$result" ] && JSON_INPUT="$result" EXPECTED_TEXT="$text" EXPECTED_ID="$be_id" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
expected_id = os.environ["EXPECTED_ID"]
text = os.environ["EXPECTED_TEXT"]
for status in data:
    if status.get("id") == expected_id or text in (status.get("content") or ""):
        raise SystemExit(0)
raise SystemExit(1)
PY
        then
            found=1
            break
        fi

        sleep 2
    done

    if [ "$found" != "1" ]; then
        fail "Unfathomably did not place $GTS_LABEL mention post in the group timeline"
    fi

    http_form DELETE "$GTS_BASE/api/v1/statuses/$(json_get "$post" id)" "$token" 200 >/dev/null
    http_form POST "$GTS_BASE/api/v1/accounts/$account_id/unfollow" "$token" 200 >/dev/null || true
    printf 'supported: %s imported the Group actor as an account and Unfathomably accepted top-level mention posting into the group\n' "$GTS_LABEL"
}

check_logs() {
    local name="$1"
    local label="$2"
    local logs=""
    local recovered_announce_count=0
    local enrich_announce_count=0

    logs="$(docker logs "$name" 2>&1)"
    recovered_announce_count="$(printf '%s\n' "$logs" | grep -Fxc 'recovered panic: nil error' || true)"
    enrich_announce_count="$(printf '%s\n' "$logs" | grep -Fxc 'dereferencing.(*Dereferencer).EnrichAnnounce()' || true)"

    # GoToSocial beta currently recovers a nil-error panic when it receives
    # the Announce emitted after one of its own posts is accepted by a remote
    # Group actor.  Require the exact recovery line and one matching
    # EnrichAnnounce frame per occurrence.  Any other panic remains fatal.
    if [ "$recovered_announce_count" -gt 0 ]; then
        if [ "$label" != "GoToSocial" ] || [ "$recovered_announce_count" -ne "$enrich_announce_count" ]; then
            printf '%s\n' "$logs" >&2
            fail "$label emitted an unclassified recovered panic"
        fi

        printf 'not_supported: stock GoToSocial beta recovered its nil-error EnrichAnnounce path instead of importing the remote Group Announce\n'
    fi

    if printf '%s\n' "$logs" |
        grep -Ei 'panic:|segmentation fault|FunctionClauseError|MatchError|ArgumentError|(^|[[:space:]])fatal error|level=(fatal|FATAL)|\[fatal\]' |
        grep -Fvx 'recovered panic: nil error' >/dev/null; then
        printf '%s\n' "$logs" >&2
        fail "$label emitted a crash-class log line"
    fi
}

run_account_peer_smoke() {
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

log "Starting databases and stock $GTS_LABEL"
docker run -d \
    --name "$BE_DB_CONTAINER" \
    --network "$NETWORK" \
    -e POSTGRES_PASSWORD="$BE_DB_PASSWORD" \
    "$POSTGRES_IMAGE" >/dev/null

wait_postgres
prepare_database
start_gotosocial
start_gts_proxy
wait_gotosocial

log "Creating $GTS_LABEL test account"
create_gts_user "$GTS_USERNAME" "$GTS_USERNAME@$GTS_HOST"

log "Migrating and starting Unfathomably"
migrate_and_create_be_user alice "alice@$BE_HOST"
start_be
start_be_proxy
wait_be

log "Creating API credentials"
ALICE_TOKEN="$(create_be_token alice)"
GTS_TOKEN="$(create_gts_token "$GTS_USERNAME" "$GTS_USERNAME@$GTS_HOST")"
GTS_CREDENTIALS="$(http_form PATCH "$GTS_BASE/api/v1/accounts/update_credentials" "$GTS_TOKEN" 200 "locked=false")"
json_assert "$GTS_CREDENTIALS" 'data.get("locked") is False' "$GTS_LABEL smoke account could not be unlocked"
http_form GET "$BE_BASE/api/v1/accounts/verify_credentials" "$ALICE_TOKEN" 200 >/dev/null

log "Creating Unfathomably local group for $GTS_LABEL Group actor probe"
BE_GROUP_NAME="$GTS_GROUP_NAME"
BE_GROUP="$(
    http_form POST "$BE_BASE/api/v1/groups" "$ALICE_TOKEN" 200 \
        "display_name=Unfathomably $GTS_LABEL Smoke" \
        "name=$BE_GROUP_NAME" \
        "note=Open group used by the $GTS_LABEL bidirectional smoke harness." \
        "locked=false"
)"
BE_GROUP_ID="$(json_get "$BE_GROUP" id)"

log "Following accounts in both directions"
BE_ACCOUNT_ID="$(resolve_account_id "$GTS_BASE" "$GTS_TOKEN" "alice@$BE_HOST" "$GTS_LABEL could not resolve Unfathomably account")"
GTS_FOLLOW_BE="$(http_form POST "$GTS_BASE/api/v1/accounts/$BE_ACCOUNT_ID/follow" "$GTS_TOKEN" 200)"
json_assert "$GTS_FOLLOW_BE" 'data.get("following") is True or data.get("requested") is True' "$GTS_LABEL could not follow Unfathomably account"

# The remote Follow is deliberately sent first. Some peers correctly publish
# HTTP actor IDs on an isolated test network while generic WebFinger clients
# prefer HTTPS. Receiving the signed Follow gives Unfathomably the canonical
# actor document before it performs the reverse account lookup.
GTS_ACCOUNT_ID="$(resolve_account_id "$BE_BASE" "$ALICE_TOKEN" "$GTS_USERNAME@$GTS_HOST" "Unfathomably could not resolve $GTS_LABEL account after its signed Follow")"
BE_FOLLOW_GTS="$(http_form POST "$BE_BASE/api/v1/accounts/$GTS_ACCOUNT_ID/follow" "$ALICE_TOKEN" 200)"
json_assert "$BE_FOLLOW_GTS" 'data.get("following") is True or data.get("requested") is True' "Unfathomably could not follow $GTS_LABEL account"

poll_relationship_following "$GTS_BASE" "$GTS_TOKEN" "$BE_ACCOUNT_ID" "$GTS_LABEL follow of Unfathomably did not become accepted"
poll_relationship_following "$BE_BASE" "$ALICE_TOKEN" "$GTS_ACCOUNT_ID" "Unfathomably follow of $GTS_LABEL did not become accepted"

log "Testing Unfathomably post delivery into $GTS_LABEL"
BE_TO_GTS_TEXT="Unfathomably to $GTS_LABEL smoke $(basename "$WORK_DIR")"
BE_TO_GTS_POST="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
    "status=$BE_TO_GTS_TEXT" \
    "visibility=public")"
BE_TO_GTS_ID="$(json_get "$BE_TO_GTS_POST" id)"
BE_TO_GTS_URI="$(json_get "$BE_TO_GTS_POST" uri)"
GTS_VIEW_OF_BE_ID="$(resolve_status_id "$GTS_BASE" "$GTS_TOKEN" "$BE_TO_GTS_URI" "$GTS_LABEL could not resolve Unfathomably post")"

GTS_LIKE_BE="$(http_form POST "$GTS_BASE/api/v1/statuses/$GTS_VIEW_OF_BE_ID/favourite" "$GTS_TOKEN" 200)"
json_assert "$GTS_LIKE_BE" 'data.get("favourited") is True' "$GTS_LABEL could not favourite Unfathomably post"
poll_status_count "$BE_BASE" "$ALICE_TOKEN" "$BE_TO_GTS_ID" 'int(data.get("favourites_count") or 0) >= 1' "Unfathomably did not receive $GTS_LABEL favourite"

GTS_UNLIKE_BE="$(http_form POST "$GTS_BASE/api/v1/statuses/$GTS_VIEW_OF_BE_ID/unfavourite" "$GTS_TOKEN" 200)"
json_assert "$GTS_UNLIKE_BE" 'data.get("favourited") is False' "$GTS_LABEL could not unfavourite Unfathomably post"
poll_status_count "$BE_BASE" "$ALICE_TOKEN" "$BE_TO_GTS_ID" 'int(data.get("favourites_count") or 0) == 0' "Unfathomably did not receive $GTS_LABEL unfavourite"

GTS_REPLY_TEXT="$GTS_LABEL reply to Unfathomably $(basename "$WORK_DIR")"
GTS_REPLY="$(http_form POST "$GTS_BASE/api/v1/statuses" "$GTS_TOKEN" 200 \
    "status=$GTS_REPLY_TEXT @alice@$BE_HOST" \
    "in_reply_to_id=$GTS_VIEW_OF_BE_ID" \
    "visibility=public")"
GTS_REPLY_ID="$(json_get "$GTS_REPLY" id)"
poll_context_status_by_text "$BE_BASE" "$ALICE_TOKEN" "$BE_TO_GTS_ID" "$GTS_REPLY_TEXT" "Unfathomably did not receive $GTS_LABEL reply"
http_form DELETE "$GTS_BASE/api/v1/statuses/$GTS_REPLY_ID" "$GTS_TOKEN" 200 >/dev/null

log "Testing $GTS_LABEL post delivery into Unfathomably"
GTS_TO_BE_TEXT="$GTS_LABEL to Unfathomably smoke $(basename "$WORK_DIR")"
GTS_TO_BE_POST="$(http_form POST "$GTS_BASE/api/v1/statuses" "$GTS_TOKEN" 200 \
    "status=$GTS_TO_BE_TEXT @alice@$BE_HOST" \
    "visibility=public")"
GTS_TO_BE_ID="$(json_get "$GTS_TO_BE_POST" id)"
GTS_TO_BE_URI="$(json_get "$GTS_TO_BE_POST" uri)"
BE_VIEW_OF_GTS_ID="$(poll_home_status_by_text "$BE_BASE" "$ALICE_TOKEN" "$GTS_TO_BE_TEXT" "Unfathomably did not receive $GTS_LABEL post")"

BE_LIKE_GTS="$(http_form POST "$BE_BASE/api/v1/statuses/$BE_VIEW_OF_GTS_ID/favourite" "$ALICE_TOKEN" 200)"
json_assert "$BE_LIKE_GTS" 'data.get("favourited") is True' "Unfathomably could not favourite $GTS_LABEL post"
poll_status_count "$GTS_BASE" "$GTS_TOKEN" "$GTS_TO_BE_ID" 'int(data.get("favourites_count") or 0) >= 1' "$GTS_LABEL did not receive Unfathomably favourite"

BE_UNLIKE_GTS="$(http_form POST "$BE_BASE/api/v1/statuses/$BE_VIEW_OF_GTS_ID/unfavourite" "$ALICE_TOKEN" 200)"
json_assert "$BE_UNLIKE_GTS" 'data.get("favourited") is False' "Unfathomably could not unfavourite $GTS_LABEL post"
poll_status_count "$GTS_BASE" "$GTS_TOKEN" "$GTS_TO_BE_ID" 'int(data.get("favourites_count") or 0) == 0' "$GTS_LABEL did not receive Unfathomably unfavourite"

BE_REPLY_TEXT="Unfathomably reply to $GTS_LABEL $(basename "$WORK_DIR")"
BE_REPLY="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
    "status=$BE_REPLY_TEXT" \
    "in_reply_to_id=$BE_VIEW_OF_GTS_ID")"
BE_REPLY_ID="$(json_get "$BE_REPLY" id)"
poll_context_status_by_text "$GTS_BASE" "$GTS_TOKEN" "$GTS_TO_BE_ID" "$BE_REPLY_TEXT" "$GTS_LABEL did not receive Unfathomably reply"
http_form DELETE "$BE_BASE/api/v1/statuses/$BE_REPLY_ID" "$ALICE_TOKEN" 200 >/dev/null

log "Testing top-level deletes"
http_form DELETE "$BE_BASE/api/v1/statuses/$BE_TO_GTS_ID" "$ALICE_TOKEN" 200 >/dev/null
poll_status_missing "$GTS_BASE" "$GTS_TOKEN" "$GTS_VIEW_OF_BE_ID" "$GTS_LABEL did not lose deleted Unfathomably status"
http_form DELETE "$GTS_BASE/api/v1/statuses/$GTS_TO_BE_ID" "$GTS_TOKEN" 200 >/dev/null
poll_status_missing "$BE_BASE" "$ALICE_TOKEN" "$BE_VIEW_OF_GTS_ID" "Unfathomably did not lose deleted $GTS_LABEL status"

log "Unfollowing accounts"
http_form POST "$BE_BASE/api/v1/accounts/$GTS_ACCOUNT_ID/unfollow" "$ALICE_TOKEN" 200 >/dev/null
http_form POST "$GTS_BASE/api/v1/accounts/$BE_ACCOUNT_ID/unfollow" "$GTS_TOKEN" 200 >/dev/null

log "Probing $GTS_LABEL behavior around Unfathomably Group actors"
GROUP_SUMMARY="$(probe_gts_group_actor "$GTS_TOKEN" "$BE_GROUP_NAME@$BE_HOST" "$BE_GROUP_ID")"
printf '%s\n' "$GROUP_SUMMARY"

check_logs "$BE_CONTAINER" "Unfathomably"
check_logs "$GTS_CONTAINER" "$GTS_LABEL"

cat <<EOF

$GTS_LABEL federation smoke passed.

Covered against stock $GTS_LABEL:
* supported: OAuth/token creation on Unfathomably and $GTS_LABEL
* supported: account discovery and follow in both directions
* supported: Unfathomably-to-$GTS_LABEL status delivery
* supported: $GTS_LABEL-to-Unfathomably status delivery
* supported: replies in both directions
* supported: favourites and unfavourites in both directions
* supported: top-level deletes in both directions
* supported: account unfollow cleanup in both directions
* $GROUP_SUMMARY
* not_supported: $GTS_LABEL cannot report that a remote server defederated it
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run_account_peer_smoke
fi

# end of build_scripts/unfathomably-gotosocial-smoke.sh
