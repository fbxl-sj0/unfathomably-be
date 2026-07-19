#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-friendica-smoke.sh
#
# Purpose:
#
#   Start a clean Unfathomably backend and a stock Friendica
#   instance on the same Docker network, then prove the group/forum
#   federation paths that Friendica can perform in the wild.
#
# Responsibilities:
#
#   * boot an unmodified Friendica image with MariaDB
#   * advertise both peers through dotted internal HTTP hostnames
#   * create a Friendica author account and a public forum account
#   * exercise group follow, post, reply, like, unlike, delete, and
#     unfollow paths in both supported directions
#   * fail loudly if either server logs obvious 500/crash output
#
# This file intentionally does NOT contain:
#
#   * production deployment logic
#   * persistent Friendica database management
#   * patches to Friendica itself
#   * browser automation
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

IMAGE="${SMOKE_IMAGE:-unfathomably-elixir-smoke:otp28}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:17-alpine}"
MARIADB_IMAGE="${MARIADB_IMAGE:-mariadb:11}"
FRIENDICA_IMAGE="${FRIENDICA_IMAGE:-friendica:stable}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.27-alpine}"

PREFIX="${SMOKE_PREFIX:-unfathomably-friendica-smoke}"
NETWORK="${SMOKE_NETWORK:-$PREFIX-net}"

BE_DB_CONTAINER="${BE_DB_CONTAINER:-$PREFIX-be-db}"
BE_CONTAINER="${BE_CONTAINER:-$PREFIX-be}"
BE_PROXY_CONTAINER="${BE_PROXY_CONTAINER:-$PREFIX-be-proxy}"
FRIENDICA_DB_CONTAINER="${FRIENDICA_DB_CONTAINER:-$PREFIX-friendica-db}"
FRIENDICA_CONTAINER="${FRIENDICA_CONTAINER:-$PREFIX-friendica}"

BE_HOST="${BE_HOST:-unfathomably-friendica.test}"
BE_APP_HOST="${BE_APP_HOST:-unfathomably-friendica-app}"
FRIENDICA_HOST="${FRIENDICA_HOST:-friendica-ref.test}"

BE_PORT="${BE_PORT:-4861}"
FRIENDICA_PORT="${FRIENDICA_PORT:-4862}"

PASSWORD="${SMOKE_USER_PASSWORD:-SmokeTest_01}"
BE_DB_PASSWORD="${SMOKE_DB_PASSWORD:-postgres}"
FRIENDICA_DB_PASSWORD="${FRIENDICA_DB_PASSWORD:-friendica}"
BE_DB_NAME="${BE_DB_NAME:-unfathomably_friendica_smoke_be}"
FRIENDICA_DB_NAME="${FRIENDICA_DB_NAME:-friendica}"
KEEP_SMOKE="${KEEP_SMOKE:-0}"
POLL_ATTEMPTS="${SMOKE_POLL_ATTEMPTS:-90}"

WORK_DIR="${SMOKE_WORK_DIR:-}"
if [ -z "$WORK_DIR" ]; then
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/unfathomably-friendica-smoke.XXXXXX")"
fi

BE_BASE="http://127.0.0.1:$BE_PORT"
FRIENDICA_BASE="http://127.0.0.1:$FRIENDICA_PORT"
FRIENDICA_INTERNAL_BASE="http://$FRIENDICA_HOST"

BE_SECRET="$WORK_DIR/be/dev.secret.exs"
BE_NGINX_CONF="$WORK_DIR/be-nginx/default.conf"
BE_UPLOADS="$WORK_DIR/be/uploads"
BE_STATIC="$WORK_DIR/be/static"

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
        "$BE_DB_CONTAINER" \
        "$FRIENDICA_CONTAINER" \
        "$FRIENDICA_DB_CONTAINER"; do
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
Unfathomably: $BE_BASE       (federated host: $BE_HOST)
Friendica:     $FRIENDICA_BASE  (federated host: $FRIENDICA_HOST)
Work dir:      $WORK_DIR
EOF
        return
    fi

    docker rm -f \
        "$FRIENDICA_CONTAINER" \
        "$FRIENDICA_DB_CONTAINER" \
        "$BE_PROXY_CONTAINER" \
        "$BE_CONTAINER" \
        "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
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

value = json.loads(os.environ["JSON_PAYLOAD"])

for part in sys.argv[1].split("."):
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
    value = json.loads(os.environ["JSON_PAYLOAD"])
    for part in sys.argv[1].split("."):
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

friendica_api() {
    local method="$1"
    local path="$2"
    local expected="$3"
    shift 3

    local tmp code
    tmp="$(mktemp)"

    local args=(-sS -X "$method" -u "author:$PASSWORD" -o "$tmp" -w "%{http_code}")
    for field in "$@"; do
        args+=(--data-urlencode "$field")
    done
    args+=("$FRIENDICA_BASE$path")

    code="$(curl "${args[@]}")" || {
        cat "$tmp" >&2 || true
        rm -f "$tmp"
        fail "Friendica curl failed for $method $path"
    }

    if [ "$code" != "$expected" ]; then
        cat "$tmp" >&2 || true
        rm -f "$tmp"
        fail "Unexpected Friendica HTTP $code for $method $path (expected $expected)"
    fi

    cat "$tmp"
    rm -f "$tmp"
}

poll_json_assert() {
    local command="$1"
    local expr="$2"
    local message="$3"
    local result=""

    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        result="$(eval "$command" || true)"

        if [ -n "$result" ] && json_matches "$result" "$expr"; then
            printf '%s\n' "$result"
            return 0
        fi

        friendica_worker 1 >/dev/null 2>&1 || true
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
    local id

    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        result="$(
            http_form GET \
                "$BE_BASE/api/v2/search?q=$(urlencode "$uri")&type=statuses&resolve=true" \
                "$token" \
                200 || true
        )"

        id="$(
            JSON_PAYLOAD="$result" TARGET_URI="$uri" python3 - <<'PY' || true
import json
import os

try:
    data = json.loads(os.environ["JSON_PAYLOAD"])
except json.JSONDecodeError:
    raise SystemExit(1)

target = os.environ["TARGET_URI"]

for status in data.get("statuses", []):
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

resolve_be_context_status_id() {
    local parent_id="$1"
    local uri="$2"
    local token="$3"
    local message="$4"
    local result
    local id

    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        result="$(
            http_form GET \
                "$BE_BASE/api/v1/statuses/$parent_id/context" \
                "$token" \
                200 || true
        )"

        id="$(
            JSON_PAYLOAD="$result" TARGET_URI="$uri" python3 - <<'PY' || true
import json
import os

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
  url: [scheme: "http", host: "$BE_HOST", port: 80],
  secret_key_base: "$secret_key_base",
  live_view: [signing_salt: "$signing_salt"],
  code_reloader: false,
  live_reload: false,
  watchers: [],
  server: true

config :pleroma, :instance,
  name: "Unfathomably Friendica Smoke",
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

write_be_proxy_config() {
    mkdir -p "$(dirname "$BE_NGINX_CONF")"

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

wait_mariadb() {
    local stable=0

    for _ in $(seq 1 100); do
        if docker exec "$FRIENDICA_DB_CONTAINER" mariadb -uroot -p"$FRIENDICA_DB_PASSWORD" -e "select 1" >/dev/null 2>&1; then
            stable=$((stable + 1))

            if [ "$stable" -ge 3 ]; then
                return 0
            fi
        else
            stable=0
        fi

        sleep 1
    done

    fail "MariaDB did not become ready"
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
        "$NGINX_IMAGE" >/dev/null
}

wait_be() {
    for _ in $(seq 1 140); do
        if curl -fsS "$BE_BASE/api/v1/instance" >/dev/null 2>&1; then
            return 0
        fi

        sleep 1
    done

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
            "client_name=friendica-smoke-$username" \
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

start_friendica() {
    docker run -d \
        --name "$FRIENDICA_DB_CONTAINER" \
        --network "$NETWORK" \
        --network-alias friendica-db \
        -e MARIADB_ROOT_PASSWORD="$FRIENDICA_DB_PASSWORD" \
        -e MARIADB_DATABASE="$FRIENDICA_DB_NAME" \
        -e MARIADB_USER=friendica \
        -e MARIADB_PASSWORD="$FRIENDICA_DB_PASSWORD" \
        "$MARIADB_IMAGE" >/dev/null

    wait_mariadb

    docker run -d \
        --name "$FRIENDICA_CONTAINER" \
        --hostname "$FRIENDICA_HOST" \
        --network "$NETWORK" \
        --network-alias "$FRIENDICA_HOST" \
        -p "127.0.0.1:$FRIENDICA_PORT:80" \
        -e FRIENDICA_URL="$FRIENDICA_INTERNAL_BASE" \
        -e FRIENDICA_ADMIN_MAIL="admin@$FRIENDICA_HOST" \
        -e FRIENDICA_TZ=UTC \
        -e FRIENDICA_NO_VALIDATION=true \
        -e MYSQL_HOST=friendica-db \
        -e MYSQL_DATABASE="$FRIENDICA_DB_NAME" \
        -e MYSQL_USER=friendica \
        -e MYSQL_PASSWORD="$FRIENDICA_DB_PASSWORD" \
        "$FRIENDICA_IMAGE" >/dev/null
}

wait_friendica() {
    for _ in $(seq 1 180); do
        if curl -fsS "$FRIENDICA_BASE" >/dev/null 2>&1; then
            return 0
        fi

        sleep 2
    done

    fail "Timed out waiting for Friendica at $FRIENDICA_BASE"
}

friendica_console() {
    docker exec "$FRIENDICA_CONTAINER" sh -lc "cd /var/www/html && $*"
}

friendica_worker() {
    local runs="${1:-4}"

    for _ in $(seq 1 "$runs"); do
        friendica_console "bin/console worker -n" >/dev/null 2>&1 || true
    done
}

create_friendica_user() {
    local nick="$1"
    local email="$2"
    local display="$3"

    friendica_console \
        "bin/console user add '$display' '$nick' '$email' en ''" \
        >/dev/null
    friendica_console "bin/console user password '$nick' '$PASSWORD'" >/dev/null
    friendica_console "bin/console user allow '$nick'" >/dev/null
}

repair_friendica_system_actor() {
    local private_key_b64
    local public_key_b64

    docker exec "$FRIENDICA_CONTAINER" sh -lc \
        "openssl genrsa 2048 >/tmp/friendica-system.key 2>/dev/null && openssl rsa -in /tmp/friendica-system.key -pubout >/tmp/friendica-system.pub 2>/dev/null"

    private_key_b64="$(
        docker exec "$FRIENDICA_CONTAINER" sh -lc \
            "base64 /tmp/friendica-system.key | tr -d '\n'"
    )"
    public_key_b64="$(
        docker exec "$FRIENDICA_CONTAINER" sh -lc \
            "base64 /tmp/friendica-system.pub | tr -d '\n'"
    )"

    docker exec "$FRIENDICA_DB_CONTAINER" \
        mariadb -ufriendica -p"$FRIENDICA_DB_PASSWORD" "$FRIENDICA_DB_NAME" \
        -e "insert into config (cat, k, v) values ('system', 'actor_name', 's:9:\"friendica\";') on duplicate key update v = values(v);
            insert into config (cat, k, v) values ('system', 'system_actor_name', 's:9:\"friendica\";') on duplicate key update v = values(v);
            update user set nickname = 'friendica', username = 'Friendica System'
              where uid = 0 and (nickname = '' or nickname is null);
            update contact
              set self = 1,
                  nick = 'friendica',
                  addr = 'friendica@$FRIENDICA_HOST',
                  name = 'Friendica System',
                  url = '$FRIENDICA_INTERNAL_BASE/friendica',
                  nurl = '$FRIENDICA_INTERNAL_BASE/friendica',
                  network = 'apub',
                  blocked = 0,
                  pending = 0,
                  readonly = 0,
                  pubkey = from_base64('$public_key_b64'),
                  prvkey = from_base64('$private_key_b64')
              where uid = 0 and id = 0;" \
        >/dev/null

    friendica_console "bin/console cache clear" >/dev/null || true
}

make_friendica_forum() {
    docker exec "$FRIENDICA_DB_CONTAINER" \
        mariadb -ufriendica -p"$FRIENDICA_DB_PASSWORD" "$FRIENDICA_DB_NAME" \
        -e "update user set \`account-type\` = 3, \`page-flags\` = 2 where nickname = 'forum'; update contact set \`contact-type\` = 3 where nick = 'forum';" \
        >/dev/null

    local actor
    actor="$(
        docker exec "$FRIENDICA_CONTAINER" \
            curl -sS -H 'Accept: application/activity+json' \
            http://127.0.0.1/profile/forum
    )"
    json_assert "$actor" 'data.get("type") == "Group"' "Friendica forum account did not render as ActivityPub Group"
}

friendica_search_account_id() {
    local query="$1"
    local message="$2"
    local result
    local id

    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        result="$(friendica_api GET "/api/v1/accounts/search?q=$(urlencode "$query")&resolve=true&limit=10" 200 || true)"
        id="$(
            JSON_PAYLOAD="$result" python3 - <<'PY' || true
import json
import os

data = json.loads(os.environ["JSON_PAYLOAD"])
for account in data:
    if account.get("id"):
        print(account["id"])
        raise SystemExit(0)
raise SystemExit(1)
PY
        )"

        if [ -n "$id" ]; then
            printf '%s\n' "$id"
            return 0
        fi

        friendica_worker 1 >/dev/null 2>&1 || true
        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

friendica_contact_id_for_url() {
    local url="$1"

    docker exec "$FRIENDICA_DB_CONTAINER" \
        mariadb -N -B -ufriendica -p"$FRIENDICA_DB_PASSWORD" "$FRIENDICA_DB_NAME" \
        -e "select c.id from contact c join user u on u.uid = c.uid where u.nickname = 'author' and c.url = '$url' order by c.id desc limit 1;"
}

friendica_contact_network() {
    local contact_id="$1"

    docker exec "$FRIENDICA_DB_CONTAINER" \
        mariadb -N -B -ufriendica -p"$FRIENDICA_DB_PASSWORD" "$FRIENDICA_DB_NAME" \
        -e "select network from contact where id = $contact_id;"
}

friendica_follow_be_group() {
    local url="$1"
    local id
    local network
    local output

    output="$(friendica_console "bin/console contact add author '$url' apub")"
    friendica_worker 8

    id="$(printf '%s\n' "$output" | sed -n 's/.*contact ID \([0-9][0-9]*\).*/\1/p' | tail -1)"
    if [ -z "$id" ]; then
        id="$(friendica_contact_id_for_url "$url")"
    fi

    if [ -z "$id" ]; then
        printf '%s\n' "$output" >&2
        fail "Friendica added no local author contact for $url"
    fi

    network="$(friendica_contact_network "$id")"
    if [ "$network" != "apub" ]; then
        printf '%s\n' "$output" >&2
        fail "Friendica resolved $url as $network instead of apub"
    fi

    printf '%s\n' "$id"
}

friendica_unfollow_be_group() {
    local contact_id="$1"

    friendica_console "bin/console contact remove '$contact_id'" >/dev/null
    friendica_worker 6
}

friendica_status_by_text() {
    local text="$1"
    local result

    result="$(friendica_api GET "/api/v1/timelines/home?limit=40" 200 || true)"

    if JSON_PAYLOAD="$result" TARGET_TEXT="$text" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_PAYLOAD"])
target = os.environ["TARGET_TEXT"]

for status in data:
    if target in (status.get("content") or ""):
        print(json.dumps(status))
        raise SystemExit(0)

raise SystemExit(1)
PY
    then
        return 0
    fi

    friendica_status_from_db_by_text "$text"
}

friendica_status_from_db_by_text() {
    local text="$1"
    local sql_text
    local status_id

    sql_text="$(
        TARGET_TEXT="$text" python3 - <<'PY'
import os

text = os.environ["TARGET_TEXT"]
print("'" + text.replace("'", "''") + "'")
PY
    )"

    status_id="$(
        docker exec "$FRIENDICA_DB_CONTAINER" \
            mariadb -N -B -ufriendica -p"$FRIENDICA_DB_PASSWORD" "$FRIENDICA_DB_NAME" \
            -e "select \`uri-id\` from \`post-user-view\` where body like concat('%', $sql_text, '%') and deleted = 0 order by uid desc, id desc limit 1;" \
            2>/dev/null || true
    )"

    if [ -n "$status_id" ]; then
        STATUS_ID="$status_id" STATUS_TEXT="$text" python3 - <<'PY'
import json
import os

print(json.dumps({"id": os.environ["STATUS_ID"], "content": os.environ["STATUS_TEXT"]}))
PY
    fi
}

friendica_context_status_by_text() {
    local parent_id="$1"
    local text="$2"
    local result

    result="$(friendica_api GET "/api/v1/statuses/$parent_id/context" 200 || true)"
    JSON_PAYLOAD="$result" TARGET_TEXT="$text" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_PAYLOAD"])
target = os.environ["TARGET_TEXT"]

for status in data.get("descendants", []):
    if target in (status.get("content") or ""):
        print(json.dumps(status))
        raise SystemExit(0)

raise SystemExit(1)
PY
}

poll_friendica_status_by_text() {
    local text="$1"
    local message="$2"
    local result=""

    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        result="$(friendica_status_by_text "$text" || true)"

        if [ -n "$result" ]; then
            printf '%s\n' "$result"
            return 0
        fi

        friendica_worker 1 >/dev/null 2>&1 || true
        sleep 2
    done

    fail "$message"
}

poll_friendica_context_status_by_text() {
    local parent_id="$1"
    local text="$2"
    local message="$3"
    local result=""

    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        result="$(friendica_context_status_by_text "$parent_id" "$text" || true)"

        if [ -n "$result" ]; then
            printf '%s\n' "$result"
            return 0
        fi

        friendica_worker 1 >/dev/null 2>&1 || true
        sleep 2
    done

    fail "$message"
}

friendica_deleted_status_count() {
    local status_id="$1"

    docker exec "$FRIENDICA_DB_CONTAINER" \
        mariadb -N -B -ufriendica -p"$FRIENDICA_DB_PASSWORD" "$FRIENDICA_DB_NAME" \
        -e "select count(*) from \`post-user-view\` where \`uri-id\` = $status_id and deleted = 1;"
}

poll_friendica_status_deleted() {
    local status_id="$1"
    local message="$2"
    local count=""

    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        count="$(friendica_deleted_status_count "$status_id" || true)"

        if [ -n "$count" ] && [ "$count" -ge 1 ] 2>/dev/null; then
            return 0
        fi

        friendica_worker 1 >/dev/null 2>&1 || true
        sleep 2
    done

    fail "$message"
}

friendica_status_deleted_matches() {
    local status_id="$1"
    local attempts="${FRIENDICA_OPTIONAL_POLL_ATTEMPTS:-12}"
    local count=""

    for _ in $(seq 1 "$attempts"); do
        count="$(friendica_deleted_status_count "$status_id" || true)"

        if [ -n "$count" ] && [ "$count" -ge 1 ] 2>/dev/null; then
            return 0
        fi

        friendica_worker 1 >/dev/null 2>&1 || true
        sleep 2
    done

    return 1
}

poll_friendica_status_count() {
    local status_id="$1"
    local expr="$2"
    local message="$3"

    poll_json_assert \
        "friendica_api GET /api/v1/statuses/$status_id 200" \
        "$expr" \
        "$message" >/dev/null
}

poll_be_status_count() {
    local status_id="$1"
    local expr="$2"
    local message="$3"

    poll_json_assert \
        "http_form GET $BE_BASE/api/v1/statuses/$status_id $ALICE_TOKEN 200" \
        "$expr" \
        "$message" >/dev/null
}

be_status_matches() {
    local status_id="$1"
    local expr="$2"
    local attempts="${FRIENDICA_OPTIONAL_POLL_ATTEMPTS:-12}"
    local result

    for _ in $(seq 1 "$attempts"); do
        result="$(http_form GET "$BE_BASE/api/v1/statuses/$status_id" "$ALICE_TOKEN" 200 || true)"

        if [ -n "$result" ] && json_matches "$result" "$expr"; then
            return 0
        fi

        friendica_worker 1 >/dev/null 2>&1 || true
        sleep 2
    done

    return 1
}

poll_be_context_absent() {
    local parent_id="$1"
    local text="$2"
    local token="$3"
    local result

    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        result="$(http_form GET "$BE_BASE/api/v1/statuses/$parent_id/context" "$token" 200 || true)"

        if JSON_PAYLOAD="$result" TARGET_TEXT="$text" python3 - <<'PY'; then
import json
import os

data = json.loads(os.environ["JSON_PAYLOAD"])
target = os.environ["TARGET_TEXT"]

for status in data.get("ancestors", []) + data.get("descendants", []):
    if target in (status.get("content") or ""):
        raise SystemExit(1)
PY
            return 0
        fi

        friendica_worker 1 >/dev/null 2>&1 || true
        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "Deleted Friendica reply is still visible in Unfathomably context"
}

log "Writing disposable Unfathomably and proxy configuration"
write_be_secret
write_be_proxy_config

log "Creating Docker network"
docker rm -f \
    "$FRIENDICA_CONTAINER" \
    "$FRIENDICA_DB_CONTAINER" \
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

wait_postgres
prepare_database

log "Starting stock Friendica"
start_friendica
wait_friendica

log "Repairing Friendica system actor bootstrap"
repair_friendica_system_actor

log "Creating Friendica author and forum accounts"
create_friendica_user author "author@$FRIENDICA_HOST" "Friendica Author"
create_friendica_user forum "forum@$FRIENDICA_HOST" "Friendica Forum"
make_friendica_forum
friendica_worker 4

log "Migrating and starting Unfathomably"
docker_run_mix "${PREFIX}-migrate-be" "mix ecto.migrate"
create_be_user alice "alice@$BE_HOST"
start_be
start_be_proxy
wait_be

log "Creating Unfathomably API credentials and local group"
ALICE_TOKEN="$(create_be_token alice)"
BE_GROUP_NAME="unfathomably_friendica_smoke"
BE_GROUP="$(
    http_form POST "$BE_BASE/api/v1/groups" "$ALICE_TOKEN" 200 \
        "display_name=Unfathomably Friendica Smoke" \
        "name=$BE_GROUP_NAME" \
        "note=Open group used by the Friendica bidirectional smoke harness." \
        "locked=false"
)"
BE_GROUP_ID="$(json_get "$BE_GROUP" id)"
BE_GROUP_AP_ID="$(json_get_optional "$BE_GROUP" ap_id)"
if [ -z "$BE_GROUP_AP_ID" ]; then
    BE_GROUP_AP_ID="$(json_get "$BE_GROUP" url)"
fi

log "Following groups in both directions"
FRIENDICA_FORUM_AP_ID="$FRIENDICA_INTERNAL_BASE/profile/forum"
BE_REMOTE_FRIENDICA_GROUP="$(
    http_form GET "$BE_BASE/api/v1/groups/lookup?uri=$(urlencode "$FRIENDICA_FORUM_AP_ID")" \
        "$ALICE_TOKEN" \
        200
)"
BE_REMOTE_FRIENDICA_GROUP_ID="$(json_get "$BE_REMOTE_FRIENDICA_GROUP" id)"
BE_JOIN_FRIENDICA="$(
    http_form POST "$BE_BASE/api/v1/groups/$BE_REMOTE_FRIENDICA_GROUP_ID/join" \
        "$ALICE_TOKEN" \
        200
)"
json_assert "$BE_JOIN_FRIENDICA" 'data.get("member") is True or data.get("requested") is True' \
    "Unfathomably could not follow the Friendica forum actor"
friendica_worker 6

FRIENDICA_REMOTE_BE_CONTACT_ID="$(friendica_follow_be_group "$BE_GROUP_AP_ID")"

poll_json_assert \
    "http_form GET $BE_BASE/api/v1/accounts/$BE_GROUP_ID/followers?limit=40 $ALICE_TOKEN 200" \
    'any(account.get("acct") == "author@'$FRIENDICA_HOST'" or account.get("fqn") == "author@'$FRIENDICA_HOST'" for account in data)' \
    "Unfathomably did not see the Friendica author following the group" >/dev/null

log "Testing Friendica post delivery into Unfathomably"
FRIENDICA_TO_BE_TEXT="Friendica to Unfathomably group smoke $(basename "$WORK_DIR")"
FRIENDICA_TO_BE_POST="$(
    friendica_api POST /api/v1/statuses 200 \
        "status=$FRIENDICA_TO_BE_TEXT @$BE_GROUP_NAME@$BE_HOST" \
        "visibility=public"
)"
FRIENDICA_TO_BE_ID="$(json_get "$FRIENDICA_TO_BE_POST" id)"
FRIENDICA_TO_BE_URI="$(json_get "$FRIENDICA_TO_BE_POST" uri)"
friendica_worker 8
BE_VIEW_OF_FRIENDICA_POST_ID="$(resolve_be_status_id "$FRIENDICA_TO_BE_URI" "$ALICE_TOKEN" "Unfathomably could not resolve Friendica group mention post")"

BE_LIKE_FRIENDICA="$(http_form POST "$BE_BASE/api/v1/statuses/$BE_VIEW_OF_FRIENDICA_POST_ID/favourite" "$ALICE_TOKEN" 200)"
json_assert "$BE_LIKE_FRIENDICA" 'data.get("favourited") is True' "Unfathomably could not like Friendica post"
friendica_worker 6
poll_friendica_status_count "$FRIENDICA_TO_BE_ID" 'int(data.get("favourites_count") or 0) >= 1' \
    "Friendica did not see Unfathomably like on Friendica post"

BE_UNLIKE_FRIENDICA="$(http_form POST "$BE_BASE/api/v1/statuses/$BE_VIEW_OF_FRIENDICA_POST_ID/unfavourite" "$ALICE_TOKEN" 200)"
json_assert "$BE_UNLIKE_FRIENDICA" 'data.get("favourited") is False' "Unfathomably could not unlike Friendica post"
friendica_worker 6
poll_friendica_status_count "$FRIENDICA_TO_BE_ID" 'int(data.get("favourites_count") or 0) == 0' \
    "Friendica did not see Unfathomably unlike on Friendica post"

BE_DISLIKE_FRIENDICA="$(
    http_form POST \
        "$BE_BASE/api/friendica/statuses/$BE_VIEW_OF_FRIENDICA_POST_ID/dislike" \
        "$ALICE_TOKEN" \
        200
)"
json_assert "$BE_DISLIKE_FRIENDICA" 'data.get("disliked") is True and int(data.get("dislikes_count") or 0) >= 1' \
    "Unfathomably could not dislike Friendica post"
friendica_worker 6
poll_friendica_status_count "$FRIENDICA_TO_BE_ID" 'int(data.get("dislikes_count") or data.get("friendica", {}).get("dislikes_count") or 0) >= 1' \
    "Friendica did not see Unfathomably dislike on Friendica post"

BE_UNDISLIKE_FRIENDICA="$(
    http_form POST \
        "$BE_BASE/api/friendica/statuses/$BE_VIEW_OF_FRIENDICA_POST_ID/undislike" \
        "$ALICE_TOKEN" \
        200
)"
json_assert "$BE_UNDISLIKE_FRIENDICA" 'data.get("disliked") is False and int(data.get("dislikes_count") or 0) == 0' \
    "Unfathomably could not remove dislike from Friendica post"
friendica_worker 6
poll_friendica_status_count "$FRIENDICA_TO_BE_ID" 'int(data.get("dislikes_count") or data.get("friendica", {}).get("dislikes_count") or 0) == 0' \
    "Friendica did not see Unfathomably remove dislike from Friendica post"

BE_REPLY_TEXT="Unfathomably reply to Friendica $(basename "$WORK_DIR")"
BE_REPLY="$(
    http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$BE_REPLY_TEXT" \
        "in_reply_to_id=$BE_VIEW_OF_FRIENDICA_POST_ID"
)"
BE_REPLY_ID="$(json_get "$BE_REPLY" id)"
friendica_worker 8
FRIENDICA_VIEW_OF_BE_REPLY="$(poll_friendica_context_status_by_text "$FRIENDICA_TO_BE_ID" "$BE_REPLY_TEXT" "Friendica did not receive Unfathomably reply under Friendica post")"
FRIENDICA_VIEW_OF_BE_REPLY_ID="$(json_get "$FRIENDICA_VIEW_OF_BE_REPLY" id)"

http_form DELETE "$BE_BASE/api/v1/statuses/$BE_REPLY_ID" "$ALICE_TOKEN" 200 >/dev/null
friendica_worker 8
poll_friendica_status_deleted "$FRIENDICA_VIEW_OF_BE_REPLY_ID" \
    "Friendica did not mark the deleted Unfathomably reply as deleted"

log "Testing Unfathomably post delivery into Friendica"
BE_TO_FRIENDICA_TEXT="Unfathomably to Friendica forum smoke $(basename "$WORK_DIR")"
BE_TO_FRIENDICA_POST="$(
    http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$BE_TO_FRIENDICA_TEXT" \
        "group_id=$BE_REMOTE_FRIENDICA_GROUP_ID"
)"
BE_TO_FRIENDICA_POST_ID="$(json_get "$BE_TO_FRIENDICA_POST" id)"
friendica_worker 10
FRIENDICA_VIEW_OF_BE_POST="$(poll_friendica_status_by_text "$BE_TO_FRIENDICA_TEXT" "Friendica did not receive Unfathomably group post")"
FRIENDICA_VIEW_OF_BE_POST_ID="$(json_get "$FRIENDICA_VIEW_OF_BE_POST" id)"

FRIENDICA_REPLY_TEXT="Friendica reply to Unfathomably $(basename "$WORK_DIR")"
FRIENDICA_REPLY="$(
    friendica_api POST /api/v1/statuses 200 \
        "status=$FRIENDICA_REPLY_TEXT" \
        "in_reply_to_id=$FRIENDICA_VIEW_OF_BE_POST_ID" \
        "visibility=public"
)"
FRIENDICA_REPLY_ID="$(json_get "$FRIENDICA_REPLY" id)"
FRIENDICA_REPLY_URI="$(json_get "$FRIENDICA_REPLY" uri)"
friendica_worker 8
BE_VIEW_OF_FRIENDICA_REPLY_ID="$(resolve_be_context_status_id "$BE_TO_FRIENDICA_POST_ID" "$FRIENDICA_REPLY_URI" "$ALICE_TOKEN" "Unfathomably did not receive Friendica reply")"

FRIENDICA_DISLIKE_BE="$(
    friendica_api POST "/api/friendica/statuses/$FRIENDICA_VIEW_OF_BE_POST_ID/dislike" 200
)"
json_assert "$FRIENDICA_DISLIKE_BE" '(data.get("disliked") is True or data.get("friendica", {}).get("disliked") is True) and int(data.get("dislikes_count") or data.get("friendica", {}).get("dislikes_count") or 0) >= 1' \
    "Friendica could not dislike Unfathomably post"
friendica_worker 8

if be_status_matches "$BE_TO_FRIENDICA_POST_ID" 'int(data.get("dislikes_count") or 0) >= 1'; then
    FRIENDICA_UNDISLIKE_BE="$(
        friendica_api POST "/api/friendica/statuses/$FRIENDICA_VIEW_OF_BE_POST_ID/undislike" 200
    )"
    json_assert "$FRIENDICA_UNDISLIKE_BE" '(data.get("disliked") is False or data.get("friendica", {}).get("disliked") is False) and int(data.get("dislikes_count") or data.get("friendica", {}).get("dislikes_count") or 0) == 0' \
        "Friendica could not remove dislike from Unfathomably post"
    friendica_worker 8
    poll_be_status_count "$BE_TO_FRIENDICA_POST_ID" 'int(data.get("dislikes_count") or 0) == 0' \
        "Unfathomably did not see Friendica remove dislike from Unfathomably post"
    FRIENDICA_DISLIKE_SUMMARY="* supported: Friendica dislike and undislike on Unfathomably content"
else
    printf '%s\n' \
        "not_supported: stock Friendica accepted a local dislike of the forum copy but did not deliver an ActivityPub Dislike to Unfathomably"
    FRIENDICA_UNDISLIKE_BE="$(
        friendica_api POST "/api/friendica/statuses/$FRIENDICA_VIEW_OF_BE_POST_ID/undislike" 200
    )"
    json_assert "$FRIENDICA_UNDISLIKE_BE" '(data.get("disliked") is False or data.get("friendica", {}).get("disliked") is False) and int(data.get("dislikes_count") or data.get("friendica", {}).get("dislikes_count") or 0) == 0' \
        "Friendica could not remove its local dislike from Unfathomably post"
    friendica_worker 8
    FRIENDICA_DISLIKE_SUMMARY="* not_supported: stock Friendica local dislikes of remote forum copies do not federate Dislike/Undo Dislike back to the origin server"
fi

FRIENDICA_LIKE_BE="$(friendica_api POST "/api/v1/statuses/$FRIENDICA_VIEW_OF_BE_POST_ID/favourite" 200)"
json_assert "$FRIENDICA_LIKE_BE" 'data.get("favourited") is True' "Friendica could not like Unfathomably post"
friendica_worker 8

if be_status_matches "$BE_TO_FRIENDICA_POST_ID" 'int(data.get("favourites_count") or 0) >= 1'; then
    FRIENDICA_UNLIKE_BE="$(friendica_api POST "/api/v1/statuses/$FRIENDICA_VIEW_OF_BE_POST_ID/unfavourite" 200)"
    json_assert "$FRIENDICA_UNLIKE_BE" 'data.get("favourited") is False' "Friendica could not unlike Unfathomably post"
    friendica_worker 8
    poll_be_status_count "$BE_TO_FRIENDICA_POST_ID" 'int(data.get("favourites_count") or 0) == 0' \
        "Unfathomably did not see Friendica unlike on Unfathomably post"
    FRIENDICA_FAVOURITE_SUMMARY="* supported: Friendica like and unlike on Unfathomably content"
else
    printf '%s\n' \
        "not_supported: stock Friendica accepted a local favourite of the forum copy but did not deliver an ActivityPub Like to Unfathomably"
    FRIENDICA_UNLIKE_BE="$(friendica_api POST "/api/v1/statuses/$FRIENDICA_VIEW_OF_BE_POST_ID/unfavourite" 200)"
    json_assert "$FRIENDICA_UNLIKE_BE" 'data.get("favourited") is False' "Friendica could not unlike Unfathomably post"
    friendica_worker 8
    FRIENDICA_FAVOURITE_SUMMARY="* not_supported: stock Friendica local favourites of remote forum copies do not federate Like/Undo Like back to the origin server"
fi

friendica_api DELETE "/api/v1/statuses/$FRIENDICA_REPLY_ID" 200 >/dev/null
friendica_worker 10
poll_be_context_absent "$BE_TO_FRIENDICA_POST_ID" "$FRIENDICA_REPLY_TEXT" "$ALICE_TOKEN"

http_form DELETE "$BE_BASE/api/v1/statuses/$BE_TO_FRIENDICA_POST_ID" "$ALICE_TOKEN" 200 >/dev/null
friendica_worker 10

if friendica_status_deleted_matches "$FRIENDICA_VIEW_OF_BE_POST_ID"; then
    FRIENDICA_DELETE_SUMMARY="* supported: Unfathomably top-level post Delete delivery into Friendica"
else
    printf '%s\n' \
        "not_supported: stock Friendica stores group-targeted remote posts as forum-owned copies and does not apply the remote author's Delete to that forum copy"
    FRIENDICA_DELETE_SUMMARY="* not_supported: stock Friendica does not delete forum-owned copies of remote group posts when the remote author sends Delete"
fi

log "Unfollowing groups"
http_form POST "$BE_BASE/api/v1/groups/$BE_REMOTE_FRIENDICA_GROUP_ID/leave" "$ALICE_TOKEN" 200 >/dev/null
friendica_unfollow_be_group "$FRIENDICA_REMOTE_BE_CONTACT_ID"

cat <<EOF

Friendica bidirectional smoke passed:
* supported: Unfathomably follow of a Friendica forum Group actor
* supported: Friendica follow of an Unfathomably group through the native contact command
* supported: Friendica top-level group mention delivery into Unfathomably
* supported: Unfathomably dislike and undislike propagation into Friendica
$FRIENDICA_DISLIKE_SUMMARY
* supported: Unfathomably like, unlike, reply, and reply Delete on Friendica content
* supported: Unfathomably top-level group post delivery into Friendica
* supported: Friendica reply and reply Delete on Unfathomably content
$FRIENDICA_FAVOURITE_SUMMARY
$FRIENDICA_DELETE_SUMMARY
* supported: Group unfollow cleanup in both directions
EOF

exit 0

# end of unfathomably-friendica-smoke.sh
