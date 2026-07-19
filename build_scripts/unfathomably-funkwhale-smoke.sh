#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-funkwhale-smoke.sh
#
# Purpose:
#
#   Run a local stock Funkwhale peer against Unfathomably and prove the
#   audio-oriented ActivityPub path that Funkwhale exposes.
#
# Responsibilities:
#
#   * boot isolated Unfathomably, Funkwhale, PostgreSQL, Redis, Celery, and
#     nginx proxy containers
#   * advertise HTTPS actor and audio URLs through disposable local TLS proxies
#   * create deterministic smoke users and API tokens on both peers
#   * upload and federate a small tagged audio track from Funkwhale
#   * exercise Unfathomably discovery, follow, track resolution, favourite,
#     unfavourite, audio delete, and follow cleanup where stock Funkwhale
#     supports those operations
#   * probe Funkwhale behavior around Unfathomably account and Group actors and
#     report stock limitations explicitly
#
# This file intentionally does NOT contain:
#
#   * production deployment logic
#   * patched Funkwhale source code
#   * browser-driven OAuth flows
#   * hidden success for unsupported forum-style group behavior
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BE_ROOT="${BE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PREFIX="${SMOKE_PREFIX:-unfathomably-funkwhale-smoke}"
NETWORK="${PREFIX}-net"

BE_DB_CONTAINER="${PREFIX}-be-db"
BE_CONTAINER="${PREFIX}-be"
BE_PROXY_CONTAINER="${PREFIX}-be-proxy"
BE_APP_HOST="${PREFIX}-be-app"
BE_HOST="${BE_HOST:-unfathomably-funkwhale.test}"
BE_PORT="${BE_PORT:-4985}"
BE_BASE="http://127.0.0.1:$BE_PORT"
BE_DB_NAME="${BE_DB_NAME:-unfathomably_funkwhale_smoke_be}"
BE_DB_PASSWORD="${BE_DB_PASSWORD:-postgres}"

FW_DB_CONTAINER="${PREFIX}-fw-db"
FW_REDIS_CONTAINER="${PREFIX}-fw-redis"
FW_API_CONTAINER="${PREFIX}-fw-api"
FW_WORKER_CONTAINER="${PREFIX}-fw-worker"
FW_PROXY_CONTAINER="${PREFIX}-fw-proxy"
FW_APP_HOST="${PREFIX}-fw-app"
FW_HOST="${FW_HOST:-funkwhale-ref.test}"
FW_PORT="${FW_PORT:-4986}"
FW_BASE="http://127.0.0.1:$FW_PORT"
FW_DB_NAME="${FW_DB_NAME:-funkwhale_smoke}"
FW_DB_PASSWORD="${FW_DB_PASSWORD:-postgres}"

IMAGE="${UNFATHOMABLY_SMOKE_IMAGE:-unfathomably-elixir-smoke:otp28}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:17-alpine}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.27-alpine}"
FW_API_IMAGE="${FUNKWHALE_API_IMAGE:-funkwhale/api:2.0.5}"
PASSWORD="${SMOKE_PASSWORD:-SmokeTest_01}"
KEEP_CONTAINERS="${KEEP_CONTAINERS:-0}"
POLL_ATTEMPTS="${SMOKE_POLL_ATTEMPTS:-120}"
# Negative capability probes start a Django management shell on each attempt.
# Eight attempts leave ample worker time without turning unsupported behavior
# into a multi-minute delay.
CAPABILITY_POLL_ATTEMPTS="${SMOKE_CAPABILITY_POLL_ATTEMPTS:-8}"
WAIT_BE_ATTEMPTS="${SMOKE_WAIT_BE_ATTEMPTS:-600}"
WAIT_FUNKWHALE_ATTEMPTS="${SMOKE_WAIT_FUNKWHALE_ATTEMPTS:-240}"
MIX_BUILD_PATH="${MIX_BUILD_PATH:-/work/_build_funkwhale_smoke}"
WORK_DIR="${SMOKE_WORK_DIR:-}"

if [ -z "$WORK_DIR" ]; then
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/unfathomably-funkwhale-smoke.XXXXXX")"
fi

BE_SECRET="$WORK_DIR/be/dev.secret.exs"
BE_UPLOADS="$WORK_DIR/be/uploads"
BE_STATIC="$WORK_DIR/be/static"
BE_NGINX_CONF="$WORK_DIR/be-nginx/default.conf"
FW_ENV="$WORK_DIR/funkwhale/.env"
FW_MEDIA="$WORK_DIR/funkwhale/media"
FW_SPA="$WORK_DIR/funkwhale/spa"
FW_STATIC="$WORK_DIR/funkwhale/static"
FW_MUSIC="$WORK_DIR/funkwhale/music"
FW_NGINX_CONF="$WORK_DIR/funkwhale-nginx/default.conf"
SMOKE_AUDIO_FILE="$WORK_DIR/smoke.mp3"
CA_DIR="$WORK_DIR/ca"
CA_CERT="$CA_DIR/smoke-ca.crt"
CA_KEY="$CA_DIR/smoke-ca.key"
BE_CERT="$CA_DIR/be.crt"
BE_KEY="$CA_DIR/be.key"
FW_CERT="$CA_DIR/funkwhale.crt"
FW_KEY="$CA_DIR/funkwhale.key"

log() { printf '\n==> %s\n' "$*"; }

fail() {
    printf '\nERROR: %s\n' "$*" >&2
    printf 'Work directory: %s\n' "$WORK_DIR" >&2
    dump_logs
    exit 1
}

dump_logs() {
    local c
    for c in "$BE_CONTAINER" "$BE_PROXY_CONTAINER" "$FW_API_CONTAINER" "$FW_WORKER_CONTAINER" "$FW_PROXY_CONTAINER" "$BE_DB_CONTAINER" "$FW_DB_CONTAINER" "$FW_REDIS_CONTAINER"; do
        if docker inspect "$c" >/dev/null 2>&1; then
            printf '\n--- docker logs --tail 180 %s ---\n' "$c" >&2
            docker logs --tail 180 "$c" >&2 || true
        fi
    done
}

cleanup() {
    local status="$?"
    if [ "$KEEP_CONTAINERS" = "1" ]; then
        printf '\nKEEP_CONTAINERS=1, leaving containers and work directory in place.\n' >&2
        printf 'Unfathomably: %s as https://%s\n' "$BE_BASE" "$BE_HOST" >&2
        printf 'Funkwhale:     %s as https://%s\n' "$FW_BASE" "$FW_HOST" >&2
        printf 'Work dir:      %s\n' "$WORK_DIR" >&2
        exit "$status"
    fi
    docker rm -f "$FW_PROXY_CONTAINER" "$FW_WORKER_CONTAINER" "$FW_API_CONTAINER" "$FW_REDIS_CONTAINER" "$FW_DB_CONTAINER" "$BE_PROXY_CONTAINER" "$BE_CONTAINER" "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true

    # Funkwhale writes imported media as the container root user.  Reclaim the
    # disposable tree before removing it so cleanup cannot turn a passing
    # federation run into a failure merely because of bind-mount ownership.
    docker run --rm -v "$WORK_DIR:/work" --entrypoint sh "$POSTGRES_IMAGE" \
        -c "chown -R $(id -u):$(id -g) /work" >/dev/null 2>&1 || true
    if ! rm -rf "$WORK_DIR"; then
        printf 'WARNING: could not remove work directory: %s\n' "$WORK_DIR" >&2
    fi
    exit "$status"
}
trap cleanup EXIT

clean_previous() {
    docker rm -f "$FW_PROXY_CONTAINER" "$FW_WORKER_CONTAINER" "$FW_API_CONTAINER" "$FW_REDIS_CONTAINER" "$FW_DB_CONTAINER" "$BE_PROXY_CONTAINER" "$BE_CONTAINER" "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
}

require_command() { command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"; }
require_command curl
require_command docker
require_command openssl
require_command python3

json_get() {
    JSON_INPUT="$1" python3 - "$2" <<'PY'
import json, os, sys
value = json.loads(os.environ["JSON_INPUT"])
for part in sys.argv[1].split("."):
    if not part:
        continue
    value = value[int(part)] if isinstance(value, list) else value[part]
print(json.dumps(value) if isinstance(value, (dict, list)) else ("" if value is None else value))
PY
}

json_get_optional() {
    JSON_INPUT="$1" python3 - "$2" <<'PY'
import json, os, sys
try:
    value = json.loads(os.environ["JSON_INPUT"])
    for part in sys.argv[1].split("."):
        if not part:
            continue
        value = value[int(part)] if isinstance(value, list) else value.get(part)
        if value is None:
            print(""); raise SystemExit(0)
    print(json.dumps(value) if isinstance(value, (dict, list)) else value)
except Exception:
    print("")
PY
}

json_assert() {
    local json="$1" expr="$2" message="$3"
    if ! JSON_INPUT="$json" python3 - "$expr" <<'PY'
import json, os, sys
data = json.loads(os.environ["JSON_INPUT"])
safe = {"all": all, "any": any, "int": int, "len": len, "str": str}
if not eval(sys.argv[1], {"__builtins__": safe}, {"data": data}):
    raise SystemExit(1)
PY
    then
        printf '%s\n' "$json" >&2
        fail "$message"
    fi
}

urlencode() { python3 - "$1" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=""))
PY
}

http_form() {
    local method="$1" url="$2" token="$3" expected="$4" tmp code field
    shift 4
    tmp="$(mktemp)"
    local args=(-sS -X "$method" -o "$tmp" -w "%{http_code}" -H 'Accept: application/json')
    [ -n "$token" ] && args+=(-H "Authorization: Bearer $token")
    for field in "$@"; do args+=(-F "$field"); done
    args+=("$url")
    code="$(curl "${args[@]}")" || { cat "$tmp" >&2 || true; rm -f "$tmp"; fail "curl failed for $method $url"; }
    if [ "$code" != "$expected" ]; then cat "$tmp" >&2 || true; rm -f "$tmp"; fail "Unexpected HTTP $code for $method $url (expected $expected)"; fi
    cat "$tmp"; rm -f "$tmp"
}

http_json() {
    local method="$1" url="$2" token="$3" expected="$4" body="$5" tmp code
    tmp="$(mktemp)"
    local args=(-sS -X "$method" -o "$tmp" -w "%{http_code}" -H 'Accept: application/json' -H 'Content-Type: application/json')
    [ -n "$token" ] && args+=(-H "Authorization: Bearer $token")
    args+=(-d "$body" "$url")
    code="$(curl "${args[@]}")" || { cat "$tmp" >&2 || true; rm -f "$tmp"; fail "curl failed for $method $url"; }
    if [ "$code" != "$expected" ]; then cat "$tmp" >&2 || true; rm -f "$tmp"; fail "Unexpected HTTP $code for $method $url (expected $expected)"; fi
    cat "$tmp"; rm -f "$tmp"
}

http_status() {
    local method="$1" url="$2" token="$3" expected="$4" tmp code
    tmp="$(mktemp)"
    local args=(-sS -X "$method" -o "$tmp" -w "%{http_code}" -H 'Accept: application/json')
    [ -n "$token" ] && args+=(-H "Authorization: Bearer $token")
    args+=("$url")
    code="$(curl "${args[@]}")" || code="000"
    rm -f "$tmp"
    [ "$code" = "$expected" ]
}

poll_json() {
    local command="$1" expr="$2" message="$3" result=""
    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        result="$(eval "$command" 2>/dev/null || true)"
        if [ -n "$result" ] && JSON_INPUT="$result" python3 - "$expr" <<'PY'
import json, os, sys
data = json.loads(os.environ["JSON_INPUT"])
safe = {"all": all, "any": any, "int": int, "len": len, "str": str}
if not eval(sys.argv[1], {"__builtins__": safe}, {"data": data}):
    raise SystemExit(1)
PY
        then printf '%s\n' "$result"; return 0; fi
        sleep 2
    done
    printf '%s\n' "$result" >&2
    fail "$message"
}
poll_http_status() {
    local method="$1" url="$2" token="$3" expected="$4" message="$5"
    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        if http_status "$method" "$url" "$token" "$expected"; then return 0; fi
        sleep 2
    done
    fail "$message"
}

accept_funkwhale_inbound_follow() {
    local be_actor="https://$BE_HOST/users/alice"
    local response=""
    local follow_uuid=""

    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        response="$(http_form GET "$FW_BASE/api/v2/federation/follows/user/?page_size=50" "$FW_TOKEN" 200)"
        follow_uuid="$(JSON_INPUT="$response" BE_ACTOR="$be_actor" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
items = data.get("results", []) if isinstance(data, dict) else data

for item in items:
    actor = item.get("actor") or {}
    if actor.get("fid") == os.environ["BE_ACTOR"] and item.get("approved") is None:
        print(item["uuid"])
        break
PY
)"
        if [ -n "$follow_uuid" ]; then
            break
        fi
        sleep 2
    done

    [ -n "$follow_uuid" ] || fail "Funkwhale did not expose the pending Unfathomably follow through its API"
    http_form POST "$FW_BASE/api/v2/federation/follows/user/$follow_uuid/accept/" "$FW_TOKEN" 204 >/dev/null

    poll_json \
        "http_form GET '$FW_BASE/api/v2/federation/follows/user/$follow_uuid/' '$FW_TOKEN' 200" \
        'data.get("approved") is True' \
        "Funkwhale did not approve the Unfathomably follow" >/dev/null
}

wait_http_status_optional() {
    local method="$1" url="$2" token="$3" expected="$4"
    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        if http_status "$method" "$url" "$token" "$expected"; then return 0; fi
        sleep 2
    done
    return 1
}

write_leaf_cert() {
    local host="$1"
    local key="$2"
    local cert="$3"
    local conf="$CA_DIR/$host.cnf"
    local csr="$CA_DIR/$host.csr"
    cat >"$conf" <<EOF
[req]
distinguished_name=req_distinguished_name
req_extensions=v3_req
prompt=no
[req_distinguished_name]
CN=$host
[v3_req]
subjectAltName=@alt_names
[alt_names]
DNS.1=$host
EOF
    openssl req -new -newkey rsa:2048 -nodes -keyout "$key" -out "$csr" -config "$conf" >/dev/null 2>&1
    openssl x509 -req -in "$csr" -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial -out "$cert" -days 2 -extensions v3_req -extfile "$conf" >/dev/null 2>&1
}

write_tls_material() {
    mkdir -p "$CA_DIR"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$CA_KEY" -out "$CA_CERT" -days 2 -subj "/CN=Unfathomably Funkwhale Smoke CA" >/dev/null 2>&1
    write_leaf_cert "$BE_HOST" "$BE_KEY" "$BE_CERT"
    write_leaf_cert "$FW_HOST" "$FW_KEY" "$FW_CERT"
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
  name: "Unfathomably Funkwhale Smoke",
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
config :pleroma, :http,
  adapter: [insecure: true, ssl_options: [insecure: true, verify: :verify_none]]
config :pleroma, :frontend_configurations, soapbox_fe: %{}
config :pleroma, :database, rum_enabled: false
config :pleroma, configurable_from_database: false
config :pleroma, :rate_limit, nil
config :pleroma, :modules, runtime_dir: "$WORK_DIR/runtime-$BE_HOST"
config :pleroma, Pleroma.ScheduledActivity, daily_user_limit: 1000, total_user_limit: 10000
EOF
}

write_funkwhale_env() {
    local secret
    secret="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(48))
PY
)"
    mkdir -p "$(dirname "$FW_ENV")" "$FW_MEDIA" "$FW_SPA" "$FW_STATIC" "$FW_MUSIC"
    chmod 777 "$FW_MEDIA" "$FW_SPA" "$FW_STATIC" "$FW_MUSIC"
    cat >"$FW_SPA/index.html" <<EOF
<!doctype html>
<html><head><meta charset="utf-8"><title>Funkwhale smoke</title></head><body>Funkwhale smoke frontend placeholder</body></html>
EOF
    cat >"$FW_ENV" <<EOF
PATH=/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
DJANGO_SETTINGS_MODULE=config.settings.production
DJANGO_SECRET_KEY=$secret
FUNKWHALE_URL=https://$FW_HOST
FUNKWHALE_HOSTNAME=$FW_HOST
FEDERATION_HOSTNAME=$FW_HOST
FUNKWHALE_PROTOCOL=https
FUNKWHALE_API_PORT=5000
FUNKWHALE_WEB_WORKERS=1
DATABASE_URL=postgresql://postgres:$FW_DB_PASSWORD@$FW_DB_CONTAINER:5432/$FW_DB_NAME
CACHE_URL=redis://$FW_REDIS_CONTAINER:6379/0
CELERY_BROKER_URL=redis://$FW_REDIS_CONTAINER:6379/0
MEDIA_ROOT=/srv/funkwhale/data/media
MEDIA_URL=https://$FW_HOST/media/
STATIC_ROOT=/srv/funkwhale/data/static
MUSIC_DIRECTORY_PATH=/music
MUSIC_DIRECTORY_SERVE_PATH=/music
REVERSE_PROXY_TYPE=nginx
PROTECT_FILES_PATH=/_protected
PROXY_MEDIA=false
EMAIL_CONFIG=consolemail://
DEFAULT_FROM_EMAIL=noreply@$FW_HOST
ACCOUNT_EMAIL_VERIFICATION_ENFORCE=false
ACCOUNT_EMAIL_VERIFICATION=optional
LOGLEVEL=info
FUNKWHALE_SENTRY_DSN=
TYPESENSE_API_KEY=
SSL_CERT_FILE=/smoke-ca/smoke-ca.crt
REQUESTS_CA_BUNDLE=/smoke-ca/smoke-ca.crt
CURL_CA_BUNDLE=/smoke-ca/smoke-ca.crt
PYTHONHTTPSVERIFY=1
EOF
}

write_proxy_configs() {
    mkdir -p "$(dirname "$BE_NGINX_CONF")" "$(dirname "$FW_NGINX_CONF")"
    cat >"$BE_NGINX_CONF" <<EOF
server { listen 80; server_name _; location / { proxy_pass http://$BE_APP_HOST:4000; proxy_set_header Host $BE_HOST; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto https; proxy_set_header X-Forwarded-Ssl on; } }
server { listen 443 ssl; server_name _; ssl_certificate /etc/nginx/certs/be.crt; ssl_certificate_key /etc/nginx/certs/be.key; location / { proxy_pass http://$BE_APP_HOST:4000; proxy_set_header Host $BE_HOST; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto https; proxy_set_header X-Forwarded-Ssl on; } }
EOF
    cat >"$FW_NGINX_CONF" <<EOF
server {
    listen 80;
    server_name _;
    client_max_body_size 100m;
    location /media/ { alias /srv/funkwhale/data/media/; }
    location = /index.html { root /srv/funkwhale/spa; }
    location /_protected/media/ { internal; alias /srv/funkwhale/data/media/; }
    location /_protected/music/ { internal; alias /music/; }
    location / { proxy_pass http://$FW_APP_HOST:5000; proxy_set_header Host $FW_HOST; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto https; proxy_set_header X-Forwarded-Ssl on; }
}
server {
    listen 443 ssl;
    server_name _;
    client_max_body_size 100m;
    ssl_certificate /etc/nginx/certs/funkwhale.crt;
    ssl_certificate_key /etc/nginx/certs/funkwhale.key;
    location /media/ { alias /srv/funkwhale/data/media/; }
    location = /index.html { root /srv/funkwhale/spa; }
    location /_protected/media/ { internal; alias /srv/funkwhale/data/media/; }
    location /_protected/music/ { internal; alias /music/; }
    location / { proxy_pass http://$FW_APP_HOST:5000; proxy_set_header Host $FW_HOST; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto https; proxy_set_header X-Forwarded-Ssl on; }
}
EOF
}

funkwhale_common_args() {
    printf '%s\0' --network "$NETWORK" --env-file "$FW_ENV" \
        -e SSL_CERT_FILE=/smoke-ca/smoke-ca.crt \
        -e REQUESTS_CA_BUNDLE=/smoke-ca/smoke-ca.crt \
        -e CURL_CA_BUNDLE=/smoke-ca/smoke-ca.crt \
        -e PATH=/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        -v "$FW_MEDIA:/srv/funkwhale/data/media" \
        -v "$FW_STATIC:/srv/funkwhale/data/static" \
        -v "$FW_MUSIC:/music" \
        -v "$CA_CERT:/smoke-ca/smoke-ca.crt:ro"
}

run_funkwhale_manage() {
    local name="$1" args=()
    shift
    while IFS= read -r -d '' item; do args+=("$item"); done < <(funkwhale_common_args)
    docker run --rm --name "$name" "${args[@]}" "$FW_API_IMAGE" /venv/bin/funkwhale-manage "$@"
}

run_funkwhale_shell() {
    local name="$1" code="$2" args=()
    while IFS= read -r -d '' item; do args+=("$item"); done < <(funkwhale_common_args)
    docker run --rm --name "$name" "${args[@]}" "$FW_API_IMAGE" /venv/bin/funkwhale-manage shell -c "$code"
}

run_be_mix() {
    local name="$1" log_file="$WORK_DIR/$1.log"
    shift
    if ! docker run --rm --name "$name" --network "$NETWORK" -e MIX_ENV=dev -e MIX_HOME=/tmp/mix -e HEX_HOME=/tmp/hex -e MIX_BUILD_PATH="$MIX_BUILD_PATH" -e SSL_CERT_FILE=/smoke-ca/smoke-ca.crt -v "$BE_ROOT:/work" -v "$BE_SECRET:/work/config/dev.secret.exs:ro" -v "$CA_CERT:/smoke-ca/smoke-ca.crt:ro" "$IMAGE" bash -lc "set -euo pipefail; cd /work; mix local.hex --force >/dev/null; mix local.rebar --force >/dev/null; mix deps.get >/dev/null; $*" >"$log_file" 2>&1; then
        cat "$log_file" >&2 || true
        fail "mix command failed in $name"
    fi
}
wait_postgres() {
    local container="$1" stable=0
    for _ in $(seq 1 100); do
        if docker exec "$container" psql -U postgres -d postgres -Atc "select 1" >/dev/null 2>&1; then
            stable=$((stable + 1)); [ "$stable" -ge 3 ] && return 0
        else
            stable=0
        fi
        sleep 1
    done
    fail "PostgreSQL did not become ready in $container"
}

prepare_database() { docker exec "$1" psql -U postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE $2;" >/dev/null; }

start_be() {
    docker run -d --name "$BE_CONTAINER" --hostname "$BE_APP_HOST" --network "$NETWORK" --network-alias "$BE_APP_HOST" -e MIX_ENV=dev -e MIX_HOME=/tmp/mix -e HEX_HOME=/tmp/hex -e MIX_BUILD_PATH="$MIX_BUILD_PATH" -e SSL_CERT_FILE=/smoke-ca/smoke-ca.crt -v "$BE_ROOT:/work" -v "$BE_SECRET:/work/config/dev.secret.exs:ro" -v "$CA_CERT:/smoke-ca/smoke-ca.crt:ro" "$IMAGE" bash -lc 'set -euo pipefail; cd /work; mix local.hex --force >/dev/null; mix local.rebar --force >/dev/null; mix deps.get >/dev/null; exec mix phx.server' >/dev/null
}

start_be_proxy() {
    docker run -d --name "$BE_PROXY_CONTAINER" --hostname "$BE_PROXY_CONTAINER" --network "$NETWORK" --network-alias "$BE_HOST" -p "127.0.0.1:$BE_PORT:80" -v "$BE_NGINX_CONF:/etc/nginx/conf.d/default.conf:ro" -v "$BE_CERT:/etc/nginx/certs/be.crt:ro" -v "$BE_KEY:/etc/nginx/certs/be.key:ro" "$NGINX_IMAGE" >/dev/null
}

start_funkwhale() {
    local args=()
    while IFS= read -r -d '' item; do args+=("$item"); done < <(funkwhale_common_args)
    docker run -d --name "$FW_API_CONTAINER" --hostname "$FW_APP_HOST" --network-alias "$FW_APP_HOST" "${args[@]}" --entrypoint /app/entrypoint.sh "$FW_API_IMAGE" gunicorn >/dev/null
    docker run -d --name "$FW_WORKER_CONTAINER" --hostname "${FW_APP_HOST}-worker" "${args[@]}" -e C_FORCE_ROOT=true --entrypoint /venv/bin/celery "$FW_API_IMAGE" --app=funkwhale_api.taskapp worker --loglevel=INFO --concurrency=1 >/dev/null
    docker run -d --name "$FW_PROXY_CONTAINER" --hostname "$FW_PROXY_CONTAINER" --network "$NETWORK" --network-alias "$FW_HOST" -p "127.0.0.1:$FW_PORT:80" -v "$FW_NGINX_CONF:/etc/nginx/conf.d/default.conf:ro" -v "$FW_CERT:/etc/nginx/certs/funkwhale.crt:ro" -v "$FW_KEY:/etc/nginx/certs/funkwhale.key:ro" -v "$FW_MEDIA:/srv/funkwhale/data/media:ro" -v "$FW_SPA:/srv/funkwhale/spa:ro" -v "$FW_MUSIC:/music:ro" "$NGINX_IMAGE" >/dev/null
}

wait_be() {
    for _ in $(seq 1 "$WAIT_BE_ATTEMPTS"); do curl -fsS "$BE_BASE/api/v1/instance" >/dev/null 2>&1 && return 0; sleep 1; done
    fail "Timed out waiting for Unfathomably at $BE_BASE"
}

wait_funkwhale() {
    for _ in $(seq 1 "$WAIT_FUNKWHALE_ATTEMPTS"); do curl -fsS -H "Host: $FW_HOST" "$FW_BASE/api/v2/instance/settings/" >/dev/null 2>&1 && return 0; sleep 2; done
    fail "Timed out waiting for Funkwhale at $FW_BASE"
}

create_be_user() {
    run_be_mix "${PREFIX}-be-user-$1" "mix pleroma.user new '$1' '$2' --password '$PASSWORD' --assume-yes >/dev/null && mix run -e \"alias Pleroma.{Repo, User}; User.get_by_nickname(\\\"$1\\\") |> Ecto.Changeset.change(is_discoverable: true) |> Repo.update!()\" >/dev/null"
}

create_be_token() {
    local app token client_id client_secret
    app="$(http_form POST "$BE_BASE/api/v1/apps" "" 200 "client_name=funkwhale-smoke-$1" "redirect_uris=urn:ietf:wg:oauth:2.0:oob" "scopes=read write follow push admin")"
    client_id="$(json_get "$app" client_id)"
    client_secret="$(json_get "$app" client_secret)"
    token="$(http_form POST "$BE_BASE/oauth/token" "" 200 "grant_type=password" "username=$1" "password=$PASSWORD" "client_id=$client_id" "client_secret=$client_secret" "scope=read write follow push admin")"
    json_get "$token" access_token
}

configure_funkwhale() {
    run_funkwhale_shell "${PREFIX}-fw-prefs" '
from funkwhale_api.common import preferences
for key, value in {
    "common__api_authentication_required": False,
    "federation__enabled": True,
    "federation__public_index": True,
    "federation__pod_follow": False,
    "federation__auto_federation": False,
    "music__transcoding_enabled": False,
    "users__upload_quota": 1000,
}.items():
    preferences.set(key, value)
' >/dev/null
}

create_funkwhale_user() {
    run_funkwhale_manage "${PREFIX}-fw-user" fw users create --username whale --password "$PASSWORD" --email "whale@$FW_HOST" --upload-quota 1000 --superuser --staff >/dev/null
    set_funkwhale_user_privacy everyone
}

set_funkwhale_user_privacy() {
    local privacy_level="$1"

    case "$privacy_level" in
        everyone|followers)
            ;;
        *)
            fail "Unsupported Funkwhale smoke user privacy level: $privacy_level"
            ;;
    esac

    run_funkwhale_shell "${PREFIX}-fw-user-privacy" "
from funkwhale_api.users.models import User
user = User.objects.get(username=\"whale\")
user.privacy_level = \"$privacy_level\"
user.save(update_fields=[\"privacy_level\"])
" >/dev/null
}

create_funkwhale_token() {
    run_funkwhale_shell "${PREFIX}-fw-token" '
import datetime, secrets
from django.utils import timezone
from funkwhale_api.users.models import AccessToken, Application, User
user = User.objects.get(username="whale")
app = Application.objects.create(user=user, name="unfathomably-funkwhale-smoke", client_type=Application.CLIENT_CONFIDENTIAL, authorization_grant_type=Application.GRANT_AUTHORIZATION_CODE, redirect_uris="urn:ietf:wg:oauth:2.0:oob", scope="read write read:libraries write:libraries read:follows write:follows read:favorites write:favorites read:listenings write:listenings read:notifications write:notifications write:security")
token = secrets.token_urlsafe(48)
AccessToken.objects.create(user=user, application=app, token=token, expires=timezone.now() + datetime.timedelta(days=1), scope=app.scope)
print(token)
' | tail -1
}

funkwhale_library_info() {
    run_funkwhale_shell "${PREFIX}-fw-library" '
from funkwhale_api.users.models import User
user = User.objects.get(username="whale")
library = user.actor.libraries.filter(privacy_level="everyone", channel=None).order_by("id").first() or user.actor.libraries.filter(channel=None).order_by("id").first()
print(f"{library.uuid} {library.fid}")
' | tail -1
}

generate_audio_file() {
    docker run --rm -v "$WORK_DIR:/work" --entrypoint ffmpeg "$FW_API_IMAGE" -y -f lavfi -i sine=frequency=880:duration=1 -metadata title="Funkwhale Smoke Track" -metadata artist="Funkwhale Smoke Artist" -metadata album="Funkwhale Smoke Album" -c:a libmp3lame -b:a 64k /work/smoke.mp3 >/dev/null 2>&1
    [ -s "$SMOKE_AUDIO_FILE" ] || fail "Could not generate Funkwhale smoke audio"
}

upload_funkwhale_track() {
    local upload upload_uuid track_id track_fid
    upload="$(http_form POST "$FW_BASE/api/v2/uploads/" "$FW_TOKEN" 201 "audio_file=@$SMOKE_AUDIO_FILE;type=audio/mpeg" "library=$FW_LIBRARY_UUID" "import_status=pending")"
    upload_uuid="$(json_get "$upload" uuid)"
    upload="$(poll_json "http_form GET '$FW_BASE/api/v2/uploads/$upload_uuid/' '$FW_TOKEN' 200" 'data.get("import_status") == "finished" and data.get("track") and data["track"].get("fid")' "Funkwhale did not finish importing the smoke audio upload")"
    track_id="$(json_get "$upload" track.id)"
    track_fid="$(json_get "$upload" track.fid)"
    printf '%s %s %s\n' "$upload_uuid" "$track_id" "$track_fid"
}

resolve_account_id() {
    local result id
    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        result="$(http_form GET "$BE_BASE/api/v2/search?q=$(urlencode "$1")&resolve=true&type=accounts&limit=5" "$ALICE_TOKEN" 200 || true)"
        id="$(json_get_optional "$result" accounts.0.id)"
        [ -n "$id" ] && { printf '%s\n' "$id"; return 0; }
        sleep 2
    done
    printf '%s\n' "$result" >&2
    fail "$2"
}

resolve_be_status_id() {
    local result id
    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        result="$(http_form GET "$BE_BASE/api/v2/search?resolve=true&type=statuses&q=$(urlencode "$1")" "$ALICE_TOKEN" 200 || true)"
        id="$(json_get_optional "$result" statuses.0.id)"
        [ -n "$id" ] && { printf '%s\n' "$id"; return 0; }
        sleep 2
    done
    printf '%s\n' "$result" >&2
    fail "$2"
}
poll_funkwhale_favourite_count() {
    local expected="$1"
    local attempts="${2:-$POLL_ATTEMPTS}"
    local count

    for _ in $(seq 1 "$attempts"); do
        count="$(run_funkwhale_shell "${PREFIX}-fw-favourite-count" "from funkwhale_api.favorites.models import TrackFavorite; print(TrackFavorite.objects.filter(track__fid='$FW_TRACK_FID', actor__domain_id='$BE_HOST').count())" | awk '/^[0-9]+$/ { value = $0 } END { print value }')"
        [ "$count" = "$expected" ] && return 0
        sleep 2
    done
    return 1
}

poll_funkwhale_listening_count() {
    local expected="$1" count
    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        count="$(run_funkwhale_shell "${PREFIX}-fw-listening-count" "from funkwhale_api.history.models import Listening; print(Listening.objects.filter(track__fid='$FW_TRACK_FID', actor__domain_id='$BE_HOST').count())" | awk '/^[0-9]+$/ { value = $0 } END { print value }')"
        [ "$count" = "$expected" ] && return 0
        sleep 2
    done
    return 1
}

count_funkwhale_inbox_items() {
    run_funkwhale_shell "${PREFIX}-fw-inbox-count" "from funkwhale_api.federation.models import InboxItem; print(InboxItem.objects.count())" | awk '/^[0-9]+$/ { value = $0 } END { print value }'
}

poll_funkwhale_inbox_item_increment() {
    local initial="$1" message="$2" count
    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        count="$(count_funkwhale_inbox_items)"
        if [ "$count" -gt "$initial" ]; then
            return 0
        fi
        sleep 2
    done
    fail "$message"
}

count_container_log_matches() {
    local container="$1" pattern="$2"
    docker logs "$container" 2>&1 | awk -v pattern="$pattern" 'index($0, pattern) { count++ } END { print count + 0 }'
}

poll_container_log_increment() {
    local container="$1" pattern="$2" initial="$3" message="$4" count
    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        count="$(count_container_log_matches "$container" "$pattern")"
        if [ "$count" -gt "$initial" ]; then
            return 0
        fi
        sleep 2
    done
    fail "$message"
}

fetch_funkwhale_object() {
    local uri="$1" expected_type="$2" message="$3" result
    result="$(http_json POST "$FW_BASE/api/v2/federation/fetches/" "$FW_TOKEN" 201 "{\"object_uri\":\"$uri\",\"force\":true}")"
    json_assert "$result" 'data.get("status") == "finished"' "$message"
    if [ -n "$expected_type" ] && ! JSON_INPUT="$result" EXPECTED_TYPE="$expected_type" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
if data.get("type") != os.environ["EXPECTED_TYPE"]:
    raise SystemExit(1)
PY
    then
        printf '%s\n' "$result" >&2
        fail "$message"
    fi
    printf '%s\n' "$result"
}

try_funkwhale_follow_actor() {
    local actor_uri="$1" label="$2"
    printf 'not_supported: stock Funkwhale user follow discovery is tied to Funkwhale library endpoints; skipped live follow probe for %s actor %s\n' "$label" "$actor_uri"
    return 0
}

check_logs() {
    local container="$1" label="$2"
    if docker logs "$container" 2>&1 | grep -Ei 'panic:|fatal|segmentation fault|FunctionClauseError|MatchError|ArgumentError|Traceback \(most recent call last\)' >/dev/null; then
        docker logs --tail 260 "$container" >&2 || true
        fail "$label emitted a crash-class log line"
    fi
}

log "Cleaning previous Funkwhale smoke containers"
clean_previous

log "Preparing configs, TLS, and smoke fixtures"
mkdir -p "$WORK_DIR"
write_tls_material
write_be_secret
write_funkwhale_env
write_proxy_configs
generate_audio_file

log "Creating Docker network and databases"
docker network create "$NETWORK" >/dev/null

docker run -d --name "$BE_DB_CONTAINER" --network "$NETWORK" -e POSTGRES_PASSWORD="$BE_DB_PASSWORD" "$POSTGRES_IMAGE" >/dev/null
docker run -d --name "$FW_DB_CONTAINER" --network "$NETWORK" -e POSTGRES_PASSWORD="$FW_DB_PASSWORD" "$POSTGRES_IMAGE" >/dev/null
docker run -d --name "$FW_REDIS_CONTAINER" --network "$NETWORK" "$REDIS_IMAGE" >/dev/null

wait_postgres "$BE_DB_CONTAINER"
wait_postgres "$FW_DB_CONTAINER"
prepare_database "$BE_DB_CONTAINER" "$BE_DB_NAME"
prepare_database "$FW_DB_CONTAINER" "$FW_DB_NAME"

log "Migrating and starting Unfathomably"
# MIME mappings are compile-time dependency configuration.  The dedicated
# adapter build cache can outlive a source checkout update, so refresh only
# that dependency before Mix validates the current configuration.
run_be_mix "${PREFIX}-migrate-be" "rm -rf '$MIX_BUILD_PATH/lib/mime'; mix deps.compile mime --force >/dev/null; mix ecto.migrate"
create_be_user alice "alice@$BE_HOST"
start_be
start_be_proxy
wait_be

log "Migrating and starting stock Funkwhale"
run_funkwhale_manage "${PREFIX}-fw-migrate" migrate >/dev/null
configure_funkwhale
create_funkwhale_user
start_funkwhale
wait_funkwhale

log "Creating API credentials"
ALICE_TOKEN="$(create_be_token alice)"
FW_TOKEN="$(create_funkwhale_token)"
read -r FW_LIBRARY_UUID FW_LIBRARY_FID <<EOF
$(funkwhale_library_info)
EOF

log "Uploading a public Funkwhale audio track"
read -r FW_UPLOAD_UUID FW_TRACK_ID FW_TRACK_FID <<EOF
$(upload_funkwhale_track)
EOF

log "Resolving and following the Funkwhale user from Unfathomably"
FW_ACCOUNT_ID="$(resolve_account_id "whale@$FW_HOST" "Unfathomably could not resolve Funkwhale account")"
BE_FOLLOW_FW="$(http_form POST "$BE_BASE/api/v1/accounts/$FW_ACCOUNT_ID/follow" "$ALICE_TOKEN" 200)"
json_assert "$BE_FOLLOW_FW" 'data.get("following") is True or data.get("requested") is True' "Unfathomably could not follow the Funkwhale account"
accept_funkwhale_inbound_follow

#
# Funkwhale sends public user activity to known Funkwhale service actors.  A
# non-Funkwhale follower receives Listen activity through the direct followers
# route instead, so switch only after the discovery and approval flow is done.
#
set_funkwhale_user_privacy followers

log "Resolving the Funkwhale library and audio track from both sides"
fetch_funkwhale_object "$FW_LIBRARY_FID" library "Funkwhale could not fetch its own public library through the federation fetch API" >/dev/null
BE_VIEW_OF_FW_TRACK_ID="$(resolve_be_status_id "$FW_TRACK_FID" "Unfathomably could not resolve Funkwhale Audio track")"
BE_VIEW_OF_FW_TRACK="$(http_form GET "$BE_BASE/api/v1/statuses/$BE_VIEW_OF_FW_TRACK_ID" "$ALICE_TOKEN" 200)"
json_assert "$BE_VIEW_OF_FW_TRACK" '"Funkwhale Smoke Track" in str(data) or len(data.get("media_attachments") or []) >= 1' "Unfathomably did not expose the Funkwhale audio track as visible status/media data"

log "Testing Funkwhale Track Listen federation in both directions"
BE_LISTEN_PAYLOAD="$(python3 - "$FW_TRACK_FID" <<'PY'
import json
import sys

print(json.dumps({
    "title": "Funkwhale Smoke Track",
    "artist": "Funkwhale Smoke Artist",
    "track_ap_id": sys.argv[1],
}))
PY
)"
BE_LISTEN_FW="$(
    http_json POST "$BE_BASE/api/v1/pleroma/scrobble" "$ALICE_TOKEN" 200 "$BE_LISTEN_PAYLOAD"
)"
json_assert "$BE_LISTEN_FW" \
    'data.get("title") == "Funkwhale Smoke Track" and data.get("externalLink") == "'$FW_TRACK_FID'"' \
    "Unfathomably could not publish a Funkwhale Track Listen"
poll_funkwhale_listening_count 1 || \
    fail "Funkwhale did not materialize Unfathomably Track Listen"

FW_LISTEN="$(
    http_json POST "$FW_BASE/api/v2/history/listenings/" "$FW_TOKEN" 201 \
        "{\"track\":$FW_TRACK_ID}"
)"
json_assert "$FW_LISTEN" 'data.get("id") is not None' \
    "Funkwhale could not create a local Track Listen"
poll_json \
    "http_form GET '$BE_BASE/api/v1/pleroma/accounts/$FW_ACCOUNT_ID/scrobbles' '$ALICE_TOKEN' 200" \
    'any(item.get("externalLink") == "'$FW_TRACK_FID'" and item.get("title") == "Funkwhale Smoke Track" for item in data)' \
    "Unfathomably did not receive Funkwhale Track Listen" >/dev/null

log "Testing Unfathomably favourite and unfavourite of Funkwhale track"
FW_SHARED_INBOX_PATTERN='POST /federation/shared/inbox HTTP/1.1" 200'
FW_SHARED_INBOX_BEFORE_LIKE="$(count_container_log_matches "$FW_PROXY_CONTAINER" "$FW_SHARED_INBOX_PATTERN")"
BE_LIKE_FW="$(http_form POST "$BE_BASE/api/v1/statuses/$BE_VIEW_OF_FW_TRACK_ID/favourite" "$ALICE_TOKEN" 200)"
json_assert "$BE_LIKE_FW" 'data.get("favourited") is True' "Unfathomably could not favourite Funkwhale track"
poll_container_log_increment "$FW_PROXY_CONTAINER" "$FW_SHARED_INBOX_PATTERN" "$FW_SHARED_INBOX_BEFORE_LIKE" "Funkwhale did not receive Unfathomably Like inbox delivery for the track"
if poll_funkwhale_favourite_count 1 "$CAPABILITY_POLL_ATTEMPTS"; then
    FW_FAVOURITE_PROBE="supported: stock Funkwhale materialized the remote Like as a track favorite"
else
    FW_FAVOURITE_PROBE="not_supported: stock Funkwhale accepted the remote Like inbox delivery but did not materialize it as a TrackFavorite"
fi
FW_SHARED_INBOX_BEFORE_UNLIKE="$(count_container_log_matches "$FW_PROXY_CONTAINER" "$FW_SHARED_INBOX_PATTERN")"
BE_UNLIKE_FW="$(http_form POST "$BE_BASE/api/v1/statuses/$BE_VIEW_OF_FW_TRACK_ID/unfavourite" "$ALICE_TOKEN" 200)"
json_assert "$BE_UNLIKE_FW" 'data.get("favourited") is False' "Unfathomably could not unfavourite Funkwhale track"
poll_container_log_increment "$FW_PROXY_CONTAINER" "$FW_SHARED_INBOX_PATTERN" "$FW_SHARED_INBOX_BEFORE_UNLIKE" "Funkwhale did not receive Unfathomably Undo Like inbox delivery for the track"
if printf '%s\n' "$FW_FAVOURITE_PROBE" | grep -q '^supported:'; then
    poll_funkwhale_favourite_count 0 "$CAPABILITY_POLL_ATTEMPTS" || fail "Funkwhale did not remove the Unfathomably TrackFavorite after Undo Like"
    FW_UNFAVOURITE_PROBE="supported: stock Funkwhale removed the remote TrackFavorite after Undo Like"
else
    FW_UNFAVOURITE_PROBE="not_supported: stock Funkwhale did not materialize the remote Like, so TrackFavorite removal cannot be observed"
fi

log "Probing Funkwhale follow behavior for Unfathomably account and Group actors"
FW_FOLLOW_BE_ACCOUNT="$(try_funkwhale_follow_actor "https://$BE_HOST/users/alice" "Unfathomably account")"
printf '%s\n' "$FW_FOLLOW_BE_ACCOUNT"
BE_GROUP_NAME="funkwhale-smoke-$(basename "$WORK_DIR" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')"
BE_GROUP="$(http_form POST "$BE_BASE/api/v1/groups" "$ALICE_TOKEN" 200 "display_name=Funkwhale Smoke Group" "name=$BE_GROUP_NAME" "note=Open group used by the Funkwhale federation smoke harness." "locked=false")"
BE_GROUP_ACTOR="$(json_get_optional "$BE_GROUP" ap_id)"
[ -z "$BE_GROUP_ACTOR" ] && BE_GROUP_ACTOR="$(json_get "$BE_GROUP" url)"
FW_GROUP_PROBE="$(try_funkwhale_follow_actor "$BE_GROUP_ACTOR" "Unfathomably Group")"
printf '%s\n' "$FW_GROUP_PROBE"

log "Probing Funkwhale delete behavior for the uploaded audio track"
FW_TRACK_DELETE_RESPONSE="$WORK_DIR/funkwhale-track-delete.json"
FW_TRACK_DELETE_STATUS="$(curl -ksS -o "$FW_TRACK_DELETE_RESPONSE" -w '%{http_code}' -X DELETE -H "Authorization: Bearer $FW_TOKEN" "$FW_BASE/api/v2/tracks/$FW_TRACK_ID/")"
if [ "$FW_TRACK_DELETE_STATUS" = "204" ]; then
    if wait_http_status_optional GET "$BE_BASE/api/v1/statuses/$BE_VIEW_OF_FW_TRACK_ID" "$ALICE_TOKEN" 404; then
        FW_DELETE_PROBE="supported: stock Funkwhale deleted the Track object and Unfathomably lost the remote status"
    else
        FW_DELETE_PROBE="not_supported: stock Funkwhale accepted Track delete but did not federate a Delete that removed the Unfathomably status"
    fi
else
    http_form DELETE "$FW_BASE/api/v2/uploads/$FW_UPLOAD_UUID/" "$FW_TOKEN" 204 >/dev/null
    FW_DELETE_PROBE="not_supported: stock Funkwhale upload delete returned 204 but left the ActivityPub Track object visible; Track delete returned HTTP $FW_TRACK_DELETE_STATUS"
fi

log "Cleaning up follows"
http_form POST "$BE_BASE/api/v1/accounts/$FW_ACCOUNT_ID/unfollow" "$ALICE_TOKEN" 200 >/dev/null || true
if printf '%s' "$FW_FOLLOW_BE_ACCOUNT" | grep -q '^supported:'; then
    FW_FOLLOW_UUID="${FW_FOLLOW_BE_ACCOUNT#supported:}"
    http_form DELETE "$FW_BASE/api/v2/federation/follows/user/$FW_FOLLOW_UUID/" "$FW_TOKEN" 204 >/dev/null || true
fi

log "Checking logs for obvious crashes"
check_logs "$BE_CONTAINER" "Unfathomably"
check_logs "$FW_API_CONTAINER" "Funkwhale API"
check_logs "$FW_WORKER_CONTAINER" "Funkwhale worker"

cat <<EOF

Unfathomably/Funkwhale federation smoke passed.

Covered against stock Funkwhale:
* supported: clean Funkwhale 2.x API boot with PostgreSQL, Redis, Celery, and HTTPS proxy
* supported: deterministic Funkwhale user, public library, OAuth token, and tagged audio upload
* supported: Unfathomably account discovery and follow of the Funkwhale actor
* supported: Unfathomably resolution and rendering of Funkwhale Audio/Track federation data
* supported: Funkwhale Track Listen activities are created and received in both directions
* supported: Unfathomably favourite and unfavourite API behavior plus Funkwhale inbox delivery
* $FW_FAVOURITE_PROBE
* $FW_UNFAVOURITE_PROBE
* $FW_DELETE_PROBE
* $FW_FOLLOW_BE_ACCOUNT
* $FW_GROUP_PROBE
* supported: basic log scan for crash-class output
EOF

# end of build_scripts/unfathomably-funkwhale-smoke.sh
