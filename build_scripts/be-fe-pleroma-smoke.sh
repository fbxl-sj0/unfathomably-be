#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke harness
# ------------------------------------------------
#
# File: build_scripts/be-fe-pleroma-smoke.sh
#
# Purpose:
#
#   Start an unfathomably-be backend, an unfathomably-fe frontend gateway,
#   and a reference Pleroma backend on one Docker network, then exercise the
#   most important compatibility paths between them.
#
# Responsibilities:
#
#   * create isolated PostgreSQL databases for both backend servers
#   * start unfathomably-be from this source tree
#   * start a reference Pleroma server from a local or cloned source tree
#   * serve unfathomably-fe as static assets through a same-origin nginx gateway
#   * proxy backend API routes through the frontend gateway
#   * create smoke users and OAuth tokens
#   * check local group administration on unfathomably-be
#   * check basic account federation between unfathomably-be and Pleroma
#   * fail loudly on unexpected HTTP statuses, 500s, or crash signatures
#
# This file intentionally does NOT contain:
#
#   * production deployment logic
#   * persistent database management
#   * real public DNS or TLS setup
#   * browser screenshot capture
#

set -euo pipefail

PREFIX="${PREFIX:-unfathomably-stack-smoke}"
NETWORK="${NETWORK:-${PREFIX}-net}"
DB_CONTAINER="${DB_CONTAINER:-${PREFIX}-db}"

BE_CONTAINER="${BE_CONTAINER:-${PREFIX}-be}"
PLEROMA_CONTAINER="${PLEROMA_CONTAINER:-${PREFIX}-pleroma}"
FE_CONTAINER="${FE_CONTAINER:-${PREFIX}-fe}"

BE_HOST="${BE_HOST:-unfathomably-be}"
PLEROMA_HOST="${PLEROMA_HOST:-pleroma-ref}"

BE_PORT="${BE_PORT:-4631}"
PLEROMA_PORT="${PLEROMA_PORT:-4632}"
FE_PORT="${FE_PORT:-4630}"

DB_PASSWORD="${DB_PASSWORD:-postgres}"
PASSWORD="${PASSWORD:-unfathomably-smoke-password}"

IMAGE="${SMOKE_IMAGE:-unfathomably-elixir-smoke:otp28}"
PLEROMA_IMAGE="${PLEROMA_IMAGE:-$IMAGE}"
NODE_IMAGE="${NODE_IMAGE:-node:26-bookworm}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$BE_ROOT/../.." && pwd)"

DEFAULT_FE_ROOT="$PROJECT_ROOT/soapbox-fbxl/.work/soapbox-modernize"
DEFAULT_FE_STATIC_ROOT="$PROJECT_ROOT/soapbox-fbxl"
FE_ROOT="${FE_ROOT:-$DEFAULT_FE_ROOT}"
FE_STATIC_ROOT="${FE_STATIC_ROOT:-$DEFAULT_FE_STATIC_ROOT}"

WORK_DIR="${WORK_DIR:-$BE_ROOT/.smoke/be-fe-pleroma}"
PLEROMA_ROOT="${PLEROMA_ROOT:-$WORK_DIR/upstream-pleroma}"
PLEROMA_REPO_URL="${PLEROMA_REPO_URL:-https://git.pleroma.social/pleroma/pleroma.git}"
PLEROMA_BRANCH="${PLEROMA_BRANCH:-develop}"

BE_SECRET="$WORK_DIR/be/dev.secret.exs"
PLEROMA_SECRET="$WORK_DIR/pleroma/dev.secret.exs"
FE_BUILD_DIR="$WORK_DIR/fe/dist"
NGINX_CONF="$WORK_DIR/nginx/default.conf"

cleanup() {
    if [ "${KEEP_SMOKE:-0}" = "1" ]; then
        cat <<EOF

KEEP_SMOKE=1 set, leaving smoke containers running.

Frontend gateway:  http://127.0.0.1:$FE_PORT
unfathomably-be:   http://127.0.0.1:$BE_PORT
Pleroma reference: http://127.0.0.1:$PLEROMA_PORT

EOF
        return 0
    fi

    docker rm -f "$FE_CONTAINER" "$BE_CONTAINER" "$PLEROMA_CONTAINER" "$DB_CONTAINER" >/dev/null 2>&1 || true
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
    for container in "$BE_CONTAINER" "$PLEROMA_CONTAINER" "$FE_CONTAINER"; do
        if docker ps -a --format '{{.Names}}' | grep -Fx "$container" >/dev/null 2>&1; then
            printf '\n--- %s logs ---\n' "$container" >&2
            docker logs --tail 120 "$container" >&2 || true
        fi
    done
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

poll_json_assert() {
    local url="$1"
    local token="$2"
    local expression="$3"
    local message="$4"

    for _ in $(seq 1 60); do
        local body
        body="$(http_json GET "$url" "$token" 200)"

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

wait_http() {
    local url="$1"
    local label="$2"

    for _ in $(seq 1 120); do
        if curl -fsS "$url" >/dev/null 2>&1; then
            return 0
        fi

        sleep 1
    done

    fail "Timed out waiting for $label at $url"
}

write_secret() {
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
  url: [scheme: "http", host: "$host", port: 4000],
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
config :pleroma, :frontend_configurations, soapbox_fe: %{}
config :pleroma, :database, rum_enabled: false
config :pleroma, configurable_from_database: false
config :pleroma, :rate_limit, nil
config :pleroma, :modules, runtime_dir: "$WORK_DIR/runtime-$host"
config :pleroma, Pleroma.ScheduledActivity, daily_user_limit: 1000, total_user_limit: 10000
EOF
}

docker_run_mix() {
    local image="$1"
    local root="$2"
    local secret="$3"
    local name="$4"
    local log_file="$WORK_DIR/logs/$name.log"
    shift 4

    if ! docker run --rm \
        --name "$name" \
        --network "$NETWORK" \
        -e MIX_ENV=dev \
        -e MIX_HOME=/tmp/mix \
        -e HEX_HOME=/tmp/hex \
        -v "$root:/work" \
        -v "$secret:/work/config/dev.secret.exs:ro" \
        "$image" \
        bash -lc "set -euo pipefail; cd /work; git config --global --add safe.directory /work >/dev/null 2>&1 || true; mix local.hex --force >/dev/null; mix local.rebar --force >/dev/null; mix deps.get >/dev/null; $*" \
        >"$log_file" 2>&1; then
        cat "$log_file" >&2 || true
        return 1
    fi
}

prepare_database() {
    local image="$1"
    local root="$2"
    local database="$3"
    local secret="$4"

    docker exec "$DB_CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 \
        -c "CREATE DATABASE $database;" >/dev/null

    docker_run_mix "$image" "$root" "$secret" "${PREFIX}-migrate-$database" \
        "mix ecto.migrate"
}

strict_compile_backend() {
    docker_run_mix "$IMAGE" "$BE_ROOT" "$BE_SECRET" "${PREFIX}-compile-be" \
        "mix compile --warnings-as-errors --no-all-warnings >/dev/null"
}

start_backend() {
    local image="$1"
    local root="$2"
    local secret="$3"
    local container="$4"
    local alias="$5"
    local port="$6"

    docker run -d \
        --name "$container" \
        --hostname "$alias" \
        --network "$NETWORK" \
        --network-alias "$alias" \
        -p "127.0.0.1:$port:4000" \
        -e MIX_ENV=dev \
        -e MIX_HOME=/tmp/mix \
        -e HEX_HOME=/tmp/hex \
        -v "$root:/work" \
        -v "$secret:/work/config/dev.secret.exs:ro" \
        "$image" \
        bash -lc 'set -euo pipefail; cd /work; git config --global --add safe.directory /work >/dev/null 2>&1 || true; mix local.hex --force >/dev/null; mix local.rebar --force >/dev/null; mix deps.get >/dev/null; exec mix phx.server' \
        >/dev/null
}

create_user() {
    local image="$1"
    local root="$2"
    local secret="$3"
    local label="$4"
    local nickname="$5"
    local email="$6"

    docker_run_mix "$image" "$root" "$secret" "${PREFIX}-user-$label-$nickname" \
        "mix pleroma.user new '$nickname' '$email' --password '$PASSWORD' --assume-yes >/dev/null"
}

create_token() {
    local base="$1"
    local username="$2"

    local app
    app="$(http_json POST "$base/api/v1/apps" "" 200 \
        "client_name=stack-smoke-$username" \
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

ensure_pleroma_source() {
    if [ -f "$PLEROMA_ROOT/mix.exs" ]; then
        return 0
    fi

    mkdir -p "$(dirname "$PLEROMA_ROOT")"
    git clone --depth 1 --branch "$PLEROMA_BRANCH" "$PLEROMA_REPO_URL" "$PLEROMA_ROOT"
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
        proxy_pass http://$BE_HOST:4000;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
    }

    location /oauth/ {
        proxy_pass http://$BE_HOST:4000;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
    }

    location /.well-known/ {
        proxy_pass http://$BE_HOST:4000;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
    }

    location /nodeinfo/ {
        proxy_pass http://$BE_HOST:4000;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
    }

    location /socket/ {
        proxy_pass http://$BE_HOST:4000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
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

step "Cleaning any previous stack smoke containers"
cleanup

step "Preparing smoke working directories"
rm -rf "$WORK_DIR/be" "$WORK_DIR/pleroma" "$WORK_DIR/runtime-$BE_HOST" "$WORK_DIR/runtime-$PLEROMA_HOST"
mkdir -p "$WORK_DIR/be" "$WORK_DIR/pleroma" "$WORK_DIR/nginx" "$WORK_DIR/logs"

step "Preparing reference Pleroma source"
ensure_pleroma_source

step "Preparing frontend static assets"
prepare_frontend_static
write_nginx_config

step "Writing generated smoke configs"
write_secret "$BE_SECRET" "Unfathomably BE Smoke" "$BE_HOST" "unfathomably_stack_smoke_be" "$WORK_DIR/be/uploads" "$WORK_DIR/be/static"
write_secret "$PLEROMA_SECRET" "Pleroma Reference Smoke" "$PLEROMA_HOST" "unfathomably_stack_smoke_pleroma" "$WORK_DIR/pleroma/uploads" "$WORK_DIR/pleroma/static"

step "Creating Docker network and database"
docker network create "$NETWORK" >/dev/null
docker run -d \
    --name "$DB_CONTAINER" \
    --network "$NETWORK" \
    -e POSTGRES_PASSWORD="$DB_PASSWORD" \
    postgres:17 >/dev/null

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

step "Migrating both backend databases"
prepare_database "$IMAGE" "$BE_ROOT" "unfathomably_stack_smoke_be" "$BE_SECRET"
prepare_database "$PLEROMA_IMAGE" "$PLEROMA_ROOT" "unfathomably_stack_smoke_pleroma" "$PLEROMA_SECRET"

step "Creating smoke users"
create_user "$IMAGE" "$BE_ROOT" "$BE_SECRET" "be" "alice" "alice@$BE_HOST"
create_user "$IMAGE" "$BE_ROOT" "$BE_SECRET" "be" "moda" "moda@$BE_HOST"
create_user "$IMAGE" "$BE_ROOT" "$BE_SECRET" "be" "thirda" "thirda@$BE_HOST"
create_user "$PLEROMA_IMAGE" "$PLEROMA_ROOT" "$PLEROMA_SECRET" "pleroma" "pat" "pat@$PLEROMA_HOST"

BE_BASE="http://127.0.0.1:$BE_PORT"
PLEROMA_BASE="http://127.0.0.1:$PLEROMA_PORT"
FE_BASE="http://127.0.0.1:$FE_PORT"

step "Starting unfathomably-be"
start_backend "$IMAGE" "$BE_ROOT" "$BE_SECRET" "$BE_CONTAINER" "$BE_HOST" "$BE_PORT"
wait_http "$BE_BASE/api/v1/instance" "unfathomably-be"

step "Starting Pleroma reference"
start_backend "$PLEROMA_IMAGE" "$PLEROMA_ROOT" "$PLEROMA_SECRET" "$PLEROMA_CONTAINER" "$PLEROMA_HOST" "$PLEROMA_PORT"
wait_http "$PLEROMA_BASE/api/v1/instance" "Pleroma reference"

step "Starting unfathomably-fe gateway"
start_frontend_gateway
wait_http "$FE_BASE/" "unfathomably-fe"

step "Creating OAuth tokens"
ALICE_TOKEN="$(create_token "$BE_BASE" "alice")"
MODA_TOKEN="$(create_token "$BE_BASE" "moda")"
THIRDA_TOKEN="$(create_token "$BE_BASE" "thirda")"
PAT_TOKEN="$(create_token "$PLEROMA_BASE" "pat")"

ALICE_ACCOUNT="$(http_json GET "$BE_BASE/api/v1/accounts/verify_credentials" "$ALICE_TOKEN" 200)"
MODA_ACCOUNT="$(http_json GET "$BE_BASE/api/v1/accounts/verify_credentials" "$MODA_TOKEN" 200)"
THIRDA_ACCOUNT="$(http_json GET "$BE_BASE/api/v1/accounts/verify_credentials" "$THIRDA_TOKEN" 200)"
PAT_ACCOUNT="$(http_json GET "$PLEROMA_BASE/api/v1/accounts/verify_credentials" "$PAT_TOKEN" 200)"

MODA_ID="$(json_get "$MODA_ACCOUNT" id)"
THIRDA_ID="$(json_get "$THIRDA_ACCOUNT" id)"

step "Checking FE-to-BE same-origin wiring"
FE_INDEX="$(curl -fsS "$FE_BASE/")"
case "$FE_INDEX" in
    *"<html"*|*"<!doctype html"*|*"<!DOCTYPE html"*) ;;
    *) fail "frontend index did not look like an HTML application shell" ;;
esac

FE_INSTANCE="$(http_json GET "$FE_BASE/api/v1/instance" "" 200)"
json_assert "$FE_INSTANCE" '("Unfathomably" in data.get("title", "")) or ("Unfathomably" in data.get("uri", "")) or ("unfathomably" in str(data).lower())' "frontend gateway proxies instance API to unfathomably-be"

step "Checking discovery endpoints on both backends"
curl -fsS "$BE_BASE/.well-known/webfinger?resource=acct:alice@$BE_HOST" >/dev/null
curl -fsS "$PLEROMA_BASE/.well-known/webfinger?resource=acct:pat@$PLEROMA_HOST" >/dev/null
curl -fsS "$BE_BASE/nodeinfo/2.1.json" >/dev/null
curl -fsS "$PLEROMA_BASE/nodeinfo/2.1.json" >/dev/null || curl -fsS "$PLEROMA_BASE/nodeinfo/2.0.json" >/dev/null

step "Testing unfathomably-be local group administration"
OPEN_GROUP="$(http_json POST "$BE_BASE/api/v1/groups" "$ALICE_TOKEN" 200 \
    "display_name=Stack Smoke Open Group" \
    "name=stack-smoke-open-group" \
    "note=Open smoke group served through the BE/FE/Pleroma stack test." \
    "locked=false")"
OPEN_GROUP_ID="$(json_get "$OPEN_GROUP" id)"
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

CLOSED_GROUP="$(http_json POST "$BE_BASE/api/v1/groups" "$ALICE_TOKEN" 200 \
    "display_name=Stack Smoke Closed Group" \
    "name=stack-smoke-closed-group" \
    "note=Closed smoke group for request approval checks." \
    "locked=true")"
CLOSED_GROUP_ID="$(json_get "$CLOSED_GROUP" id)"

CLOSED_JOIN="$(http_json POST "$BE_BASE/api/v1/groups/$CLOSED_GROUP_ID/join" "$THIRDA_TOKEN" 200)"
json_assert "$CLOSED_JOIN" 'data["member"] is False and data["requested"] is True' "closed group join stays pending"

APPROVED="$(http_json POST "$BE_BASE/api/v1/groups/$CLOSED_GROUP_ID/membership_requests/$THIRDA_ID/authorize" "$ALICE_TOKEN" 200)"
json_assert "$APPROVED" 'data["member"] is True and data["requested"] is False' "closed group request can be approved"

step "Testing status actions through the frontend gateway"
FE_STATUS="$(http_json POST "$FE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
    "status=Stack smoke post through unfathomably-fe gateway" \
    "visibility=public")"
FE_STATUS_ID="$(json_get "$FE_STATUS" id)"

FE_CONTEXT="$(http_json GET "$FE_BASE/api/v1/statuses/$FE_STATUS_ID/context" "$ALICE_TOKEN" 200)"
json_assert "$FE_CONTEXT" '"ancestors" in data and "descendants" in data' "frontend gateway can read status context"

step "Testing account federation between unfathomably-be and Pleroma"
ALICE_ACTOR_URL="$(json_get "$ALICE_ACCOUNT" url)"
PAT_ACTOR_URL="$(json_get "$PAT_ACCOUNT" url)"

REMOTE_ALICE="$(poll_json_assert \
    "$PLEROMA_BASE/api/v2/search?resolve=true&type=accounts&q=$(urlencode "$ALICE_ACTOR_URL")" \
    "$PAT_TOKEN" \
    'len(data.get("accounts", [])) >= 1 and data["accounts"][0]["id"] != ""' \
    "Pleroma to resolve unfathomably-be account")"
REMOTE_ALICE_ID="$(json_get "$REMOTE_ALICE" accounts.0.id)"
json_assert "$REMOTE_ALICE" 'len(data.get("accounts", [])) >= 1 and data["accounts"][0]["id"] != ""' "Pleroma can resolve unfathomably-be account"

REMOTE_PAT="$(poll_json_assert \
    "$BE_BASE/api/v2/search?resolve=true&type=accounts&q=$(urlencode "$PAT_ACTOR_URL")" \
    "$ALICE_TOKEN" \
    'len(data.get("accounts", [])) >= 1 and data["accounts"][0]["id"] != ""' \
    "unfathomably-be to resolve Pleroma account")"
REMOTE_PAT_ID="$(json_get "$REMOTE_PAT" accounts.0.id)"
json_assert "$REMOTE_PAT" 'len(data.get("accounts", [])) >= 1 and data["accounts"][0]["id"] != ""' "unfathomably-be can resolve Pleroma account"

PAT_FOLLOWS_ALICE="$(http_json POST "$PLEROMA_BASE/api/v1/accounts/$REMOTE_ALICE_ID/follow" "$PAT_TOKEN" 200)"
json_assert "$PAT_FOLLOWS_ALICE" 'data["following"] is True or data["requested"] is True' "Pleroma can follow unfathomably-be account"

ALICE_FOLLOWS_PAT="$(http_json POST "$BE_BASE/api/v1/accounts/$REMOTE_PAT_ID/follow" "$ALICE_TOKEN" 200)"
json_assert "$ALICE_FOLLOWS_PAT" 'data["following"] is True or data["requested"] is True' "unfathomably-be can follow Pleroma account"

PAT_STATUS="$(http_json POST "$PLEROMA_BASE/api/v1/statuses" "$PAT_TOKEN" 200 \
    "status=Reference Pleroma smoke post for unfathomably-be lookup" \
    "visibility=public")"
PAT_STATUS_URI="$(json_get "$PAT_STATUS" uri)"

REMOTE_PAT_STATUS="$(poll_json_assert \
    "$BE_BASE/api/v2/search?resolve=true&type=statuses&q=$(urlencode "$PAT_STATUS_URI")" \
    "$ALICE_TOKEN" \
    'len(data.get("statuses", [])) >= 1' \
    "unfathomably-be to resolve a Pleroma status URL")"
json_assert "$REMOTE_PAT_STATUS" 'len(data.get("statuses", [])) >= 1' "unfathomably-be can resolve a Pleroma status URL"

step "Checking no obvious server crashes were logged"
for container in "$BE_CONTAINER" "$PLEROMA_CONTAINER" "$FE_CONTAINER"; do
    if docker logs "$container" 2>&1 | grep -E "status=500|Internal Server Error|\\*\\* \\(|GenServer terminating|FunctionClauseError|UndefinedFunctionError|Protocol\\.UndefinedError" >/dev/null; then
        docker logs --tail 200 "$container" >&2
        fail "$container logged a 500 or crash signature during smoke run"
    fi
done

cat <<EOF

Unfathomably BE/FE plus Pleroma smoke test passed.

Covered:
  * startup, migrations, frontend static serving, and FE-to-BE proxying
  * unfathomably-be instance discovery, WebFinger, NodeInfo
  * Pleroma reference instance discovery, WebFinger, NodeInfo
  * OAuth app creation and password-token login on both backends
  * unfathomably-be group create, open join, closed join request, approval
  * unfathomably-be group moderator promote, ban, block list, unban
  * status create/context through the frontend gateway
  * account resolution/follow in both directions between unfathomably-be and Pleroma
  * Pleroma status URL resolution from unfathomably-be
  * basic log scan for 500/crash output

Run with KEEP_SMOKE=1 to leave the stack available for browser/API work.
Run with BUILD_FE=1 to rebuild unfathomably-fe from FE_ROOT instead of using FE_STATIC_ROOT.
Use PLEROMA_ROOT to point at a prepared Pleroma checkout, or let the script clone one.
EOF

# end of build_scripts/be-fe-pleroma-smoke.sh
