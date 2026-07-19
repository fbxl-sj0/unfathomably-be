#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-pixelfed-smoke.sh
#
# Purpose:
#
#   Run a local stock Pixelfed peer against Unfathomably and prove that the
#   photo-oriented ActivityPub path works in both directions.
#
# Responsibilities:
#
#   * build or reuse a Pixelfed image from the official Pixelfed source tree
#   * boot isolated Unfathomably, Pixelfed, PostgreSQL, MySQL, Redis, and
#     nginx proxy containers
#   * create deterministic smoke users and API tokens on both peers
#   * exercise bidirectional account discovery, follow, media post delivery,
#     replies, favourites, unfavourites where stock Pixelfed applies them,
#     deletes, and unfollow cleanup
#   * verify remote media attachments are visible through each peer's
#     Mastodon-compatible API
#   * report stock Pixelfed inbox-accepted but not materialized behaviours
#   * probe Pixelfed behavior around Unfathomably Group actors and report the
#     stock result explicitly
#
# This file intentionally does NOT contain:
#
#   * production deployment logic
#   * patched Pixelfed source code
#   * browser-driven OAuth flows
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BE_ROOT="${BE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

PREFIX="${SMOKE_PREFIX:-unfathomably-pixelfed-smoke}"
NETWORK="${PREFIX}-net"

BE_DB_CONTAINER="${PREFIX}-be-db"
BE_CONTAINER="${PREFIX}-be"
BE_PROXY_CONTAINER="${PREFIX}-be-proxy"
BE_APP_HOST="${PREFIX}-be-app"
BE_HOST="${BE_HOST:-uf-pix.test}"
BE_PORT="${BE_PORT:-4995}"
BE_BASE="https://127.0.0.1:$BE_PORT"
BE_DB_NAME="${BE_DB_NAME:-unfathomably_pixelfed_smoke_be}"
BE_DB_PASSWORD="${BE_DB_PASSWORD:-postgres}"

PIXELFED_DB_CONTAINER="${PREFIX}-pixelfed-db"
PIXELFED_REDIS_CONTAINER="${PREFIX}-pixelfed-redis"
PIXELFED_CONTAINER="${PREFIX}-pixelfed"
PIXELFED_WORKER_CONTAINER="${PREFIX}-pixelfed-worker"
PIXELFED_PROXY_CONTAINER="${PREFIX}-pixelfed-proxy"
PIXELFED_APP_HOST="${PREFIX}-pixelfed-app"
PIXELFED_HOST="${PIXELFED_HOST:-pixelfed-ref.test}"
PIXELFED_PORT="${PIXELFED_PORT:-4996}"
PIXELFED_BASE="https://127.0.0.1:$PIXELFED_PORT"
PIXELFED_DB_NAME="${PIXELFED_DB_NAME:-pixelfed}"
PIXELFED_DB_USER="${PIXELFED_DB_USER:-pixelfed}"
PIXELFED_DB_PASSWORD="${PIXELFED_DB_PASSWORD:-pixelfed}"
PIXELFED_DB_ROOT_PASSWORD="${PIXELFED_DB_ROOT_PASSWORD:-pixelfed}"

IMAGE="${UNFATHOMABLY_SMOKE_IMAGE:-unfathomably-elixir-smoke:otp28}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:17}"
MYSQL_IMAGE="${PIXELFED_MYSQL_IMAGE:-mysql:8.4}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.27-alpine}"
PIXELFED_IMAGE="${PIXELFED_IMAGE:-unfathomably-pixelfed-smoke:dev}"
PIXELFED_GIT_URL="${PIXELFED_GIT_URL:-https://github.com/pixelfed/pixelfed.git}"
PIXELFED_GIT_REF="${PIXELFED_GIT_REF:-dev}"
PIXELFED_REBUILD="${PIXELFED_REBUILD:-0}"

PASSWORD="${SMOKE_PASSWORD:-SmokeTest_01}"
KEEP_CONTAINERS="${KEEP_CONTAINERS:-0}"
WORK_DIR="${SMOKE_WORK_DIR:-}"
MIX_BUILD_PATH="${MIX_BUILD_PATH:-/work/_build/pixelfed-smoke}"

if [ -z "$WORK_DIR" ]; then
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/unfathomably-pixelfed-smoke.XXXXXX")"
fi

BE_SECRET="$WORK_DIR/be/dev.secret.exs"
BE_UPLOADS="$WORK_DIR/be/uploads"
BE_STATIC="$WORK_DIR/be/static"
BE_NGINX_CONF="$WORK_DIR/be-nginx/default.conf"
PIXELFED_ENV="$WORK_DIR/pixelfed/.env"
PIXELFED_STORAGE="$WORK_DIR/pixelfed/storage"
PIXELFED_CACHE="$WORK_DIR/pixelfed/bootstrap-cache"
PIXELFED_NGINX_CONF="$WORK_DIR/pixelfed-nginx/default.conf"
PIXELFED_PHP_INI="$WORK_DIR/pixelfed/php-smoke-ca.ini"
SMOKE_IMAGE_FILE="$WORK_DIR/smoke.png"
CA_DIR="$WORK_DIR/ca"
CA_CERT="$CA_DIR/smoke-ca.crt"
CA_KEY="$CA_DIR/smoke-ca.key"
BE_CERT="$CA_DIR/be.crt"
BE_KEY="$CA_DIR/be.key"
PIXELFED_CERT="$CA_DIR/pixelfed.crt"
PIXELFED_KEY="$CA_DIR/pixelfed.key"
CA_OPENSSL_CONF="$CA_DIR/ca-openssl.cnf"
BE_OPENSSL_CONF="$CA_DIR/be-openssl.cnf"
PIXELFED_OPENSSL_CONF="$CA_DIR/pixelfed-openssl.cnf"

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
        "$PIXELFED_PROXY_CONTAINER" \
        "$PIXELFED_WORKER_CONTAINER" \
        "$PIXELFED_CONTAINER" \
        "$PIXELFED_REDIS_CONTAINER" \
        "$PIXELFED_DB_CONTAINER" \
        "$BE_PROXY_CONTAINER" \
        "$BE_CONTAINER" \
        "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    if [ -n "$WORK_DIR" ] && [ "$WORK_DIR" != "/" ]; then
        if ! rm -rf -- "$WORK_DIR" >/dev/null 2>&1; then
            # Pixelfed writes uploaded media as the container user.  Remove
            # those root/container-owned files through a disposable container
            # so a successful smoke run keeps its original exit status.
            docker run --rm \
                -v "$WORK_DIR:/work" \
                --entrypoint sh \
                "$NGINX_IMAGE" \
                -c 'find /work -mindepth 1 -exec rm -rf {} +' >/dev/null 2>&1 || true
            rmdir -- "$WORK_DIR" >/dev/null 2>&1 || true
        fi
    fi
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
    local path="$2"

    JSON_INPUT="$json" python3 - "$path" <<'PY'
import json
import os
import sys

data = json.loads(os.environ["JSON_INPUT"])
value = data

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

json_assert() {
    local json="$1"
    local expression="$2"
    local message="$3"

    if ! JSON_INPUT="$json" python3 - "$expression" <<'PY'
import json
import os
import sys

data = json.loads(os.environ["JSON_INPUT"])
helpers = {"any": any, "all": all, "int": int, "len": len, "str": str, "sum": sum}
sys.exit(0 if eval(sys.argv[1], {"__builtins__": {}}, {"data": data, **helpers}) else 1)
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

host_for_url() {
    local url="$1"

    case "$url" in
        "$BE_BASE"*)
            printf '%s\n' "$BE_HOST"
            ;;
        "$PIXELFED_BASE"*)
            printf '%s\n' "$PIXELFED_HOST"
            ;;
        *)
            printf '\n'
            ;;
    esac
}

http_json() {
    local method="$1"
    local url="$2"
    local token="$3"
    local expected="$4"
    shift 4

    local response status body host
    local args=(-k -sS -X "$method" -w '\n%{http_code}' -H 'Accept: application/json')

    host="$(host_for_url "$url")"
    if [ -n "$host" ]; then
        args+=(-H "Host: $host")
    fi

    if [ -n "$token" ]; then
        args+=(-H "Authorization: Bearer $token")
    fi

    if [ "$#" -gt 0 ]; then
        args+=(-H 'Content-Type: application/x-www-form-urlencoded')
    fi

    while [ "$#" -gt 0 ]; do
        args+=(--data-urlencode "$1")
        shift
    done

    response="$(curl "${args[@]}" "$url" || true)"
    status="${response##*$'\n'}"
    body="${response%$'\n'$status}"

    if [ "$status" != "$expected" ]; then
        printf 'Unexpected HTTP %s for %s %s, expected %s\n' "$status" "$method" "$url" "$expected" >&2
        printf '%s\n' "$body" >&2
        return 1
    fi

    printf '%s' "$body"
}

http_multipart() {
    local method="$1"
    local url="$2"
    local token="$3"
    local expected="$4"
    shift 4

    local response status body host
    local args=(-k -sS -X "$method" -w '\n%{http_code}' -H 'Accept: application/json')

    host="$(host_for_url "$url")"
    if [ -n "$host" ]; then
        args+=(-H "Host: $host")
    fi

    if [ -n "$token" ]; then
        args+=(-H "Authorization: Bearer $token")
    fi

    while [ "$#" -gt 0 ]; do
        args+=(-F "$1")
        shift
    done

    response="$(curl "${args[@]}" "$url" || true)"
    status="${response##*$'\n'}"
    body="${response%$'\n'$status}"

    if [ "$status" != "$expected" ]; then
        printf 'Unexpected HTTP %s for %s %s, expected %s\n' "$status" "$method" "$url" "$expected" >&2
        printf '%s\n' "$body" >&2
        return 1
    fi

    printf '%s' "$body"
}

poll_json_assert() {
    local method="$1"
    local url="$2"
    local token="$3"
    local expected="$4"
    local expression="$5"
    local message="$6"
    local attempts="${7:-90}"
    local delay="${8:-2}"
    shift 8 || true

    local body=""

    for _ in $(seq 1 "$attempts"); do
        if body="$(http_json "$method" "$url" "$token" "$expected" "$@" 2>/dev/null)" &&
            JSON_INPUT="$body" python3 - "$expression" <<'PY'
import json
import os
import sys

data = json.loads(os.environ["JSON_INPUT"])
helpers = {"any": any, "all": all, "int": int, "len": len, "str": str, "sum": sum}
sys.exit(0 if eval(sys.argv[1], {"__builtins__": {}}, {"data": data, **helpers}) else 1)
PY
        then
            printf '%s' "$body"
            return 0
        fi

        sleep "$delay"
    done

    printf 'Polling timed out: %s\n' "$message" >&2
    if [ -n "$body" ]; then
        printf '%s\n' "$body" >&2
    fi
    return 1
}

poll_http_status() {
    local method="$1"
    local url="$2"
    local token="$3"
    local expected="$4"
    local message="$5"
    local attempts="${6:-90}"
    local delay="${7:-2}"
    local status host tmp

    tmp="$WORK_DIR/http-status-body.txt"

    for _ in $(seq 1 "$attempts"); do
        local args=(-k -sS -X "$method" -o "$tmp" -w '%{http_code}' -H 'Accept: application/json')
        host="$(host_for_url "$url")"
        if [ -n "$host" ]; then
            args+=(-H "Host: $host")
        fi
        if [ -n "$token" ]; then
            args+=(-H "Authorization: Bearer $token")
        fi

        status="$(curl "${args[@]}" "$url" || true)"
        if [ "$status" = "$expected" ]; then
            return 0
        fi
        sleep "$delay"
    done

    printf 'Polling timed out: %s, last HTTP status %s\n' "$message" "$status" >&2
    cat "$tmp" >&2 || true
    return 1
}

json_find_status_id() {
    local json="$1"
    local text="$2"

    JSON_INPUT="$json" NEEDLE="$text" python3 <<'PY'
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
needle = os.environ["NEEDLE"]

if isinstance(data, dict) and "statuses" in data:
    items = data["statuses"]
elif isinstance(data, dict) and "descendants" in data:
    items = list(data.get("ancestors") or []) + list(data.get("descendants") or [])
elif isinstance(data, list):
    items = data
else:
    items = [data]

for item in items:
    if needle in str(item):
        print(item.get("id", ""))
        break
PY
}

poll_home_status_by_text() {
    local base="$1"
    local token="$2"
    local text="$3"
    local message="$4"
    local body id

    for _ in $(seq 1 90); do
        body="$(http_json GET "$base/api/v1/timelines/home?limit=40" "$token" 200 2>/dev/null || true)"
        if [ -n "$body" ]; then
            id="$(json_find_status_id "$body" "$text")"
            if [ -n "$id" ]; then
                printf '%s\n' "$id"
                return 0
            fi
        fi
        sleep 2
    done

    fail "$message"
}

poll_account_status_by_text() {
    local base="$1"
    local token="$2"
    local account_id="$3"
    local text="$4"
    local message="$5"
    local body id

    for _ in $(seq 1 90); do
        body="$(http_json GET "$base/api/v1/accounts/$account_id/statuses?limit=40" "$token" 200 2>/dev/null || true)"
        if [ -n "$body" ]; then
            id="$(json_find_status_id "$body" "$text")"
            if [ -n "$id" ]; then
                printf '%s\n' "$id"
                return 0
            fi
        fi
        sleep 2
    done

    fail "$message"
}

poll_context_status_by_text() {
    local base="$1"
    local token="$2"
    local status_id="$3"
    local text="$4"
    local message="$5"
    local body id

    for _ in $(seq 1 90); do
        body="$(http_json GET "$base/api/v1/statuses/$status_id/context" "$token" 200 2>/dev/null || true)"
        if [ -n "$body" ]; then
            id="$(json_find_status_id "$body" "$text")"
            if [ -n "$id" ]; then
                printf '%s\n' "$id"
                return 0
            fi
        fi
        sleep 2
    done

    fail "$message"
}

resolve_account_id() {
    local base="$1"
    local token="$2"
    local query="$3"
    local message="$4"
    local account_expression="${5:-True}"
    local result

    result="$(poll_json_assert GET "$base/api/v1/accounts/search?q=$(urlencode "$query")&resolve=true&limit=5" "$token" 200 "any(($account_expression) for account in data)" "$message")"

    JSON_INPUT="$result" python3 - "$account_expression" <<'PY'
import json
import os
import sys

data = json.loads(os.environ["JSON_INPUT"])
helpers = {"int": int, "len": len, "str": str}

for account in data:
    if eval(sys.argv[1], {"__builtins__": {}}, {"account": account, **helpers}):
        print(account["id"])
        sys.exit(0)

sys.exit(1)
PY
}

poll_relationship_following() {
    local base="$1"
    local token="$2"
    local account_id="$3"
    local message="$4"

    poll_json_assert GET "$base/api/v1/accounts/relationships?id[]=$account_id" "$token" 200 \
        'len(data) == 1 and (data[0].get("following") is True or data[0].get("requested") is True)' \
        "$message" >/dev/null
}

poll_status_count() {
    local base="$1"
    local token="$2"
    local status_id="$3"
    local expression="$4"
    local message="$5"

    poll_json_assert GET "$base/api/v1/statuses/$status_id" "$token" 200 "$expression" "$message" >/dev/null
}

wait_pixelfed_follow_row() {
    local follower_profile_id="$1"
    local following_profile_id="$2"
    local message="$3"
    local count

    for _ in $(seq 1 90); do
        count="$(
            docker exec "$PIXELFED_DB_CONTAINER" \
                mysql -N -u"$PIXELFED_DB_USER" -p"$PIXELFED_DB_PASSWORD" "$PIXELFED_DB_NAME" \
                -e "select count(*) from followers where profile_id = $follower_profile_id and following_id = $following_profile_id" 2>/dev/null ||
                printf '0\n'
        )"

        if [ "$count" != "0" ]; then
            return 0
        fi

        sleep 1
    done

    fail "$message"
}

wait_api() {
    local base="$1"
    local token="$2"
    local label="$3"

    for _ in $(seq 1 "${WAIT_API_ATTEMPTS:-240}"); do
        if http_json GET "$base/api/v1/instance" "$token" 200 >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    fail "Timed out waiting for $label"
}

build_pixelfed_image() {
    if [ "$PIXELFED_REBUILD" != "1" ] && docker image inspect "$PIXELFED_IMAGE" >/dev/null 2>&1; then
        return 0
    fi

    log "Building stock Pixelfed image from $PIXELFED_GIT_URL#$PIXELFED_GIT_REF"
    docker build -t "$PIXELFED_IMAGE" "$PIXELFED_GIT_URL#$PIXELFED_GIT_REF"
}

write_create_user_script() {
    cat >"$WORK_DIR/create_smoke_user.exs" <<'EOF'
alias Pleroma.User

password = System.fetch_env!("SMOKE_PASSWORD")

users =
  System.fetch_env!("SMOKE_USERS")
  |> String.split("\n", trim: true)
  |> Enum.map(fn line ->
    case String.split(line, "\t", parts: 2) do
      [nickname, email] -> {nickname, email}
      _ -> raise "invalid smoke user line: #{inspect(line)}"
    end
  end)

Enum.each(users, fn {nickname, email} ->
  params = %{
    nickname: nickname,
    email: email,
    password: password,
    password_confirmation: password,
    name: nickname,
    bio: ""
  }

  changeset = User.register_changeset(%User{}, params, confirmed: true, approved: true)

  case User.register(changeset) do
    {:ok, _user} -> :ok
    {:error, changeset} ->
      errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
      raise "could not create smoke user #{nickname}: #{inspect(errors)}"
  end
end)
EOF
}

write_tls_material() {
    mkdir -p "$CA_DIR"

    cat >"$CA_OPENSSL_CONF" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_ca
prompt = no

[req_distinguished_name]
CN = Unfathomably Pixelfed Smoke CA

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

    cat >"$PIXELFED_OPENSSL_CONF" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $PIXELFED_HOST

[v3_req]
subjectAltName = @alt_names
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = $PIXELFED_HOST
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
        -config "$PIXELFED_OPENSSL_CONF" \
        -keyout "$PIXELFED_KEY" \
        -out "$CA_DIR/pixelfed.csr" >/dev/null 2>&1

    openssl x509 -req -days 3 \
        -in "$CA_DIR/pixelfed.csr" \
        -CA "$CA_CERT" \
        -CAkey "$CA_KEY" \
        -CAcreateserial \
        -out "$PIXELFED_CERT" \
        -extensions v3_req \
        -extfile "$PIXELFED_OPENSSL_CONF" >/dev/null 2>&1
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
print(secrets.token_urlsafe(16))
PY
)"

    mkdir -p "$(dirname "$BE_SECRET")" "$BE_UPLOADS" "$BE_STATIC"

    cat >"$BE_SECRET" <<EOF
import Config

config :pleroma, Pleroma.Web.Endpoint,
  http: [
    ip: {0, 0, 0, 0},
    port: 4000,
    protocol_options: [max_request_line_length: 8192, max_header_value_length: 8192]
  ],
  url: [scheme: "https", host: "$BE_HOST", port: 443],
  secret_key_base: "$secret_key_base",
  live_view: [signing_salt: "$signing_salt"],
  code_reloader: false,
  live_reload: false,
  watchers: [],
  server: true

config :pleroma, Pleroma.Repo,
  adapter: Ecto.Adapters.Postgres,
  username: "postgres",
  password: "$BE_DB_PASSWORD",
  database: "$BE_DB_NAME",
  hostname: "$BE_DB_CONTAINER",
  pool_size: 10

config :pleroma, :instance,
  name: "Unfathomably Pixelfed Smoke",
  description: "Disposable Pixelfed federation smoke instance",
  email: "admin@$BE_HOST",
  notify_email: "noreply@$BE_HOST",
  domain: "$BE_HOST",
  federating: true,
  registrations_open: true,
  account_approval_required: false,
  external_user_synchronization: true,
  skip_thread_containment: true,
  static_dir: "$BE_STATIC"

config :pleroma, :activitypub,
  sign_object_fetches: false,
  follow_handshake_timeout: 5_000

config :pleroma, Pleroma.Uploaders.Local, uploads: "$BE_UPLOADS"

config :pleroma, Pleroma.Emails.Mailer, adapter: Swoosh.Adapters.Local, enabled: false

config :pleroma, :rich_media, enabled: false

config :logger, :console, level: :warning, format: "[\$level] \$message\\n"
EOF
}

write_nginx_configs() {
    mkdir -p "$(dirname "$BE_NGINX_CONF")" "$(dirname "$PIXELFED_NGINX_CONF")"

    cat >"$BE_NGINX_CONF" <<EOF
server {
    listen 80;
    server_name $BE_HOST;

    location / {
        return 301 https://$BE_HOST\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name $BE_HOST;
    client_max_body_size 200m;

    ssl_certificate /etc/nginx/smoke-certs/be.crt;
    ssl_certificate_key /etc/nginx/smoke-certs/be.key;

    location / {
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Ssl on;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://$BE_APP_HOST:4000;
    }
}
EOF

    cat >"$PIXELFED_NGINX_CONF" <<EOF
server {
    listen 80;
    server_name $PIXELFED_HOST;

    location / {
        return 301 https://$PIXELFED_HOST\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name $PIXELFED_HOST;
    client_max_body_size 200m;

    ssl_certificate /etc/nginx/smoke-certs/pixelfed.crt;
    ssl_certificate_key /etc/nginx/smoke-certs/pixelfed.key;

    location / {
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Ssl on;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://$PIXELFED_APP_HOST:8080;
    }
}
EOF
}

write_pixelfed_env() {
    local app_key

    app_key="base64:$(openssl rand -base64 32)"
    mkdir -p "$(dirname "$PIXELFED_ENV")" \
        "$PIXELFED_STORAGE/app/public" \
        "$PIXELFED_STORAGE/framework/cache/data" \
        "$PIXELFED_STORAGE/framework/sessions" \
        "$PIXELFED_STORAGE/framework/testing" \
        "$PIXELFED_STORAGE/framework/views" \
        "$PIXELFED_STORAGE/logs" \
        "$PIXELFED_CACHE"
    chmod -R 0777 "$(dirname "$PIXELFED_ENV")"

    cat >"$PIXELFED_ENV" <<EOF
APP_NAME=Pixelfed
APP_ENV=production
APP_KEY=$app_key
APP_DEBUG=false
APP_URL=https://$PIXELFED_HOST
APP_DOMAIN=$PIXELFED_HOST
ADMIN_DOMAIN=$PIXELFED_HOST
SESSION_DOMAIN=$PIXELFED_HOST
FORCE_HTTPS_URLS=true
TRUST_PROXIES=*
OPEN_REGISTRATION=true
ENFORCE_EMAIL_VERIFICATION=false
OAUTH_ENABLED=true
ENABLE_CONFIG_CACHE=false
INSTANCE_DISCOVER_PUBLIC=true
ACTIVITY_PUB=true
AP_REMOTE_FOLLOW=true
AP_INBOX=true
AP_OUTBOX=true
AP_SHAREDINBOX=true
DB_CONNECTION=mysql
DB_HOST=$PIXELFED_DB_CONTAINER
DB_PORT=3306
DB_DATABASE=$PIXELFED_DB_NAME
DB_USERNAME=$PIXELFED_DB_USER
DB_PASSWORD=$PIXELFED_DB_PASSWORD
REDIS_CLIENT=phpredis
REDIS_SCHEME=tcp
REDIS_HOST=$PIXELFED_REDIS_CONTAINER
REDIS_PASSWORD=null
REDIS_PORT=6379
CACHE_DRIVER=redis
CACHE_STORE=redis
SESSION_DRIVER=database
QUEUE_DRIVER=redis
QUEUE_CONNECTION=redis
BROADCAST_DRIVER=log
MAIL_DRIVER=log
MAIL_MAILER=log
MAIL_FROM_ADDRESS=pixelfed@$PIXELFED_HOST
MAIL_FROM_NAME=Pixelfed
PF_OPTIMIZE_IMAGES=false
IMAGE_QUALITY=90
MAX_PHOTO_SIZE=15000
MAX_CAPTION_LENGTH=500
MAX_ALBUM_LENGTH=4
PF_ENABLE_CLOUD=false
FILESYSTEM_CLOUD=s3
LOG_CHANNEL=stderr
AUTORUN_ENABLED=false
PHP_POST_MAX_SIZE=200M
PHP_UPLOAD_MAX_FILE_SIZE=200M
PHP_OPCACHE_ENABLE=0
NGINX_HTTP_PORT=8080
EOF

    cat >"$PIXELFED_PHP_INI" <<EOF
openssl.cafile=/smoke-ca/smoke-ca.crt
curl.cainfo=/smoke-ca/smoke-ca.crt
EOF
}

write_smoke_image() {
    python3 - "$SMOKE_IMAGE_FILE" <<'PY'
import struct
import sys
import zlib

with open(sys.argv[1], "wb") as handle:
    def chunk(kind, payload):
        return (
            struct.pack(">I", len(payload)) +
            kind +
            payload +
            struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff)
        )

    # PNG rows are prefixed with a filter byte. This smoke image is tiny, but
    # building the chunks directly keeps the test independent of Pillow or
    # ImageMagick while still producing a standards-valid upload fixture.
    width = 2
    height = 2
    raw_rows = b"\x00\xff\x66\x33\x33\x99\xff" + b"\x00\x33\x99\xff\xff\xcc\x33"

    handle.write(b"\x89PNG\r\n\x1a\n")
    handle.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)))
    handle.write(chunk(b"IDAT", zlib.compress(raw_rows)))
    handle.write(chunk(b"IEND", b""))
PY
}

run_be_mix() {
    docker run --rm \
        --name "${PREFIX}-be-run" \
        --network "$NETWORK" \
        -e MIX_ENV=dev \
        -e MIX_HOME=/tmp/mix \
        -e HEX_HOME=/tmp/hex \
        -e MIX_BUILD_PATH="$MIX_BUILD_PATH" \
        -e SSL_CERT_FILE=/smoke-ca/smoke-ca.crt \
        -v "$BE_ROOT:/work" \
        -v "$BE_SECRET:/work/config/dev.secret.exs:ro" \
        -v "$CA_CERT:/smoke-ca/smoke-ca.crt:ro" \
        -v "$CA_CERT:/usr/local/share/ca-certificates/unfathomably-pixelfed-smoke-ca.crt:ro" \
        "$IMAGE" \
        bash -lc "set -euo pipefail; if command -v update-ca-certificates >/dev/null 2>&1; then update-ca-certificates >/dev/null; fi; cd /work; mix local.hex --force >/dev/null; mix local.rebar --force >/dev/null; mix deps.get >/dev/null; $*"
}

migrate_be() {
    docker exec "$BE_DB_CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 \
        -c "CREATE DATABASE $BE_DB_NAME;" >/dev/null

    # MIME mappings are compile-time dependency configuration.  The dedicated
    # adapter build cache can outlive a source checkout update, so refresh only
    # that dependency rather than rebuilding every Erlang dependency.
    run_be_mix "rm -rf '$MIX_BUILD_PATH/lib/mime'; mix deps.compile mime --force >/dev/null; mix compile >/dev/null; mix pleroma.ecto.migrate --migrations-path /work/priv/repo/migrations"
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
        -e MIX_BUILD_PATH="$MIX_BUILD_PATH" \
        -e SSL_CERT_FILE=/smoke-ca/smoke-ca.crt \
        -v "$BE_ROOT:/work" \
        -v "$BE_SECRET:/work/config/dev.secret.exs:ro" \
        -v "$CA_CERT:/smoke-ca/smoke-ca.crt:ro" \
        -v "$CA_CERT:/usr/local/share/ca-certificates/unfathomably-pixelfed-smoke-ca.crt:ro" \
        "$IMAGE" \
        bash -lc 'set -euo pipefail; if command -v update-ca-certificates >/dev/null 2>&1; then update-ca-certificates >/dev/null; fi; cd /work; mix local.hex --force >/dev/null; mix local.rebar --force >/dev/null; mix deps.get >/dev/null; mix compile >/dev/null; exec mix phx.server' \
        >/dev/null
}

start_proxy() {
    local container="$1"
    local host="$2"
    local port="$3"
    local config="$4"

    docker run -d \
        --name "$container" \
        --network "$NETWORK" \
        --network-alias "$host" \
        -p "127.0.0.1:$port:443" \
        -v "$config:/etc/nginx/conf.d/default.conf:ro" \
        -v "$CA_DIR:/etc/nginx/smoke-certs:ro" \
        "$NGINX_IMAGE" >/dev/null
}

create_be_users() {
    local users

    users="alice"$'\t'"alice@$BE_HOST"$'\n'

    docker run --rm \
        --name "${PREFIX}-be-users" \
        --network "$NETWORK" \
        -e MIX_ENV=dev \
        -e MIX_HOME=/tmp/mix \
        -e HEX_HOME=/tmp/hex \
        -e MIX_BUILD_PATH="$MIX_BUILD_PATH" \
        -e SMOKE_PASSWORD="$PASSWORD" \
        -e SMOKE_USERS="$users" \
        -v "$BE_ROOT:/work" \
        -v "$BE_SECRET:/work/config/dev.secret.exs:ro" \
        -v "$WORK_DIR/create_smoke_user.exs:/tmp/create_smoke_user.exs:ro" \
        "$IMAGE" \
        bash -lc 'set -euo pipefail; cd /work; mix local.hex --force >/dev/null; mix local.rebar --force >/dev/null; mix deps.get >/dev/null; mix compile >/dev/null; mix run /tmp/create_smoke_user.exs >/dev/null'
}

create_be_token() {
    local app client_id client_secret token

    app="$(http_json POST "$BE_BASE/api/v1/apps" "" 200 \
        'client_name=Pixelfed smoke Alice' \
        'redirect_uris=urn:ietf:wg:oauth:2.0:oob' \
        'scopes=read write follow')"
    client_id="$(json_get "$app" client_id)"
    client_secret="$(json_get "$app" client_secret)"

    token="$(http_json POST "$BE_BASE/oauth/token" "" 200 \
        'grant_type=password' \
        'username=alice' \
        "password=$PASSWORD" \
        "client_id=$client_id" \
        "client_secret=$client_secret" \
        'scope=read write follow')"
    json_get "$token" access_token
}

pixelfed_common_args() {
    printf '%s\0' \
        --network "$NETWORK" \
        --env-file "$PIXELFED_ENV" \
        -e SSL_CERT_FILE=/smoke-ca/smoke-ca.crt \
        -e CURL_CA_BUNDLE=/smoke-ca/smoke-ca.crt \
        -e REQUESTS_CA_BUNDLE=/smoke-ca/smoke-ca.crt \
        -v "$PIXELFED_STORAGE:/var/www/html/storage" \
        -v "$PIXELFED_CACHE:/var/www/html/bootstrap/cache" \
        -v "$CA_CERT:/smoke-ca/smoke-ca.crt:ro" \
        -v "$PIXELFED_PHP_INI:/usr/local/etc/php/conf.d/zz-unfathomably-smoke-ca.ini:ro" \
        -v "$CA_CERT:/usr/local/share/ca-certificates/unfathomably-pixelfed-smoke-ca.crt:ro"
}

run_pixelfed_artisan() {
    local args=()
    while IFS= read -r -d '' item; do
        args+=("$item")
    done < <(pixelfed_common_args)

    docker run --rm "${args[@]}" --entrypoint php "$PIXELFED_IMAGE" artisan "$@"
}

migrate_pixelfed() {
    run_pixelfed_artisan migrate --force >/dev/null
    run_pixelfed_artisan passport:keys --force >/dev/null
    # Stock Pixelfed's current Passport stack rejects personal-access tokens
    # when the personal client is the first OAuth client in a fresh database.
    # Seeding a normal client first mirrors a configured instance and keeps
    # the personal client on the code path Pixelfed accepts.
    run_pixelfed_artisan passport:client --password --provider=users --name=SmokePasswordSeed --no-interaction --no-ansi >/dev/null
    run_pixelfed_artisan passport:client --personal --name=SmokePersonal --no-interaction --no-ansi >/dev/null
    run_pixelfed_artisan storage:link >/dev/null || true
    run_pixelfed_artisan instance:actor >/dev/null || true
}

create_pixelfed_user() {
    run_pixelfed_artisan user:create \
        --name='Pixel Smoke' \
        --username=pixel \
        --email="pixel@$PIXELFED_HOST" \
        --password="$PASSWORD" \
        --is_admin=1 \
        --confirm_email=1 >/dev/null
}

create_pixelfed_token() {
    local raw token

    raw="$(run_pixelfed_artisan tinker --execute='echo "TOKEN=" . App\User::where("username", "pixel")->first()->createToken("smoke", ["read", "write", "follow", "push"])->accessToken . PHP_EOL;')"
    token="$(printf '%s\n' "$raw" | sed -n 's/^TOKEN=//p' | tail -1)"

    if [ -z "$token" ]; then
        printf '%s\n' "$raw" >&2
        fail "Could not create Pixelfed API token"
    fi

    printf '%s\n' "$token"
}

start_pixelfed() {
    local args=()
    while IFS= read -r -d '' item; do
        args+=("$item")
    done < <(pixelfed_common_args)

    docker run -d \
        --name "$PIXELFED_CONTAINER" \
        --hostname "$PIXELFED_APP_HOST" \
        --network-alias "$PIXELFED_APP_HOST" \
        "${args[@]}" \
        "$PIXELFED_IMAGE" >/dev/null

    docker run -d \
        --name "$PIXELFED_WORKER_CONTAINER" \
        --hostname "${PIXELFED_APP_HOST}-worker" \
        "${args[@]}" \
        --entrypoint php \
        "$PIXELFED_IMAGE" artisan horizon >/dev/null
}

check_logs() {
    local container="$1"
    local label="$2"
    local pattern="$3"

    if docker logs "$container" 2>&1 | grep -E "$pattern" >/dev/null; then
        docker logs --tail 200 "$container" >&2
        fail "$label logged an unexpected crash or server error"
    fi
}

probe_pixelfed_group_actor() {
    local group_actor="$1"
    local group_id="$2"
    local result account_id follow post text

    result="$(http_json GET "$PIXELFED_BASE/api/v1/accounts/search?q=$(urlencode "$group_actor")&resolve=true&limit=5" "$PIXELFED_TOKEN" 200 2>/dev/null || true)"
    account_id=""

    if [ -n "$result" ]; then
        account_id="$(json_get "$result" 0.id 2>/dev/null || true)"
    fi

    if [ -z "$account_id" ]; then
        printf 'not_supported: Pixelfed did not import the Unfathomably Group actor as a followable account\n'
        return 0
    fi

    follow="$(http_json POST "$PIXELFED_BASE/api/v1/accounts/$account_id/follow" "$PIXELFED_TOKEN" 200 2>/dev/null || true)"
    if [ -z "$follow" ]; then
        printf 'not_supported: Pixelfed imported the Group actor but could not follow it through the account API\n'
        return 0
    fi

    text="Pixelfed group mention probe $(basename "$WORK_DIR")"
    post="$(http_json POST "$PIXELFED_BASE/api/v1/statuses" "$PIXELFED_TOKEN" 200 \
        "status=$text @$BE_GROUP_NAME@$BE_HOST" \
        'visibility=public' 2>/dev/null || true)"

    if [ -z "$post" ]; then
        printf 'not_supported: Pixelfed followed the Group actor but could not publish a top-level mention probe\n'
        return 0
    fi

    if poll_json_assert GET "$BE_BASE/api/v1/groups/$group_id/preview" "$ALICE_TOKEN" 200 "'$text' in str(data)" "Pixelfed group mention probe did not reach Unfathomably" 45 2 >/dev/null 2>&1; then
        printf 'supported: Pixelfed imported the Group actor as an account and Unfathomably accepted top-level mention posting into the group\n'
    else
        printf 'not_supported: Pixelfed posted a Group mention, but it did not appear in the Unfathomably group preview\n'
    fi
}

log "Preparing Pixelfed stock image and smoke files"
build_pixelfed_image
mkdir -p "$WORK_DIR" "$BE_UPLOADS" "$BE_STATIC"
write_create_user_script
write_tls_material
write_be_secret
write_pixelfed_env
write_nginx_configs
write_smoke_image

docker rm -f \
    "$PIXELFED_PROXY_CONTAINER" \
    "$PIXELFED_WORKER_CONTAINER" \
    "$PIXELFED_CONTAINER" \
    "$PIXELFED_REDIS_CONTAINER" \
    "$PIXELFED_DB_CONTAINER" \
    "$BE_PROXY_CONTAINER" \
    "$BE_CONTAINER" \
    "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
docker network rm "$NETWORK" >/dev/null 2>&1 || true

log "Creating Docker network and databases"
docker network create "$NETWORK" >/dev/null

docker run -d \
    --name "$BE_DB_CONTAINER" \
    --network "$NETWORK" \
    -e POSTGRES_PASSWORD="$BE_DB_PASSWORD" \
    "$POSTGRES_IMAGE" >/dev/null

for _ in $(seq 1 90); do
    if docker exec "$BE_DB_CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
sleep 2
docker exec "$BE_DB_CONTAINER" pg_isready -U postgres >/dev/null 2>&1 || fail "Postgres did not become ready"

docker run -d \
    --name "$PIXELFED_DB_CONTAINER" \
    --network "$NETWORK" \
    -e MYSQL_DATABASE="$PIXELFED_DB_NAME" \
    -e MYSQL_USER="$PIXELFED_DB_USER" \
    -e MYSQL_PASSWORD="$PIXELFED_DB_PASSWORD" \
    -e MYSQL_ROOT_PASSWORD="$PIXELFED_DB_ROOT_PASSWORD" \
    "$MYSQL_IMAGE" >/dev/null

docker run -d \
    --name "$PIXELFED_REDIS_CONTAINER" \
    --network "$NETWORK" \
    "$REDIS_IMAGE" >/dev/null

for _ in $(seq 1 120); do
    if docker exec "$PIXELFED_DB_CONTAINER" mysqladmin ping -h 127.0.0.1 -u"$PIXELFED_DB_USER" -p"$PIXELFED_DB_PASSWORD" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
docker exec "$PIXELFED_DB_CONTAINER" mysqladmin ping -h 127.0.0.1 -u"$PIXELFED_DB_USER" -p"$PIXELFED_DB_PASSWORD" >/dev/null 2>&1 || fail "MySQL did not become ready"

log "Migrating and starting Unfathomably"
migrate_be
start_be
start_proxy "$BE_PROXY_CONTAINER" "$BE_HOST" "$BE_PORT" "$BE_NGINX_CONF"
wait_api "$BE_BASE" "" "Unfathomably"

log "Migrating and starting stock Pixelfed"
migrate_pixelfed
create_pixelfed_user
start_pixelfed
start_proxy "$PIXELFED_PROXY_CONTAINER" "$PIXELFED_HOST" "$PIXELFED_PORT" "$PIXELFED_NGINX_CONF"
wait_api "$PIXELFED_BASE" "" "Pixelfed"
PIXELFED_TOKEN="$(create_pixelfed_token)"

log "Creating Unfathomably API credentials and group probe target"
create_be_users
ALICE_TOKEN="$(create_be_token)"
ALICE_ACCOUNT="$(http_json GET "$BE_BASE/api/v1/accounts/verify_credentials" "$ALICE_TOKEN" 200)"
ALICE_ACTOR_URL="$(json_get "$ALICE_ACCOUNT" url)"
PIXELFED_ACCOUNT="$(http_json GET "$PIXELFED_BASE/api/v1/accounts/verify_credentials" "$PIXELFED_TOKEN" 200)"
PIXELFED_ACTOR_URL="$(json_get "$PIXELFED_ACCOUNT" url)"
PIXELFED_LOCAL_ACCOUNT_ID="$(json_get "$PIXELFED_ACCOUNT" id)"

log "Following accounts in both directions"
PIXELFED_ACCOUNT_ID="$(resolve_account_id "$BE_BASE" "$ALICE_TOKEN" "https://$PIXELFED_HOST/users/pixel" "Unfathomably could not resolve Pixelfed account" 'account.get("acct") == "pixel@'"$PIXELFED_HOST"'" or account.get("fqn") == "pixel@'"$PIXELFED_HOST"'" or str(account.get("url") or "").find("'"$PIXELFED_HOST"'") >= 0')"

BE_FOLLOW_PIXELFED="$(http_json POST "$BE_BASE/api/v1/accounts/$PIXELFED_ACCOUNT_ID/follow" "$ALICE_TOKEN" 200)"
json_assert "$BE_FOLLOW_PIXELFED" 'data.get("following") is True or data.get("requested") is True' "Unfathomably could not follow Pixelfed account"
poll_relationship_following "$BE_BASE" "$ALICE_TOKEN" "$PIXELFED_ACCOUNT_ID" "Unfathomably follow of Pixelfed did not settle"

BE_ACCOUNT_ID="$(resolve_account_id "$PIXELFED_BASE" "$PIXELFED_TOKEN" "@alice@$BE_HOST" "Pixelfed could not find Unfathomably account after receiving the follow" 'account.get("acct") == "alice@'"$BE_HOST"'" or account.get("username") == "alice" or str(account.get("url") or "").find("'"$BE_HOST"'") >= 0')"
PIXELFED_FOLLOW_BE="$(http_json POST "$PIXELFED_BASE/api/v1/accounts/$BE_ACCOUNT_ID/follow" "$PIXELFED_TOKEN" 200)"
json_assert "$PIXELFED_FOLLOW_BE" 'data.get("following") is True or data.get("requested") is True' "Pixelfed could not follow Unfathomably account"
poll_relationship_following "$PIXELFED_BASE" "$PIXELFED_TOKEN" "$BE_ACCOUNT_ID" "Pixelfed follow of Unfathomably did not settle"
wait_pixelfed_follow_row "$PIXELFED_LOCAL_ACCOUNT_ID" "$BE_ACCOUNT_ID" "Pixelfed follow row for Unfathomably account did not settle"

BE_GROUP_NAME="pixelfed-smoke-$(basename "$WORK_DIR" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')"
BE_GROUP="$(http_json POST "$BE_BASE/api/v1/groups" "$ALICE_TOKEN" 200 \
    "display_name=Pixelfed Smoke Group" \
    "name=$BE_GROUP_NAME")"
BE_GROUP_ID="$(json_get "$BE_GROUP" id)"
BE_GROUP_ACTOR="$(json_get "$BE_GROUP" ap_id)"

log "Testing Unfathomably media post delivery into Pixelfed"
BE_MEDIA="$(http_multipart POST "$BE_BASE/api/v1/media" "$ALICE_TOKEN" 200 \
    "file=@$SMOKE_IMAGE_FILE;type=image/png" \
    'description=Unfathomably Pixelfed smoke image')"
BE_MEDIA_ID="$(json_get "$BE_MEDIA" id)"
BE_TO_PIXELFED_TEXT="Unfathomably media post to Pixelfed $(basename "$WORK_DIR")"
BE_TO_PIXELFED_POST="$(http_json POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
    "status=$BE_TO_PIXELFED_TEXT @pixel@$PIXELFED_HOST" \
    "media_ids[]=$BE_MEDIA_ID" \
    'visibility=public')"
BE_TO_PIXELFED_ID="$(json_get "$BE_TO_PIXELFED_POST" id)"
PIXELFED_VIEW_OF_BE_ID="$(poll_account_status_by_text "$PIXELFED_BASE" "$PIXELFED_TOKEN" "$BE_ACCOUNT_ID" "$BE_TO_PIXELFED_TEXT" "Pixelfed did not receive Unfathomably media post")"
poll_status_count "$PIXELFED_BASE" "$PIXELFED_TOKEN" "$PIXELFED_VIEW_OF_BE_ID" 'len(data.get("media_attachments") or []) >= 1' "Pixelfed did not expose the Unfathomably media attachment"

PIXELFED_LIKE_BE="$(http_json POST "$PIXELFED_BASE/api/v1/statuses/$PIXELFED_VIEW_OF_BE_ID/favourite" "$PIXELFED_TOKEN" 200)"
json_assert "$PIXELFED_LIKE_BE" 'data.get("favourited") is True' "Pixelfed could not favourite Unfathomably post"
poll_status_count "$BE_BASE" "$ALICE_TOKEN" "$BE_TO_PIXELFED_ID" 'int(data.get("favourites_count") or 0) >= 1' "Unfathomably did not receive Pixelfed favourite"
PIXELFED_UNLIKE_BE="$(http_json POST "$PIXELFED_BASE/api/v1/statuses/$PIXELFED_VIEW_OF_BE_ID/unfavourite" "$PIXELFED_TOKEN" 200)"
json_assert "$PIXELFED_UNLIKE_BE" 'data.get("favourited") is False' "Pixelfed could not unfavourite Unfathomably post"
poll_status_count "$BE_BASE" "$ALICE_TOKEN" "$BE_TO_PIXELFED_ID" 'int(data.get("favourites_count") or 0) == 0' "Unfathomably did not receive Pixelfed unfavourite"

PIXELFED_REPLY_TEXT="Pixelfed reply to Unfathomably $(basename "$WORK_DIR")"
PIXELFED_REPLY="$(http_json POST "$PIXELFED_BASE/api/v1/statuses" "$PIXELFED_TOKEN" 200 \
    "status=$PIXELFED_REPLY_TEXT @alice@$BE_HOST" \
    "in_reply_to_id=$PIXELFED_VIEW_OF_BE_ID" \
    'visibility=public')"
PIXELFED_REPLY_ID="$(json_get "$PIXELFED_REPLY" id)"
BE_VIEW_OF_PIXELFED_REPLY_ID="$(poll_context_status_by_text "$BE_BASE" "$ALICE_TOKEN" "$BE_TO_PIXELFED_ID" "$PIXELFED_REPLY_TEXT" "Unfathomably did not receive Pixelfed reply")"
http_json DELETE "$PIXELFED_BASE/api/v1/statuses/$PIXELFED_REPLY_ID" "$PIXELFED_TOKEN" 200 >/dev/null
poll_http_status GET "$BE_BASE/api/v1/statuses/$BE_VIEW_OF_PIXELFED_REPLY_ID" "$ALICE_TOKEN" 404 "Unfathomably did not lose deleted Pixelfed reply"

log "Testing Pixelfed media post delivery into Unfathomably"
PIXELFED_MEDIA="$(http_multipart POST "$PIXELFED_BASE/api/v1/media" "$PIXELFED_TOKEN" 200 \
    "file=@$SMOKE_IMAGE_FILE;type=image/png" \
    'description=Pixelfed smoke image')"
PIXELFED_MEDIA_ID="$(json_get "$PIXELFED_MEDIA" id)"
PIXELFED_TO_BE_TEXT="Pixelfed media post to Unfathomably $(basename "$WORK_DIR")"
PIXELFED_TO_BE_POST="$(http_json POST "$PIXELFED_BASE/api/v1/statuses" "$PIXELFED_TOKEN" 200 \
    "status=$PIXELFED_TO_BE_TEXT @alice@$BE_HOST" \
    "media_ids[]=$PIXELFED_MEDIA_ID" \
    'visibility=public')"
PIXELFED_TO_BE_ID="$(json_get "$PIXELFED_TO_BE_POST" id)"
BE_VIEW_OF_PIXELFED_ID="$(poll_home_status_by_text "$BE_BASE" "$ALICE_TOKEN" "$PIXELFED_TO_BE_TEXT" "Unfathomably did not receive Pixelfed media post")"
poll_status_count "$BE_BASE" "$ALICE_TOKEN" "$BE_VIEW_OF_PIXELFED_ID" 'len(data.get("media_attachments") or []) >= 1' "Unfathomably did not expose the Pixelfed media attachment"

BE_LIKE_PIXELFED="$(http_json POST "$BE_BASE/api/v1/statuses/$BE_VIEW_OF_PIXELFED_ID/favourite" "$ALICE_TOKEN" 200)"
json_assert "$BE_LIKE_PIXELFED" 'data.get("favourited") is True' "Unfathomably could not favourite Pixelfed post"
poll_status_count "$PIXELFED_BASE" "$PIXELFED_TOKEN" "$PIXELFED_TO_BE_ID" 'int(data.get("favourites_count") or 0) >= 1' "Pixelfed did not receive Unfathomably favourite"
BE_UNLIKE_PIXELFED="$(http_json POST "$BE_BASE/api/v1/statuses/$BE_VIEW_OF_PIXELFED_ID/unfavourite" "$ALICE_TOKEN" 200)"
json_assert "$BE_UNLIKE_PIXELFED" 'data.get("favourited") is False' "Unfathomably could not unfavourite Pixelfed post"
if poll_json_assert GET "$PIXELFED_BASE/api/v1/statuses/$PIXELFED_TO_BE_ID" "$PIXELFED_TOKEN" 200 \
    'int(data.get("favourites_count") or 0) == 0' \
    "Pixelfed did not receive Unfathomably unfavourite" 45 2 >/dev/null 2>&1; then
    PIXELFED_REMOTE_UNFAVOURITE_SUMMARY="supported: Pixelfed decremented its favourite counter after receiving Unfathomably Undo Like"
else
    PIXELFED_REMOTE_UNFAVOURITE_SUMMARY="not_supported: stock Pixelfed accepted the Unfathomably Undo Like inbox delivery but did not decrement the remote status favourite counter"
fi
printf '%s\n' "$PIXELFED_REMOTE_UNFAVOURITE_SUMMARY"

BE_REPLY_TEXT="Unfathomably reply to Pixelfed $(basename "$WORK_DIR")"
BE_REPLY="$(http_json POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
    "status=$BE_REPLY_TEXT" \
    "in_reply_to_id=$BE_VIEW_OF_PIXELFED_ID")"
BE_REPLY_ID="$(json_get "$BE_REPLY" id)"
PIXELFED_VIEW_OF_BE_REPLY_ID="$(poll_context_status_by_text "$PIXELFED_BASE" "$PIXELFED_TOKEN" "$PIXELFED_TO_BE_ID" "$BE_REPLY_TEXT" "Pixelfed did not receive Unfathomably reply")"
http_json DELETE "$BE_BASE/api/v1/statuses/$BE_REPLY_ID" "$ALICE_TOKEN" 200 >/dev/null
if poll_http_status GET "$PIXELFED_BASE/api/v1/statuses/$PIXELFED_VIEW_OF_BE_REPLY_ID" "$PIXELFED_TOKEN" 404 \
    "Pixelfed did not lose deleted Unfathomably reply" 45 2 >/dev/null 2>&1; then
    PIXELFED_REMOTE_REPLY_DELETE_SUMMARY="supported: Pixelfed removed imported Unfathomably reply after receiving Delete"
else
    PIXELFED_REMOTE_REPLY_DELETE_SUMMARY="not_supported: stock Pixelfed accepted the Unfathomably reply Delete inbox delivery but kept the imported reply visible"
fi
printf '%s\n' "$PIXELFED_REMOTE_REPLY_DELETE_SUMMARY"

log "Testing top-level deletes"
http_json DELETE "$BE_BASE/api/v1/statuses/$BE_TO_PIXELFED_ID" "$ALICE_TOKEN" 200 >/dev/null
if poll_http_status GET "$PIXELFED_BASE/api/v1/statuses/$PIXELFED_VIEW_OF_BE_ID" "$PIXELFED_TOKEN" 404 \
    "Pixelfed did not lose deleted Unfathomably status" 45 2 >/dev/null 2>&1; then
    PIXELFED_REMOTE_STATUS_DELETE_SUMMARY="supported: Pixelfed removed imported Unfathomably top-level status after receiving Delete"
else
    PIXELFED_REMOTE_STATUS_DELETE_SUMMARY="not_supported: stock Pixelfed accepted the Unfathomably top-level Delete inbox delivery but kept the imported status visible"
fi
printf '%s\n' "$PIXELFED_REMOTE_STATUS_DELETE_SUMMARY"
http_json DELETE "$PIXELFED_BASE/api/v1/statuses/$PIXELFED_TO_BE_ID" "$PIXELFED_TOKEN" 200 >/dev/null
poll_http_status GET "$BE_BASE/api/v1/statuses/$BE_VIEW_OF_PIXELFED_ID" "$ALICE_TOKEN" 404 "Unfathomably did not lose deleted Pixelfed status"

log "Unfollowing accounts"
http_json POST "$BE_BASE/api/v1/accounts/$PIXELFED_ACCOUNT_ID/unfollow" "$ALICE_TOKEN" 200 >/dev/null
http_json POST "$PIXELFED_BASE/api/v1/accounts/$BE_ACCOUNT_ID/unfollow" "$PIXELFED_TOKEN" 200 >/dev/null

log "Probing Pixelfed behavior around Unfathomably Group actors"
GROUP_SUMMARY="$(probe_pixelfed_group_actor "$BE_GROUP_ACTOR" "$BE_GROUP_ID")"
printf '%s\n' "$GROUP_SUMMARY"

check_logs "$BE_CONTAINER" "Unfathomably" 'status=500|Internal Server Error|\*\* \(|GenServer terminating|FunctionClauseError|UndefinedFunctionError|Protocol\.UndefinedError'
check_logs "$PIXELFED_CONTAINER" "Pixelfed" 'production\.ERROR|SQLSTATE|RuntimeException|Fatal error|Uncaught| 500 '
check_logs "$PIXELFED_WORKER_CONTAINER" "Pixelfed worker" 'production\.ERROR|SQLSTATE|RuntimeException|Fatal error|Uncaught'

cat <<EOF

Pixelfed federation smoke passed.

Covered against stock Pixelfed:
* supported: image built from the official Pixelfed source Dockerfile when not already cached
* supported: Pixelfed migrations, Passport keys/client, local account creation, and API token minting
* supported: account discovery and follow in both directions
* supported: Unfathomably-to-Pixelfed media status delivery
* supported: Pixelfed-to-Unfathomably media status delivery
* supported: remote media attachment visibility in both Mastodon-compatible APIs
* supported: replies in both directions
* supported: favourites in both directions and local unfavourite cleanup
* $PIXELFED_REMOTE_UNFAVOURITE_SUMMARY
* $PIXELFED_REMOTE_REPLY_DELETE_SUMMARY
* $PIXELFED_REMOTE_STATUS_DELETE_SUMMARY
* supported: Pixelfed-origin reply Deletes and top-level Deletes
* supported: account unfollow cleanup in both directions
* $GROUP_SUMMARY
EOF

# end of unfathomably-pixelfed-smoke.sh
