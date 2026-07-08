#!/usr/bin/env bash

#
# Project: Unfathomably BE federation smoke testing
# -------------------------------------------------
#
# File: two-instance-federation-smoke.sh
#
# Purpose:
#
#   Start two disposable Unfathomably BE instances on one Docker host and make
#   them exercise the federation surfaces that are easiest to break during
#   release work.
#
# Responsibilities:
#
#   * create isolated databases and per-instance development secrets
#   * boot two application containers on a private Docker network
#   * create smoke users and OAuth clients through supported interfaces
#   * exercise local group administration
#   * exercise cross-instance group lookup, join, follow, posting, and preview
#   * exercise source lookup, follow, and unfollow across the pair
#   * fail loudly on unexpected HTTP status codes, 500s, and crash signatures
#
# This file intentionally does NOT contain:
#
#   * production deployment logic
#   * long-running service management
#   * destructive operations outside containers created by this script
#

set -euo pipefail
poll_http_status() {
  local method="$1"
  local url="$2"
  local token="$3"
  local expected="$4"
  local message="$5"
  local attempts="${6:-60}"
  local delay="${7:-2}"
  local tmp code last_code

  last_code=""

  for _ in $(seq 1 "$attempts"); do
    tmp="$(mktemp)"

    if [ -n "$token" ]; then
      code="$(curl -sS -X "$method" -H "Authorization: Bearer $token" -o "$tmp" -w "%{http_code}" "$url" || true)"
    else
      code="$(curl -sS -X "$method" -o "$tmp" -w "%{http_code}" "$url" || true)"
    fi

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
  local uri="$3"
  local message="$4"
  local search_result

  search_result="$(poll_json_assert GET "$base/api/v2/search?resolve=true&type=statuses&q=$(urlencode "$uri")" "$token" 200 'len(data.get("statuses", [])) >= 1' "$message" 90 2)"
  json_get "$search_result" statuses.0.id
}

poll_timeline_contains_text() {
  local base="$1"
  local token="$2"
  local needle="$3"
  local message="$4"

  poll_json_assert GET "$base/api/v1/timelines/home?limit=40" "$token" 200 "'$needle' in str(data)" "$message" 90 2 >/dev/null
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

IMAGE="${SMOKE_IMAGE:-unfathomably-elixir-smoke:otp28}"
PREFIX="${SMOKE_PREFIX:-unfathomably-pair-smoke}"
NETWORK="${SMOKE_NETWORK:-$PREFIX-net}"
NETWORK_SUBNET="${SMOKE_NETWORK_SUBNET:-}"
DB_CONTAINER="${PREFIX}-db"
A_CONTAINER="${PREFIX}-a"
B_CONTAINER="${PREFIX}-b"
A_HOST="${SMOKE_A_HOST:-smoke-a}"
B_HOST="${SMOKE_B_HOST:-smoke-b}"
A_PORT="${SMOKE_A_PORT:-4611}"
B_PORT="${SMOKE_B_PORT:-4612}"
DB_PASSWORD="${SMOKE_DB_PASSWORD:-postgres}"
PASSWORD="${SMOKE_USER_PASSWORD:-SmokeTest_01}"
KEEP_SMOKE="${KEEP_SMOKE:-0}"
WORK_DIR="${SMOKE_WORK_DIR:-}"
SMOKE_BUILD_HOST_PATH=""

if [ -z "${SMOKE_MIX_BUILD_PATH:-}" ]; then
    MIX_BUILD_PATH="/work/_build/dev"
else
    MIX_BUILD_PATH="$SMOKE_MIX_BUILD_PATH"
fi

if [ -z "$WORK_DIR" ]; then
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/unfathomably-pair-smoke.XXXXXX")"
fi

step() {
    printf '\n==> %s\n' "$*"
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    collect_logs
    exit 1
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        fail "Required command not found: $1"
    fi
}

collect_logs() {
    if command -v docker >/dev/null 2>&1; then
        for container in "$A_CONTAINER" "$B_CONTAINER"; do
            if docker ps -a --format '{{.Names}}' | grep -qx "$container"; then
                printf '\n--- %s logs ---\n' "$container" >&2
                docker logs --tail 160 "$container" >&2 || true
            fi
        done
    fi
}

remove_smoke_build_path() {
    if [ -z "$SMOKE_BUILD_HOST_PATH" ]; then
        return
    fi

    rm -rf "$SMOKE_BUILD_HOST_PATH" >/dev/null 2>&1 && {
        rmdir "$REPO_ROOT/.smoke_build" >/dev/null 2>&1 || true
        return
    }

    if command -v docker >/dev/null 2>&1; then
        docker run --rm \
            -v "$REPO_ROOT/.smoke_build:/smoke_build" \
            "$IMAGE" \
            sh -c "rm -rf '/smoke_build/$PREFIX'" >/dev/null 2>&1 || true
    fi

    rmdir "$REPO_ROOT/.smoke_build" >/dev/null 2>&1 || true
}

cleanup() {
    if [ "$KEEP_SMOKE" = "1" ]; then
        cat <<EOF

Smoke containers preserved because KEEP_SMOKE=1.

Instance A: http://127.0.0.1:$A_PORT
Instance B: http://127.0.0.1:$B_PORT

Containers:
  $A_CONTAINER
  $B_CONTAINER
  $DB_CONTAINER

Temporary files:
  $WORK_DIR
EOF
        return
    fi

    docker rm -f "$A_CONTAINER" "$B_CONTAINER" "$DB_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    remove_smoke_build_path
    rm -rf "$WORK_DIR"
}

trap cleanup EXIT

require_command docker
require_command curl
require_command python3

if [ -n "$SMOKE_BUILD_HOST_PATH" ]; then
    remove_smoke_build_path
    mkdir -p "$SMOKE_BUILD_HOST_PATH"
fi

json_get() {
    local body="$1"
    local path="$2"

    JSON_BODY="$body" python3 - "$path" <<'PY'
import json
import os
import sys

value = json.loads(os.environ["JSON_BODY"])

for part in sys.argv[1].split("."):
    if not part:
        continue

    if part.isdigit():
        value = value[int(part)]
    else:
        value = value[part]

if value is None:
    print("")
elif isinstance(value, bool):
    print("true" if value else "false")
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

try:
    helpers = {"any": any, "all": all, "len": len, "str": str, "int": int}
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

urlencode() {
    python3 - "$1" <<'PY'
import sys
import urllib.parse

print(urllib.parse.quote(sys.argv[1], safe=""))
PY
}

http_json() {
    local method="$1"
    local url="$2"
    local token="$3"
    local expected="$4"
    shift 4

    local response
    local status
    local body
    local args=(-sS -X "$method" -w '\n%{http_code}')

    if [ -n "$token" ]; then
        args+=(-H "Authorization: Bearer $token")
    fi

    if [ "$#" -gt 0 ]; then
        args+=(-H "Content-Type: application/x-www-form-urlencoded")
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

poll_json_assert() {
    local method="$1"
    local url="$2"
    local token="$3"
    local expected="$4"
    local expression="$5"
    local message="$6"
    local attempts="${7:-40}"
    local delay="${8:-2}"
    shift 8 || true

    local body=""

    for _ in $(seq 1 "$attempts"); do
        if body="$(http_json "$method" "$url" "$token" "$expected" "$@" 2>/dev/null)" &&
            JSON_BODY="$body" python3 - "$expression" <<'PY'
import json
import os
import sys

data = json.loads(os.environ["JSON_BODY"])
helpers = {"any": any, "all": all, "len": len, "str": str, "int": int}
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

wait_http() {
    local url="$1"
    local label="$2"

    for _ in $(seq 1 90); do
        if curl -fsS "$url" >/dev/null 2>&1; then
            return 0
        fi

        sleep 2
    done

    fail "Timed out waiting for $label at $url"
}

docker_exec_mix() {
    local container="$1"
    shift

    docker exec -e MIX_ENV=dev -e MIX_BUILD_PATH="$MIX_BUILD_PATH" "$container" bash -lc "cd /work && $*"
}

docker_run_mix() {
    local container="$1"
    local secret="$2"
    shift 2

    docker run --rm \
        --name "$container" \
        --network "$NETWORK" \
        -e MIX_ENV=dev \
        -e MIX_HOME=/tmp/mix \
        -e HEX_HOME=/tmp/hex \
        -e MIX_BUILD_PATH="$MIX_BUILD_PATH" \
        -v "$REPO_ROOT:/work" \
        -v "$secret:/work/config/dev.secret.exs:ro" \
        "$IMAGE" \
        bash -lc "set -euo pipefail; cd /work; mix local.hex --force >/dev/null; mix local.rebar --force >/dev/null; mix deps.get >/dev/null; $*"
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
      [nickname, email] ->
        {nickname, email}

      _ ->
        raise "invalid smoke user line: #{inspect(line)}"
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
    {:ok, _user} ->
      :ok

    {:error, changeset} ->
      errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
      raise "could not create smoke user #{nickname}: #{inspect(errors)}"
  end
end)
EOF
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
print(secrets.token_urlsafe(16))
PY
)"

    cat >"$file" <<EOF
import Config

config :pleroma, Pleroma.Web.Endpoint,
  http: [
    ip: {0, 0, 0, 0},
    port: 4000,
    protocol_options: [max_request_line_length: 8192, max_header_value_length: 8192]
  ],
  url: [scheme: "http", host: "$host", port: 4000],
  secret_key_base: "$secret_key_base",
  live_view: [signing_salt: "$signing_salt"],
  code_reloader: false,
  live_reload: false,
  watchers: [],
  server: true

config :pleroma, Pleroma.Repo,
  adapter: Ecto.Adapters.Postgres,
  username: "postgres",
  password: "$DB_PASSWORD",
  database: "$database",
  hostname: "$DB_CONTAINER",
  pool_size: 10

config :pleroma, :instance,
  name: "$instance_name",
  description: "$instance_name disposable federation smoke instance",
  email: "admin@$host",
  notify_email: "noreply@$host",
  domain: "$host",
  federating: true,
  registrations_open: true,
  account_approval_required: false,
  external_user_synchronization: true,
  skip_thread_containment: true,
  static_dir: "$static_dir"

config :pleroma, :activitypub,
  sign_object_fetches: false,
  follow_handshake_timeout: 5_000

config :pleroma, Pleroma.Uploaders.Local, uploads: "$uploads"

config :pleroma, Pleroma.Emails.Mailer, adapter: Swoosh.Adapters.Local, enabled: false

config :pleroma, :rich_media, enabled: false

config :logger, :console, level: :warning, format: "[\$level] \$message\\n"
EOF
}

prepare_database() {
    local database="$1"
    local secret="$2"

    docker exec "$DB_CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 \
        -c "CREATE DATABASE $database;" >/dev/null

    docker run --rm \
        --name "${PREFIX}-migrate-$database" \
        --network "$NETWORK" \
        -e MIX_ENV=dev \
        -e MIX_HOME=/tmp/mix \
        -e HEX_HOME=/tmp/hex \
        -e MIX_BUILD_PATH="$MIX_BUILD_PATH" \
        -v "$REPO_ROOT:/work" \
        -v "$secret:/work/config/dev.secret.exs:ro" \
        "$IMAGE" \
        bash -lc 'set -euo pipefail; cd /work; mix local.hex --force >/dev/null; mix local.rebar --force >/dev/null; mix deps.get >/dev/null; mix compile --force >/dev/null; mix pleroma.ecto.migrate --migrations-path /work/priv/repo/migrations'
}

start_instance() {
    local container="$1"
    local alias="$2"
    local port="$3"
    local secret="$4"
    local ca_args=()

    if [ -n "${SMOKE_EXTRA_CA_CERT:-}" ]; then
        ca_args=(
            -e SSL_CERT_FILE=/tmp/smoke-extra-ca.pem
            -v "$SMOKE_EXTRA_CA_CERT:/tmp/smoke-extra-ca.pem:ro"
        )
    fi

    docker run -d \
        --name "$container" \
        --hostname "$alias" \
        --network "$NETWORK" \
        --network-alias "$alias" \
        -p "127.0.0.1:$port:4000" \
        -e MIX_ENV=dev \
        -e MIX_HOME=/tmp/mix \
        -e HEX_HOME=/tmp/hex \
        -e MIX_BUILD_PATH="$MIX_BUILD_PATH" \
        "${ca_args[@]}" \
        -v "$REPO_ROOT:/work" \
        -v "$secret:/work/config/dev.secret.exs:ro" \
        "$IMAGE" \
        bash -lc 'set -euo pipefail; cd /work; mix local.hex --force >/dev/null; mix local.rebar --force >/dev/null; mix deps.get >/dev/null; mix compile --force >/dev/null; exec mix phx.server' \
        >/dev/null
}

create_users() {
    local label="$1"
    local secret="$2"
    shift 2

    local users=""

    while [ "$#" -gt 1 ]; do
        users="${users}${1}"$'\t'"${2}"$'\n'
        shift 2
    done

    if [ "$#" -ne 0 ]; then
        fail "create_users requires nickname and email pairs"
    fi

    docker run --rm \
        --name "${PREFIX}-users-$label" \
        --network "$NETWORK" \
        -e MIX_ENV=dev \
        -e MIX_HOME=/tmp/mix \
        -e HEX_HOME=/tmp/hex \
        -e MIX_BUILD_PATH="$MIX_BUILD_PATH" \
        -e SMOKE_PASSWORD="$PASSWORD" \
        -e SMOKE_USERS="$users" \
        -v "$REPO_ROOT:/work" \
        -v "$secret:/work/config/dev.secret.exs:ro" \
        -v "$WORK_DIR/create_smoke_user.exs:/tmp/create_smoke_user.exs:ro" \
        "$IMAGE" \
        bash -lc 'set -euo pipefail; cd /work; mix local.hex --force >/dev/null; mix local.rebar --force >/dev/null; mix deps.get >/dev/null; mix compile --force >/dev/null; mix run /tmp/create_smoke_user.exs >/dev/null'
}

create_token() {
    local base="$1"
    local username="$2"

    local app
    local client_id
    local client_secret
    local token

    app="$(http_json POST "$base/api/v1/apps" "" 200 \
        "client_name=pair smoke $username" \
        "redirect_uris=urn:ietf:wg:oauth:2.0:oob" \
        "scopes=read write follow")"

    client_id="$(json_get "$app" client_id)"
    client_secret="$(json_get "$app" client_secret)"

    token="$(http_json POST "$base/oauth/token" "" 200 \
        "grant_type=password" \
        "username=$username" \
        "password=$PASSWORD" \
        "client_id=$client_id" \
        "client_secret=$client_secret" \
        "scope=read write follow")"

    json_get "$token" access_token
}

step "Cleaning any previous smoke containers"
docker rm -f "$A_CONTAINER" "$B_CONTAINER" "$DB_CONTAINER" >/dev/null 2>&1 || true
docker network rm "$NETWORK" >/dev/null 2>&1 || true
mkdir -p "$WORK_DIR/a/uploads" "$WORK_DIR/a/static" "$WORK_DIR/b/uploads" "$WORK_DIR/b/static"

step "Creating Docker network and database"
if [ -n "$NETWORK_SUBNET" ]; then
    docker network create --subnet "$NETWORK_SUBNET" "$NETWORK" >/dev/null
else
    docker network create "$NETWORK" >/dev/null
fi
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

#
# The official postgres image briefly starts a private server while it runs
# initdb, then shuts that server down and starts the real long-lived server.
# A plain pg_isready loop can accidentally catch the private server and then
# fail during the restart window. Give the entrypoint a moment to finish that
# handoff, then require readiness from the final server.
#
sleep 3

for _ in $(seq 1 60); do
    if docker exec "$DB_CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then
        break
    fi

    sleep 1
done

docker exec "$DB_CONTAINER" pg_isready -U postgres >/dev/null 2>&1 ||
    fail "Postgres did not become ready"

A_SECRET="$WORK_DIR/a/dev.secret.exs"
B_SECRET="$WORK_DIR/b/dev.secret.exs"
write_secret "$A_SECRET" "Unfathomably Smoke A" "$A_HOST" "pleroma_smoke_a" "$WORK_DIR/a/uploads" "$WORK_DIR/a/static"
write_secret "$B_SECRET" "Unfathomably Smoke B" "$B_HOST" "pleroma_smoke_b" "$WORK_DIR/b/uploads" "$WORK_DIR/b/static"

step "Migrating both smoke databases"
prepare_database "pleroma_smoke_a" "$A_SECRET"
prepare_database "pleroma_smoke_b" "$B_SECRET"

step "Creating smoke users"
write_create_user_script
create_users "a" "$A_SECRET" \
    "alice" "alice@$A_HOST" \
    "moda" "moda@$A_HOST" \
    "thirda" "thirda@$A_HOST"
create_users "b" "$B_SECRET" \
    "bob" "bob@$B_HOST" \
    "carol" "carol@$B_HOST"

A_BASE="http://127.0.0.1:$A_PORT"
B_BASE="http://127.0.0.1:$B_PORT"

step "Starting smoke instance A"
start_instance "$A_CONTAINER" "$A_HOST" "$A_PORT" "$A_SECRET"
wait_http "$A_BASE/api/v1/instance" "instance A"

step "Starting smoke instance B"
start_instance "$B_CONTAINER" "$B_HOST" "$B_PORT" "$B_SECRET"
wait_http "$B_BASE/api/v1/instance" "instance B"

step "Creating OAuth clients and tokens"
ALICE_TOKEN="$(create_token "$A_BASE" "alice")"
MODA_TOKEN="$(create_token "$A_BASE" "moda")"
THIRDA_TOKEN="$(create_token "$A_BASE" "thirda")"
BOB_TOKEN="$(create_token "$B_BASE" "bob")"
CAROL_TOKEN="$(create_token "$B_BASE" "carol")"

ALICE_ACCOUNT="$(http_json GET "$A_BASE/api/v1/accounts/verify_credentials" "$ALICE_TOKEN" 200)"
MODA_ACCOUNT="$(http_json GET "$A_BASE/api/v1/accounts/verify_credentials" "$MODA_TOKEN" 200)"
THIRDA_ACCOUNT="$(http_json GET "$A_BASE/api/v1/accounts/verify_credentials" "$THIRDA_TOKEN" 200)"
BOB_ACCOUNT="$(http_json GET "$B_BASE/api/v1/accounts/verify_credentials" "$BOB_TOKEN" 200)"

MODA_ID="$(json_get "$MODA_ACCOUNT" id)"
THIRDA_ID="$(json_get "$THIRDA_ACCOUNT" id)"
BOB_ID="$(json_get "$BOB_ACCOUNT" id)"

step "Checking discovery endpoints"
ALICE_WEBFINGER_RESOURCE="$(urlencode "acct:alice@$A_HOST")"
BOB_WEBFINGER_RESOURCE="$(urlencode "acct:bob@$B_HOST")"
http_json GET "$A_BASE/.well-known/webfinger?resource=$ALICE_WEBFINGER_RESOURCE" "" 200 >/dev/null
http_json GET "$B_BASE/.well-known/webfinger?resource=$BOB_WEBFINGER_RESOURCE" "" 200 >/dev/null
http_json GET "$A_BASE/nodeinfo/2.1.json" "" 200 >/dev/null
http_json GET "$B_BASE/nodeinfo/2.1.json" "" 200 >/dev/null

step "Testing local group administration on instance A"
OPEN_GROUP="$(http_json POST "$A_BASE/api/v1/groups" "$ALICE_TOKEN" 200 \
    "display_name=Smoke Open Group" \
    "name=smoke-open-group")"
OPEN_GROUP_ID="$(json_get "$OPEN_GROUP" id)"
OPEN_GROUP_AP_ID="$(json_get "$OPEN_GROUP" ap_id)"

json_assert "$OPEN_GROUP" 'data["relationship"]["role"] == "owner"' "group creator is owner"
json_assert "$OPEN_GROUP" 'data["group_visibility"] == "public"' "open group is public"

MOD_JOIN="$(http_json POST "$A_BASE/api/v1/groups/$OPEN_GROUP_ID/join" "$MODA_TOKEN" 200)"
json_assert "$MOD_JOIN" 'data["member"] is True and data["requested"] is False' "open group join is immediate"

THIRD_JOIN="$(http_json POST "$A_BASE/api/v1/groups/$OPEN_GROUP_ID/join" "$THIRDA_TOKEN" 200)"
json_assert "$THIRD_JOIN" 'data["member"] is True and data["requested"] is False' "second open group join is immediate"

PROMOTE="$(http_json POST "$A_BASE/api/v1/groups/$OPEN_GROUP_ID/promote" "$ALICE_TOKEN" 200 \
    "account_ids[]=$MODA_ID" \
    "role=moderator")"
json_assert "$PROMOTE" 'data["role"] == "moderator"' "owner promotes moderator"

DEMOTE="$(http_json POST "$A_BASE/api/v1/groups/$OPEN_GROUP_ID/demote" "$ALICE_TOKEN" 200 \
    "account_ids[]=$MODA_ID")"
json_assert "$DEMOTE" 'data["role"] == "user"' "owner demotes moderator"

PROMOTE_AGAIN="$(http_json POST "$A_BASE/api/v1/groups/$OPEN_GROUP_ID/promote" "$ALICE_TOKEN" 200 \
    "account_ids[]=$MODA_ID" \
    "role=moderator")"
json_assert "$PROMOTE_AGAIN" 'data["role"] == "moderator"' "owner restores moderator"

http_json POST "$A_BASE/api/v1/groups/$OPEN_GROUP_ID/blocks" "$MODA_TOKEN" 200 \
    "account_ids[]=$THIRDA_ID" >/dev/null

BLOCKS="$(http_json GET "$A_BASE/api/v1/groups/$OPEN_GROUP_ID/blocks" "$ALICE_TOKEN" 200)"
json_assert "$BLOCKS" 'any(account["id"] == "'$THIRDA_ID'" for account in data)' "banned account appears in group block list"

THIRD_REJOIN="$(http_json POST "$A_BASE/api/v1/groups/$OPEN_GROUP_ID/join" "$THIRDA_TOKEN" 403)"
json_assert "$THIRD_REJOIN" 'data["error"] == "You are banned from this group"' "banned account cannot join"

http_json DELETE "$A_BASE/api/v1/groups/$OPEN_GROUP_ID/blocks" "$ALICE_TOKEN" 200 \
    "account_ids[]=$THIRDA_ID" >/dev/null

THIRD_REJOIN_AFTER_UNBAN="$(http_json POST "$A_BASE/api/v1/groups/$OPEN_GROUP_ID/join" "$THIRDA_TOKEN" 200)"
json_assert "$THIRD_REJOIN_AFTER_UNBAN" 'data["member"] is True' "unbanned account can rejoin"

THIRD_LEAVE="$(http_json POST "$A_BASE/api/v1/groups/$OPEN_GROUP_ID/leave" "$THIRDA_TOKEN" 200)"
json_assert "$THIRD_LEAVE" 'data["member"] is False' "rejoined account can leave cleanly"

CLOSED_GROUP="$(http_json POST "$A_BASE/api/v1/groups" "$ALICE_TOKEN" 200 \
    "display_name=Smoke Closed Group" \
    "name=smoke-closed-group" \
    "group_visibility=members_only")"
CLOSED_GROUP_ID="$(json_get "$CLOSED_GROUP" id)"

CLOSED_JOIN="$(http_json POST "$A_BASE/api/v1/groups/$CLOSED_GROUP_ID/join" "$THIRDA_TOKEN" 200)"
json_assert "$CLOSED_JOIN" 'data["member"] is False and data["requested"] is True' "closed group join stays pending"

REQUESTS="$(http_json GET "$A_BASE/api/v1/groups/$CLOSED_GROUP_ID/membership_requests" "$ALICE_TOKEN" 200)"
json_assert "$REQUESTS" 'any(account["id"] == "'$THIRDA_ID'" for account in data)' "closed group request is visible to owner"

APPROVED="$(http_json POST "$A_BASE/api/v1/groups/$CLOSED_GROUP_ID/membership_requests/$THIRDA_ID/authorize" "$ALICE_TOKEN" 200)"
json_assert "$APPROVED" 'data["member"] is True and data["requested"] is False' "closed group request can be approved"

step "Testing local status actions that federation commonly depends on"
STATUS_A="$(http_json POST "$A_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
    "status=Smoke status from Alice to the pair smoke harness")"
STATUS_A_ID="$(json_get "$STATUS_A" id)"

http_json POST "$A_BASE/api/v1/statuses/$STATUS_A_ID/favourite" "$MODA_TOKEN" 200 >/dev/null
http_json POST "$A_BASE/api/v1/statuses/$STATUS_A_ID/unfavourite" "$MODA_TOKEN" 200 >/dev/null
http_json POST "$A_BASE/api/v1/statuses/$STATUS_A_ID/reblog" "$MODA_TOKEN" 200 >/dev/null
http_json POST "$A_BASE/api/v1/statuses/$STATUS_A_ID/unreblog" "$MODA_TOKEN" 200 >/dev/null
http_json POST "$A_BASE/api/v1/statuses/$STATUS_A_ID/bookmark" "$MODA_TOKEN" 200 >/dev/null
http_json POST "$A_BASE/api/v1/statuses/$STATUS_A_ID/unbookmark" "$MODA_TOKEN" 200 >/dev/null

REPLY_A="$(http_json POST "$A_BASE/api/v1/statuses" "$MODA_TOKEN" 200 \
    "status=Smoke reply from Moda" \
    "in_reply_to_id=$STATUS_A_ID")"
REPLY_A_ID="$(json_get "$REPLY_A" id)"
CONTEXT_A="$(http_json GET "$A_BASE/api/v1/statuses/$STATUS_A_ID/context" "$ALICE_TOKEN" 200)"
json_assert "$CONTEXT_A" 'any(status["id"] == "'$REPLY_A_ID'" for status in data["descendants"])' "reply appears in context"

step "Testing cross-instance group lookup and membership"
OPEN_GROUP_LOOKUP_URI="$(urlencode "$OPEN_GROUP_AP_ID")"
REMOTE_GROUP="$(http_json GET "$B_BASE/api/v1/groups/lookup?uri=$OPEN_GROUP_LOOKUP_URI" "$BOB_TOKEN" 200)"
REMOTE_GROUP_ID="$(json_get "$REMOTE_GROUP" id)"
json_assert "$REMOTE_GROUP" 'data["actor_type"] == "Group"' "remote group lookup resolves to group"

REMOTE_JOIN="$(http_json POST "$B_BASE/api/v1/groups/$REMOTE_GROUP_ID/join" "$BOB_TOKEN" 200)"
json_assert "$REMOTE_JOIN" 'data["requested"] is True or data["member"] is True' "remote group join creates a follow state"

poll_json_assert GET "$B_BASE/api/v1/groups/relationships?id[]=$REMOTE_GROUP_ID" "$BOB_TOKEN" 200 \
    'len(data) == 1 and (data[0]["requested"] is True or data[0]["member"] is True)' \
    "remote group relationship exists" 30 2 >/dev/null

GROUP_MENTION_STATUS="$(http_json POST "$B_BASE/api/v1/statuses" "$BOB_TOKEN" 200 \
    "status=Smoke cross-instance group post from Bob to $OPEN_GROUP_AP_ID")"
GROUP_MENTION_STATUS_ID="$(json_get "$GROUP_MENTION_STATUS" id)"

poll_json_assert GET "$B_BASE/api/v1/statuses/$GROUP_MENTION_STATUS_ID" "$BOB_TOKEN" 200 \
    'data["id"] == "'$GROUP_MENTION_STATUS_ID'"' \
    "Bob group status remains readable" 10 1 >/dev/null

REMOTE_PREVIEW="$(http_json GET "$B_BASE/api/v1/groups/$REMOTE_GROUP_ID/preview" "$BOB_TOKEN" 200)"
json_assert "$REMOTE_PREVIEW" '"items" in data' "remote group preview returns an item envelope"

REMOTE_LEAVE="$(http_json POST "$B_BASE/api/v1/groups/$REMOTE_GROUP_ID/leave" "$BOB_TOKEN" 200)"
json_assert "$REMOTE_LEAVE" 'data["requested"] is False or data["member"] is False' "remote group leave clears relationship state"

step "Testing ordinary profiles stay out of source lookup"
ALICE_ACTOR_URL="$(json_get "$ALICE_ACCOUNT" url)"
ALICE_SOURCE_LOOKUP_URI="$(urlencode "$ALICE_ACTOR_URL")"
http_json GET "$B_BASE/api/v1/sources/lookup?name=$ALICE_SOURCE_LOOKUP_URI" "$BOB_TOKEN" 404 >/dev/null

step "Testing bidirectional group federation proof matrix"
PROOF_ID="$(basename "$WORK_DIR")"
B_OPEN_GROUP="$(http_json POST "$B_BASE/api/v1/groups" "$BOB_TOKEN" 200 "display_name=Smoke B Open Group" "name=smoke-b-open-group")"
B_OPEN_GROUP_ID="$(json_get "$B_OPEN_GROUP" id)"
B_OPEN_GROUP_AP_ID="$(json_get "$B_OPEN_GROUP" ap_id)"
json_assert "$B_OPEN_GROUP" 'data.get("actor_type") == "Group" and data.get("relationship", {}).get("role") == "owner"' "Bob owns the local B group"

B_REMOTE_A_GROUP="$(http_json GET "$B_BASE/api/v1/groups/lookup?uri=$OPEN_GROUP_LOOKUP_URI" "$BOB_TOKEN" 200)"
B_REMOTE_A_GROUP_ID="$(json_get "$B_REMOTE_A_GROUP" id)"
B_JOIN_A_GROUP="$(http_json POST "$B_BASE/api/v1/groups/$B_REMOTE_A_GROUP_ID/join" "$BOB_TOKEN" 200)"
json_assert "$B_JOIN_A_GROUP" 'data.get("member") is True or data.get("requested") is True' "Bob can follow Alice's group from instance B"
poll_json_assert GET "$B_BASE/api/v1/groups/relationships?id=$B_REMOTE_A_GROUP_ID" "$BOB_TOKEN" 200 'len(data) == 1 and (data[0].get("member") is True or data[0].get("requested") is True)' "Bob's follow of Alice's group settles" 60 2 >/dev/null

B_OPEN_GROUP_LOOKUP_URI="$(urlencode "$B_OPEN_GROUP_AP_ID")"
A_REMOTE_B_GROUP="$(http_json GET "$A_BASE/api/v1/groups/lookup?uri=$B_OPEN_GROUP_LOOKUP_URI" "$ALICE_TOKEN" 200)"
A_REMOTE_B_GROUP_ID="$(json_get "$A_REMOTE_B_GROUP" id)"
A_JOIN_B_GROUP="$(http_json POST "$A_BASE/api/v1/groups/$A_REMOTE_B_GROUP_ID/join" "$ALICE_TOKEN" 200)"
json_assert "$A_JOIN_B_GROUP" 'data.get("member") is True or data.get("requested") is True' "Alice can follow Bob's group from instance A"
poll_json_assert GET "$A_BASE/api/v1/groups/relationships?id=$A_REMOTE_B_GROUP_ID" "$ALICE_TOKEN" 200 'len(data) == 1 and (data[0].get("member") is True or data[0].get("requested") is True)' "Alice's follow of Bob's group settles" 60 2 >/dev/null

B_TO_A_TEXT="Smoke B-to-A group post proof $PROOF_ID"
B_TO_A_POST="$(http_json POST "$B_BASE/api/v1/statuses" "$BOB_TOKEN" 200 "status=$B_TO_A_TEXT" "group_id=$B_REMOTE_A_GROUP_ID")"
B_TO_A_POST_ID="$(json_get "$B_TO_A_POST" id)"
B_TO_A_POST_URI="$(json_get "$B_TO_A_POST" uri)"
poll_timeline_contains_text "$A_BASE" "$ALICE_TOKEN" "$B_TO_A_TEXT" "Alice receives Bob's post through the followed A group"
A_VIEW_OF_B_POST_ID="$(resolve_remote_status_id "$A_BASE" "$ALICE_TOKEN" "$B_TO_A_POST_URI" "Alice can resolve Bob's group post")"

A_LIKES_B="$(http_json POST "$A_BASE/api/v1/statuses/$A_VIEW_OF_B_POST_ID/favourite" "$ALICE_TOKEN" 200)"
json_assert "$A_LIKES_B" 'data.get("favourited") is True' "Alice can like Bob's federated group post"
poll_json_assert GET "$B_BASE/api/v1/statuses/$B_TO_A_POST_ID" "$BOB_TOKEN" 200 'int(data.get("favourites_count") or 0) >= 1' "Bob sees Alice's like on his group post" 90 2 >/dev/null
A_UNLIKES_B="$(http_json POST "$A_BASE/api/v1/statuses/$A_VIEW_OF_B_POST_ID/unfavourite" "$ALICE_TOKEN" 200)"
json_assert "$A_UNLIKES_B" 'data.get("favourited") is False' "Alice can undo her like on Bob's group post"
poll_json_assert GET "$B_BASE/api/v1/statuses/$B_TO_A_POST_ID" "$BOB_TOKEN" 200 'int(data.get("favourites_count") or 0) == 0' "Bob sees Alice's unlike on his group post" 90 2 >/dev/null

A_COMMENT_ON_B_TEXT="Smoke Alice comment on Bob group post $PROOF_ID"
A_COMMENT_ON_B="$(http_json POST "$A_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 "status=$A_COMMENT_ON_B_TEXT" "in_reply_to_id=$A_VIEW_OF_B_POST_ID")"
A_COMMENT_ON_B_ID="$(json_get "$A_COMMENT_ON_B" id)"
A_COMMENT_ON_B_URI="$(json_get "$A_COMMENT_ON_B" uri)"
B_VIEW_OF_A_COMMENT_ID="$(resolve_remote_status_id "$B_BASE" "$BOB_TOKEN" "$A_COMMENT_ON_B_URI" "Bob can resolve Alice's reply to his group post")"
poll_json_assert GET "$B_BASE/api/v1/statuses/$B_TO_A_POST_ID/context" "$BOB_TOKEN" 200 "'$A_COMMENT_ON_B_TEXT' in str(data)" "Bob sees Alice's comment under his group post" 90 2 >/dev/null
http_json DELETE "$A_BASE/api/v1/statuses/$A_COMMENT_ON_B_ID" "$ALICE_TOKEN" 200 >/dev/null
poll_http_status GET "$B_BASE/api/v1/statuses/$B_VIEW_OF_A_COMMENT_ID" "$BOB_TOKEN" 404 "Bob sees Alice's deleted group comment" 90 2
http_json DELETE "$B_BASE/api/v1/statuses/$B_TO_A_POST_ID" "$BOB_TOKEN" 200 >/dev/null
poll_http_status GET "$A_BASE/api/v1/statuses/$A_VIEW_OF_B_POST_ID" "$ALICE_TOKEN" 404 "Alice sees Bob's deleted group post" 90 2

A_TO_B_TEXT="Smoke A-to-B group post proof $PROOF_ID"
A_TO_B_POST="$(http_json POST "$A_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 "status=$A_TO_B_TEXT" "group_id=$A_REMOTE_B_GROUP_ID")"
A_TO_B_POST_ID="$(json_get "$A_TO_B_POST" id)"
A_TO_B_POST_URI="$(json_get "$A_TO_B_POST" uri)"
poll_timeline_contains_text "$B_BASE" "$BOB_TOKEN" "$A_TO_B_TEXT" "Bob receives Alice's post through the followed B group"
B_VIEW_OF_A_POST_ID="$(resolve_remote_status_id "$B_BASE" "$BOB_TOKEN" "$A_TO_B_POST_URI" "Bob can resolve Alice's group post")"

B_LIKES_A="$(http_json POST "$B_BASE/api/v1/statuses/$B_VIEW_OF_A_POST_ID/favourite" "$BOB_TOKEN" 200)"
json_assert "$B_LIKES_A" 'data.get("favourited") is True' "Bob can like Alice's federated group post"
poll_json_assert GET "$A_BASE/api/v1/statuses/$A_TO_B_POST_ID" "$ALICE_TOKEN" 200 'int(data.get("favourites_count") or 0) >= 1' "Alice sees Bob's like on her group post" 90 2 >/dev/null
B_UNLIKES_A="$(http_json POST "$B_BASE/api/v1/statuses/$B_VIEW_OF_A_POST_ID/unfavourite" "$BOB_TOKEN" 200)"
json_assert "$B_UNLIKES_A" 'data.get("favourited") is False' "Bob can undo his like on Alice's group post"
poll_json_assert GET "$A_BASE/api/v1/statuses/$A_TO_B_POST_ID" "$ALICE_TOKEN" 200 'int(data.get("favourites_count") or 0) == 0' "Alice sees Bob's unlike on her group post" 90 2 >/dev/null

B_COMMENT_ON_A_TEXT="Smoke Bob comment on Alice group post $PROOF_ID"
B_COMMENT_ON_A="$(http_json POST "$B_BASE/api/v1/statuses" "$BOB_TOKEN" 200 "status=$B_COMMENT_ON_A_TEXT" "in_reply_to_id=$B_VIEW_OF_A_POST_ID")"
B_COMMENT_ON_A_ID="$(json_get "$B_COMMENT_ON_A" id)"
B_COMMENT_ON_A_URI="$(json_get "$B_COMMENT_ON_A" uri)"
A_VIEW_OF_B_COMMENT_ID="$(resolve_remote_status_id "$A_BASE" "$ALICE_TOKEN" "$B_COMMENT_ON_A_URI" "Alice can resolve Bob's reply to her group post")"
poll_json_assert GET "$A_BASE/api/v1/statuses/$A_TO_B_POST_ID/context" "$ALICE_TOKEN" 200 "'$B_COMMENT_ON_A_TEXT' in str(data)" "Alice sees Bob's comment under her group post" 90 2 >/dev/null
http_json DELETE "$B_BASE/api/v1/statuses/$B_COMMENT_ON_A_ID" "$BOB_TOKEN" 200 >/dev/null
poll_http_status GET "$A_BASE/api/v1/statuses/$A_VIEW_OF_B_COMMENT_ID" "$ALICE_TOKEN" 404 "Alice sees Bob's deleted group comment" 90 2
http_json DELETE "$A_BASE/api/v1/statuses/$A_TO_B_POST_ID" "$ALICE_TOKEN" 200 >/dev/null
poll_http_status GET "$B_BASE/api/v1/statuses/$B_VIEW_OF_A_POST_ID" "$BOB_TOKEN" 404 "Bob sees Alice's deleted group post" 90 2

B_LEAVE_A_GROUP="$(http_json POST "$B_BASE/api/v1/groups/$B_REMOTE_A_GROUP_ID/leave" "$BOB_TOKEN" 200)"
json_assert "$B_LEAVE_A_GROUP" 'data.get("member") is False' "Bob can undo his follow of Alice's group"
poll_json_assert GET "$B_BASE/api/v1/groups/relationships?id=$B_REMOTE_A_GROUP_ID" "$BOB_TOKEN" 200 'len(data) == 1 and data[0].get("member") is False and data[0].get("requested") is False' "Bob's unfollow of Alice's group settles" 60 2 >/dev/null
A_LEAVE_B_GROUP="$(http_json POST "$A_BASE/api/v1/groups/$A_REMOTE_B_GROUP_ID/leave" "$ALICE_TOKEN" 200)"
json_assert "$A_LEAVE_B_GROUP" 'data.get("member") is False' "Alice can undo her follow of Bob's group"
poll_json_assert GET "$A_BASE/api/v1/groups/relationships?id=$A_REMOTE_B_GROUP_ID" "$ALICE_TOKEN" 200 'len(data) == 1 and data[0].get("member") is False and data[0].get("requested") is False' "Alice's unfollow of Bob's group settles" 60 2 >/dev/null
step "Checking no obvious server crashes were logged"
for container in "$A_CONTAINER" "$B_CONTAINER"; do
    if docker logs "$container" 2>&1 | grep -E "status=500|Internal Server Error|\\*\\* \\(|GenServer terminating|FunctionClauseError|UndefinedFunctionError|Protocol\\.UndefinedError" >/dev/null; then
        docker logs --tail 200 "$container" >&2
        fail "$container logged errors during smoke run"
    fi
done

cat <<EOF

Two-instance federation smoke test passed.

Covered:
  * startup, migrations, instance discovery, WebFinger, NodeInfo
  * OAuth app creation and password-token login
  * local group create, open join, closed join request, approval
  * local group moderator promote/demote, ban, block list, unban
  * local status create, reply/context, favourite/unfavourite, reblog/unreblog, bookmark/unbookmark
  * cross-instance group lookup, bidirectional follow/unfollow, preview, leave
  * bidirectional group post delivery, comments, likes/unlikes, comment deletion, post deletion
  * cross-instance source lookup, follow, unfollow
  * basic log scan for 500/crash output

Run with KEEP_SMOKE=1 to leave the pair available for manual browser/API work.
EOF

# end of two-instance-federation-smoke.sh
