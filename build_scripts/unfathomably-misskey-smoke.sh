#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-misskey-smoke.sh
#
# Purpose:
#
#   Run a local stock Misskey federation peer against Unfathomably and prove
#   both ordinary account federation and the Misskey-specific ActivityPub
#   shapes that Unfathomably intentionally supports.
#
# Responsibilities:
#
#   * boot isolated Unfathomably, Misskey, database, Redis, and proxy containers
#   * create local test accounts and API tokens on both peers
#   * exercise bidirectional follow, post, reply, favourite, emoji reaction,
#     delete, and unfollow behavior
#   * verify Misskey-specific quote, profile summary, and reaction federation
#     through the public API fields consumed by the frontend
#
# This file intentionally does NOT contain:
#
#   * production deployment logic
#   * patched Misskey binaries
#   * hidden success for forum or Group actor semantics Misskey does not expose
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BE_ROOT="${BE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

PREFIX="${SMOKE_PREFIX:-unfathomably-misskey-smoke}"
NETWORK="${PREFIX}-net"

BE_DB_CONTAINER="${PREFIX}-be-db"
BE_CONTAINER="${PREFIX}-be"
BE_PROXY_CONTAINER="${PREFIX}-be-proxy"
BE_APP_HOST="${PREFIX}-be-app"
BE_HOST="${BE_HOST:-unfathomably-misskey.test}"
BE_PORT="${BE_PORT:-4981}"
BE_BASE="https://127.0.0.1:$BE_PORT"
BE_DB_NAME="${BE_DB_NAME:-unfathomably_misskey_smoke_be}"
BE_DB_PASSWORD="${BE_DB_PASSWORD:-postgres}"

MISSKEY_DB_CONTAINER="${PREFIX}-misskey-db"
MISSKEY_REDIS_CONTAINER="${PREFIX}-misskey-redis"
MISSKEY_CONTAINER="${PREFIX}-misskey"
MISSKEY_PROXY_CONTAINER="${PREFIX}-misskey-proxy"
MISSKEY_APP_HOST="${PREFIX}-misskey-app"
MISSKEY_HOST="${MISSKEY_HOST:-misskey-ref.test}"
MISSKEY_PORT="${MISSKEY_PORT:-4982}"
MISSKEY_BASE="https://127.0.0.1:$MISSKEY_PORT"
MISSKEY_DB_NAME="${MISSKEY_DB_NAME:-misskey}"
MISSKEY_DB_USER="${MISSKEY_DB_USER:-misskey}"
MISSKEY_DB_PASSWORD="${MISSKEY_DB_PASSWORD:-misskey}"
MISSKEY_REACTION="${MISSKEY_REACTION:-⭐}"
MISSKEY_LABEL="${MISSKEY_LABEL:-Misskey}"
MISSKEY_USERNAME="${MISSKEY_USERNAME:-misskey}"
MISSKEY_RUNTIME_HOME="${MISSKEY_RUNTIME_HOME:-/misskey}"

IMAGE="${UNFATHOMABLY_SMOKE_IMAGE:-unfathomably-elixir-smoke:otp28}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:15-alpine}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.27-alpine}"
MISSKEY_IMAGE="${MISSKEY_IMAGE:-misskey/misskey:latest}"
PASSWORD="${SMOKE_PASSWORD:-correct horse battery staple 12345}"
KEEP_CONTAINERS="${KEEP_CONTAINERS:-0}"
WORK_DIR="${SMOKE_WORK_DIR:-}"

if [ -z "$WORK_DIR" ]; then
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/unfathomably-misskey-smoke.XXXXXX")"
fi

BE_SECRET="$WORK_DIR/be/dev.secret.exs"
BE_UPLOADS="$WORK_DIR/be/uploads"
BE_STATIC="$WORK_DIR/be/static"
BE_NGINX_CONF="$WORK_DIR/be-nginx/default.conf"
MISSKEY_CONFIG_DIR="$WORK_DIR/misskey/.config"
MISSKEY_FILES_DIR="$WORK_DIR/misskey/files"
MISSKEY_NGINX_CONF="$WORK_DIR/misskey-nginx/default.conf"
CA_DIR="$WORK_DIR/ca"
CA_CERT="$CA_DIR/smoke-ca.crt"
CA_KEY="$CA_DIR/smoke-ca.key"
MISSKEY_CERT="$CA_DIR/misskey.crt"
MISSKEY_KEY="$CA_DIR/misskey.key"
BE_CERT="$CA_DIR/be.crt"
BE_KEY="$CA_DIR/be.key"
CA_OPENSSL_CONF="$CA_DIR/ca-openssl.cnf"
MISSKEY_OPENSSL_CONF="$CA_DIR/misskey-openssl.cnf"
BE_OPENSSL_CONF="$CA_DIR/be-openssl.cnf"

log() {
    printf '\n==> %s\n' "$*"
}

fail() {
    printf '\nERROR: %s\n' "$*" >&2
    printf 'Work directory: %s\n' "$WORK_DIR" >&2
    exit 1
}

cleanup() {
    local status="$?"

    if [ "$KEEP_CONTAINERS" = "1" ]; then
        printf '\nKEEP_CONTAINERS=1, leaving containers and work directory in place.\n' >&2
        exit "$status"
    fi

    docker rm -f \
        "$MISSKEY_PROXY_CONTAINER" \
        "$MISSKEY_CONTAINER" \
        "$MISSKEY_REDIS_CONTAINER" \
        "$MISSKEY_DB_CONTAINER" \
        "$BE_PROXY_CONTAINER" \
        "$BE_CONTAINER" \
        "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR"
    exit "$status"
}

trap cleanup EXIT

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

require_command curl
require_command docker
require_command openssl
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
    print(json.dumps(value, ensure_ascii=False))
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
        print(json.dumps(value, ensure_ascii=False))
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
safe_builtins = {"all": all, "any": any, "int": int, "len": len, "str": str, "sum": sum}
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

json_payload() {
    python3 - "$@" <<'PY'
import json
import sys

payload = {}
for arg in sys.argv[1:]:
    key, value = arg.split("=", 1)
    if value.startswith("int:"):
        payload[key] = int(value[4:])
    elif value.startswith("bool:"):
        payload[key] = value[5:].lower() == "true"
    elif value.startswith("json:"):
        payload[key] = json.loads(value[5:])
    elif value == "null":
        payload[key] = None
    else:
        payload[key] = value
print(json.dumps(payload, ensure_ascii=False))
PY
}

payload_with_token() {
    local token="$1"
    local payload="$2"

    MISSKEY_TOKEN="$token" JSON_INPUT="$payload" python3 - <<'PY'
import json
import os

payload = json.loads(os.environ["JSON_INPUT"])
payload["i"] = os.environ["MISSKEY_TOKEN"]
print(json.dumps(payload, ensure_ascii=False))
PY
}

http_form() {
    local method="$1"
    local url="$2"
    local token="$3"
    local expected="$4"
    shift 4

    local headers=(-H 'Accept: application/json')
    local args=(-k -sS -X "$method" -w '\n%{http_code}')

    if [ -n "$token" ]; then
        headers+=(-H "Authorization: Bearer $token")
    fi

    for field in "$@"; do
        args+=(-F "$field")
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
    local args=(-k -sS -X "$method" -w '\n%{http_code}' --data "$payload")

    if [ -n "$token" ]; then
        headers+=(-H "Authorization: Bearer $token")
    fi

    local response status body retry_after

    for attempt in $(seq 1 4); do
        response="$(curl "${args[@]}" "${headers[@]}" "$url")" || return 1
        status="${response##*$'\n'}"
        body="${response%$'\n'*}"

        if [ "$status" != "429" ] || [ "$attempt" = "4" ]; then
            break
        fi

        # Newer Misskey releases rate-limit destructive note operations to one
        # call per window and report the next usable instant in resetMs.
        retry_after="$(JSON_INPUT="$body" python3 - <<'PY'
import json
import math
import os
import time

try:
    data = json.loads(os.environ["JSON_INPUT"])
    reset_ms = data["error"]["info"]["resetMs"]
    seconds = math.ceil((float(reset_ms) - time.time() * 1000) / 1000) + 1
except (KeyError, TypeError, ValueError, json.JSONDecodeError):
    seconds = 5

print(max(1, min(seconds, 120)))
PY
)"
        sleep "$retry_after"
    done

    if [ "$status" != "$expected" ]; then
        printf 'Unexpected HTTP status for %s %s: expected %s got %s\n' \
            "$method" "$url" "$expected" "$status" >&2
        printf '%s\n' "$body" >&2
        return 1
    fi

    printf '%s\n' "$body"
}

misskey_api() {
    local endpoint="$1"
    local token="$2"
    local expected="$3"
    local payload="$4"

    if [ -n "$token" ]; then
        payload="$(payload_with_token "$token" "$payload")"
    fi

    http_json POST "$MISSKEY_BASE/api/$endpoint" "" "$expected" "$payload"
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
safe_builtins = {"all": all, "any": any, "int": int, "len": len, "str": str, "sum": sum}
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

write_tls_material() {
    mkdir -p "$CA_DIR"

    cat >"$CA_OPENSSL_CONF" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_ca
prompt = no

[req_distinguished_name]
CN = Unfathomably Misskey Smoke CA

[v3_ca]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, keyCertSign, cRLSign
EOF

    cat >"$MISSKEY_OPENSSL_CONF" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $MISSKEY_HOST

[v3_req]
subjectAltName = @alt_names
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = $MISSKEY_HOST
EOF

    cat >"$BE_OPENSSL_CONF" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $BE_HOST

[v3_req]
subjectAltName = @alt_names
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = $BE_HOST
EOF

    openssl req -x509 -newkey rsa:2048 -nodes -days 3 \
        -config "$CA_OPENSSL_CONF" \
        -keyout "$CA_KEY" \
        -out "$CA_CERT" >/dev/null 2>&1

    openssl req -newkey rsa:2048 -nodes \
        -config "$MISSKEY_OPENSSL_CONF" \
        -keyout "$MISSKEY_KEY" \
        -out "$CA_DIR/misskey.csr" >/dev/null 2>&1

    openssl x509 -req -days 3 \
        -in "$CA_DIR/misskey.csr" \
        -CA "$CA_CERT" \
        -CAkey "$CA_KEY" \
        -CAcreateserial \
        -out "$MISSKEY_CERT" \
        -extensions v3_req \
        -extfile "$MISSKEY_OPENSSL_CONF" >/dev/null 2>&1

    openssl req -newkey rsa:2048 -nodes \
        -config "$BE_OPENSSL_CONF" \
        -keyout "$BE_KEY" \
        -out "$CA_DIR/be.csr" >/dev/null 2>&1

    openssl x509 -req -days 3 \
        -in "$CA_DIR/be.csr" \
        -CA "$CA_CERT" \
        -CAkey "$CA_KEY" \
        -CAcreateserial \
        -out "$BE_CERT" \
        -extensions v3_req \
        -extfile "$BE_OPENSSL_CONF" >/dev/null 2>&1
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
  url: [scheme: "https", host: "$BE_HOST", port: 443],
  secret_key_base: "$secret_key_base",
  live_view: [signing_salt: "$signing_salt"],
  code_reloader: false,
  live_reload: false,
  watchers: [],
  server: true

config :pleroma, :instance,
  name: "Unfathomably Misskey Smoke",
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
config :pleroma, :http,
  adapter: [
    certificates_verification: false,
    ssl_options: [verify: :verify_none, cacertfile: "/smoke-ca/smoke-ca.crt"],
    tls_opts: [verify: :verify_none, cacertfile: "/smoke-ca/smoke-ca.crt"]
  ]
config :pleroma, configurable_from_database: false
config :pleroma, :rate_limit, nil
config :pleroma, :modules, runtime_dir: "$WORK_DIR/runtime-$BE_HOST"
config :pleroma, Pleroma.ScheduledActivity, daily_user_limit: 1000, total_user_limit: 10000
EOF
}

write_misskey_config() {
    mkdir -p "$MISSKEY_CONFIG_DIR" "$MISSKEY_FILES_DIR"
    chmod 0777 "$MISSKEY_FILES_DIR" >/dev/null 2>&1 || true

    cat >"$MISSKEY_CONFIG_DIR/default.yml" <<EOF
url: https://$MISSKEY_HOST/
port: 3000

# The smoke network is intentionally private. Misskey blocks private network
# fetches by default, so this allowlist is scoped to loopback and the
# RFC1918 ranges Docker commonly assigns to local bridge networks.
allowedPrivateNetworks:
  - 127.0.0.1/32
  - 10.0.0.0/8
  - 172.16.0.0/12
  - 192.168.0.0/16

proxyBypassHosts:
  - $BE_HOST
  - $MISSKEY_HOST

clusterLimit: 1
id: aidx

# Keep the smoke responsive without creating a large background worker fleet.
deliverJobConcurrency: 8
inboxJobConcurrency: 8
deliverJobPerSec: 64
inboxJobPerSec: 64
deliverJobMaxAttempts: 3
inboxJobMaxAttempts: 3
proxyRemoteFiles: false

redis:
  host: $MISSKEY_REDIS_CONTAINER
  port: 6379

db:
  host: $MISSKEY_DB_CONTAINER
  port: 5432
  db: $MISSKEY_DB_NAME
  user: $MISSKEY_DB_USER
  pass: $MISSKEY_DB_PASSWORD
EOF
}

write_proxy_configs() {
    mkdir -p "$(dirname "$BE_NGINX_CONF")" "$(dirname "$MISSKEY_NGINX_CONF")"

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

server {
    listen 443 ssl;
    server_name _;

    client_max_body_size 50m;

    ssl_certificate /etc/nginx/smoke-certs/be.crt;
    ssl_certificate_key /etc/nginx/smoke-certs/be.key;

    location / {
        proxy_pass http://$BE_APP_HOST:4000;
        proxy_set_header Host $BE_HOST;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF

    cat >"$MISSKEY_NGINX_CONF" <<EOF
server {
    listen 80;
    server_name _;

    location / {
        return 301 https://$MISSKEY_HOST\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name _;

    client_max_body_size 50m;

    ssl_certificate /etc/nginx/smoke-certs/misskey.crt;
    ssl_certificate_key /etc/nginx/smoke-certs/misskey.key;

    location / {
        proxy_pass http://$MISSKEY_APP_HOST:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $MISSKEY_HOST;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
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
        -e SSL_CERT_FILE=/smoke-ca/smoke-ca.crt \
        -v "$BE_ROOT:/work" \
        -v "$BE_SECRET:/work/config/dev.secret.exs:ro" \
        -v "$CA_CERT:/smoke-ca/smoke-ca.crt:ro" \
        "$IMAGE" \
        bash -lc "set -euo pipefail; cd /work; git config --global --add safe.directory /work >/dev/null 2>&1 || true; mix local.hex --force >/dev/null; mix local.rebar --force >/dev/null; mix deps.get >/dev/null; $*" \
        >"$log_file" 2>&1; then
        cat "$log_file" >&2 || true
        fail "mix command failed in $name"
    fi
}

wait_postgres_container() {
    local container="$1"
    local user="$2"
    local database="$3"
    local stable=0

    for _ in $(seq 1 100); do
        if docker exec "$container" psql -U "$user" -d "$database" -Atc "select 1" >/dev/null 2>&1; then
            stable=$((stable + 1))

            if [ "$stable" -ge 3 ]; then
                return 0
            fi
        else
            stable=0
        fi

        sleep 1
    done

    fail "PostgreSQL container $container did not become ready"
}

prepare_database() {
    docker exec "$BE_DB_CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 \
        -c "CREATE DATABASE $BE_DB_NAME;" >/dev/null
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
        -e SSL_CERT_FILE=/smoke-ca/smoke-ca.crt \
        -v "$BE_ROOT:/work" \
        -v "$BE_SECRET:/work/config/dev.secret.exs:ro" \
        -v "$CA_CERT:/smoke-ca/smoke-ca.crt:ro" \
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
        -p "127.0.0.1:$BE_PORT:443" \
        -v "$BE_NGINX_CONF:/etc/nginx/conf.d/default.conf:ro" \
        -v "$CA_DIR:/etc/nginx/smoke-certs:ro" \
        "$NGINX_IMAGE" >/dev/null
}

wait_be() {
    for _ in $(seq 1 140); do
        if curl -k -fsS "$BE_BASE/api/v1/instance" >/dev/null 2>&1; then
            return 0
        fi

        sleep 1
    done

    docker logs "$BE_CONTAINER" >&2 || true
    fail "Timed out waiting for Unfathomably at $BE_BASE"
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
            "client_name=misskey-smoke-$username" \
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

init_misskey() {
    local log_file="$WORK_DIR/misskey-init.log"

    if ! docker run --rm \
        --name "${PREFIX}-misskey-init" \
        --network "$NETWORK" \
        -v "$MISSKEY_CONFIG_DIR:$MISSKEY_RUNTIME_HOME/.config:ro" \
        -v "$MISSKEY_FILES_DIR:$MISSKEY_RUNTIME_HOME/files" \
        "$MISSKEY_IMAGE" \
        sh -lc 'pnpm run init' \
        >"$log_file" 2>&1; then
        cat "$log_file" >&2 || true
        fail "$MISSKEY_LABEL database initialization failed"
    fi
}

start_misskey() {
    docker run -d \
        --name "$MISSKEY_CONTAINER" \
        --hostname "$MISSKEY_APP_HOST" \
        --network "$NETWORK" \
        --network-alias "$MISSKEY_APP_HOST" \
        -e NODE_EXTRA_CA_CERTS=/smoke-ca/smoke-ca.crt \
        -v "$CA_CERT:/smoke-ca/smoke-ca.crt:ro" \
        -v "$MISSKEY_CONFIG_DIR:$MISSKEY_RUNTIME_HOME/.config:ro" \
        -v "$MISSKEY_FILES_DIR:$MISSKEY_RUNTIME_HOME/files" \
        "$MISSKEY_IMAGE" >/dev/null
}

start_misskey_proxy() {
    docker run -d \
        --name "$MISSKEY_PROXY_CONTAINER" \
        --hostname "$MISSKEY_PROXY_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$MISSKEY_HOST" \
        -p "127.0.0.1:$MISSKEY_PORT:443" \
        -v "$MISSKEY_NGINX_CONF:/etc/nginx/conf.d/default.conf:ro" \
        -v "$CA_DIR:/etc/nginx/smoke-certs:ro" \
        "$NGINX_IMAGE" >/dev/null
}

wait_misskey() {
    for _ in $(seq 1 240); do
        if http_json POST "$MISSKEY_BASE/api/meta" "" 200 '{}' >/dev/null 2>&1; then
            return 0
        fi

        sleep 1
    done

    docker logs "$MISSKEY_CONTAINER" >&2 || true
    fail "Timed out waiting for $MISSKEY_LABEL at $MISSKEY_BASE"
}

create_misskey_admin_token() {
    local account

    account="$(misskey_api admin/accounts/create "" 200 "$(json_payload username="$MISSKEY_USERNAME" password="$PASSWORD")")"
    json_get "$account" token
}

resolve_account_id() {
    local base="$1"
    local token="$2"
    local acct="$3"
    local message="$4"
    local result id

    for _ in $(seq 1 90); do
        result="$(http_form GET "$base/api/v2/search?q=$(urlencode "$acct")&resolve=true&type=accounts&limit=5" "$token" 200 || true)"
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
    local result id

    for _ in $(seq 1 90); do
        result="$(http_form GET "$base/api/v2/search?q=$(urlencode "$uri")&resolve=true&type=statuses&limit=5" "$token" 200 || true)"
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

resolve_misskey_user_id() {
    local token="$1"
    local username="$2"
    local host="$3"
    local message="$4"
    local result id payload

    payload="$(json_payload username="$username" host="$host")"

    for _ in $(seq 1 90); do
        result="$(misskey_api users/show "$token" 200 "$payload" || true)"
        id="$(json_get_optional "$result" id)"

        if [ -n "$id" ]; then
            printf '%s\n' "$id"
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

resolve_misskey_note_id() {
    local token="$1"
    local uri="$2"
    local message="$3"
    local result id payload

    payload="$(json_payload uri="$uri")"

    for _ in $(seq 1 90); do
        result="$(misskey_api ap/show "$token" 200 "$payload" || true)"
        id="$(json_get_optional "$result" object.id)"

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

poll_be_account_note_contains() {
    local account_id="$1"
    local text="$2"
    local message="$3"

    poll_json_assert \
        "http_form GET '$BE_BASE/api/v1/accounts/$account_id' '$ALICE_TOKEN' 200" \
        "'$text' in (data.get('note') or '')" \
        "$message" >/dev/null
}

poll_be_has_emoji_reaction() {
    local status_id="$1"
    local reaction="$2"
    local message="$3"
    local result=""

    for _ in $(seq 1 90); do
        result="$(http_form GET "$BE_BASE/api/v1/statuses/$status_id" "$ALICE_TOKEN" 200 || true)"

        if [ -n "$result" ] && JSON_INPUT="$result" EXPECTED_REACTION="$reaction" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
reaction = os.environ["EXPECTED_REACTION"]
reactions = data.get("reactions") or data.get("pleroma", {}).get("emoji_reactions") or []
for item in reactions:
    if item.get("name") == reaction and int(item.get("count") or 0) >= 1:
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

poll_be_no_emoji_reaction() {
    local status_id="$1"
    local reaction="$2"
    local message="$3"
    local result=""

    for _ in $(seq 1 90); do
        result="$(http_form GET "$BE_BASE/api/v1/statuses/$status_id" "$ALICE_TOKEN" 200 || true)"

        if [ -n "$result" ] && JSON_INPUT="$result" EXPECTED_REACTION="$reaction" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
reaction = os.environ["EXPECTED_REACTION"]
reactions = data.get("reactions") or data.get("pleroma", {}).get("emoji_reactions") or []
for item in reactions:
    if item.get("name") == reaction and int(item.get("count") or 0) > 0:
        raise SystemExit(1)
raise SystemExit(0)
PY
        then
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

poll_be_status_quote() {
    local status_id="$1"
    local quoted_status_id="$2"
    local quoted_uri="$3"
    local message="$4"
    local result=""

    for _ in $(seq 1 90); do
        result="$(http_form GET "$BE_BASE/api/v1/statuses/$status_id" "$ALICE_TOKEN" 200 || true)"

        if [ -n "$result" ] && JSON_INPUT="$result" QUOTED_STATUS_ID="$quoted_status_id" QUOTED_URI="$quoted_uri" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
expected_id = os.environ["QUOTED_STATUS_ID"]
expected_uri = os.environ["QUOTED_URI"]
pleroma = data.get("pleroma") or {}
quote = data.get("quote") or pleroma.get("quote") or {}
quote_url = data.get("quote_url") or pleroma.get("quote_url") or ""
if isinstance(quote, dict) and (quote.get("id") == expected_id or quote.get("uri") == expected_uri):
    raise SystemExit(0)
if quote_url == expected_uri:
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

poll_misskey_note_replies_by_text() {
    local note_id="$1"
    local text="$2"
    local message="$3"
    local payload result

    payload="$(json_payload noteId="$note_id" limit=int:30)"

    for _ in $(seq 1 90); do
        result="$(misskey_api notes/replies "$MISSKEY_TOKEN" 200 "$payload" || true)"

        if [ -n "$result" ] && JSON_INPUT="$result" EXPECTED_TEXT="$text" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
text = os.environ["EXPECTED_TEXT"]
for note in data:
    if text in (note.get("text") or ""):
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

poll_misskey_reaction_count() {
    local note_id="$1"
    local expr="$2"
    local message="$3"
    local payload

    payload="$(json_payload noteId="$note_id")"
    poll_json_assert \
        "misskey_api notes/show '$MISSKEY_TOKEN' 200 '$payload'" \
        "$expr" \
        "$message" >/dev/null
}

poll_misskey_poll_votes() {
    local note_id="$1"
    local choice="$2"
    local message="$3"
    local payload result

    payload="$(json_payload noteId="$note_id")"

    for _ in $(seq 1 90); do
        result="$(misskey_api notes/show "$MISSKEY_TOKEN" 200 "$payload" 2>/dev/null || true)"
        if [ -n "$result" ] && JSON_INPUT="$result" CHOICE="$choice" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
choice = int(os.environ["CHOICE"])
choices = (data.get("poll") or {}).get("choices") or []
if choice >= len(choices) or int(choices[choice].get("votes") or 0) < 1:
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

poll_misskey_note_missing() {
    local note_id="$1"
    local message="$2"
    local payload response status

    payload="$(payload_with_token "$MISSKEY_TOKEN" "$(json_payload noteId="$note_id")")"

    for _ in $(seq 1 60); do
        response="$(curl -k -sS -X POST -w '\n%{http_code}' \
            -H 'Accept: application/json' \
            -H 'Content-Type: application/json' \
            --data "$payload" \
            "$MISSKEY_BASE/api/notes/show" || true)"
        status="${response##*$'\n'}"

        if [ "$status" != "200" ]; then
            return 0
        fi

        sleep 2
    done

    fail "$message"
}

poll_status_missing() {
    local base="$1"
    local token="$2"
    local status_id="$3"
    local message="$4"
    local status

    for _ in $(seq 1 60); do
        status="$(curl -k -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" -H 'Accept: application/json' "$base/api/v1/statuses/$status_id" || true)"

        if [ "$status" = "404" ] || [ "$status" = "410" ]; then
            return 0
        fi

        sleep 2
    done

    fail "$message"
}

check_logs() {
    local name="$1"
    local label="$2"

    if docker logs "$name" 2>&1 | grep -Ei 'panic:|fatal|segmentation fault|FunctionClauseError|MatchError|ArgumentError' >/dev/null; then
        docker logs "$name" >&2 || true
        fail "$label emitted a crash-class log line"
    fi
}

write_tls_material
write_be_secret
write_misskey_config
write_proxy_configs

log "Creating Docker network"
docker rm -f \
    "$MISSKEY_PROXY_CONTAINER" \
    "$MISSKEY_CONTAINER" \
    "$MISSKEY_REDIS_CONTAINER" \
    "$MISSKEY_DB_CONTAINER" \
    "$BE_PROXY_CONTAINER" \
    "$BE_CONTAINER" \
    "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
docker network rm "$NETWORK" >/dev/null 2>&1 || true
docker network create "$NETWORK" >/dev/null

log "Starting databases and Redis"
docker run -d \
    --name "$BE_DB_CONTAINER" \
    --network "$NETWORK" \
    -e POSTGRES_PASSWORD="$BE_DB_PASSWORD" \
    "$POSTGRES_IMAGE" >/dev/null

docker run -d \
    --name "$MISSKEY_DB_CONTAINER" \
    --network "$NETWORK" \
    -e POSTGRES_DB="$MISSKEY_DB_NAME" \
    -e POSTGRES_USER="$MISSKEY_DB_USER" \
    -e POSTGRES_PASSWORD="$MISSKEY_DB_PASSWORD" \
    "$POSTGRES_IMAGE" >/dev/null

docker run -d \
    --name "$MISSKEY_REDIS_CONTAINER" \
    --network "$NETWORK" \
    "$REDIS_IMAGE" >/dev/null

wait_postgres_container "$BE_DB_CONTAINER" postgres postgres
wait_postgres_container "$MISSKEY_DB_CONTAINER" "$MISSKEY_DB_USER" "$MISSKEY_DB_NAME"
prepare_database

log "Initializing and starting stock $MISSKEY_LABEL"
init_misskey
start_misskey
start_misskey_proxy
wait_misskey

log "Creating $MISSKEY_LABEL test account and profile"
MISSKEY_TOKEN="$(create_misskey_admin_token)"
misskey_api admin/update-meta "$MISSKEY_TOKEN" 204 "$(json_payload \
    federation=all \
    federationHosts=json:[] \
    disableRegistration=bool:true)" >/dev/null
MISSKEY_SUMMARY="$MISSKEY_LABEL smoke summary $(basename "$WORK_DIR")"
misskey_api i/update "$MISSKEY_TOKEN" 200 "$(json_payload \
    description="$MISSKEY_SUMMARY" \
    isLocked=bool:false \
    isExplorable=bool:true \
    publicReactions=bool:true)" >/dev/null

log "Migrating and starting Unfathomably"
docker_run_mix "${PREFIX}-migrate-be" "mix ecto.migrate"
create_be_user alice "alice@$BE_HOST"
start_be
start_be_proxy
wait_be

log "Creating Unfathomably API credentials"
ALICE_TOKEN="$(create_be_token alice)"
http_form GET "$BE_BASE/api/v1/accounts/verify_credentials" "$ALICE_TOKEN" 200 >/dev/null

log "Following accounts in both directions"
MISSKEY_ACCOUNT_ID="$(resolve_account_id "$BE_BASE" "$ALICE_TOKEN" "$MISSKEY_USERNAME@$MISSKEY_HOST" "Unfathomably could not resolve $MISSKEY_LABEL account")"
poll_be_account_note_contains "$MISSKEY_ACCOUNT_ID" "$MISSKEY_SUMMARY" "Unfathomably did not preserve $MISSKEY_LABEL profile summary"
BE_USER_ID="$(resolve_misskey_user_id "$MISSKEY_TOKEN" alice "$BE_HOST" "$MISSKEY_LABEL could not resolve Unfathomably account")"

BE_FOLLOW_MISSKEY="$(http_form POST "$BE_BASE/api/v1/accounts/$MISSKEY_ACCOUNT_ID/follow" "$ALICE_TOKEN" 200)"
json_assert "$BE_FOLLOW_MISSKEY" 'data.get("following") is True or data.get("requested") is True' "Unfathomably could not follow $MISSKEY_LABEL account"
misskey_api following/create "$MISSKEY_TOKEN" 200 "$(json_payload userId="$BE_USER_ID")" >/dev/null
poll_relationship_following "$BE_BASE" "$ALICE_TOKEN" "$MISSKEY_ACCOUNT_ID" "Unfathomably follow of $MISSKEY_LABEL did not become accepted"

log "Testing Unfathomably post delivery into $MISSKEY_LABEL"
BE_TO_MISSKEY_TEXT="Unfathomably to $MISSKEY_LABEL smoke $(basename "$WORK_DIR")"
BE_TO_MISSKEY_POST="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
    "status=$BE_TO_MISSKEY_TEXT" \
    "visibility=public")"
BE_TO_MISSKEY_ID="$(json_get "$BE_TO_MISSKEY_POST" id)"
BE_TO_MISSKEY_URI="$(json_get "$BE_TO_MISSKEY_POST" uri)"
MISSKEY_VIEW_OF_BE_ID="$(resolve_misskey_note_id "$MISSKEY_TOKEN" "$BE_TO_MISSKEY_URI" "$MISSKEY_LABEL could not resolve Unfathomably post")"

misskey_api notes/reactions/create "$MISSKEY_TOKEN" 204 "$(json_payload noteId="$MISSKEY_VIEW_OF_BE_ID" reaction="$MISSKEY_REACTION")" >/dev/null
poll_be_has_emoji_reaction "$BE_TO_MISSKEY_ID" "$MISSKEY_REACTION" "Unfathomably did not receive $MISSKEY_LABEL _misskey_reaction emoji reaction"
misskey_api notes/reactions/delete "$MISSKEY_TOKEN" 204 "$(json_payload noteId="$MISSKEY_VIEW_OF_BE_ID")" >/dev/null
poll_be_no_emoji_reaction "$BE_TO_MISSKEY_ID" "$MISSKEY_REACTION" "Unfathomably did not receive $MISSKEY_LABEL emoji unreaction"

MISSKEY_REPLY_TEXT="$MISSKEY_LABEL reply to Unfathomably $(basename "$WORK_DIR")"
MISSKEY_REPLY="$(misskey_api notes/create "$MISSKEY_TOKEN" 200 "$(json_payload \
    text="$MISSKEY_REPLY_TEXT @alice@$BE_HOST" \
    visibility=public \
    replyId="$MISSKEY_VIEW_OF_BE_ID")")"
MISSKEY_REPLY_ID="$(json_get "$MISSKEY_REPLY" createdNote.id)"
poll_context_status_by_text "$BE_BASE" "$ALICE_TOKEN" "$BE_TO_MISSKEY_ID" "$MISSKEY_REPLY_TEXT" "Unfathomably did not receive $MISSKEY_LABEL reply"
misskey_api notes/delete "$MISSKEY_TOKEN" 204 "$(json_payload noteId="$MISSKEY_REPLY_ID")" >/dev/null

log "Testing $MISSKEY_LABEL quote delivery into Unfathomably"
MISSKEY_QUOTE_TEXT="$MISSKEY_LABEL quote of Unfathomably $(basename "$WORK_DIR")"
MISSKEY_QUOTE="$(misskey_api notes/create "$MISSKEY_TOKEN" 200 "$(json_payload \
    text="$MISSKEY_QUOTE_TEXT @alice@$BE_HOST" \
    visibility=public \
    renoteId="$MISSKEY_VIEW_OF_BE_ID")")"
MISSKEY_QUOTE_ID="$(json_get "$MISSKEY_QUOTE" createdNote.id)"
BE_VIEW_OF_MISSKEY_QUOTE_ID="$(poll_home_status_by_text "$BE_BASE" "$ALICE_TOKEN" "$MISSKEY_QUOTE_TEXT" "Unfathomably did not receive $MISSKEY_LABEL quote note")"
poll_be_status_quote "$BE_VIEW_OF_MISSKEY_QUOTE_ID" "$BE_TO_MISSKEY_ID" "$BE_TO_MISSKEY_URI" "Unfathomably did not expose $MISSKEY_LABEL _misskey_quote or quoteUrl as a quote"
poll_status_count "$BE_BASE" "$ALICE_TOKEN" "$BE_TO_MISSKEY_ID" 'int(data.get("quotes_count") or 0) >= 1' "Unfathomably did not count the $MISSKEY_LABEL quote"

log "Testing federated polls with $MISSKEY_LABEL in both directions"
MISSKEY_POLL_TEXT="$MISSKEY_LABEL poll to Unfathomably $(basename "$WORK_DIR")"
MISSKEY_POLL="$(misskey_api notes/create "$MISSKEY_TOKEN" 200 "$(json_payload \
    text="$MISSKEY_POLL_TEXT @alice@$BE_HOST" \
    visibility=public \
    poll='json:{"choices":["Misskey option one","Misskey option two"],"multiple":false,"expiredAfter":600000}')")"
MISSKEY_POLL_NOTE_ID="$(json_get "$MISSKEY_POLL" createdNote.id)"
BE_VIEW_OF_MISSKEY_POLL_ID="$(
    poll_home_status_by_text \
        "$BE_BASE" \
        "$ALICE_TOKEN" \
        "$MISSKEY_POLL_TEXT" \
        "Unfathomably did not receive $MISSKEY_LABEL poll"
)"
BE_VIEW_OF_MISSKEY_POLL="$(http_form GET "$BE_BASE/api/v1/statuses/$BE_VIEW_OF_MISSKEY_POLL_ID" "$ALICE_TOKEN" 200)"
BE_MISSKEY_POLL_ID="$(json_get "$BE_VIEW_OF_MISSKEY_POLL" poll.id)"
BE_MISSKEY_POLL_VOTE="$(
    http_form POST "$BE_BASE/api/v1/polls/$BE_MISSKEY_POLL_ID/votes" "$ALICE_TOKEN" 200 \
        "choices[]=0"
)"
json_assert "$BE_MISSKEY_POLL_VOTE" 'data.get("voted") is True and data.get("own_votes") == [0]' \
    "Unfathomably could not vote in $MISSKEY_LABEL poll"
poll_misskey_poll_votes "$MISSKEY_POLL_NOTE_ID" 0 \
    "$MISSKEY_LABEL did not receive Unfathomably poll vote"

BE_POLL_TEXT="Unfathomably poll to $MISSKEY_LABEL $(basename "$WORK_DIR")"
BE_POLL="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
    "status=$BE_POLL_TEXT" \
    "visibility=public" \
    "poll[options][]=Unfathomably option one" \
    "poll[options][]=Unfathomably option two" \
    "poll[expires_in]=600")"
BE_POLL_STATUS_ID="$(json_get "$BE_POLL" id)"
BE_POLL_ID="$(json_get "$BE_POLL" poll.id)"
BE_POLL_URI="$(json_get "$BE_POLL" uri)"
MISSKEY_VIEW_OF_BE_POLL_ID="$(
    resolve_misskey_note_id \
        "$MISSKEY_TOKEN" \
        "$BE_POLL_URI" \
        "$MISSKEY_LABEL could not resolve Unfathomably poll"
)"
MISSKEY_BE_POLL_VOTE="$(misskey_api notes/polls/vote "$MISSKEY_TOKEN" 204 "$(json_payload \
    noteId="$MISSKEY_VIEW_OF_BE_POLL_ID" \
    choice=int:1)")"
poll_json_assert \
    "http_form GET '$BE_BASE/api/v1/polls/$BE_POLL_ID' '$ALICE_TOKEN' 200" \
    'int(data.get("votes_count") or 0) >= 1 and int(data["options"][1].get("votes_count") or 0) >= 1' \
    "Unfathomably did not receive $MISSKEY_LABEL poll vote" >/dev/null

log "Testing $MISSKEY_LABEL post delivery into Unfathomably"
MISSKEY_TO_BE_TEXT="$MISSKEY_LABEL to Unfathomably smoke $(basename "$WORK_DIR")"
MISSKEY_TO_BE="$(misskey_api notes/create "$MISSKEY_TOKEN" 200 "$(json_payload \
    text="$MISSKEY_TO_BE_TEXT @alice@$BE_HOST" \
    visibility=public)")"
MISSKEY_TO_BE_ID="$(json_get "$MISSKEY_TO_BE" createdNote.id)"
BE_VIEW_OF_MISSKEY_ID="$(poll_home_status_by_text "$BE_BASE" "$ALICE_TOKEN" "$MISSKEY_TO_BE_TEXT" "Unfathomably did not receive $MISSKEY_LABEL post")"

BE_LIKE_MISSKEY="$(http_form POST "$BE_BASE/api/v1/statuses/$BE_VIEW_OF_MISSKEY_ID/favourite" "$ALICE_TOKEN" 200)"
json_assert "$BE_LIKE_MISSKEY" 'data.get("favourited") is True' "Unfathomably could not favourite $MISSKEY_LABEL post"
poll_misskey_reaction_count "$MISSKEY_TO_BE_ID" 'sum((data.get("reactions") or {}).values()) >= 1' "$MISSKEY_LABEL did not receive Unfathomably favourite"
BE_UNLIKE_MISSKEY="$(http_form POST "$BE_BASE/api/v1/statuses/$BE_VIEW_OF_MISSKEY_ID/unfavourite" "$ALICE_TOKEN" 200)"
json_assert "$BE_UNLIKE_MISSKEY" 'data.get("favourited") is False' "Unfathomably could not unfavourite $MISSKEY_LABEL post"
poll_misskey_reaction_count "$MISSKEY_TO_BE_ID" 'sum((data.get("reactions") or {}).values()) == 0' "$MISSKEY_LABEL did not receive Unfathomably unfavourite"

BE_REACTION_ENCODED="$(urlencode "$MISSKEY_REACTION")"
http_form PUT "$BE_BASE/api/v1/pleroma/statuses/$BE_VIEW_OF_MISSKEY_ID/reactions/$BE_REACTION_ENCODED" "$ALICE_TOKEN" 200 >/dev/null
poll_misskey_reaction_count "$MISSKEY_TO_BE_ID" 'sum((data.get("reactions") or {}).values()) >= 1' "$MISSKEY_LABEL did not receive Unfathomably emoji reaction"
http_form DELETE "$BE_BASE/api/v1/pleroma/statuses/$BE_VIEW_OF_MISSKEY_ID/reactions/$BE_REACTION_ENCODED" "$ALICE_TOKEN" 200 >/dev/null
poll_misskey_reaction_count "$MISSKEY_TO_BE_ID" 'sum((data.get("reactions") or {}).values()) == 0' "$MISSKEY_LABEL did not receive Unfathomably emoji unreaction"

BE_REPLY_TEXT="Unfathomably reply to $MISSKEY_LABEL $(basename "$WORK_DIR")"
BE_REPLY="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
    "status=$BE_REPLY_TEXT" \
    "in_reply_to_id=$BE_VIEW_OF_MISSKEY_ID")"
BE_REPLY_ID="$(json_get "$BE_REPLY" id)"
poll_misskey_note_replies_by_text "$MISSKEY_TO_BE_ID" "$BE_REPLY_TEXT" "$MISSKEY_LABEL did not receive Unfathomably reply"
http_form DELETE "$BE_BASE/api/v1/statuses/$BE_REPLY_ID" "$ALICE_TOKEN" 200 >/dev/null

log "Testing top-level deletes"
misskey_api notes/delete "$MISSKEY_TOKEN" 204 "$(json_payload noteId="$MISSKEY_QUOTE_ID")" >/dev/null
misskey_api notes/delete "$MISSKEY_TOKEN" 204 "$(json_payload noteId="$MISSKEY_POLL_NOTE_ID")" >/dev/null
http_form DELETE "$BE_BASE/api/v1/statuses/$BE_POLL_STATUS_ID" "$ALICE_TOKEN" 200 >/dev/null
http_form DELETE "$BE_BASE/api/v1/statuses/$BE_TO_MISSKEY_ID" "$ALICE_TOKEN" 200 >/dev/null
poll_misskey_note_missing "$MISSKEY_VIEW_OF_BE_ID" "$MISSKEY_LABEL did not lose deleted Unfathomably status"
misskey_api notes/delete "$MISSKEY_TOKEN" 204 "$(json_payload noteId="$MISSKEY_TO_BE_ID")" >/dev/null
poll_status_missing "$BE_BASE" "$ALICE_TOKEN" "$BE_VIEW_OF_MISSKEY_ID" "Unfathomably did not lose deleted $MISSKEY_LABEL status"

log "Unfollowing accounts"
http_form POST "$BE_BASE/api/v1/accounts/$MISSKEY_ACCOUNT_ID/unfollow" "$ALICE_TOKEN" 200 >/dev/null
misskey_api following/delete "$MISSKEY_TOKEN" 200 "$(json_payload userId="$BE_USER_ID")" >/dev/null || true

check_logs "$BE_CONTAINER" "Unfathomably"
check_logs "$MISSKEY_CONTAINER" "$MISSKEY_LABEL"

cat <<EOF

$MISSKEY_LABEL federation smoke passed.

Covered against stock $MISSKEY_LABEL:
* supported: API token creation on Unfathomably and $MISSKEY_LABEL
* supported: account discovery and follow in both directions
* supported: $MISSKEY_LABEL profile summary import through _misskey_summary-compatible profile data
* supported: Unfathomably-to-$MISSKEY_LABEL status delivery
* supported: $MISSKEY_LABEL-to-Unfathomably status delivery
* supported: replies in both directions
* supported: favourites and unfavourites in both directions
* supported: emoji reactions and unreactions in both directions
* supported: $MISSKEY_LABEL quote notes exposed through Unfathomably quote fields
* supported: federated polls and votes in both directions
* supported: top-level deletes in both directions
* supported: account unfollow cleanup in both directions
* not_supported: Group actors are not part of stock $MISSKEY_LABEL account/note federation
* not_supported: $MISSKEY_LABEL cannot report that a remote server defederated it
EOF

# end of build_scripts/unfathomably-misskey-smoke.sh
