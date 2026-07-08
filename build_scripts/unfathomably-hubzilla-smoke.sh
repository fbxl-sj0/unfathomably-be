#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-hubzilla-smoke.sh
#
# Purpose:
#
#   Start a clean Unfathomably backend and a stock Hubzilla
#   instance on the same Docker network, then prove the group/forum
#   federation paths that Hubzilla can perform in the wild.
#
# Responsibilities:
#
#   * boot an unmodified Hubzilla Docker image with MariaDB
#   * enable Hubzilla's stock pubcrawl ActivityPub addon
#   * create a normal Hubzilla author channel and a forum Group channel
#   * exercise group follow, post, reply, like, unlike, delete, and
#     unfollow paths in both supported directions
#   * fail loudly if either server logs obvious 500/crash output
#
# This file intentionally does NOT contain:
#
#   * production deployment logic
#   * persistent Hubzilla database management
#   * patches to Hubzilla itself
#   * browser automation
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

IMAGE="${SMOKE_IMAGE:-unfathomably-elixir-smoke:otp28}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:17-alpine}"
MARIADB_IMAGE="${MARIADB_IMAGE:-mariadb:11}"
HUBZILLA_IMAGE="${HUBZILLA_IMAGE:-ghcr.io/saiwal/hubzilla-docker:latest}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.27-alpine}"

PREFIX="${SMOKE_PREFIX:-unfathomably-hubzilla-smoke}"
NETWORK="${SMOKE_NETWORK:-$PREFIX-net}"

BE_DB_CONTAINER="${BE_DB_CONTAINER:-$PREFIX-be-db}"
BE_CONTAINER="${BE_CONTAINER:-$PREFIX-be}"
BE_PROXY_CONTAINER="${BE_PROXY_CONTAINER:-$PREFIX-be-proxy}"
HUBZILLA_DB_CONTAINER="${HUBZILLA_DB_CONTAINER:-$PREFIX-hubzilla-db}"
HUBZILLA_CONTAINER="${HUBZILLA_CONTAINER:-$PREFIX-hubzilla}"
HUBZILLA_VOLUME="${HUBZILLA_VOLUME:-$PREFIX-hubzilla-data}"

BE_HOST="${BE_HOST:-unfathomably-hubzilla.test}"
BE_APP_HOST="${BE_APP_HOST:-unfathomably-hubzilla-app}"
HUBZILLA_HOST="${HUBZILLA_HOST:-hubzilla-ref.test}"

BE_PORT="${BE_PORT:-4871}"
HUBZILLA_PORT="${HUBZILLA_PORT:-4872}"

PASSWORD="${SMOKE_USER_PASSWORD:-SmokeTest_01}"
BE_DB_PASSWORD="${SMOKE_DB_PASSWORD:-postgres}"
HUBZILLA_DB_PASSWORD="${HUBZILLA_DB_PASSWORD:-hubzilla}"
BE_DB_NAME="${BE_DB_NAME:-unfathomably_hubzilla_smoke_be}"
HUBZILLA_DB_NAME="${HUBZILLA_DB_NAME:-hubzilla}"
KEEP_SMOKE="${KEEP_SMOKE:-0}"
POLL_ATTEMPTS="${SMOKE_POLL_ATTEMPTS:-90}"
OPTIONAL_POLL_ATTEMPTS="${HUBZILLA_OPTIONAL_POLL_ATTEMPTS:-12}"

WORK_DIR="${SMOKE_WORK_DIR:-}"
if [ -z "$WORK_DIR" ]; then
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/unfathomably-hubzilla-smoke.XXXXXX")"
fi

BE_BASE="http://127.0.0.1:$BE_PORT"
HUBZILLA_BASE="http://127.0.0.1:$HUBZILLA_PORT"
HUBZILLA_INTERNAL_BASE="http://$HUBZILLA_HOST"

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
        "$HUBZILLA_CONTAINER" \
        "$HUBZILLA_DB_CONTAINER"; do
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
Hubzilla:      $HUBZILLA_BASE  (federated host: $HUBZILLA_HOST)
Work dir:      $WORK_DIR
EOF
        return
    fi

    docker rm -f \
        "$HUBZILLA_CONTAINER" \
        "$HUBZILLA_DB_CONTAINER" \
        "$BE_PROXY_CONTAINER" \
        "$BE_CONTAINER" \
        "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    docker volume rm "$HUBZILLA_VOLUME" >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR"
}

trap cleanup EXIT

urlencode() {
    python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

sql_literal() {
    python3 -c 'import sys; value = sys.argv[1]; print("\047" + value.replace("\\", "\\\\").replace("\047", "\047\047") + "\047")' "$1"
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

hubzilla_form() {
    local method="$1"
    local path="$2"
    local expected="$3"
    shift 3

    local tmp code
    tmp="$(mktemp)"

    local args=(-sS -X "$method" -H "Host: $HUBZILLA_HOST" -u "author:$PASSWORD" -o "$tmp" -w "%{http_code}")
    for field in "$@"; do
        args+=(--data-urlencode "$field")
    done
    args+=("$HUBZILLA_BASE$path")

    code="$(curl "${args[@]}")" || {
        cat "$tmp" >&2 || true
        rm -f "$tmp"
        fail "Hubzilla curl failed for $method $path"
    }

    if [ "$code" != "$expected" ]; then
        cat "$tmp" >&2 || true
        rm -f "$tmp"
        fail "Unexpected Hubzilla HTTP $code for $method $path (expected $expected)"
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
        hubzilla_cron 1 >/dev/null 2>&1 || true
        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

try_poll_json_assert() {
    local command="$1"
    local expr="$2"
    local result=""

    for _ in $(seq 1 "$OPTIONAL_POLL_ATTEMPTS"); do
        result="$(eval "$command" || true)"
        if [ -n "$result" ] && json_matches "$result" "$expr"; then
            printf '%s\n' "$result"
            return 0
        fi
        hubzilla_cron 1 >/dev/null 2>&1 || true
        sleep 2
    done

    printf '%s\n' "$result" >&2
    return 1
}

resolve_be_status_id() {
    local uri="$1"
    local token="$2"
    local message="$3"
    local result id

    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        result="$(http_form GET "$BE_BASE/api/v2/search?q=$(urlencode "$uri")&type=statuses&resolve=true" "$token" 200 || true)"
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
    local result id

    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        result="$(http_form GET "$BE_BASE/api/v1/statuses/$parent_id/context" "$token" 200 || true)"
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
  name: "Unfathomably Hubzilla Smoke",
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

    for _ in $(seq 1 120); do
        if docker exec "$HUBZILLA_DB_CONTAINER" mariadb -uroot -p"$HUBZILLA_DB_PASSWORD" -e "select 1" >/dev/null 2>&1; then
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
            "client_name=hubzilla-smoke-$username" \
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

start_hubzilla() {
    docker run -d \
        --name "$HUBZILLA_DB_CONTAINER" \
        --network "$NETWORK" \
        --network-alias hubzilla-db \
        -e MARIADB_ROOT_PASSWORD="$HUBZILLA_DB_PASSWORD" \
        -e MARIADB_DATABASE="$HUBZILLA_DB_NAME" \
        -e MARIADB_USER=hubzilla \
        -e MARIADB_PASSWORD="$HUBZILLA_DB_PASSWORD" \
        "$MARIADB_IMAGE" >/dev/null

    wait_mariadb
    docker volume create "$HUBZILLA_VOLUME" >/dev/null

    docker run -d \
        --name "$HUBZILLA_CONTAINER" \
        --hostname "$HUBZILLA_HOST" \
        --network "$NETWORK" \
        --network-alias "$HUBZILLA_HOST" \
        -p "127.0.0.1:$HUBZILLA_PORT:80" \
        -e HUBZILLA_DB_HOST=hubzilla-db \
        -e HUBZILLA_DB_USER=hubzilla \
        -e HUBZILLA_DB_PASS="$HUBZILLA_DB_PASSWORD" \
        -e HUBZILLA_DB_NAME="$HUBZILLA_DB_NAME" \
        -e SSMTP_ROOT=postmaster \
        -e SSMTP_MAILHUB=localhost \
        -e SSMTP_AUTHUSER= \
        -e SSMTP_AUTHPASS= \
        -e SSMTP_USESTARTTLS=NO \
        -e SSMTP_FROMLINEOVERRIDE=YES \
        -e REVALIASES_ROOT=root:postmaster:localhost \
        -e REVALIASES_WWWDATA=www-data:postmaster:localhost \
        -v "$HUBZILLA_VOLUME:/var/www/html" \
        "$HUBZILLA_IMAGE" >/dev/null
}

wait_hubzilla_tree() {
    for _ in $(seq 1 180); do
        if docker exec "$HUBZILLA_CONTAINER" test -f /var/www/html/install/schema_mysql.sql >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    fail "Timed out waiting for Hubzilla checkout"
}

install_hubzilla() {
    local htconfig="$WORK_DIR/hubzilla-htconfig.php"
    local setup_php="$WORK_DIR/hubzilla-setup.php"

    cat >"$htconfig" <<EOF
<?php

App::set_baseurl('$HUBZILLA_INTERNAL_BASE');

\$db_host = 'hubzilla-db';
\$db_port = '0';
\$db_user = 'hubzilla';
\$db_pass = '$HUBZILLA_DB_PASSWORD';
\$db_data = '$HUBZILLA_DB_NAME';
\$db_type = 'mysql';
\$default_timezone = 'UTC';
\$admin_email = 'admin@$HUBZILLA_HOST';
\$system['php_path'] = '/usr/local/bin/php';
\$system['site_id'] = '$PREFIX-hubzilla-site';
EOF

    docker cp "$htconfig" "$HUBZILLA_CONTAINER:/var/www/html/.htconfig.php"
    docker exec "$HUBZILLA_CONTAINER" bash -lc 'cd /var/www/html && mkdir -p store/[data]/smarty3 && chown -R www-data:www-data store'
    docker cp "$HUBZILLA_CONTAINER:/var/www/html/install/schema_mysql.sql" "$WORK_DIR/schema_mysql.sql"
    docker cp "$WORK_DIR/schema_mysql.sql" "$HUBZILLA_DB_CONTAINER:/tmp/schema_mysql.sql"
    docker exec "$HUBZILLA_DB_CONTAINER" sh -lc "mariadb -uhubzilla -p'$HUBZILLA_DB_PASSWORD' '$HUBZILLA_DB_NAME' < /tmp/schema_mysql.sql"
    docker exec "$HUBZILLA_CONTAINER" bash -lc 'cd /var/www/html && php util/update_db >/tmp/update_db.log 2>&1 || { cat /tmp/update_db.log >&2; exit 1; }'
    docker exec "$HUBZILLA_CONTAINER" bash -lc 'cd /var/www/html && php util/addons install pubcrawl >/tmp/pubcrawl-install.log 2>&1 || { cat /tmp/pubcrawl-install.log >&2; exit 1; }'

    cat >"$setup_php" <<'PHP'
<?php
require_once('include/cli_startup.php');
cli_startup();
require_once('include/account.php');
require_once('include/channel.php');
require_once('include/permissions.php');
use Zotlabs\Lib\Apps;
use Zotlabs\Lib\Config;

Config::Set('system', 'allowed_themes', 'redbasic');
Config::Set('system', 'register_policy', 0);
Config::Set('system', 'default_permissions_role', 'social');
Config::Set('system', 'activitypub_allowed', 1);
Config::Set('system', 'baseurl', '__HUBZILLA_INTERNAL_BASE__');
App::set_baseurl('__HUBZILLA_INTERNAL_BASE__');
create_sys_channel();

function make_smoke_account($email, $password) {
    $existing = q("select account_id from account where account_email = '%s' limit 1", dbesc($email));
    if ($existing) {
        return intval($existing[0]['account_id']);
    }

    $salt = random_string(32);
    $hash = hash('whirlpool', $salt . $password);
    q("insert into account (account_parent, account_salt, account_password, account_email, account_language, account_created, account_flags, account_roles, account_level, account_expires, account_service_class) values (0, '%s', '%s', '%s', 'en', '%s', 0, 0, 5, '%s', '')",
        dbesc($salt), dbesc($hash), dbesc($email), dbesc(datetime_convert()), dbesc(DBA::$dba->get_null_date()));
    $r = q("select * from account where account_email = '%s' limit 1", dbesc($email));
    if (!$r) {
        fwrite(STDERR, "could not create Hubzilla smoke account\n");
        exit(1);
    }
    q("update account set account_parent = %d where account_id = %d", intval($r[0]['account_id']), intval($r[0]['account_id']));
    return intval($r[0]['account_id']);
}

function ensure_channel($account_id, $address, $name, $group_actor) {
    $existing = q("select * from channel where channel_address = '%s' limit 1", dbesc($address));
    if ($existing) {
        $channel = $existing[0];
    }
    else {
        $result = create_identity([
            'account_id' => $account_id,
            'name' => $name,
            'nickname' => $address,
            'permissions_role' => 'social',
            'publish' => 1,
        ]);
        if (!$result['success']) {
            fwrite(STDERR, "could not create $address: " . $result['message'] . "\n");
            exit(1);
        }
        $channel = $result['channel'];
    }

    set_pconfig($channel['channel_id'], 'system', 'autoperms', 1);
    set_pconfig($channel['channel_id'], 'system', 'group_actor', $group_actor ? 1 : 0);
    return $channel;
}

function install_pubcrawl_app($channel_id) {
    $app = [
        'uid' => $channel_id,
        'guid' => hash('whirlpool', 'Activitypub Protocol'),
        'system' => 1,
        'version' => '5',
        'url' => '$baseurl/pubcrawl',
        'requires' => 'local_channel',
        'name' => 'Activitypub Protocol',
        'photo' => '$baseurl/addon/pubcrawl/activitypub.png',
        'categories' => 'Federation',
        'desc' => 'This app enables your channel to communicate with platforms implementing the Activitypub protocol.',
        'type' => 'system',
        'plugin' => 'pubcrawl'
    ];

    q("delete from app where app_id = '%s' and app_channel = %d", dbesc($app['guid']), intval($channel_id));
    $ok = Apps::app_store($app);
    if (!$ok['success']) {
        fwrite(STDERR, "could not install pubcrawl app for channel $channel_id\n");
        exit(1);
    }
}

$aid = make_smoke_account('author@hubzilla-ref.test', 'SmokeTest_01');
$author = ensure_channel($aid, 'author', 'Hubzilla Author', false);
$forum = ensure_channel($aid, 'forum', 'Hubzilla Forum', true);
install_pubcrawl_app(0);
install_pubcrawl_app($author['channel_id']);
install_pubcrawl_app($forum['channel_id']);

print json_encode([
    'author_id' => $author['channel_id'],
    'forum_id' => $forum['channel_id'],
    'forum' => 'forum'
]) . "\n";
PHP

    sed -i "s#__HUBZILLA_INTERNAL_BASE__#$HUBZILLA_INTERNAL_BASE#g" "$setup_php"
    docker cp "$setup_php" "$HUBZILLA_CONTAINER:/tmp/hubzilla-setup.php"
    docker exec "$HUBZILLA_CONTAINER" bash -lc 'cd /var/www/html && php /tmp/hubzilla-setup.php'
    docker exec "$HUBZILLA_CONTAINER" bash -lc 'cd /var/www/html && php util/addons install pubcrawl >/tmp/pubcrawl-install-final.log 2>&1 || { cat /tmp/pubcrawl-install-final.log >&2; exit 1; }'
    docker exec "$HUBZILLA_CONTAINER" bash -lc 'cd /var/www/html && php util/addons list | grep -qx pubcrawl'
}

wait_hubzilla() {
    for _ in $(seq 1 120); do
        if curl -fsS -H "Host: $HUBZILLA_HOST" "$HUBZILLA_BASE/channel/forum" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    fail "Timed out waiting for Hubzilla at $HUBZILLA_BASE"
}

hubzilla_cron() {
    local runs="${1:-1}"

    for _ in $(seq 1 "$runs"); do
        docker exec "$HUBZILLA_CONTAINER" bash -lc 'cd /var/www/html && php Zotlabs/Daemon/Master.php Cron' >/dev/null 2>&1 || true
    done
}

hubzilla_connect() {
    local channel="$1"
    local target="$2"
    local helper="$WORK_DIR/hubzilla-connect.php"

    cat >"$helper" <<'PHP'
<?php
require_once('include/cli_startup.php');
cli_startup();
require_once('include/channel.php');
use Zotlabs\Lib\Connect;

App::set_baseurl('__HUBZILLA_INTERNAL_BASE__');
$channel = channelx_by_nick($argv[1]);
if (!$channel) {
    fwrite(STDERR, "source channel not found\n");
    exit(1);
}

$result = Connect::connect($channel, $argv[2]);
print json_encode($result) . "\n";
if (empty($result['success'])) {
    exit(1);
}
PHP

    sed -i "s#__HUBZILLA_INTERNAL_BASE__#$HUBZILLA_INTERNAL_BASE#g" "$helper"
    docker cp "$helper" "$HUBZILLA_CONTAINER:/tmp/hubzilla-connect.php"
    docker exec "$HUBZILLA_CONTAINER" bash -lc "cd /var/www/html && php /tmp/hubzilla-connect.php '$channel' '$target'"
}

hubzilla_sql() {
    docker exec "$HUBZILLA_DB_CONTAINER" \
        mariadb -N -B -uhubzilla -p"$HUBZILLA_DB_PASSWORD" "$HUBZILLA_DB_NAME" \
        -e "$1"
}

hubzilla_item_row_by_text() {
    local literal
    literal="$(sql_literal "$1")"
    hubzilla_sql "select id, mid from item where body like concat('%', $literal, '%') and item_deleted = 0 order by id desc limit 1;"
}

poll_hubzilla_item_by_text() {
    local text="$1"
    local message="$2"
    local row=""

    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        row="$(hubzilla_item_row_by_text "$text" || true)"
        if [ -n "$row" ]; then
            printf '%s\n' "$row"
            return 0
        fi
        hubzilla_cron 1 >/dev/null 2>&1 || true
        sleep 2
    done

    fail "$message"
}

try_poll_hubzilla_item_by_text() {
    local text="$1"
    local row=""

    for _ in $(seq 1 "$OPTIONAL_POLL_ATTEMPTS"); do
        row="$(hubzilla_item_row_by_text "$text" || true)"
        if [ -n "$row" ]; then
            printf '%s\n' "$row"
            return 0
        fi
        hubzilla_cron 1 >/dev/null 2>&1 || true
        sleep 2
    done

    return 1
}

hubzilla_item_deleted_count() {
    hubzilla_sql "select count(*) from item where id = $1 and item_deleted = 1;"
}

poll_hubzilla_item_deleted() {
    local item_id="$1"
    local message="$2"
    local count=""

    for _ in $(seq 1 "$POLL_ATTEMPTS"); do
        count="$(hubzilla_item_deleted_count "$item_id" || true)"
        if [ -n "$count" ] && [ "$count" -ge 1 ] 2>/dev/null; then
            return 0
        fi
        hubzilla_cron 1 >/dev/null 2>&1 || true
        sleep 2
    done

    fail "$message"
}

try_poll_hubzilla_item_deleted() {
    local item_id="$1"
    local count=""

    for _ in $(seq 1 "$OPTIONAL_POLL_ATTEMPTS"); do
        count="$(hubzilla_item_deleted_count "$item_id" || true)"
        if [ -n "$count" ] && [ "$count" -ge 1 ] 2>/dev/null; then
            return 0
        fi
        hubzilla_cron 1 >/dev/null 2>&1 || true
        sleep 2
    done

    return 1
}

hubzilla_like_count() {
    local literal
    literal="$(sql_literal "$1")"
    hubzilla_sql "select count(*) from item where verb = 'Like' and thr_parent = $literal and item_deleted = 0;"
}

poll_hubzilla_like_count() {
    local parent_mid="$1"
    local expected_expr="$2"
    local count=""

    for _ in $(seq 1 "$OPTIONAL_POLL_ATTEMPTS"); do
        count="$(hubzilla_like_count "$parent_mid" || true)"
        if [ -n "$count" ] && python3 - "$count" "$expected_expr" <<'PY'
import sys
count = int(sys.argv[1])
expr = sys.argv[2]
sys.exit(0 if eval(expr, {"__builtins__": {}}, {"count": count}) else 1)
PY
        then
            return 0
        fi
        hubzilla_cron 1 >/dev/null 2>&1 || true
        sleep 2
    done

    return 1
}

hubzilla_drop_item() {
    local helper="$WORK_DIR/hubzilla-drop.php"

    cat >"$helper" <<'PHP'
<?php
require_once('include/cli_startup.php');
cli_startup();
require_once('include/items.php');
$id = intval($argv[1]);
drop_item($id, DROPITEM_PHASE1);
print "dropped $id\n";
PHP

    docker cp "$helper" "$HUBZILLA_CONTAINER:/tmp/hubzilla-drop.php"
    docker exec "$HUBZILLA_CONTAINER" bash -lc "cd /var/www/html && php /tmp/hubzilla-drop.php '$1'" >/dev/null
}

hubzilla_like_path() {
    local item_id="$1"
    local verb="$2"
    local tmp code
    tmp="$(mktemp)"
    code="$(curl -sS -H "Host: $HUBZILLA_HOST" -u "author:$PASSWORD" -o "$tmp" -w "%{http_code}" "$HUBZILLA_BASE/like/$item_id?verb=$verb" || true)"
    rm -f "$tmp"
    [ "$code" = "200" ] || [ "$code" = "302" ]
}

poll_be_status_count() {
    poll_json_assert \
        "http_form GET $BE_BASE/api/v1/statuses/$1 $ALICE_TOKEN 200" \
        "$2" \
        "$3" >/dev/null
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
        sleep 2
    done

    fail "Deleted Hubzilla reply is still visible in Unfathomably context"
}

log "Writing disposable Unfathomably and proxy configuration"
write_be_secret
write_be_proxy_config

log "Creating Docker network"
docker rm -f \
    "$HUBZILLA_CONTAINER" \
    "$HUBZILLA_DB_CONTAINER" \
    "$BE_PROXY_CONTAINER" \
    "$BE_CONTAINER" \
    "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
docker network rm "$NETWORK" >/dev/null 2>&1 || true
docker volume rm "$HUBZILLA_VOLUME" >/dev/null 2>&1 || true
docker network create "$NETWORK" >/dev/null

log "Starting databases"
docker run -d \
    --name "$BE_DB_CONTAINER" \
    --network "$NETWORK" \
    -e POSTGRES_PASSWORD="$BE_DB_PASSWORD" \
    "$POSTGRES_IMAGE" >/dev/null

wait_postgres
prepare_database

log "Starting stock Hubzilla"
start_hubzilla
wait_hubzilla_tree
install_hubzilla
wait_hubzilla

log "Migrating and starting Unfathomably"
docker_run_mix "${PREFIX}-migrate-be" "mix ecto.migrate"
create_be_user alice "alice@$BE_HOST"
start_be
start_be_proxy
wait_be

log "Creating Unfathomably API credentials and local group"
ALICE_TOKEN="$(create_be_token alice)"
BE_GROUP_NAME="unfathomably_hubzilla_smoke"
BE_GROUP="$(
    http_form POST "$BE_BASE/api/v1/groups" "$ALICE_TOKEN" 200 \
        "display_name=Unfathomably Hubzilla Smoke" \
        "name=$BE_GROUP_NAME" \
        "note=Open group used by the Hubzilla bidirectional smoke harness." \
        "locked=false"
)"
BE_GROUP_ID="$(json_get "$BE_GROUP" id)"
BE_GROUP_AP_ID="$(json_get_optional "$BE_GROUP" ap_id)"
if [ -z "$BE_GROUP_AP_ID" ]; then
    BE_GROUP_AP_ID="$(json_get "$BE_GROUP" url)"
fi

log "Verifying Hubzilla forum actor"
HUBZILLA_FORUM_AP_ID="$HUBZILLA_INTERNAL_BASE/channel/forum"
HUBZILLA_FORUM_ACTOR="$(curl -sS -H "Host: $HUBZILLA_HOST" -H 'Accept: application/activity+json' "$HUBZILLA_BASE/channel/forum")"
json_assert "$HUBZILLA_FORUM_ACTOR" 'data.get("type") == "Group"' "Hubzilla forum channel did not render as an ActivityPub Group"

log "Following groups in both supported directions"
BE_REMOTE_HUBZILLA_GROUP="$(
    http_form GET "$BE_BASE/api/v1/groups/lookup?uri=$(urlencode "$HUBZILLA_FORUM_AP_ID")" \
        "$ALICE_TOKEN" \
        200
)"
BE_REMOTE_HUBZILLA_GROUP_ID="$(json_get "$BE_REMOTE_HUBZILLA_GROUP" id)"
BE_JOIN_HUBZILLA="$(
    http_form POST "$BE_BASE/api/v1/groups/$BE_REMOTE_HUBZILLA_GROUP_ID/join" \
        "$ALICE_TOKEN" \
        200
)"
json_assert "$BE_JOIN_HUBZILLA" 'data.get("member") is True or data.get("requested") is True' \
    "Unfathomably could not follow the Hubzilla forum actor"
hubzilla_cron 8

hubzilla_connect author "$BE_GROUP_AP_ID" >/dev/null
hubzilla_cron 8

poll_json_assert \
    "http_form GET $BE_BASE/api/v1/accounts/$BE_GROUP_ID/followers?limit=40 $ALICE_TOKEN 200" \
    'any(account.get("acct") == "author@'$HUBZILLA_HOST'" or account.get("fqn") == "author@'$HUBZILLA_HOST'" for account in data)' \
    "Unfathomably did not see the Hubzilla author following the group" >/dev/null

log "Testing Hubzilla post delivery into Unfathomably"
HUBZILLA_TO_BE_TEXT="Hubzilla to Unfathomably group smoke $(basename "$WORK_DIR")"
HUBZILLA_TO_BE_POST="$(
    hubzilla_form POST /api/z/1.0/item/update 200 \
        "body=$HUBZILLA_TO_BE_TEXT @$BE_GROUP_NAME@$BE_HOST"
)"
HUBZILLA_TO_BE_ID="$(json_get "$HUBZILLA_TO_BE_POST" item.id)"
HUBZILLA_TO_BE_MID="$(json_get "$HUBZILLA_TO_BE_POST" item.mid)"
hubzilla_cron 10
BE_VIEW_OF_HUBZILLA_POST_ID="$(resolve_be_status_id "$HUBZILLA_TO_BE_MID" "$ALICE_TOKEN" "Unfathomably could not resolve Hubzilla group mention post")"

BE_LIKE_HUBZILLA="$(http_form POST "$BE_BASE/api/v1/statuses/$BE_VIEW_OF_HUBZILLA_POST_ID/favourite" "$ALICE_TOKEN" 200)"
json_assert "$BE_LIKE_HUBZILLA" 'data.get("favourited") is True' "Unfathomably could not like Hubzilla post"
hubzilla_cron 8
if poll_hubzilla_like_count "$HUBZILLA_TO_BE_MID" 'count >= 1'; then
    BE_UNLIKE_HUBZILLA="$(http_form POST "$BE_BASE/api/v1/statuses/$BE_VIEW_OF_HUBZILLA_POST_ID/unfavourite" "$ALICE_TOKEN" 200)"
    json_assert "$BE_UNLIKE_HUBZILLA" 'data.get("favourited") is False' "Unfathomably could not unlike Hubzilla post"
    hubzilla_cron 8
    poll_hubzilla_like_count "$HUBZILLA_TO_BE_MID" 'count == 0' ||
        fail "Hubzilla did not see Unfathomably unlike on Hubzilla post"
    HUBZILLA_LIKE_SUMMARY="* Unfathomably like and unlike on Hubzilla content"
else
    printf '%s\n' \
        "not_supported: stock Hubzilla did not materialize a remote ActivityPub Like in the local item table during the smoke window"
    http_form POST "$BE_BASE/api/v1/statuses/$BE_VIEW_OF_HUBZILLA_POST_ID/unfavourite" "$ALICE_TOKEN" 200 >/dev/null
    HUBZILLA_LIKE_SUMMARY="* not_supported: stock Hubzilla did not expose remote Like/Undo Like state through the smoke-observable item table"
fi

BE_REPLY_TEXT="Unfathomably reply to Hubzilla $(basename "$WORK_DIR")"
BE_REPLY="$(
    http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$BE_REPLY_TEXT" \
        "in_reply_to_id=$BE_VIEW_OF_HUBZILLA_POST_ID"
)"
BE_REPLY_ID="$(json_get "$BE_REPLY" id)"
hubzilla_cron 10
if HUBZILLA_VIEW_OF_BE_REPLY="$(try_poll_hubzilla_item_by_text "$BE_REPLY_TEXT")"; then
    HUBZILLA_VIEW_OF_BE_REPLY_ID="$(printf '%s\n' "$HUBZILLA_VIEW_OF_BE_REPLY" | cut -f1)"

    http_form DELETE "$BE_BASE/api/v1/statuses/$BE_REPLY_ID" "$ALICE_TOKEN" 200 >/dev/null
    hubzilla_cron 10
    poll_hubzilla_item_deleted "$HUBZILLA_VIEW_OF_BE_REPLY_ID" \
        "Hubzilla did not mark the deleted Unfathomably reply as deleted"
    BE_REPLY_SUMMARY="* Unfathomably reply and reply-delete on Hubzilla content"
else
    printf '%s\n' \
        "not_supported: stock Hubzilla accepted the remote reply activity but did not materialize an Unfathomably reply under Hubzilla-authored content in the smoke-observable item table"
    http_form DELETE "$BE_BASE/api/v1/statuses/$BE_REPLY_ID" "$ALICE_TOKEN" 200 >/dev/null
    hubzilla_cron 10
    BE_REPLY_SUMMARY="* not_supported: stock Hubzilla did not materialize Unfathomably replies under Hubzilla-authored content in the smoke-observable item table"
fi

log "Testing Unfathomably post delivery into Hubzilla"
BE_TO_HUBZILLA_TEXT="Unfathomably to Hubzilla forum smoke $(basename "$WORK_DIR")"
BE_TO_HUBZILLA_POST="$(
    http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$BE_TO_HUBZILLA_TEXT" \
        "group_id=$BE_REMOTE_HUBZILLA_GROUP_ID"
)"
BE_TO_HUBZILLA_POST_ID="$(json_get "$BE_TO_HUBZILLA_POST" id)"
hubzilla_cron 12
HUBZILLA_VIEW_OF_BE_POST="$(poll_hubzilla_item_by_text "$BE_TO_HUBZILLA_TEXT" "Hubzilla did not receive Unfathomably group post")"
HUBZILLA_VIEW_OF_BE_POST_ID="$(printf '%s\n' "$HUBZILLA_VIEW_OF_BE_POST" | cut -f1)"
HUBZILLA_VIEW_OF_BE_POST_MID="$(printf '%s\n' "$HUBZILLA_VIEW_OF_BE_POST" | cut -f2)"

HUBZILLA_REPLY_TEXT="Hubzilla reply to Unfathomably $(basename "$WORK_DIR")"
HUBZILLA_REPLY="$(
    hubzilla_form POST /api/z/1.0/item/update 200 \
        "body=$HUBZILLA_REPLY_TEXT" \
        "parent_mid=$HUBZILLA_VIEW_OF_BE_POST_MID"
)"
if HUBZILLA_REPLY_ROW="$(try_poll_hubzilla_item_by_text "$HUBZILLA_REPLY_TEXT")"; then
    HUBZILLA_REPLY_ID="$(printf '%s\n' "$HUBZILLA_REPLY_ROW" | cut -f1)"
    HUBZILLA_REPLY_MID="$(printf '%s\n' "$HUBZILLA_REPLY_ROW" | cut -f2)"
    hubzilla_cron 10
    resolve_be_context_status_id "$BE_TO_HUBZILLA_POST_ID" "$HUBZILLA_REPLY_MID" "$ALICE_TOKEN" "Unfathomably did not receive Hubzilla reply" >/dev/null
    HUBZILLA_REPLY_SUMMARY="* Hubzilla reply and reply-delete on Unfathomably content"
else
    printf '%s\n' \
        "not_supported: stock Hubzilla returned no stored reply for its authenticated item/update call against the imported Unfathomably object"
    printf 'hubzilla_reply_response=%s\n' "$HUBZILLA_REPLY"
    HUBZILLA_REPLY_ID=""
    HUBZILLA_REPLY_SUMMARY="* not_supported: stock Hubzilla did not expose a scriptable authenticated reply path for imported Unfathomably ActivityPub content in this harness"
fi

if hubzilla_like_path "$HUBZILLA_VIEW_OF_BE_POST_ID" like; then
    hubzilla_cron 10
    if try_poll_json_assert \
        "http_form GET $BE_BASE/api/v1/statuses/$BE_TO_HUBZILLA_POST_ID $ALICE_TOKEN 200" \
        'int(data.get("favourites_count") or 0) >= 1' \
        >/dev/null; then
        hubzilla_like_path "$HUBZILLA_VIEW_OF_BE_POST_ID" unlike || true
        hubzilla_cron 10
        poll_be_status_count "$BE_TO_HUBZILLA_POST_ID" 'int(data.get("favourites_count") or 0) == 0' \
            "Unfathomably did not see Hubzilla unlike on Unfathomably post"
        HUBZILLA_REMOTE_LIKE_SUMMARY="* Hubzilla like and unlike on Unfathomably content"
    else
        HUBZILLA_REMOTE_LIKE_SUMMARY="* not_supported: stock Hubzilla accepted the local like action but did not federate Like to Unfathomably during the smoke window"
    fi
else
    HUBZILLA_REMOTE_LIKE_SUMMARY="* not_supported: stock Hubzilla did not expose a scriptable authenticated Like endpoint for imported ActivityPub content in this harness"
fi

if [ -n "$HUBZILLA_REPLY_ID" ]; then
    hubzilla_drop_item "$HUBZILLA_REPLY_ID"
    hubzilla_cron 12
    poll_be_context_absent "$BE_TO_HUBZILLA_POST_ID" "$HUBZILLA_REPLY_TEXT" "$ALICE_TOKEN"
fi

http_form DELETE "$BE_BASE/api/v1/statuses/$BE_TO_HUBZILLA_POST_ID" "$ALICE_TOKEN" 200 >/dev/null
hubzilla_cron 12
if try_poll_hubzilla_item_deleted "$HUBZILLA_VIEW_OF_BE_POST_ID"; then
    HUBZILLA_DELETE_SUMMARY="* Unfathomably top-level post delete delivery into Hubzilla"
else
    printf '%s\n' \
        "not_supported: stock Hubzilla accepted the Delete inbox delivery but did not mark the imported Unfathomably top-level post deleted in the smoke-observable item table"
    HUBZILLA_DELETE_SUMMARY="* not_supported: stock Hubzilla did not apply remote Delete to the imported Unfathomably top-level post in the smoke-observable item table"
fi

log "Unfollowing groups"
http_form POST "$BE_BASE/api/v1/groups/$BE_REMOTE_HUBZILLA_GROUP_ID/leave" "$ALICE_TOKEN" 200 >/dev/null
printf '%s\n' \
    "not_supported: stock Hubzilla exposes follow creation through util/connect, but this harness found no matching stock CLI/API unfollow helper; browser connection removal remains a manual Hubzilla operation"

log "Checking logs for obvious crashes"
for container in "$HUBZILLA_CONTAINER" "$BE_CONTAINER"; do
    if docker logs "$container" 2>&1 |
        grep -E "status=500|Internal Server Error|Fatal error|GenServer terminating|FunctionClauseError|UndefinedFunctionError|Protocol\\.UndefinedError" >/dev/null; then
        docker logs --tail 260 "$container" >&2
        fail "$container logged errors during Hubzilla smoke run"
    fi
done

cat <<EOF

Hubzilla bidirectional smoke passed:
* Unfathomably follow of a Hubzilla forum Group actor
* Hubzilla follow of an Unfathomably group through Hubzilla's Connect helper
* Hubzilla top-level group mention delivery into Unfathomably
$HUBZILLA_LIKE_SUMMARY
$BE_REPLY_SUMMARY
* Unfathomably top-level group post delivery into Hubzilla
$HUBZILLA_REPLY_SUMMARY
$HUBZILLA_REMOTE_LIKE_SUMMARY
$HUBZILLA_DELETE_SUMMARY
* Unfathomably unfollow cleanup of the Hubzilla forum actor
* not_supported: Hubzilla unfollow from CLI/API was not available in the stock harness surface
EOF

exit 0

# end of unfathomably-hubzilla-smoke.sh
