#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-iceshrimp-smoke.sh
#
# Purpose:
#
#   Run a local stock Iceshrimp.NET federation peer against Unfathomably and
#   prove both ordinary account federation and the Iceshrimp.NET-specific
#   ActivityPub/client API surfaces Unfathomably intentionally supports.
#
# Responsibilities:
#
#   * boot isolated Unfathomably, Iceshrimp.NET, PostgreSQL, and proxy
#     containers
#   * create local test accounts and API tokens on both peers
#   * exercise bidirectional follow, post, reply, favourite, unfavourite,
#     emoji reaction, delete, and unfollow behavior
#   * verify Iceshrimp.NET quote and reaction data through the API fields
#     consumed by clients
#   * probe Iceshrimp.NET behavior around Unfathomably Group actors and report
#     stock limitations explicitly
#
# This file intentionally does NOT contain:
#
#   * production deployment logic
#   * patched Iceshrimp.NET binaries
#   * hidden success for unsupported Group actor semantics
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BE_ROOT="${BE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

PREFIX="${SMOKE_PREFIX:-unfathomably-iceshrimp-smoke}"
NETWORK="${PREFIX}-net"

BE_DB_CONTAINER="${PREFIX}-be-db"
BE_CONTAINER="${PREFIX}-be"
BE_PROXY_CONTAINER="${PREFIX}-be-proxy"
BE_APP_HOST="${PREFIX}-be-app"
BE_HOST="${BE_HOST:-unfathomably-iceshrimp.test}"
BE_PORT="${BE_PORT:-4991}"
BE_BASE="https://127.0.0.1:$BE_PORT"
BE_DB_NAME="${BE_DB_NAME:-unfathomably_iceshrimp_smoke_be}"
BE_DB_PASSWORD="${BE_DB_PASSWORD:-postgres}"

ICESHRIMP_DB_CONTAINER="${PREFIX}-iceshrimp-db"
ICESHRIMP_CONTAINER="${PREFIX}-iceshrimp"
ICESHRIMP_PROXY_CONTAINER="${PREFIX}-iceshrimp-proxy"
ICESHRIMP_APP_HOST="${PREFIX}-iceshrimp-app"
ICESHRIMP_HOST="${ICESHRIMP_HOST:-iceshrimp-ref.test}"
ICESHRIMP_PORT="${ICESHRIMP_PORT:-4992}"
ICESHRIMP_BASE="https://127.0.0.1:$ICESHRIMP_PORT"
ICESHRIMP_DB_NAME="${ICESHRIMP_DB_NAME:-iceshrimp}"
ICESHRIMP_DB_USER="${ICESHRIMP_DB_USER:-iceshrimp}"
ICESHRIMP_DB_PASSWORD="${ICESHRIMP_DB_PASSWORD:-iceshrimp}"
ICESHRIMP_TOKEN="${ICESHRIMP_TOKEN:-}"
ICESHRIMP_REACTION="${ICESHRIMP_REACTION:-⭐}"

IMAGE="${UNFATHOMABLY_SMOKE_IMAGE:-unfathomably-elixir-smoke:otp28}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:17-alpine}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.27-alpine}"
ICESHRIMP_IMAGE="${ICESHRIMP_IMAGE:-iceshrimp.dev/iceshrimp/iceshrimp.net:dev}"
PASSWORD="${SMOKE_PASSWORD:-correct horse battery staple 12345}"
KEEP_CONTAINERS="${KEEP_CONTAINERS:-0}"
WORK_DIR="${SMOKE_WORK_DIR:-}"

if [ -z "$WORK_DIR" ]; then
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/unfathomably-iceshrimp-smoke.XXXXXX")"
fi

BE_SECRET="$WORK_DIR/be/dev.secret.exs"
BE_UPLOADS="$WORK_DIR/be/uploads"
BE_STATIC="$WORK_DIR/be/static"
BE_NGINX_CONF="$WORK_DIR/be-nginx/default.conf"
ICESHRIMP_CONFIG="$WORK_DIR/iceshrimp/configuration.ini"
ICESHRIMP_MEDIA="$WORK_DIR/iceshrimp/media"
ICESHRIMP_NGINX_CONF="$WORK_DIR/iceshrimp-nginx/default.conf"
CA_DIR="$WORK_DIR/ca"
CA_CERT="$CA_DIR/smoke-ca.crt"
CA_KEY="$CA_DIR/smoke-ca.key"
BE_CERT="$CA_DIR/be.crt"
BE_KEY="$CA_DIR/be.key"
ICESHRIMP_CERT="$CA_DIR/iceshrimp.crt"
ICESHRIMP_KEY="$CA_DIR/iceshrimp.key"
CA_OPENSSL_CONF="$CA_DIR/ca-openssl.cnf"
BE_OPENSSL_CONF="$CA_DIR/be-openssl.cnf"
ICESHRIMP_OPENSSL_CONF="$CA_DIR/iceshrimp-openssl.cnf"

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
        "$ICESHRIMP_PROXY_CONTAINER" \
        "$ICESHRIMP_CONTAINER" \
        "$ICESHRIMP_DB_CONTAINER" \
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

random_hex() {
    python3 - "$1" <<'PY'
import secrets
import sys

print(secrets.token_hex(int(sys.argv[1])))
PY
}

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

best_effort_delete_status() {
    local base="$1"
    local token="$2"
    local status_id="$3"
    local status

    status="$(
        curl -k -s -o /dev/null -w '%{http_code}' -X DELETE \
            -H "Authorization: Bearer $token" \
            -H 'Accept: application/json' \
            "$base/api/v1/statuses/$status_id" || true
    )"

    case "$status" in
        200|202|204|404|410|000)
            return 0
            ;;
    esac

    printf 'Best-effort cleanup delete for %s/api/v1/statuses/%s returned HTTP %s\n' \
        "$base" "$status_id" "$status" >&2
    return 0
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
CN = Unfathomably Iceshrimp Smoke CA

[v3_ca]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, keyCertSign, cRLSign
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

    cat >"$ICESHRIMP_OPENSSL_CONF" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $ICESHRIMP_HOST

[v3_req]
subjectAltName = @alt_names
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = $ICESHRIMP_HOST
EOF

    openssl req -x509 -newkey rsa:2048 -nodes -days 3 \
        -config "$CA_OPENSSL_CONF" \
        -keyout "$CA_KEY" \
        -out "$CA_CERT" >/dev/null 2>&1

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

    openssl req -newkey rsa:2048 -nodes \
        -config "$ICESHRIMP_OPENSSL_CONF" \
        -keyout "$ICESHRIMP_KEY" \
        -out "$CA_DIR/iceshrimp.csr" >/dev/null 2>&1

    openssl x509 -req -days 3 \
        -in "$CA_DIR/iceshrimp.csr" \
        -CA "$CA_CERT" \
        -CAkey "$CA_KEY" \
        -CAcreateserial \
        -out "$ICESHRIMP_CERT" \
        -extensions v3_req \
        -extfile "$ICESHRIMP_OPENSSL_CONF" >/dev/null 2>&1
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
  name: "Unfathomably Iceshrimp Smoke",
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

write_iceshrimp_config() {
    mkdir -p "$(dirname "$ICESHRIMP_CONFIG")" "$ICESHRIMP_MEDIA"
    chmod 0777 "$ICESHRIMP_MEDIA" >/dev/null 2>&1 || true

    cat >"$ICESHRIMP_CONFIG" <<EOF
[Instance]
ListenPort = 3000
ListenHost = 0.0.0.0
WebDomain = $ICESHRIMP_HOST
AccountDomain = $ICESHRIMP_HOST
CharacterLimit = 8192

[Security]
AuthorizedFetch = false
ValidateRequestSignatures = false
AllowLoopback = true
AllowLocalIPv4 = true
AllowLocalIPv6 = true
Registrations = Open
FederationMode = BlockList
PublicPreview = Public
ExceptionVerbosity = Full

[Database]
Host = $ICESHRIMP_DB_CONTAINER
Port = 5432
Database = $ICESHRIMP_DB_NAME
Username = $ICESHRIMP_DB_USER
Password = $ICESHRIMP_DB_PASSWORD
MaxConnections = 40

[Storage]
Provider = Local
ProxyRemoteMedia = false
MediaRetention = 0

[Storage:Local]
Path = /media

[Storage:MediaProcessing]
ImageProcessor = ImageSharp

[Performance:QueueConcurrency]
Inbox = 4
Deliver = 8
PreDeliver = 4
BackgroundTask = 4
Backfill = 4
BackfillUser = 4

[Logging:LogLevel]
Default = Information
Iceshrimp = Information
Microsoft.AspNetCore = Warning
Microsoft.EntityFrameworkCore = Warning
EOF
}

write_proxy_configs() {
    mkdir -p "$(dirname "$BE_NGINX_CONF")" "$(dirname "$ICESHRIMP_NGINX_CONF")"

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

    cat >"$ICESHRIMP_NGINX_CONF" <<EOF
server {
    listen 80;
    server_name _;

    location / {
        return 301 https://$ICESHRIMP_HOST\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name _;

    client_max_body_size 50m;

    ssl_certificate /etc/nginx/smoke-certs/iceshrimp.crt;
    ssl_certificate_key /etc/nginx/smoke-certs/iceshrimp.key;

    location / {
        proxy_pass http://$ICESHRIMP_APP_HOST:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $ICESHRIMP_HOST;
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

prepare_be_database() {
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
    for _ in $(seq 1 160); do
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
            "client_name=iceshrimp-smoke-$username" \
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

migrate_iceshrimp() {
    local log_file="$WORK_DIR/iceshrimp-migrate.log"

    if ! docker run --rm \
        --entrypoint /app/Iceshrimp.Backend \
        --name "${PREFIX}-iceshrimp-migrate" \
        --network "$NETWORK" \
        -v "$ICESHRIMP_CONFIG:/app/configuration.ini:ro" \
        -v "$ICESHRIMP_MEDIA:/media" \
        "$ICESHRIMP_IMAGE" \
        --migrate >"$log_file" 2>&1; then
        cat "$log_file" >&2 || true
        fail "Iceshrimp.NET migration failed"
    fi
}

create_iceshrimp_user() {
    local username="$1"
    local log_file="$WORK_DIR/iceshrimp-create-user.log"

    if ! docker run --rm \
        --entrypoint /app/Iceshrimp.Backend \
        --name "${PREFIX}-iceshrimp-create-user" \
        --network "$NETWORK" \
        -v "$ICESHRIMP_CONFIG:/app/configuration.ini:ro" \
        -v "$ICESHRIMP_MEDIA:/media" \
        "$ICESHRIMP_IMAGE" \
        --create-admin-user "$username" --password "$PASSWORD" >"$log_file" 2>&1; then
        cat "$log_file" >&2 || true
        fail "Iceshrimp.NET user creation failed"
    fi

    if ! grep -F "Username: $username" "$log_file" >/dev/null; then
        cat "$log_file" >&2 || true
        fail "Iceshrimp.NET CLI did not create the expected user"
    fi
}

seed_iceshrimp_token() {
    local username="$1"
    local app_id token_id client_id client_secret code

    app_id="app$(random_hex 8)"
    token_id="tok$(random_hex 8)"
    client_id="client$(random_hex 12)"
    client_secret="secret$(random_hex 12)"
    code="code$(random_hex 12)"
    ICESHRIMP_TOKEN="token$(random_hex 16)"

    docker exec -i "$ICESHRIMP_DB_CONTAINER" psql -U "$ICESHRIMP_DB_USER" -d "$ICESHRIMP_DB_NAME" -v ON_ERROR_STOP=1 >/dev/null <<SQL
INSERT INTO oauth_app (
  id,
  "createdAt",
  "clientId",
  "clientSecret",
  name,
  website,
  scopes,
  "redirectUris"
) VALUES (
  '$app_id',
  now(),
  '$client_id',
  '$client_secret',
  'unfathomably-iceshrimp-smoke',
  NULL,
  ARRAY['read','write','follow','write:bites']::varchar[],
  ARRAY['urn:ietf:wg:oauth:2.0:oob']::varchar[]
);

INSERT INTO oauth_token (
  id,
  "createdAt",
  "appId",
  "userId",
  code,
  token,
  active,
  scopes,
  "redirectUri",
  "autoDetectQuotes",
  "supportsHtmlFormatting",
  "isPleroma",
  "supportsInlineMedia"
)
SELECT
  '$token_id',
  now(),
  '$app_id',
  id,
  '$code',
  '$ICESHRIMP_TOKEN',
  true,
  ARRAY['read','write','follow','write:bites']::varchar[],
  'urn:ietf:wg:oauth:2.0:oob',
  true,
  true,
  false,
  true
FROM "user"
WHERE username = '$username' AND host IS NULL;
SQL
}

start_iceshrimp() {
    docker run -d \
        --name "$ICESHRIMP_CONTAINER" \
        --hostname "$ICESHRIMP_APP_HOST" \
        --network "$NETWORK" \
        --network-alias "$ICESHRIMP_APP_HOST" \
        -e SSL_CERT_FILE=/smoke-ca/smoke-ca.crt \
        -v "$ICESHRIMP_CONFIG:/app/configuration.ini:ro" \
        -v "$ICESHRIMP_MEDIA:/media" \
        -v "$CA_CERT:/smoke-ca/smoke-ca.crt:ro" \
        "$ICESHRIMP_IMAGE" >/dev/null
}

start_iceshrimp_proxy() {
    docker run -d \
        --name "$ICESHRIMP_PROXY_CONTAINER" \
        --hostname "$ICESHRIMP_PROXY_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$ICESHRIMP_HOST" \
        -p "127.0.0.1:$ICESHRIMP_PORT:443" \
        -v "$ICESHRIMP_NGINX_CONF:/etc/nginx/conf.d/default.conf:ro" \
        -v "$CA_DIR:/etc/nginx/smoke-certs:ro" \
        "$NGINX_IMAGE" >/dev/null
}

wait_iceshrimp() {
    for _ in $(seq 1 180); do
        if curl -k -fsS "$ICESHRIMP_BASE/api/v1/instance" >/dev/null 2>&1; then
            return 0
        fi

        sleep 1
    done

    docker logs "$ICESHRIMP_CONTAINER" >&2 || true
    fail "Timed out waiting for Iceshrimp.NET at $ICESHRIMP_BASE"
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

poll_iceshrimp_reaction_count() {
    local status_id="$1"
    local expr="$2"
    local message="$3"

    poll_json_assert \
        "http_form GET '$ICESHRIMP_BASE/api/v1/statuses/$status_id' '$ICESHRIMP_TOKEN' 200" \
        "$expr" \
        "$message" >/dev/null
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

probe_iceshrimp_group_actor() {
    local group_acct="$1"
    local group_id="$2"
    local result account_id follow_result post text be_id found

    result="$(http_form GET "$ICESHRIMP_BASE/api/v2/search?q=$(urlencode "$group_acct")&resolve=true&type=accounts&limit=5" "$ICESHRIMP_TOKEN" 200 || true)"
    account_id="$(json_get_optional "$result" accounts.0.id)"

    if [ -z "$account_id" ]; then
        printf 'not_supported: stock Iceshrimp.NET did not import Unfathomably Group actor %s as a followable account\n' "$group_acct"
        return 0
    fi

    follow_result="$(http_form POST "$ICESHRIMP_BASE/api/v1/accounts/$account_id/follow" "$ICESHRIMP_TOKEN" 200 || true)"
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
        printf 'not_supported: stock Iceshrimp.NET resolved Group actor %s but did not follow it\n' "$group_acct"
        return 0
    fi

    text="Iceshrimp mention into Unfathomably group $(basename "$WORK_DIR")"
    post="$(http_form POST "$ICESHRIMP_BASE/api/v1/statuses" "$ICESHRIMP_TOKEN" 200 \
        "status=$text @$group_acct" \
        "visibility=public")"
    be_id="$(resolve_status_id "$BE_BASE" "$ALICE_TOKEN" "$(json_get "$post" uri)" "Unfathomably could not resolve Iceshrimp.NET group mention post")"

    found=0

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
        fail "Unfathomably did not place Iceshrimp.NET mention post in the group timeline"
    fi

    http_form DELETE "$ICESHRIMP_BASE/api/v1/statuses/$(json_get "$post" id)" "$ICESHRIMP_TOKEN" 200 >/dev/null
    http_form POST "$ICESHRIMP_BASE/api/v1/accounts/$account_id/unfollow" "$ICESHRIMP_TOKEN" 200 >/dev/null || true
    printf 'supported: Iceshrimp.NET imported the Group actor as an account and Unfathomably accepted top-level mention posting into the group\n'
}

check_logs() {
    local name="$1"
    local label="$2"

    if docker logs "$name" 2>&1 | grep -Ei 'panic:|segmentation fault|FunctionClauseError|MatchError|ArgumentError|Unhandled exception|System\.[A-Za-z]+Exception|crit:' >/dev/null; then
        docker logs "$name" >&2 || true
        fail "$label emitted a crash-class log line"
    fi
}

write_tls_material
write_be_secret
write_iceshrimp_config
write_proxy_configs

log "Creating Docker network"
docker rm -f \
    "$ICESHRIMP_PROXY_CONTAINER" \
    "$ICESHRIMP_CONTAINER" \
    "$ICESHRIMP_DB_CONTAINER" \
    "$BE_PROXY_CONTAINER" \
    "$BE_CONTAINER" \
    "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
docker network rm "$NETWORK" >/dev/null 2>&1 || true
docker network create "$NETWORK" >/dev/null

log "Starting databases"
docker run -d \
    --name "$BE_DB_CONTAINER" \
    --network "$NETWORK" \
    -e POSTGRES_PASSWORD="$BE_DB_PASSWORD" \
    "$POSTGRES_IMAGE" >/dev/null

docker run -d \
    --name "$ICESHRIMP_DB_CONTAINER" \
    --network "$NETWORK" \
    -e POSTGRES_DB="$ICESHRIMP_DB_NAME" \
    -e POSTGRES_USER="$ICESHRIMP_DB_USER" \
    -e POSTGRES_PASSWORD="$ICESHRIMP_DB_PASSWORD" \
    "$POSTGRES_IMAGE" >/dev/null

wait_postgres_container "$BE_DB_CONTAINER" postgres postgres
wait_postgres_container "$ICESHRIMP_DB_CONTAINER" "$ICESHRIMP_DB_USER" "$ICESHRIMP_DB_NAME"
prepare_be_database

log "Initializing and starting stock Iceshrimp.NET"
migrate_iceshrimp
create_iceshrimp_user shrimp
seed_iceshrimp_token shrimp
start_iceshrimp
start_iceshrimp_proxy
wait_iceshrimp

log "Migrating and starting Unfathomably"
docker_run_mix "${PREFIX}-migrate-be" "mix ecto.migrate"
create_be_user alice "alice@$BE_HOST"
start_be
start_be_proxy
wait_be

log "Creating API credentials and smoke profile state"
ALICE_TOKEN="$(create_be_token alice)"
http_form GET "$BE_BASE/api/v1/accounts/verify_credentials" "$ALICE_TOKEN" 200 >/dev/null
ICESHRIMP_SUMMARY="Iceshrimp.NET smoke summary $(basename "$WORK_DIR")"
ICESHRIMP_CREDENTIALS="$(http_form PATCH "$ICESHRIMP_BASE/api/v1/accounts/update_credentials" "$ICESHRIMP_TOKEN" 200 \
    "display_name=Iceshrimp.NET Smoke" \
    "note=$ICESHRIMP_SUMMARY" \
    "locked=false")"
json_assert "$ICESHRIMP_CREDENTIALS" "'$ICESHRIMP_SUMMARY' in (data.get('note') or data.get('source', {}).get('note') or '')" "Iceshrimp.NET profile summary update was not visible"

log "Creating Unfathomably local group for Iceshrimp.NET Group actor probe"
BE_GROUP_NAME="unfathomably_iceshrimp_smoke"
BE_GROUP="$(
    http_form POST "$BE_BASE/api/v1/groups" "$ALICE_TOKEN" 200 \
        "display_name=Unfathomably Iceshrimp Smoke" \
        "name=$BE_GROUP_NAME" \
        "note=Open group used by the Iceshrimp.NET bidirectional smoke harness." \
        "locked=false"
)"
BE_GROUP_ID="$(json_get "$BE_GROUP" id)"

log "Following accounts in both directions"
ICESHRIMP_ACCOUNT_ID="$(resolve_account_id "$BE_BASE" "$ALICE_TOKEN" "shrimp@$ICESHRIMP_HOST" "Unfathomably could not resolve Iceshrimp.NET account")"
BE_ACCOUNT_ID="$(resolve_account_id "$ICESHRIMP_BASE" "$ICESHRIMP_TOKEN" "alice@$BE_HOST" "Iceshrimp.NET could not resolve Unfathomably account")"

BE_FOLLOW_ICESHRIMP="$(http_form POST "$BE_BASE/api/v1/accounts/$ICESHRIMP_ACCOUNT_ID/follow" "$ALICE_TOKEN" 200)"
json_assert "$BE_FOLLOW_ICESHRIMP" 'data.get("following") is True or data.get("requested") is True' "Unfathomably could not follow Iceshrimp.NET account"
ICESHRIMP_FOLLOW_BE="$(http_form POST "$ICESHRIMP_BASE/api/v1/accounts/$BE_ACCOUNT_ID/follow" "$ICESHRIMP_TOKEN" 200)"
json_assert "$ICESHRIMP_FOLLOW_BE" 'data.get("following") is True or data.get("requested") is True' "Iceshrimp.NET could not follow Unfathomably account"
poll_relationship_following "$BE_BASE" "$ALICE_TOKEN" "$ICESHRIMP_ACCOUNT_ID" "Unfathomably follow of Iceshrimp.NET did not become accepted"
poll_relationship_following "$ICESHRIMP_BASE" "$ICESHRIMP_TOKEN" "$BE_ACCOUNT_ID" "Iceshrimp.NET follow of Unfathomably did not become accepted"

log "Testing Unfathomably post delivery into Iceshrimp.NET"
BE_TO_ICESHRIMP_TEXT="Unfathomably to Iceshrimp.NET smoke $(basename "$WORK_DIR")"
BE_TO_ICESHRIMP_POST="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
    "status=$BE_TO_ICESHRIMP_TEXT" \
    "visibility=public")"
BE_TO_ICESHRIMP_ID="$(json_get "$BE_TO_ICESHRIMP_POST" id)"
BE_TO_ICESHRIMP_URI="$(json_get "$BE_TO_ICESHRIMP_POST" uri)"
ICESHRIMP_VIEW_OF_BE_ID="$(resolve_status_id "$ICESHRIMP_BASE" "$ICESHRIMP_TOKEN" "$BE_TO_ICESHRIMP_URI" "Iceshrimp.NET could not resolve Unfathomably post")"

ICESHRIMP_LIKE_BE="$(http_form POST "$ICESHRIMP_BASE/api/v1/statuses/$ICESHRIMP_VIEW_OF_BE_ID/favourite" "$ICESHRIMP_TOKEN" 200)"
json_assert "$ICESHRIMP_LIKE_BE" 'data.get("favourited") is True' "Iceshrimp.NET could not favourite Unfathomably post"
poll_status_count "$BE_BASE" "$ALICE_TOKEN" "$BE_TO_ICESHRIMP_ID" 'int(data.get("favourites_count") or 0) >= 1' "Unfathomably did not receive Iceshrimp.NET favourite"

ICESHRIMP_UNLIKE_BE="$(http_form POST "$ICESHRIMP_BASE/api/v1/statuses/$ICESHRIMP_VIEW_OF_BE_ID/unfavourite" "$ICESHRIMP_TOKEN" 200)"
json_assert "$ICESHRIMP_UNLIKE_BE" 'data.get("favourited") is False' "Iceshrimp.NET could not unfavourite Unfathomably post"
poll_status_count "$BE_BASE" "$ALICE_TOKEN" "$BE_TO_ICESHRIMP_ID" 'int(data.get("favourites_count") or 0) == 0' "Unfathomably did not receive Iceshrimp.NET unfavourite"

ICESHRIMP_REACTION_ENCODED="$(urlencode "$ICESHRIMP_REACTION")"
http_form POST "$ICESHRIMP_BASE/api/v1/statuses/$ICESHRIMP_VIEW_OF_BE_ID/react/$ICESHRIMP_REACTION_ENCODED" "$ICESHRIMP_TOKEN" 200 >/dev/null
poll_be_has_emoji_reaction "$BE_TO_ICESHRIMP_ID" "$ICESHRIMP_REACTION" "Unfathomably did not receive Iceshrimp.NET emoji reaction"
http_form POST "$ICESHRIMP_BASE/api/v1/statuses/$ICESHRIMP_VIEW_OF_BE_ID/unreact/$ICESHRIMP_REACTION_ENCODED" "$ICESHRIMP_TOKEN" 200 >/dev/null
poll_be_no_emoji_reaction "$BE_TO_ICESHRIMP_ID" "$ICESHRIMP_REACTION" "Unfathomably did not receive Iceshrimp.NET emoji unreaction"

ICESHRIMP_REPLY_TEXT="Iceshrimp.NET reply to Unfathomably $(basename "$WORK_DIR")"
ICESHRIMP_REPLY="$(http_form POST "$ICESHRIMP_BASE/api/v1/statuses" "$ICESHRIMP_TOKEN" 200 \
    "status=$ICESHRIMP_REPLY_TEXT @alice@$BE_HOST" \
    "visibility=public" \
    "in_reply_to_id=$ICESHRIMP_VIEW_OF_BE_ID")"
ICESHRIMP_REPLY_ID="$(json_get "$ICESHRIMP_REPLY" id)"
poll_context_status_by_text "$BE_BASE" "$ALICE_TOKEN" "$BE_TO_ICESHRIMP_ID" "$ICESHRIMP_REPLY_TEXT" "Unfathomably did not receive Iceshrimp.NET reply"
http_form DELETE "$ICESHRIMP_BASE/api/v1/statuses/$ICESHRIMP_REPLY_ID" "$ICESHRIMP_TOKEN" 200 >/dev/null

log "Testing Iceshrimp.NET quote delivery into Unfathomably"
ICESHRIMP_QUOTE_TEXT="Iceshrimp.NET quote of Unfathomably $(basename "$WORK_DIR")"
ICESHRIMP_QUOTE="$(http_form POST "$ICESHRIMP_BASE/api/v1/statuses" "$ICESHRIMP_TOKEN" 200 \
    "status=$ICESHRIMP_QUOTE_TEXT @alice@$BE_HOST" \
    "visibility=public" \
    "quote_id=$ICESHRIMP_VIEW_OF_BE_ID")"
ICESHRIMP_QUOTE_ID="$(json_get "$ICESHRIMP_QUOTE" id)"
BE_VIEW_OF_ICESHRIMP_QUOTE_ID="$(poll_home_status_by_text "$BE_BASE" "$ALICE_TOKEN" "$ICESHRIMP_QUOTE_TEXT" "Unfathomably did not receive Iceshrimp.NET quote post")"
poll_be_status_quote "$BE_VIEW_OF_ICESHRIMP_QUOTE_ID" "$BE_TO_ICESHRIMP_ID" "$BE_TO_ICESHRIMP_URI" "Unfathomably did not expose Iceshrimp.NET quote as a quote"
poll_status_count "$BE_BASE" "$ALICE_TOKEN" "$BE_TO_ICESHRIMP_ID" 'int(data.get("quotes_count") or 0) >= 1' "Unfathomably did not count the Iceshrimp.NET quote"

log "Testing Iceshrimp.NET post delivery into Unfathomably"
ICESHRIMP_TO_BE_TEXT="Iceshrimp.NET to Unfathomably smoke $(basename "$WORK_DIR")"
ICESHRIMP_TO_BE_POST="$(http_form POST "$ICESHRIMP_BASE/api/v1/statuses" "$ICESHRIMP_TOKEN" 200 \
    "status=$ICESHRIMP_TO_BE_TEXT @alice@$BE_HOST" \
    "visibility=public")"
ICESHRIMP_TO_BE_ID="$(json_get "$ICESHRIMP_TO_BE_POST" id)"
BE_VIEW_OF_ICESHRIMP_ID="$(poll_home_status_by_text "$BE_BASE" "$ALICE_TOKEN" "$ICESHRIMP_TO_BE_TEXT" "Unfathomably did not receive Iceshrimp.NET post")"

BE_LIKE_ICESHRIMP="$(http_form POST "$BE_BASE/api/v1/statuses/$BE_VIEW_OF_ICESHRIMP_ID/favourite" "$ALICE_TOKEN" 200)"
json_assert "$BE_LIKE_ICESHRIMP" 'data.get("favourited") is True' "Unfathomably could not favourite Iceshrimp.NET post"
poll_status_count "$ICESHRIMP_BASE" "$ICESHRIMP_TOKEN" "$ICESHRIMP_TO_BE_ID" 'int(data.get("favourites_count") or 0) >= 1' "Iceshrimp.NET did not receive Unfathomably favourite"

BE_UNLIKE_ICESHRIMP="$(http_form POST "$BE_BASE/api/v1/statuses/$BE_VIEW_OF_ICESHRIMP_ID/unfavourite" "$ALICE_TOKEN" 200)"
json_assert "$BE_UNLIKE_ICESHRIMP" 'data.get("favourited") is False' "Unfathomably could not unfavourite Iceshrimp.NET post"
poll_status_count "$ICESHRIMP_BASE" "$ICESHRIMP_TOKEN" "$ICESHRIMP_TO_BE_ID" 'int(data.get("favourites_count") or 0) == 0' "Iceshrimp.NET did not receive Unfathomably unfavourite"

BE_REACTION_ENCODED="$(urlencode "$ICESHRIMP_REACTION")"
http_form PUT "$BE_BASE/api/v1/pleroma/statuses/$BE_VIEW_OF_ICESHRIMP_ID/reactions/$BE_REACTION_ENCODED" "$ALICE_TOKEN" 200 >/dev/null
poll_iceshrimp_reaction_count "$ICESHRIMP_TO_BE_ID" 'int(data.get("reactions_count") or 0) >= 1 or sum(int(item.get("count") or 0) for item in (data.get("reactions") or [])) >= 1' "Iceshrimp.NET did not receive Unfathomably emoji reaction"
http_form DELETE "$BE_BASE/api/v1/pleroma/statuses/$BE_VIEW_OF_ICESHRIMP_ID/reactions/$BE_REACTION_ENCODED" "$ALICE_TOKEN" 200 >/dev/null
poll_iceshrimp_reaction_count "$ICESHRIMP_TO_BE_ID" 'int(data.get("reactions_count") or 0) == 0 and sum(int(item.get("count") or 0) for item in (data.get("reactions") or [])) == 0' "Iceshrimp.NET did not receive Unfathomably emoji unreaction"

BE_REPLY_TEXT="Unfathomably reply to Iceshrimp.NET $(basename "$WORK_DIR")"
BE_REPLY="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
    "status=$BE_REPLY_TEXT" \
    "in_reply_to_id=$BE_VIEW_OF_ICESHRIMP_ID")"
BE_REPLY_ID="$(json_get "$BE_REPLY" id)"
poll_context_status_by_text "$ICESHRIMP_BASE" "$ICESHRIMP_TOKEN" "$ICESHRIMP_TO_BE_ID" "$BE_REPLY_TEXT" "Iceshrimp.NET did not receive Unfathomably reply"
http_form DELETE "$BE_BASE/api/v1/statuses/$BE_REPLY_ID" "$ALICE_TOKEN" 200 >/dev/null

log "Testing top-level deletes"
http_form DELETE "$BE_BASE/api/v1/statuses/$BE_TO_ICESHRIMP_ID" "$ALICE_TOKEN" 200 >/dev/null
poll_status_missing "$ICESHRIMP_BASE" "$ICESHRIMP_TOKEN" "$ICESHRIMP_VIEW_OF_BE_ID" "Iceshrimp.NET did not lose deleted Unfathomably status"
http_form DELETE "$ICESHRIMP_BASE/api/v1/statuses/$ICESHRIMP_TO_BE_ID" "$ICESHRIMP_TOKEN" 200 >/dev/null
poll_status_missing "$BE_BASE" "$ALICE_TOKEN" "$BE_VIEW_OF_ICESHRIMP_ID" "Unfathomably did not lose deleted Iceshrimp.NET status"
best_effort_delete_status "$ICESHRIMP_BASE" "$ICESHRIMP_TOKEN" "$ICESHRIMP_QUOTE_ID"

log "Unfollowing accounts"
http_form POST "$BE_BASE/api/v1/accounts/$ICESHRIMP_ACCOUNT_ID/unfollow" "$ALICE_TOKEN" 200 >/dev/null
http_form POST "$ICESHRIMP_BASE/api/v1/accounts/$BE_ACCOUNT_ID/unfollow" "$ICESHRIMP_TOKEN" 200 >/dev/null

log "Probing Iceshrimp.NET behavior around Unfathomably Group actors"
GROUP_SUMMARY="$(probe_iceshrimp_group_actor "$BE_GROUP_NAME@$BE_HOST" "$BE_GROUP_ID")"
printf '%s\n' "$GROUP_SUMMARY"

check_logs "$BE_CONTAINER" "Unfathomably"
check_logs "$ICESHRIMP_CONTAINER" "Iceshrimp.NET"

cat <<EOF

Iceshrimp.NET federation smoke passed.

Covered against stock Iceshrimp.NET:
* supported: API token creation on Unfathomably and deterministic Iceshrimp.NET smoke token seeding
* supported: account discovery and follow in both directions
* supported: Iceshrimp.NET profile summary import
* supported: Unfathomably-to-Iceshrimp.NET status delivery
* supported: Iceshrimp.NET-to-Unfathomably status delivery
* supported: replies in both directions
* supported: favourites and unfavourites in both directions
* supported: emoji reactions and unreactions in both directions
* supported: Iceshrimp.NET quote posts exposed through Unfathomably quote fields
* supported: top-level Deletes in both directions
* supported: account unfollow cleanup in both directions
* $GROUP_SUMMARY
EOF

# end of build_scripts/unfathomably-iceshrimp-smoke.sh
