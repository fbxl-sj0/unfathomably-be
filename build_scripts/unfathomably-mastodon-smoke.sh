#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke harness
# ------------------------------------------------
#
# File: build_scripts/unfathomably-mastodon-smoke.sh
#
# Purpose:
#
#   Start an unfathomably-be backend, an unfathomably-fe frontend gateway,
#   and a reference Mastodon server on one Docker network, then exercise the
#   compatibility paths that matter most between them.
#
# Responsibilities:
#
#   * create isolated PostgreSQL databases for unfathomably-be and Mastodon
#   * start Redis for Mastodon cache, streaming coordination, and Sidekiq
#   * start unfathomably-be from this source tree
#   * serve unfathomably-fe through a same-origin nginx gateway
#   * start Mastodon web and Sidekiq workers
#   * create smoke users and API tokens on both servers
#   * check local group administration on unfathomably-be
#   * check Mastodon account lookup, follows, and status resolution both ways
#   * prove Mastodon handles unfathomably group actors safely
#   * fail loudly on unexpected HTTP statuses, 500s, or crash signatures
#
# This file intentionally does NOT contain:
#
#   * production deployment logic
#   * persistent database management
#   * real public DNS or TLS setup
#   * Mastodon streaming API coverage
#   * browser screenshot capture
#

set -euo pipefail

PREFIX="${PREFIX:-unfathomably-mastodon-smoke}"
NETWORK="${NETWORK:-${PREFIX}-net}"
DB_CONTAINER="${DB_CONTAINER:-${PREFIX}-db}"
REDIS_CONTAINER="${REDIS_CONTAINER:-${PREFIX}-redis}"

BE_CONTAINER="${BE_CONTAINER:-${PREFIX}-be}"
BE_PROXY_CONTAINER="${BE_PROXY_CONTAINER:-${PREFIX}-be-proxy}"
FE_CONTAINER="${FE_CONTAINER:-${PREFIX}-fe}"
MASTODON_WEB_CONTAINER="${MASTODON_WEB_CONTAINER:-${PREFIX}-mastodon-web}"
MASTODON_SIDEKIQ_CONTAINER="${MASTODON_SIDEKIQ_CONTAINER:-${PREFIX}-mastodon-sidekiq}"
MASTODON_PROXY_CONTAINER="${MASTODON_PROXY_CONTAINER:-${PREFIX}-mastodon-proxy}"

BE_HOST="${BE_HOST:-unfathomably-be.test}"
BE_APP_HOST="${BE_APP_HOST:-unfathomably-be-app}"
MASTODON_HOST="${MASTODON_HOST:-mastodon-ref.test}"
MASTODON_APP_HOST="${MASTODON_APP_HOST:-mastodon-app}"

BE_PORT="${BE_PORT:-4641}"
FE_PORT="${FE_PORT:-4640}"
MASTODON_PORT="${MASTODON_PORT:-4642}"

DB_PASSWORD="${DB_PASSWORD:-postgres}"
PASSWORD="${PASSWORD:-unfathomably-smoke-password}"

IMAGE="${SMOKE_IMAGE:-unfathomably-elixir-smoke:otp28}"
NODE_IMAGE="${NODE_IMAGE:-node:26-bookworm}"
MASTODON_IMAGE="${MASTODON_IMAGE:-ghcr.io/mastodon/mastodon:latest}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$BE_ROOT/.." && pwd)"

DEFAULT_FE_ROOT="$PROJECT_ROOT/unfathomably-fe"
DEFAULT_FE_STATIC_ROOT="$PROJECT_ROOT/unfathomably-fe"
FE_ROOT="${FE_ROOT:-$DEFAULT_FE_ROOT}"
FE_STATIC_ROOT="${FE_STATIC_ROOT:-$DEFAULT_FE_STATIC_ROOT}"

WORK_DIR="${WORK_DIR:-$BE_ROOT/.smoke/unfathomably-mastodon}"
BE_SECRET="$WORK_DIR/be/dev.secret.exs"
MASTODON_ENV="$WORK_DIR/mastodon/.env.production"
FE_BUILD_DIR="$WORK_DIR/fe/dist"
NGINX_CONF="$WORK_DIR/nginx/default.conf"
BE_NGINX_CONF="$WORK_DIR/be-nginx/default.conf"
BE_CERT_DIR="$WORK_DIR/be-certs"
MASTODON_NGINX_CONF="$WORK_DIR/mastodon-nginx/default.conf"
MASTODON_CERT_DIR="$WORK_DIR/mastodon-certs"
SMOKE_CA_DIR="$WORK_DIR/smoke-ca"
SMOKE_CA_KEY="$SMOKE_CA_DIR/smoke-ca.key"
SMOKE_CA_CERT="$SMOKE_CA_DIR/smoke-ca.crt"

cleanup() {
    if [ "${KEEP_SMOKE:-0}" = "1" ]; then
        cat <<EOF

KEEP_SMOKE=1 set, leaving smoke containers running.

Frontend gateway:  http://127.0.0.1:$FE_PORT
unfathomably-be:   http://127.0.0.1:$BE_PORT
Mastodon:          http://127.0.0.1:$MASTODON_PORT

Mastodon expects Host: $MASTODON_HOST for browser-like requests.

EOF
        return 0
    fi

    docker rm -f \
        "$FE_CONTAINER" \
        "$BE_PROXY_CONTAINER" \
        "$BE_CONTAINER" \
        "$MASTODON_PROXY_CONTAINER" \
        "$MASTODON_WEB_CONTAINER" \
        "$MASTODON_SIDEKIQ_CONTAINER" \
        "$REDIS_CONTAINER" \
        "$DB_CONTAINER" >/dev/null 2>&1 || true

    docker network rm "$NETWORK" >/dev/null 2>&1 || true
}

trap cleanup EXIT

step() {
    printf '\n==> %s\n' "$*"
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    dump_logs
    exit 1
}

dump_logs() {
    for container in "$BE_CONTAINER" "$FE_CONTAINER" "$MASTODON_PROXY_CONTAINER" "$MASTODON_WEB_CONTAINER" "$MASTODON_SIDEKIQ_CONTAINER"; do
        if docker ps -a --format '{{.Names}}' | grep -Fx "$container" >/dev/null 2>&1; then
            printf '\n--- %s logs ---\n' "$container" >&2
            docker logs --tail 140 "$container" >&2 || true
        fi
    done
}

random_hex() {
    local bytes="$1"

    python3 - "$bytes" <<'PY'
import secrets
import sys

print(secrets.token_hex(int(sys.argv[1])))
PY
}

urlencode() {
    python3 - "$1" <<'PY'
import sys
import urllib.parse

print(urllib.parse.quote(sys.argv[1], safe=""))
PY
}

json_get() {
    local body="$1"
    local path="$2"

    JSON_BODY="$body" python3 - "$path" <<'PY'
import json
import os
import sys

data = json.loads(os.environ["JSON_BODY"])
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
    local body="$1"
    local path="$2"

    JSON_BODY="$body" python3 - "$path" <<'PY'
import json
import os
import sys

data = json.loads(os.environ["JSON_BODY"])
value = data

try:
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

nodeinfo_href() {
    local body="$1"
    local rel="$2"

    JSON_BODY="$body" NODEINFO_REL="$rel" python3 - <<'PY'
import json
import os
import sys

data = json.loads(os.environ["JSON_BODY"])
rel = os.environ["NODEINFO_REL"]

for link in data.get("links", []):
    if link.get("rel") == rel and link.get("href"):
        print(link["href"])
        sys.exit(0)

sys.exit(1)
PY
}

url_path_and_query() {
    python3 - "$1" <<'PY'
import sys
from urllib.parse import urlsplit

parts = urlsplit(sys.argv[1])
path = parts.path or "/"

if parts.query:
    path = f"{path}?{parts.query}"

print(path)
PY
}

json_assert() {
    local body="$1"
    local expression="$2"
    local message="$3"

    JSON_BODY="$body" python3 - "$expression" "$message" <<'PY'
import json
import os
import sys

data = json.loads(os.environ["JSON_BODY"])
expression = sys.argv[1]
message = sys.argv[2]
helpers = {"any": any, "all": all, "len": len, "str": str}

try:
    ok = bool(eval(expression, {"__builtins__": {}}, {"data": data, **helpers}))
except Exception as exc:
    print(f"assertion raised: {message}: {exc}", file=sys.stderr)
    sys.exit(1)

if not ok:
    print(f"assertion failed: {message}", file=sys.stderr)
    print(json.dumps(data, indent=2, sort_keys=True), file=sys.stderr)
    sys.exit(1)
PY
}

http_json() {
    local method="$1"
    local url="$2"
    local token="$3"
    local expected="$4"
    shift 4

    local tmp
    local code
    tmp="$(mktemp)"

    local args=(-sS -X "$method" -o "$tmp" -w "%{http_code}")

    if [ -n "$token" ]; then
        args+=(-H "Authorization: Bearer $token")
    fi

    if [ "$#" -gt 0 ]; then
        args+=(-H "Content-Type: application/x-www-form-urlencoded")
        for form_arg in "$@"; do
            args+=(--data-urlencode "$form_arg")
        done
    fi

    code="$(curl "${args[@]}" "$url")" || {
        cat "$tmp" >&2 || true
        rm -f "$tmp"
        fail "curl failed for $method $url"
    }

    local body
    body="$(cat "$tmp")"
    rm -f "$tmp"

    if [ "$code" != "$expected" ]; then
        printf 'Unexpected HTTP %s for %s %s, expected %s\n' "$code" "$method" "$url" "$expected" >&2
        printf '%s\n' "$body" >&2
        fail "HTTP assertion failed"
    fi

    printf '%s' "$body"
}

mastodon_json() {
    local method="$1"
    local url="$2"
    local token="$3"
    local expected="$4"
    shift 4

    local tmp
    local code
    tmp="$(mktemp)"

    local args=(-sS -X "$method" -H "Host: $MASTODON_HOST" -H "X-Forwarded-Proto: https" -H "X-Forwarded-Ssl: on" -o "$tmp" -w "%{http_code}")

    if [ -n "$token" ]; then
        args+=(-H "Authorization: Bearer $token")
    fi

    if [ "$#" -gt 0 ]; then
        args+=(-H "Content-Type: application/x-www-form-urlencoded")
        for form_arg in "$@"; do
            args+=(--data-urlencode "$form_arg")
        done
    fi

    code="$(curl "${args[@]}" "$url")" || {
        cat "$tmp" >&2 || true
        rm -f "$tmp"
        fail "curl failed for $method $url"
    }

    local body
    body="$(cat "$tmp")"
    rm -f "$tmp"

    if [ "$code" != "$expected" ]; then
        printf 'Unexpected HTTP %s for %s %s, expected %s\n' "$code" "$method" "$url" "$expected" >&2
        printf '%s\n' "$body" >&2
        fail "Mastodon HTTP assertion failed"
    fi

    printf '%s' "$body"
}

wait_http() {
    local url="$1"
    local label="$2"
    shift 2

    for _ in $(seq 1 160); do
        if curl -fsS "$@" "$url" >/dev/null 2>&1; then
            return 0
        fi

        sleep 1
    done

    fail "Timed out waiting for $label at $url"
}

write_be_secret() {
    local file="$1"
    local instance_name="$2"
    local host="$3"
    local database="$4"
    local uploads="$5"
    local static_dir="$6"

    local secret_key_base
    local signing_salt

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

    mkdir -p "$(dirname "$file")" "$uploads" "$static_dir"

    cat >"$file" <<EOF
import Config

config :pleroma, Pleroma.Web.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000, protocol_options: [max_request_line_length: 8192]],
  url: [scheme: "https", host: "$host", port: 443],
  secret_key_base: "$secret_key_base",
  live_view: [signing_salt: "$signing_salt"],
  code_reloader: false,
  live_reload: false,
  watchers: [],
  server: true

config :pleroma, :instance,
  name: "$instance_name",
  email: "admin@$host",
  notify_email: "admin@$host",
  limit: 5000,
  registrations_open: true,
  public: true

config :pleroma, Pleroma.Repo,
  username: "postgres",
  password: "$DB_PASSWORD",
  hostname: "$DB_CONTAINER",
  database: "$database",
  pool_size: 10

config :pleroma, :media_proxy, enabled: false
config :pleroma, Pleroma.Uploaders.Local, uploads: "$uploads"
config :pleroma, :instance, static_dir: "$static_dir"
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
config :pleroma, :modules, runtime_dir: "$WORK_DIR/runtime-$host"
config :pleroma, Pleroma.ScheduledActivity, daily_user_limit: 1000, total_user_limit: 10000
EOF
}

generate_vapid_keys() {
    docker run --rm \
        --name "${PREFIX}-mastodon-vapid" \
        -e RAILS_ENV=production \
        -e SECRET_KEY_BASE="$(random_hex 64)" \
        -e OTP_SECRET="$(random_hex 64)" \
        -e LOCAL_DOMAIN="$MASTODON_HOST" \
        "$MASTODON_IMAGE" \
        bash -lc 'bundle exec rake mastodon:webpush:generate_vapid_key' |
        awk -F= '/^VAPID_(PRIVATE|PUBLIC)_KEY=/{print}'
}

write_mastodon_env() {
    local vapid
    local vapid_private
    local vapid_public

    mkdir -p "$(dirname "$MASTODON_ENV")"

    vapid="$(generate_vapid_keys)"
    vapid_private="$(printf '%s\n' "$vapid" | awk -F= '/^VAPID_PRIVATE_KEY=/{print $2; exit}')"
    vapid_public="$(printf '%s\n' "$vapid" | awk -F= '/^VAPID_PUBLIC_KEY=/{print $2; exit}')"

    if [ -z "$vapid_private" ] || [ -z "$vapid_public" ]; then
        fail "Could not generate Mastodon VAPID keys"
    fi

    cat >"$MASTODON_ENV" <<EOF
RAILS_ENV=production
NODE_ENV=production
LOCAL_DOMAIN=$MASTODON_HOST
WEB_DOMAIN=$MASTODON_HOST
LOCAL_HTTPS=false
FORCE_SSL=false
RAILS_SERVE_STATIC_FILES=true
AUTHORIZED_FETCH=false
SINGLE_USER_MODE=false
ALLOWED_PRIVATE_ADDRESSES=127.0.0.1/32,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16

DB_HOST=$DB_CONTAINER
DB_PORT=5432
DB_USER=postgres
DB_NAME=unfathomably_mastodon_smoke_mastodon
DB_PASS=$DB_PASSWORD
DB_SSLMODE=disable
PREPARED_STATEMENTS=false

REDIS_HOST=$REDIS_CONTAINER
REDIS_PORT=6379

SECRET_KEY_BASE=$(random_hex 64)
OTP_SECRET=$(random_hex 64)
VAPID_PRIVATE_KEY=$vapid_private
VAPID_PUBLIC_KEY=$vapid_public
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=$(random_hex 32)
ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=$(random_hex 32)
ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=$(random_hex 32)

SMTP_SERVER=localhost
SMTP_PORT=25
SMTP_DELIVERY_METHOD=test
SMTP_AUTH_METHOD=none
SMTP_FROM_ADDRESS=notifications@$MASTODON_HOST
ES_ENABLED=false
DEEPL_API_KEY=
LIBRE_TRANSLATE_ENDPOINT=
EOF
}

docker_run_mix() {
    local root="$1"
    local secret="$2"
    local name="$3"
    local log_file="$WORK_DIR/logs/$name.log"
    shift 3

    if ! docker run --rm \
        --name "$name" \
        --network "$NETWORK" \
        -e MIX_ENV=dev \
        -e MIX_HOME=/tmp/mix \
        -e HEX_HOME=/tmp/hex \
        -v "$root:/work" \
        -v "$secret:/work/config/dev.secret.exs:ro" \
        "$IMAGE" \
        bash -lc "set -euo pipefail; cd /work; git config --global --add safe.directory /work >/dev/null 2>&1 || true; mix local.hex --force >/dev/null; mix local.rebar --force >/dev/null; mix deps.get >/dev/null; $*" \
        >"$log_file" 2>&1; then
        cat "$log_file" >&2 || true
        return 1
    fi
}

mastodon_run() {
    local name="$1"
    shift

    docker run --rm \
        --name "$name" \
        --network "$NETWORK" \
        --env-file "$MASTODON_ENV" \
        "$MASTODON_IMAGE" \
        bash -lc "set -euo pipefail; $*"
}

prepare_database() {
    local database="$1"

    docker exec "$DB_CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 \
        -c "CREATE DATABASE $database;" >/dev/null
}

prepare_be_database() {
    prepare_database "unfathomably_mastodon_smoke_be"
    docker_run_mix "$BE_ROOT" "$BE_SECRET" "${PREFIX}-migrate-be" "mix ecto.migrate"
}

strict_compile_backend() {
    docker_run_mix "$BE_ROOT" "$BE_SECRET" "${PREFIX}-compile-be" \
        "mix compile --warnings-as-errors --no-all-warnings >/dev/null"
}

prepare_mastodon_database() {
    prepare_database "unfathomably_mastodon_smoke_mastodon"
    mastodon_run "${PREFIX}-migrate-mastodon" "bundle exec rails db:prepare"
}

start_be() {
    docker run -d \
        --name "$BE_CONTAINER" \
        --hostname "$BE_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$BE_APP_HOST" \
        -e MIX_ENV=dev \
        -e MIX_HOME=/tmp/mix \
        -e HEX_HOME=/tmp/hex \
        -v "$BE_ROOT:/work" \
        -v "$BE_SECRET:/work/config/dev.secret.exs:ro" \
        -v "$SMOKE_CA_CERT:/usr/local/share/ca-certificates/unfathomably-smoke-ca.crt:ro" \
        -e SSL_CERT_FILE=/usr/local/share/ca-certificates/unfathomably-smoke-ca.crt \
        "$IMAGE" \
        bash -lc 'set -euo pipefail; if command -v update-ca-certificates >/dev/null 2>&1; then update-ca-certificates >/dev/null; fi; cd /work; git config --global --add safe.directory /work >/dev/null 2>&1 || true; mix local.hex --force >/dev/null; mix local.rebar --force >/dev/null; mix deps.get >/dev/null; exec mix phx.server' \
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
        nginx:1.27-alpine >/dev/null
}

start_mastodon() {
    docker run -d \
        --name "$MASTODON_WEB_CONTAINER" \
        --hostname "$MASTODON_APP_HOST" \
        --network "$NETWORK" \
        --network-alias "$MASTODON_APP_HOST" \
        --env-file "$MASTODON_ENV" \
        -v "$SMOKE_CA_CERT:/usr/local/share/ca-certificates/unfathomably-smoke-ca.crt:ro" \
        -e SSL_CERT_FILE=/usr/local/share/ca-certificates/unfathomably-smoke-ca.crt \
        "$MASTODON_IMAGE" \
        bash -lc 'set -euo pipefail; if command -v update-ca-certificates >/dev/null 2>&1; then update-ca-certificates >/dev/null; fi; exec bundle exec puma -C config/puma.rb' \
        >/dev/null

    docker run -d \
        --name "$MASTODON_PROXY_CONTAINER" \
        --hostname "$MASTODON_PROXY_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$MASTODON_HOST" \
        -p "127.0.0.1:$MASTODON_PORT:80" \
        -v "$MASTODON_NGINX_CONF:/etc/nginx/conf.d/default.conf:ro" \
        -v "$MASTODON_CERT_DIR:/etc/nginx/certs:ro" \
        nginx:1.27-alpine >/dev/null

    docker run -d \
        --name "$MASTODON_SIDEKIQ_CONTAINER" \
        --hostname mastodon-sidekiq \
        --network "$NETWORK" \
        --env-file "$MASTODON_ENV" \
        -v "$SMOKE_CA_CERT:/usr/local/share/ca-certificates/unfathomably-smoke-ca.crt:ro" \
        -e SSL_CERT_FILE=/usr/local/share/ca-certificates/unfathomably-smoke-ca.crt \
        "$MASTODON_IMAGE" \
        bash -lc 'set -euo pipefail; if command -v update-ca-certificates >/dev/null 2>&1; then update-ca-certificates >/dev/null; fi; exec bundle exec sidekiq' \
        >/dev/null
}

create_be_user() {
    local label="$1"
    local nickname="$2"
    local email="$3"

    docker_run_mix "$BE_ROOT" "$BE_SECRET" "${PREFIX}-user-$label-$nickname" \
        "mix pleroma.user new '$nickname' '$email' --password '$PASSWORD' --assume-yes >/dev/null && mix run -e \"alias Pleroma.{Repo, User}; User.get_by_nickname(\\\"$nickname\\\") |> Ecto.Changeset.change(is_discoverable: true) |> Repo.update!()\" >/dev/null"
}

create_mastodon_user() {
    mastodon_run "${PREFIX}-user-mastodon-pat" "
        bin/tootctl accounts create pat --email unfathomably-smoke@gmail.com --confirmed --role Owner >/dev/null
        bin/tootctl accounts modify pat --approve >/dev/null || true
        bin/rails runner \"user = User.find_by!(email: 'unfathomably-smoke@gmail.com'); user.password = '$PASSWORD'; user.password_confirmation = '$PASSWORD'; user.approved = true if user.respond_to?(:approved=); user.confirmed_at ||= Time.now.utc; user.save!\"
    "
}

create_be_token() {
    local base="$1"
    local username="$2"

    local app
    app="$(http_json POST "$base/api/v1/apps" "" 200 \
        "client_name=mastodon-smoke-$username" \
        "redirect_uris=urn:ietf:wg:oauth:2.0:oob" \
        "scopes=read write follow push admin")"

    local client_id
    local client_secret
    client_id="$(json_get "$app" client_id)"
    client_secret="$(json_get "$app" client_secret)"

    local token
    token="$(http_json POST "$base/oauth/token" "" 200 \
        "grant_type=password" \
        "username=$username" \
        "password=$PASSWORD" \
        "client_id=$client_id" \
        "client_secret=$client_secret" \
        "scope=read write follow push admin")"

    json_get "$token" access_token
}

create_mastodon_token() {
    mastodon_run "${PREFIX}-token-mastodon-pat" "
        bin/rails runner \"app = Doorkeeper::Application.create!(name: 'unfathomably-mastodon-smoke', redirect_uri: 'urn:ietf:wg:oauth:2.0:oob', scopes: 'read write follow'); user = User.joins(:account).find_by!(accounts: { username: 'pat', domain: nil }); token = Doorkeeper::AccessToken.create!(application_id: app.id, resource_owner_id: user.id, scopes: 'read write follow', expires_in: nil); puts token.token\"
    " | tail -n 1
}

prepare_frontend_static() {
    if [ "${BUILD_FE:-0}" = "1" ]; then
        if [ ! -f "$FE_ROOT/package.json" ]; then
            fail "FE_ROOT does not contain package.json: $FE_ROOT"
        fi

        rm -rf "$FE_BUILD_DIR"
        mkdir -p "$(dirname "$FE_BUILD_DIR")"

        docker run --rm \
            --name "${PREFIX}-fe-build" \
            -e CI=1 \
            -e NODE_ENV=production \
            -v "$FE_ROOT:/work" \
            -v "$FE_BUILD_DIR:/out" \
            "$NODE_IMAGE" \
            bash -lc 'set -euo pipefail; cd /work; corepack enable >/dev/null; yarn install --immutable; yarn build; cp -a dist/. /out/'

        FE_STATIC_ROOT="$FE_BUILD_DIR"
    fi

    if [ ! -f "$FE_STATIC_ROOT/index.html" ]; then
        fail "FE_STATIC_ROOT does not contain index.html: $FE_STATIC_ROOT"
    fi
}

write_nginx_config() {
    mkdir -p "$(dirname "$NGINX_CONF")"

    cat >"$NGINX_CONF" <<EOF
server {
    listen 8080;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    location /api/ {
        proxy_pass http://$BE_APP_HOST:4000;
        proxy_set_header Host $BE_HOST;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }

    location /oauth/ {
        proxy_pass http://$BE_APP_HOST:4000;
        proxy_set_header Host $BE_HOST;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }

    location /.well-known/ {
        proxy_pass http://$BE_APP_HOST:4000;
        proxy_set_header Host $BE_HOST;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }

    location /nodeinfo/ {
        proxy_pass http://$BE_APP_HOST:4000;
        proxy_set_header Host $BE_HOST;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }

    location /socket/ {
        proxy_pass http://$BE_APP_HOST:4000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $BE_HOST;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF
}

ensure_smoke_ca() {
    mkdir -p "$SMOKE_CA_DIR"

    if [ -f "$SMOKE_CA_KEY" ] && [ -f "$SMOKE_CA_CERT" ]; then
        return 0
    fi

    if ! command -v openssl >/dev/null 2>&1; then
        fail "openssl is required to create the smoke TLS CA"
    fi

    openssl req \
        -x509 \
        -nodes \
        -newkey rsa:2048 \
        -sha256 \
        -keyout "$SMOKE_CA_KEY" \
        -out "$SMOKE_CA_CERT" \
        -days 2 \
        -subj "/CN=Unfathomably federation smoke CA" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        >/dev/null 2>&1
}

write_smoke_server_certificate() {
    local cert_dir="$1"
    local key_path="$2"
    local cert_path="$3"
    local common_name="$4"
    local subject_alt_name="$5"
    local csr_path="$cert_dir/server.csr"
    local ext_path="$cert_dir/server.ext"

    mkdir -p "$cert_dir"
    ensure_smoke_ca

    cat >"$ext_path" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=$subject_alt_name
EOF

    openssl req \
        -nodes \
        -newkey rsa:2048 \
        -sha256 \
        -keyout "$key_path" \
        -out "$csr_path" \
        -subj "/CN=$common_name" \
        >/dev/null 2>&1

    openssl x509 \
        -req \
        -in "$csr_path" \
        -CA "$SMOKE_CA_CERT" \
        -CAkey "$SMOKE_CA_KEY" \
        -CAcreateserial \
        -out "$cert_path" \
        -days 2 \
        -sha256 \
        -extfile "$ext_path" \
        >/dev/null 2>&1
}

write_be_proxy_config() {
    mkdir -p "$(dirname "$BE_NGINX_CONF")" "$BE_CERT_DIR"

    write_smoke_server_certificate \
        "$BE_CERT_DIR" \
        "$BE_CERT_DIR/be.key" \
        "$BE_CERT_DIR/be.crt" \
        "$BE_HOST" \
        "DNS:$BE_HOST,DNS:$BE_APP_HOST"

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

write_mastodon_proxy_config() {
    mkdir -p "$(dirname "$MASTODON_NGINX_CONF")" "$MASTODON_CERT_DIR"

    write_smoke_server_certificate \
        "$MASTODON_CERT_DIR" \
        "$MASTODON_CERT_DIR/mastodon.key" \
        "$MASTODON_CERT_DIR/mastodon.crt" \
        "$MASTODON_HOST" \
        "DNS:$MASTODON_HOST,DNS:$MASTODON_APP_HOST"

    cat >"$MASTODON_NGINX_CONF" <<EOF
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://$MASTODON_APP_HOST:3000;
        proxy_set_header Host $MASTODON_HOST;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Ssl on;
    }
}

server {
    listen 443 ssl;
    server_name _;

    ssl_certificate /etc/nginx/certs/mastodon.crt;
    ssl_certificate_key /etc/nginx/certs/mastodon.key;

    location / {
        proxy_pass http://$MASTODON_APP_HOST:3000;
        proxy_set_header Host $MASTODON_HOST;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Ssl on;
    }
}
EOF
}

start_frontend_gateway() {
    docker run -d \
        --name "$FE_CONTAINER" \
        --hostname unfathomably-fe \
        --network "$NETWORK" \
        --network-alias unfathomably-fe \
        -p "127.0.0.1:$FE_PORT:8080" \
        -v "$FE_STATIC_ROOT:/usr/share/nginx/html:ro" \
        -v "$NGINX_CONF:/etc/nginx/conf.d/default.conf:ro" \
        nginx:1.27-alpine >/dev/null
}

poll_json_assert() {
    local url="$1"
    local token="$2"
    local host_header="$3"
    local expression="$4"
    local message="$5"

    for _ in $(seq 1 60); do
        local body

        if [ "$host_header" = "mastodon" ]; then
            body="$(mastodon_json GET "$url" "$token" 200)"
        else
            body="$(http_json GET "$url" "$token" 200)"
        fi

        if JSON_BODY="$body" python3 - "$expression" <<'PY'
import json
import os
import sys

data = json.loads(os.environ["JSON_BODY"])
helpers = {"any": any, "all": all, "len": len, "str": str}
sys.exit(0 if eval(sys.argv[1], {"__builtins__": {}}, {"data": data, **helpers}) else 1)
PY
        then
            printf '%s' "$body"
            return 0
        fi

        sleep 2
    done

    fail "Timed out waiting for $message"
}

poll_http_status() {
    local method="$1"
    local url="$2"
    local token="$3"
    local host_header="$4"
    local expected="$5"
    local message="$6"
    local attempts="${7:-60}"
    local delay="${8:-2}"
    local tmp
    local code
    local last_code

    last_code=""

    for _ in $(seq 1 "$attempts"); do
        tmp="$(mktemp)"

        local args=(-sS -X "$method" -o "$tmp" -w "%{http_code}")

        if [ -n "$token" ]; then
            args+=(-H "Authorization: Bearer $token")
        fi

        if [ "$host_header" = "mastodon" ]; then
            args+=(-H "Host: $MASTODON_HOST" -H "X-Forwarded-Proto: https" -H "X-Forwarded-Ssl: on")
        fi

        code="$(curl "${args[@]}" "$url" || true)"
        rm -f "$tmp"
        last_code="$code"

        if [ "$code" = "$expected" ]; then
            return 0
        fi

        sleep "$delay"
    done

    fail "Timed out waiting for $message (wanted HTTP $expected, last HTTP $last_code)"
}

resolve_remote_status_id() {
    local base="$1"
    local token="$2"
    local host_header="$3"
    local uri="$4"
    local message="$5"
    local search_result

    search_result="$(poll_json_assert \
        "$base/api/v2/search?resolve=true&type=statuses&q=$(urlencode "$uri")" \
        "$token" \
        "$host_header" \
        'len(data.get("statuses", [])) >= 1' \
        "$message")"

    json_get "$search_result" statuses.0.id
}

poll_timeline_contains_text() {
    local base="$1"
    local token="$2"
    local host_header="$3"
    local path="$4"
    local needle="$5"
    local message="$6"

    poll_json_assert \
        "$base$path" \
        "$token" \
        "$host_header" \
        "'$needle' in str(data)" \
        "$message" >/dev/null
}

step "Cleaning any previous Mastodon smoke containers"
cleanup

step "Preparing smoke working directories"
rm -rf "$WORK_DIR/be" "$WORK_DIR/mastodon" "$WORK_DIR/be-nginx" "$WORK_DIR/be-certs" "$WORK_DIR/mastodon-nginx" "$WORK_DIR/mastodon-certs" "$WORK_DIR/runtime-$BE_HOST"
mkdir -p "$WORK_DIR/be" "$WORK_DIR/mastodon" "$WORK_DIR/nginx" "$WORK_DIR/be-nginx" "$WORK_DIR/be-certs" "$WORK_DIR/mastodon-nginx" "$WORK_DIR/mastodon-certs" "$WORK_DIR/logs"

step "Preparing frontend static assets"
prepare_frontend_static
write_nginx_config
write_be_proxy_config
write_mastodon_proxy_config

step "Writing generated smoke configs"
write_be_secret "$BE_SECRET" "Unfathomably BE Mastodon Smoke" "$BE_HOST" "unfathomably_mastodon_smoke_be" "$WORK_DIR/be/uploads" "$WORK_DIR/be/static"
write_mastodon_env

step "Creating Docker network, PostgreSQL, and Redis"
docker network create "$NETWORK" >/dev/null

docker run -d \
    --name "$DB_CONTAINER" \
    --network "$NETWORK" \
    -e POSTGRES_PASSWORD="$DB_PASSWORD" \
    postgres:17 >/dev/null

docker run -d \
    --name "$REDIS_CONTAINER" \
    --network "$NETWORK" \
    redis:7-alpine >/dev/null

for _ in $(seq 1 60); do
    if docker exec "$DB_CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

if ! docker exec "$DB_CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then
    fail "PostgreSQL did not become ready"
fi

step "Checking unfathomably-be dev compile"
strict_compile_backend

step "Migrating unfathomably-be and Mastodon databases"
prepare_be_database
prepare_mastodon_database

step "Creating smoke users"
create_be_user "be" "alice" "alice@$BE_HOST"
create_be_user "be" "moda" "moda@$BE_HOST"
create_be_user "be" "thirda" "thirda@$BE_HOST"
create_mastodon_user

BE_BASE="http://127.0.0.1:$BE_PORT"
FE_BASE="http://127.0.0.1:$FE_PORT"
MASTODON_BASE="http://127.0.0.1:$MASTODON_PORT"

step "Starting unfathomably-be"
start_be
start_be_proxy
wait_http "$BE_BASE/api/v1/instance" "unfathomably-be"

step "Starting unfathomably-fe gateway"
start_frontend_gateway
wait_http "$FE_BASE/" "unfathomably-fe"

step "Starting Mastodon web and Sidekiq"
start_mastodon
wait_http "$MASTODON_BASE/api/v1/instance" "Mastodon" -H "Host: $MASTODON_HOST"

step "Creating OAuth tokens"
ALICE_TOKEN="$(create_be_token "$BE_BASE" "alice")"
MODA_TOKEN="$(create_be_token "$BE_BASE" "moda")"
THIRDA_TOKEN="$(create_be_token "$BE_BASE" "thirda")"
PAT_TOKEN="$(create_mastodon_token)"

ALICE_ACCOUNT="$(http_json GET "$BE_BASE/api/v1/accounts/verify_credentials" "$ALICE_TOKEN" 200)"
MODA_ACCOUNT="$(http_json GET "$BE_BASE/api/v1/accounts/verify_credentials" "$MODA_TOKEN" 200)"
THIRDA_ACCOUNT="$(http_json GET "$BE_BASE/api/v1/accounts/verify_credentials" "$THIRDA_TOKEN" 200)"
PAT_ACCOUNT="$(mastodon_json GET "$MASTODON_BASE/api/v1/accounts/verify_credentials" "$PAT_TOKEN" 200)"

MODA_ID="$(json_get "$MODA_ACCOUNT" id)"
THIRDA_ID="$(json_get "$THIRDA_ACCOUNT" id)"

step "Checking FE-to-BE same-origin wiring"
FE_INDEX="$(curl -fsS "$FE_BASE/")"
case "$FE_INDEX" in
    *"<html"*|*"<!doctype html"*|*"<!DOCTYPE html"*) ;;
    *) fail "frontend index did not look like an HTML application shell" ;;
esac

FE_INSTANCE="$(http_json GET "$FE_BASE/api/v1/instance" "" 200)"
json_assert "$FE_INSTANCE" 'len(data) > 0' "frontend gateway proxies instance API to unfathomably-be"

step "Checking discovery endpoints"
curl -fsS "$BE_BASE/.well-known/webfinger?resource=acct:alice@$BE_HOST" >/dev/null
curl -fsS -H "Host: $MASTODON_HOST" "$MASTODON_BASE/.well-known/webfinger?resource=acct:pat@$MASTODON_HOST" >/dev/null

BE_NODEINFO_DISCOVERY="$(curl -fsS "$BE_BASE/.well-known/nodeinfo")"
json_assert \
    "$BE_NODEINFO_DISCOVERY" \
    'data["links"][0]["rel"] == "http://nodeinfo.diaspora.software/ns/schema/2.1"' \
    "unfathomably-be advertises NodeInfo 2.1 first"

BE_NODEINFO_21="$(nodeinfo_href "$BE_NODEINFO_DISCOVERY" "http://nodeinfo.diaspora.software/ns/schema/2.1")"
curl -fsS "$BE_BASE$(url_path_and_query "$BE_NODEINFO_21")" >/dev/null

MASTODON_NODEINFO_DISCOVERY="$(curl -fsS -H "Host: $MASTODON_HOST" "$MASTODON_BASE/.well-known/nodeinfo")"
MASTODON_NODEINFO="$(nodeinfo_href "$MASTODON_NODEINFO_DISCOVERY" "http://nodeinfo.diaspora.software/ns/schema/2.1" || true)"
if [ -z "$MASTODON_NODEINFO" ]; then
    MASTODON_NODEINFO="$(nodeinfo_href "$MASTODON_NODEINFO_DISCOVERY" "http://nodeinfo.diaspora.software/ns/schema/2.0")"
fi
curl -fsS -H "Host: $MASTODON_HOST" "$MASTODON_BASE$(url_path_and_query "$MASTODON_NODEINFO")" >/dev/null

step "Testing unfathomably-be local group administration"
OPEN_GROUP="$(http_json POST "$BE_BASE/api/v1/groups" "$ALICE_TOKEN" 200 \
    "display_name=Mastodon Smoke Open Group" \
    "name=mastodon-smoke-open-group" \
    "note=Open smoke group used to prove Mastodon fails safely around Group actors." \
    "locked=false")"
OPEN_GROUP_ID="$(json_get "$OPEN_GROUP" id)"
OPEN_GROUP_AP_ID="$(json_get "$OPEN_GROUP" url)"
json_assert "$OPEN_GROUP" 'data["actor_type"] == "Group" and data.get("id")' "local open group is created"

THIRD_JOIN="$(http_json POST "$BE_BASE/api/v1/groups/$OPEN_GROUP_ID/join" "$THIRDA_TOKEN" 200)"
json_assert "$THIRD_JOIN" 'data["member"] is True' "open group accepts third account"

PROMOTE="$(http_json POST "$BE_BASE/api/v1/groups/$OPEN_GROUP_ID/promote" "$ALICE_TOKEN" 200 \
    "account_ids[]=$MODA_ID" \
    "role=moderator")"
json_assert "$PROMOTE" 'data["role"] == "moderator"' "owner promotes moderator"

http_json POST "$BE_BASE/api/v1/groups/$OPEN_GROUP_ID/blocks" "$MODA_TOKEN" 200 \
    "account_ids[]=$THIRDA_ID" >/dev/null

BLOCKS="$(http_json GET "$BE_BASE/api/v1/groups/$OPEN_GROUP_ID/blocks" "$ALICE_TOKEN" 200)"
json_assert "$BLOCKS" 'any(account["id"] == "'$THIRDA_ID'" for account in data)' "moderator ban appears in block list"

THIRD_REJOIN="$(http_json POST "$BE_BASE/api/v1/groups/$OPEN_GROUP_ID/join" "$THIRDA_TOKEN" 403)"
json_assert "$THIRD_REJOIN" 'data["error"] == "You are banned from this group"' "banned account cannot rejoin"

http_json DELETE "$BE_BASE/api/v1/groups/$OPEN_GROUP_ID/blocks" "$ALICE_TOKEN" 200 \
    "account_ids[]=$THIRDA_ID" >/dev/null

step "Testing account federation from Mastodon to unfathomably-be"
ALICE_ACCT="alice@$BE_HOST"
MASTODON_SEARCH_ALICE="$(poll_json_assert \
    "$MASTODON_BASE/api/v2/search?resolve=true&type=accounts&q=$(urlencode "$ALICE_ACCT")" \
    "$PAT_TOKEN" \
    "mastodon" \
    'len(data.get("accounts", [])) >= 1' \
    "Mastodon to resolve Alice")"
REMOTE_ALICE_ID="$(json_get "$MASTODON_SEARCH_ALICE" accounts.0.id)"

PAT_FOLLOWS_ALICE="$(mastodon_json POST "$MASTODON_BASE/api/v1/accounts/$REMOTE_ALICE_ID/follow" "$PAT_TOKEN" 200)"
json_assert "$PAT_FOLLOWS_ALICE" 'data["following"] is True or data["requested"] is True' "Mastodon can follow Alice"

step "Testing account federation from unfathomably-be to Mastodon"
PAT_ACTOR_URL="pat@$MASTODON_HOST"
REMOTE_PAT="$(poll_json_assert \
    "$BE_BASE/api/v2/search?resolve=true&type=accounts&q=$(urlencode "$PAT_ACTOR_URL")" \
    "$ALICE_TOKEN" \
    "be" \
    'len(data.get("accounts", [])) >= 1' \
    "unfathomably-be to resolve Mastodon account")"
REMOTE_PAT_ID="$(json_get "$REMOTE_PAT" accounts.0.id)"
json_assert "$REMOTE_PAT" 'len(data.get("accounts", [])) >= 1 and data["accounts"][0]["id"] != ""' "unfathomably-be resolves Mastodon account"

ALICE_FOLLOWS_PAT="$(http_json POST "$BE_BASE/api/v1/accounts/$REMOTE_PAT_ID/follow" "$ALICE_TOKEN" 200)"
json_assert "$ALICE_FOLLOWS_PAT" 'data["following"] is True or data["requested"] is True' "Alice can follow Mastodon account"

step "Testing status resolution in both directions"
BE_STATUS="$(http_json POST "$FE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
    "status=Unfathomably to Mastodon smoke post through the frontend gateway" \
    "visibility=public")"
BE_STATUS_URL="$(json_get "$BE_STATUS" url)"

MASTODON_SEARCH_STATUS="$(poll_json_assert \
    "$MASTODON_BASE/api/v2/search?resolve=true&type=statuses&q=$(urlencode "$BE_STATUS_URL")" \
    "$PAT_TOKEN" \
    "mastodon" \
    'len(data.get("statuses", [])) >= 1' \
    "Mastodon to resolve unfathomably-be status")"
REMOTE_BE_STATUS_ID="$(json_get "$MASTODON_SEARCH_STATUS" statuses.0.id)"

MASTODON_REPLY="$(mastodon_json POST "$MASTODON_BASE/api/v1/statuses" "$PAT_TOKEN" 200 \
    "status=Mastodon reply in the unfathomably interoperability smoke" \
    "visibility=public" \
    "in_reply_to_id=$REMOTE_BE_STATUS_ID")"
MASTODON_REPLY_URI="$(json_get_optional "$MASTODON_REPLY" uri)"
if [ -z "$MASTODON_REPLY_URI" ]; then
    MASTODON_REPLY_URI="$(json_get "$MASTODON_REPLY" url)"
fi

RESOLVED_MASTODON_REPLY="$(poll_json_assert \
    "$BE_BASE/api/v2/search?resolve=true&type=statuses&q=$(urlencode "$MASTODON_REPLY_URI")" \
    "$ALICE_TOKEN" \
    "be" \
    'len(data.get("statuses", [])) >= 1' \
    "unfathomably-be to resolve Mastodon reply")"
json_assert "$RESOLVED_MASTODON_REPLY" 'len(data.get("statuses", [])) >= 1' "unfathomably-be resolves Mastodon reply status"

MASTODON_STATUS="$(mastodon_json POST "$MASTODON_BASE/api/v1/statuses" "$PAT_TOKEN" 200 \
    "status=Reference Mastodon smoke post for unfathomably-be lookup" \
    "visibility=public")"
MASTODON_STATUS_URI="$(json_get_optional "$MASTODON_STATUS" uri)"
if [ -z "$MASTODON_STATUS_URI" ]; then
    MASTODON_STATUS_URI="$(json_get "$MASTODON_STATUS" url)"
fi

REMOTE_MASTODON_STATUS="$(poll_json_assert \
    "$BE_BASE/api/v2/search?resolve=true&type=statuses&q=$(urlencode "$MASTODON_STATUS_URI")" \
    "$ALICE_TOKEN" \
    "be" \
    'len(data.get("statuses", [])) >= 1' \
    "unfathomably-be to resolve Mastodon status")"
json_assert "$REMOTE_MASTODON_STATUS" 'len(data.get("statuses", [])) >= 1' "unfathomably-be resolves Mastodon status"

step "Testing Mastodon account-style interaction with an unfathomably group"

GROUP_SEARCH="$(poll_json_assert \
    "$MASTODON_BASE/api/v2/search?resolve=true&type=accounts&q=$(urlencode "$OPEN_GROUP_AP_ID")" \
    "$PAT_TOKEN" \
    "mastodon" \
    'len(data.get("accounts", [])) >= 1 and data["accounts"][0]["id"] != ""' \
    "Mastodon to resolve unfathomably group actor as a followable account")"
MASTODON_GROUP_ACCOUNT_ID="$(json_get "$GROUP_SEARCH" accounts.0.id)"
json_assert "$GROUP_SEARCH" 'data["accounts"][0].get("acct") != ""' "Mastodon exposes the group actor through ordinary account search"
OPEN_GROUP_ACCT="$(json_get "$GROUP_SEARCH" accounts.0.acct)"

PAT_FOLLOWS_GROUP="$(mastodon_json POST "$MASTODON_BASE/api/v1/accounts/$MASTODON_GROUP_ACCOUNT_ID/follow" "$PAT_TOKEN" 200)"
json_assert "$PAT_FOLLOWS_GROUP" 'data["following"] is True or data["requested"] is True' "Mastodon can follow an unfathomably group actor"

GROUP_POST_TEXT="Mastodon account-style group receive proof $PREFIX"
GROUP_POST="$(http_json POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
    "status=$GROUP_POST_TEXT" \
    "group_id=$OPEN_GROUP_ID")"
GROUP_POST_ID="$(json_get "$GROUP_POST" id)"
GROUP_POST_URI="$(json_get "$GROUP_POST" uri)"

poll_timeline_contains_text \
    "$MASTODON_BASE" \
    "$PAT_TOKEN" \
    "mastodon" \
    "/api/v1/timelines/home?limit=40" \
    "$GROUP_POST_TEXT" \
    "Mastodon receives new posts from the followed unfathomably group"

MASTODON_GROUP_POST_ID="$(resolve_remote_status_id \
    "$MASTODON_BASE" \
    "$PAT_TOKEN" \
    "mastodon" \
    "$GROUP_POST_URI" \
    "Mastodon can resolve the followed group post")"

PAT_LIKES_GROUP_POST="$(mastodon_json POST "$MASTODON_BASE/api/v1/statuses/$MASTODON_GROUP_POST_ID/favourite" "$PAT_TOKEN" 200)"
json_assert "$PAT_LIKES_GROUP_POST" 'data.get("favourited") is True' "Mastodon can like a followed group post"

poll_json_assert \
    "$BE_BASE/api/v1/statuses/$GROUP_POST_ID" \
    "$ALICE_TOKEN" \
    "be" \
    'data.get("favourites_count", 0) >= 1' \
    "unfathomably-be sees Mastodon like on a group post" >/dev/null

PAT_UNLIKES_GROUP_POST="$(mastodon_json POST "$MASTODON_BASE/api/v1/statuses/$MASTODON_GROUP_POST_ID/unfavourite" "$PAT_TOKEN" 200)"
json_assert "$PAT_UNLIKES_GROUP_POST" 'data.get("favourited") is False' "Mastodon can undo a like on a followed group post"

poll_json_assert \
    "$BE_BASE/api/v1/statuses/$GROUP_POST_ID" \
    "$ALICE_TOKEN" \
    "be" \
    'data.get("favourites_count", 0) == 0' \
    "unfathomably-be sees Mastodon unlike on a group post" >/dev/null

MASTODON_REPLY_TEXT="Mastodon account-style group reply proof $PREFIX"
MASTODON_GROUP_REPLY="$(mastodon_json POST "$MASTODON_BASE/api/v1/statuses" "$PAT_TOKEN" 200 \
    "status=$MASTODON_REPLY_TEXT" \
    "visibility=public" \
    "in_reply_to_id=$MASTODON_GROUP_POST_ID")"
MASTODON_GROUP_REPLY_ID="$(json_get "$MASTODON_GROUP_REPLY" id)"
MASTODON_GROUP_REPLY_URI="$(json_get_optional "$MASTODON_GROUP_REPLY" uri)"
if [ -z "$MASTODON_GROUP_REPLY_URI" ]; then
    MASTODON_GROUP_REPLY_URI="$(json_get "$MASTODON_GROUP_REPLY" url)"
fi

BE_VIEW_OF_MASTODON_REPLY_ID="$(resolve_remote_status_id \
    "$BE_BASE" \
    "$ALICE_TOKEN" \
    "be" \
    "$MASTODON_GROUP_REPLY_URI" \
    "unfathomably-be can resolve Mastodon reply to a group post")"

poll_timeline_contains_text \
    "$BE_BASE" \
    "$ALICE_TOKEN" \
    "be" \
    "/api/v1/timelines/group/$OPEN_GROUP_ID?with_replies=true&limit=40" \
    "$MASTODON_REPLY_TEXT" \
    "Mastodon reply appears in the unfathomably group timeline"

mastodon_json DELETE "$MASTODON_BASE/api/v1/statuses/$MASTODON_GROUP_REPLY_ID" "$PAT_TOKEN" 200 >/dev/null
poll_http_status \
    GET \
    "$BE_BASE/api/v1/statuses/$BE_VIEW_OF_MASTODON_REPLY_ID" \
    "$ALICE_TOKEN" \
    "be" \
    404 \
    "unfathomably-be sees Mastodon deleted group reply" \
    90 \
    2

http_json DELETE "$BE_BASE/api/v1/statuses/$GROUP_POST_ID" "$ALICE_TOKEN" 200 >/dev/null
poll_http_status \
    GET \
    "$MASTODON_BASE/api/v1/statuses/$MASTODON_GROUP_POST_ID" \
    "$PAT_TOKEN" \
    "mastodon" \
    404 \
    "Mastodon sees deleted unfathomably group post" \
    90 \
    2

MASTODON_TO_GROUP_TEXT="Mastodon account-style top-level group post proof $PREFIX"
MASTODON_TO_GROUP_POST="$(mastodon_json POST "$MASTODON_BASE/api/v1/statuses" "$PAT_TOKEN" 200 \
    "status=@$OPEN_GROUP_ACCT $MASTODON_TO_GROUP_TEXT" \
    "visibility=public")"
MASTODON_TO_GROUP_POST_ID="$(json_get "$MASTODON_TO_GROUP_POST" id)"
MASTODON_TO_GROUP_POST_URI="$(json_get_optional "$MASTODON_TO_GROUP_POST" uri)"
if [ -z "$MASTODON_TO_GROUP_POST_URI" ]; then
    MASTODON_TO_GROUP_POST_URI="$(json_get "$MASTODON_TO_GROUP_POST" url)"
fi

BE_VIEW_OF_MASTODON_GROUP_POST_ID="$(resolve_remote_status_id \
    "$BE_BASE" \
    "$ALICE_TOKEN" \
    "be" \
    "$MASTODON_TO_GROUP_POST_URI" \
    "unfathomably-be can resolve Mastodon top-level group mention post")"

poll_timeline_contains_text \
    "$BE_BASE" \
    "$ALICE_TOKEN" \
    "be" \
    "/api/v1/timelines/group/$OPEN_GROUP_ID?with_replies=true&limit=40" \
    "$MASTODON_TO_GROUP_TEXT" \
    "Mastodon top-level mention post appears in the unfathomably group timeline"

mastodon_json DELETE "$MASTODON_BASE/api/v1/statuses/$MASTODON_TO_GROUP_POST_ID" "$PAT_TOKEN" 200 >/dev/null
poll_http_status \
    GET \
    "$BE_BASE/api/v1/statuses/$BE_VIEW_OF_MASTODON_GROUP_POST_ID" \
    "$ALICE_TOKEN" \
    "be" \
    404 \
    "unfathomably-be sees Mastodon deleted top-level group post" \
    90 \
    2

PAT_UNFOLLOWS_GROUP="$(mastodon_json POST "$MASTODON_BASE/api/v1/accounts/$MASTODON_GROUP_ACCOUNT_ID/unfollow" "$PAT_TOKEN" 200)"
json_assert "$PAT_UNFOLLOWS_GROUP" 'data["following"] is False and data["requested"] is False' "Mastodon can unfollow an unfathomably group actor"

step "Checking no obvious server crashes were logged"
for container in "$BE_CONTAINER" "$MASTODON_WEB_CONTAINER" "$MASTODON_SIDEKIQ_CONTAINER" "$FE_CONTAINER"; do
    if docker logs "$container" 2>&1 | grep -E "status=500|Internal Server Error|\\*\\* \\(|GenServer terminating|FunctionClauseError|UndefinedFunctionError|Protocol\\.UndefinedError|FATAL|panic" >/dev/null; then
        docker logs --tail 220 "$container" >&2
        fail "$container logged a 500 or crash signature during smoke run"
    fi
done

cat <<EOF

Unfathomably plus Mastodon smoke test passed.

Covered:
  * startup, migrations, Redis, Mastodon web, Mastodon Sidekiq
  * unfathomably-fe static serving and FE-to-BE proxying
  * unfathomably-be discovery, WebFinger, NodeInfo
  * Mastodon discovery, WebFinger, NodeInfo
  * OAuth/token creation on unfathomably-be and Mastodon
  * unfathomably-be group create, open join, moderator promote, ban, block list, unban
  * Mastodon account lookup and follow of an unfathomably-be account
  * unfathomably-be account lookup and follow of a Mastodon account
  * Mastodon status resolution of an unfathomably-be status
  * unfathomably-be status resolution of Mastodon statuses and replies
  * Mastodon account-style follow, receive, like, unlike, reply, delete, post, and unfollow against an unfathomably group actor
  * basic log scan for 500/crash output

Run with KEEP_SMOKE=1 to leave the stack available for browser/API work.
Run with BUILD_FE=1 to rebuild unfathomably-fe from FE_ROOT instead of using FE_STATIC_ROOT.
Use MASTODON_IMAGE to pin a Mastodon release image instead of ghcr.io/mastodon/mastodon:latest.
EOF

# end of build_scripts/unfathomably-mastodon-smoke.sh
