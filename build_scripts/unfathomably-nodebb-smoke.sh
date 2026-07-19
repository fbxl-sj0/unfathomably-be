#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-nodebb-smoke.sh
#
# Purpose:
#
#   Start a clean Unfathomably smoke instance and a clean NodeBB
#   instance on the same Docker network, then prove that NodeBB
#   category synchronization interoperates with Unfathomably groups.
#
# Responsibilities:
#
#   * boot an unmodified NodeBB image with Redis and an internal HTTP proxy
#   * reuse the existing two-instance Unfathomably smoke bootstrap
#   * enable NodeBB ActivityPub through normal NodeBB configuration
#   * exercise category/group follow, post, reply, like, unlike, delete,
#     and unfollow paths in both supported directions
#   * fail loudly if either server logs obvious 500/crash output
#
# This file intentionally does NOT contain:
#
#   * production deployment logic
#   * persistent NodeBB database management
#   * TLS certificate provisioning
#   * browser automation
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE="${SMOKE_IMAGE:-unfathomably-elixir-smoke:otp28}"
NODEBB_IMAGE="${NODEBB_IMAGE:-ghcr.io/nodebb/nodebb:latest}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.27-alpine}"

PREFIX="${SMOKE_PREFIX:-unfathomably-nodebb-smoke}"
NETWORK="${SMOKE_NETWORK:-$PREFIX-net}"
BE_PREFIX="$PREFIX-be"

A_HOST="${SMOKE_A_HOST:-smoke-a}"
B_HOST="${SMOKE_B_HOST:-smoke-b}"
A_PORT="${SMOKE_A_PORT:-4651}"
B_PORT="${SMOKE_B_PORT:-4652}"
NODEBB_HOST="${NODEBB_HOST:-nodebb-smoke}"
NODEBB_PORT="${NODEBB_PORT:-4653}"

PASSWORD="${SMOKE_USER_PASSWORD:-SmokeTest_01}"
DB_PASSWORD="${SMOKE_DB_PASSWORD:-postgres}"
NODEBB_ADMIN_PASSWORD="${NODEBB_ADMIN_PASSWORD:-NodeBBSmoke_01}"
KEEP_SMOKE="${KEEP_SMOKE:-0}"
NODEBB_ENV="${NODEBB_ENV:-production}"
NODEBB_CI="${NODEBB_CI:-true}"
POLL_ATTEMPTS="${SMOKE_POLL_ATTEMPTS:-90}"

WORK_DIR="${SMOKE_WORK_DIR:-}"
if [ -z "$WORK_DIR" ]; then
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/unfathomably-nodebb-smoke.XXXXXX")"
fi

BASE_URL="http://127.0.0.1:$A_PORT"
NODEBB_URL="http://127.0.0.1:$NODEBB_PORT"
NODEBB_AP_BASE="http://$NODEBB_HOST"

log() {
    printf '\n==> %s\n' "$*"
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2

    for container in \
        "$PREFIX-nodebb-proxy" \
        "$PREFIX-nodebb" \
        "$PREFIX-nodebb-redis" \
        "$BE_PREFIX-a" \
        "$BE_PREFIX-b" \
        "$BE_PREFIX-db"; do
        if docker inspect "$container" >/dev/null 2>&1; then
            printf '\n--- docker logs --tail 180 %s ---\n' "$container" >&2
            docker logs --tail 180 "$container" >&2 || true
        fi
    done

    exit 1
}

cleanup() {
    if [ "$KEEP_SMOKE" = "1" ]; then
        cat <<EOF

Smoke containers preserved because KEEP_SMOKE=1.
Unfathomably: $BASE_URL
NodeBB:        $NODEBB_URL  (Host header: $NODEBB_HOST)
Work dir:      $WORK_DIR
EOF
        return
    fi

    docker rm -f \
        "$PREFIX-nodebb-proxy" \
        "$PREFIX-nodebb" \
        "$PREFIX-nodebb-setup" \
        "$PREFIX-nodebb-redis" \
        "$BE_PREFIX-a" \
        "$BE_PREFIX-b" \
        "$BE_PREFIX-db" >/dev/null 2>&1 || true
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

path = sys.argv[1].split(".")
data = json.loads(os.environ["JSON_PAYLOAD"])

for part in path:
    if isinstance(data, list):
        data = data[int(part)]
    else:
        data = data[part]

if isinstance(data, (dict, list)):
    print(json.dumps(data))
elif data is None:
    print("")
else:
    print(data)
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

nodebb_json() {
    local method="$1"
    local path="$2"
    local expected="$3"
    local body="${4:-}"

    local tmp code
    tmp="$(mktemp)"

    local args=(
        -sS
        -X "$method"
        -H "Host: $NODEBB_HOST"
        -H "Authorization: Bearer $NODEBB_TOKEN"
        -H "Content-Type: application/json"
        -o "$tmp"
        -w "%{http_code}"
    )

    if [ -n "$body" ]; then
        args+=(-d "$body")
    fi

    args+=("$NODEBB_URL$path")

    code="$(curl "${args[@]}")" || {
        cat "$tmp" >&2 || true
        rm -f "$tmp"
        fail "curl failed for NodeBB $method $path"
    }

    if [ "$code" != "$expected" ]; then
        cat "$tmp" >&2 || true
        rm -f "$tmp"
        fail "Unexpected NodeBB HTTP $code for $method $path (expected $expected)"
    fi

    cat "$tmp"
    rm -f "$tmp"
}

nodebb_get_public() {
    local path="$1"
    local expected="$2"

    local tmp code
    tmp="$(mktemp)"

    code="$(
        curl -sS \
            -H "Host: $NODEBB_HOST" \
            -o "$tmp" \
            -w "%{http_code}" \
            "$NODEBB_URL$path"
    )" || {
        cat "$tmp" >&2 || true
        rm -f "$tmp"
        fail "curl failed for NodeBB GET $path"
    }

    if [ "$code" != "$expected" ]; then
        cat "$tmp" >&2 || true
        rm -f "$tmp"
        fail "Unexpected NodeBB HTTP $code for GET $path (expected $expected)"
    fi

    cat "$tmp"
    rm -f "$tmp"
}

poll_json_assert() {
    local method="$1"
    local url="$2"
    local token="$3"
    local expected="$4"
    local expr="$5"
    local message="$6"
    local attempts="${7:-$POLL_ATTEMPTS}"
    local delay="${8:-2}"
    local result

    for _ in $(seq 1 "$attempts"); do
        result="$(http_form "$method" "$url" "$token" "$expected" || true)"

        if [ -n "$result" ] && json_matches "$result" "$expr" >/dev/null 2>&1; then
            printf '%s\n' "$result"
            return 0
        fi

        sleep "$delay"
    done

    printf '%s\n' "$result" >&2
    fail "Polling timed out: $message"
}

poll_http_status() {
    local method="$1"
    local url="$2"
    local token="$3"
    local expected="$4"
    local message="$5"
    local attempts="${6:-$POLL_ATTEMPTS}"
    local delay="${7:-2}"
    local tmp code

    tmp="$(mktemp)"

    for _ in $(seq 1 "$attempts"); do
        local args=(-sS -X "$method" -o "$tmp" -w "%{http_code}")
        if [ -n "$token" ]; then
            args+=(-H "Authorization: Bearer $token")
        fi
        args+=("$url")

        code="$(curl "${args[@]}")" || code="000"

        if [ "$code" = "$expected" ]; then
            rm -f "$tmp"
            return 0
        fi

        sleep "$delay"
    done

    cat "$tmp" >&2 || true
    rm -f "$tmp"
    fail "Polling timed out: $message stayed at HTTP $code instead of $expected"
}

wait_nodebb() {
    for _ in $(seq 1 120); do
        if curl -fsS -H "Host: $NODEBB_HOST" "$NODEBB_URL/api/v3/ping" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    fail "Timed out waiting for NodeBB at $NODEBB_URL"
}

be_token() {
    local username="$1"
    local app token client_id client_secret

    app="$(
        http_form POST "$BASE_URL/api/v1/apps" "" 200 \
            "client_name=nodebb-smoke" \
            "redirect_uris=urn:ietf:wg:oauth:2.0:oob" \
            "scopes=read write follow push"
    )"
    client_id="$(json_get "$app" client_id)"
    client_secret="$(json_get "$app" client_secret)"

    token="$(
        http_form POST "$BASE_URL/oauth/token" "" 200 \
            "grant_type=password" \
            "username=$username" \
            "password=$PASSWORD" \
            "client_id=$client_id" \
            "client_secret=$client_secret" \
            "scope=read write follow push"
    )"

    json_get "$token" access_token
}

resolve_be_status_id() {
    local uri="$1"
    local token="$2"
    local message="$3"
    local result

    result="$(
        poll_json_assert GET \
            "$BASE_URL/api/v2/search?resolve=true&type=statuses&q=$(urlencode "$uri")" \
            "$token" \
            200 \
            'len(data.get("statuses", [])) >= 1' \
            "$message" \
            90 \
            2
    )"

    json_get "$result" statuses.0.id
}

resolve_be_context_status_id() {
    local parent_id="$1"
    local uri="$2"
    local token="$3"
    local message="$4"
    local result
    local id

    for _ in $(seq 1 90); do
        result="$(
            http_form GET \
                "$BASE_URL/api/v1/statuses/$parent_id/context" \
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

resolve_nodebb_post_id() {
    local uri="$1"
    local message="$2"
    local headers redirect

    for _ in $(seq 1 90); do
        headers="$(
            curl -sS \
                -H "Host: $NODEBB_HOST" \
                -H "Authorization: Bearer $NODEBB_TOKEN" \
                -D - \
                -o /dev/null \
                "$NODEBB_URL/api/ap?resource=$(urlencode "$uri")" || true
        )"

        redirect="$(
            printf '%s\n' "$headers" |
                awk 'BEGIN { IGNORECASE = 1 } /^X-Redirect:/ { sub(/\r$/, ""); print $2 }' |
                tail -1
        )"

        case "$redirect" in
            */post/*)
                printf '%s\n' "${redirect##*/post/}"
                return 0
                ;;
            */topic/*/*)
                nodebb_post_id_from_topic_redirect "$redirect" && return 0
                ;;
        esac

        sleep 2
    done

    printf '%s\n' "$headers" >&2
    fail "$message"
}

try_resolve_nodebb_post_id() {
    local uri="$1"
    local headers redirect encoded_uri

    encoded_uri="$(urlencode "$uri")"

    for _ in $(seq 1 90); do
        headers="$(
            curl -sS \
                -H "Host: $NODEBB_HOST" \
                -H "Authorization: Bearer $NODEBB_TOKEN" \
                -D - \
                -o /dev/null \
                "$NODEBB_URL/api/ap?resource=$(urlencode "$uri")" || true
        )"

        redirect="$(
            printf '%s\n' "$headers" |
                awk 'BEGIN { IGNORECASE = 1 } /^X-Redirect:/ { sub(/\r$/, ""); print $2 }' |
                tail -1
        )"

        if [ "$redirect" = "$uri" ] || [ "$redirect" = "$encoded_uri" ]; then
            return 1
        fi

        case "$redirect" in
            */post/*)
                printf '%s\n' "${redirect##*/post/}"
                return 0
                ;;
            */topic/*/*)
                nodebb_post_id_from_topic_redirect "$redirect" && return 0
                ;;
        esac

        sleep 2
    done

    return 1
}

resolve_nodebb_topic_post_id_by_text() {
    local topic_id="$1"
    local text="$2"
    local message="$3"
    local result id

    for _ in $(seq 1 90); do
        result="$(nodebb_json GET "/api/v3/topics/$topic_id" 200 || true)"

        id="$(
            JSON_PAYLOAD="$result" MATCH_TEXT="$text" python3 - <<'PY' || true
import json
import os

try:
    data = json.loads(os.environ["JSON_PAYLOAD"])
except Exception:
    raise SystemExit(1)

text = os.environ["MATCH_TEXT"]
posts = data.get("response", {}).get("posts", [])

for post in posts:
    if text in json.dumps(post, sort_keys=True):
        pid = post.get("pid")
        if pid:
            print(pid)
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

nodebb_post_id_from_topic_redirect() {
    local redirect="$1"
    local topic_id topic

    topic_id="$(
        printf '%s\n' "$redirect" |
            sed -n 's#.*/topic/\([0-9][0-9]*\).*#\1#p'
    )"

    if [ -z "$topic_id" ]; then
        return 1
    fi

    topic="$(nodebb_json GET "/api/v3/topics/$topic_id" 200)"
    json_get "$topic" response.mainPost.pid
}

poll_nodebb_json_assert() {
    local method="$1"
    local path="$2"
    local expected="$3"
    local expr="$4"
    local message="$5"
    local attempts="${6:-$POLL_ATTEMPTS}"
    local delay="${7:-2}"
    local body="${8:-}"
    local result

    for _ in $(seq 1 "$attempts"); do
        result="$(nodebb_json "$method" "$path" "$expected" "$body" || true)"

        if [ -n "$result" ] && json_matches "$result" "$expr" >/dev/null 2>&1; then
            printf '%s\n' "$result"
            return 0
        fi

        sleep "$delay"
    done

    printf '%s\n' "$result" >&2
    fail "Polling timed out: $message"
}

poll_nodebb_json_assert_when_visible() {
    local method="$1"
    local path="$2"
    local expected="$3"
    local expr="$4"
    local message="$5"
    local attempts="${6:-$POLL_ATTEMPTS}"
    local delay="${7:-2}"
    local body="${8:-}"
    local result=""
    local tmp code

    for _ in $(seq 1 "$attempts"); do
        tmp="$(mktemp)"

        local args=(
            -sS
            -X "$method"
            -H "Host: $NODEBB_HOST"
            -H "Authorization: Bearer $NODEBB_TOKEN"
            -H "Content-Type: application/json"
            -o "$tmp"
            -w "%{http_code}"
        )

        if [ -n "$body" ]; then
            args+=(-d "$body")
        fi

        args+=("$NODEBB_URL$path")

        code="$(curl "${args[@]}")" || code="000"
        result="$(cat "$tmp" 2>/dev/null || true)"
        rm -f "$tmp"

        if [ "$code" = "$expected" ] && json_matches "$result" "$expr" >/dev/null 2>&1; then
            printf '%s\n' "$result"
            return 0
        fi

        sleep "$delay"
    done

    printf '%s\n' "$result" >&2
    fail "Polling timed out: $message"
}

poll_nodebb_post_absent_or_deleted() {
    local path="$1"
    local message="$2"
    local attempts="${3:-$POLL_ATTEMPTS}"
    local delay="${4:-2}"
    local result=""
    local tmp code

    for _ in $(seq 1 "$attempts"); do
        tmp="$(mktemp)"
        code="$(
            curl -sS \
                -X GET \
                -H "Host: $NODEBB_HOST" \
                -H "Authorization: Bearer $NODEBB_TOKEN" \
                -H "Content-Type: application/json" \
                -o "$tmp" \
                -w "%{http_code}" \
                "$NODEBB_URL$path"
        )" || code="000"
        result="$(cat "$tmp" 2>/dev/null || true)"
        rm -f "$tmp"

        if [ "$code" = "404" ]; then
            return 0
        fi

        if [ "$code" = "200" ] && \
            json_matches "$result" 'data.get("response", {}).get("deleted") in [1, True]' >/dev/null 2>&1; then
            return 0
        fi

        sleep "$delay"
    done

    printf '%s\n' "$result" >&2
    fail "Polling timed out: $message"
}

sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

poll_be_object_unliked() {
    local object_ap_id="$1"
    local actor_ap_id="$2"
    local message="$3"
    local object_sql actor_sql result

    object_sql="$(sql_escape "$object_ap_id")"
    actor_sql="$(sql_escape "$actor_ap_id")"

    for _ in $(seq 1 90); do
        result="$(
            docker exec "$BE_PREFIX-db" psql -U postgres -d pleroma_smoke_a -Atc "
                select case
                    when coalesce((data->>'like_count')::int, 0) = 0
                         and not (coalesce(data->'likes', '[]'::jsonb) ? '$actor_sql')
                    then 'ok'
                    else coalesce(data->>'like_count', 'null') || ' ' || coalesce((data->'likes')::text, 'null')
                end
                from objects
                where data->>'id' = '$object_sql';
            "
        )"

        if [ "$result" = "ok" ]; then
            return 0
        fi

        sleep 2
    done

    fail "$message: backend object still shows like state $result"
}

write_nodebb_files() {
    cat >"$WORK_DIR/nodebb-setup.json" <<EOF
{
  "url": "$NODEBB_AP_BASE",
  "port": "4567",
  "secret": "nodebb-smoke-secret",
  "database": "redis",
  "redis:host": "$PREFIX-nodebb-redis",
  "redis:port": "6379",
  "redis:database": "0",
  "admin:username": "admin",
  "admin:password": "$NODEBB_ADMIN_PASSWORD",
  "admin:password:confirm": "$NODEBB_ADMIN_PASSWORD",
  "admin:email": "admin@example.test",
  "submitPluginUsage": "no"
}
EOF

    mkdir -p "$WORK_DIR/nodebb-plugin-smoke-allowlist"

    cat >"$WORK_DIR/nodebb-plugin-smoke-allowlist/plugin.json" <<'EOF'
{
  "id": "nodebb-plugin-smoke-allowlist",
  "name": "NodeBB Smoke Request Allowlist",
  "version": "0.0.1",
  "library": "./library.js",
  "hooks": [
    { "hook": "static:app.load", "method": "installSmokeRewrites" },
    {
      "hook": "filter:request.init",
      "method": "allowSmokeHosts"
    }
  ]
}
EOF

    cat >"$WORK_DIR/nodebb-plugin-smoke-allowlist/package.json" <<'EOF'
{
  "name": "nodebb-plugin-smoke-allowlist",
  "version": "0.0.1",
  "description": "Local-only request allowlist for the Unfathomably NodeBB smoke harness",
  "main": "library.js",
  "license": "MIT"
}
EOF

    cat >"$WORK_DIR/nodebb-plugin-smoke-allowlist/library.js" <<'EOF'
'use strict';

/*
    The local smoke network uses private Docker addresses that public
    ActivityPub servers would not see in the wild.  NodeBB correctly blocks
    private-address fetches by default to prevent SSRF issues.

    This harness-only plugin allowlists the disposable container hostnames so
    official NodeBB can fetch smoke actors and public keys without patching the
    NodeBB image itself.

    NodeBB also follows the normal public-server rule that WebFinger is
    discovered through HTTPS.  The smoke backends are plain HTTP services, so
    the plugin rewrites HTTPS requests for these exact container hostnames to
    their local HTTP backend ports.  That keeps the peer binary official while
    modeling the HTTPS edge that a real deployment would provide.
*/

let fetchRewriteInstalled = false;
let requestRewriteInstalled = false;
let originalFetch = null;

function debugLog(message) {
  if (process.env.NODEBB_SMOKE_DEBUG === '1') {
    console.log(`[smoke-allowlist] ${message}`);
  }
}

function smokeRewrites() {
  const pairs = [
    [
      process.env.NODEBB_SMOKE_A_HOST,
      process.env.NODEBB_SMOKE_A_PORT,
    ],
    [
      process.env.NODEBB_SMOKE_B_HOST,
      process.env.NODEBB_SMOKE_B_PORT,
    ],
  ];

  return pairs
    .filter(([host, port]) => host && port)
    .map(([host, port]) => [
      `https://${host}`,
      `http://${host}:${port}`,
    ]);
}

function rewriteFetchInput(input) {
  const href = typeof input === 'string' ? input : input && input.url;
  if (!href) {
    return input;
  }

  const match = smokeRewrites().find(([from]) => href === from || href.startsWith(`${from}/`));
  if (!match) {
    return input;
  }

  const [from, to] = match;
  const rewritten = `${to}${href.slice(from.length)}`;

  if (typeof input === 'string') {
    return rewritten;
  }

  if (input instanceof URL) {
    return new URL(rewritten);
  }

  if (typeof Request !== 'undefined' && input instanceof Request) {
    return new Request(rewritten, input);
  }

  return input;
}

function rewriteSmokeUrl(url) {
  if (typeof url !== 'string') {
    return url;
  }

  const match = smokeRewrites().find(([from]) => url === from || url.startsWith(`${from}/`));
  if (!match) {
    return url;
  }

  const [from, to] = match;
  const rewritten = `${to}${url.slice(from.length)}`;
  debugLog(`rewriting request URL ${url} -> ${rewritten}`);
  return rewritten;
}

function installFetchRewrite() {
  if (fetchRewriteInstalled || typeof fetch !== 'function') {
    return;
  }

  originalFetch = fetch;
  global.fetch = function (input, init) {
    return originalFetch(rewriteFetchInput(input), init);
  };
  fetchRewriteInstalled = true;
}

function installRequestRewrite() {
  if (requestRewriteInstalled) {
    return;
  }

  let request;
  try {
    request = require('/usr/src/app/src/request');
  } catch (err) {
    return;
  }

  let wrapped = false;

  ['get', 'post', 'put', 'del', 'delete', 'head'].forEach((method) => {
    if (typeof request[method] !== 'function') {
      return;
    }

    if (request[method].smokeRewriteInstalled) {
      wrapped = true;
      return;
    }

    const original = request[method].bind(request);
    const rewrittenRequestMethod = function (url, ...args) {
      return original(rewriteSmokeUrl(url), ...args);
    };

    rewrittenRequestMethod.smokeRewriteInstalled = true;
    request[method] = rewrittenRequestMethod;
    wrapped = true;
  });

  requestRewriteInstalled = wrapped;
  debugLog(`request rewrite ${wrapped ? 'installed' : 'not installed yet'}`);
}

installFetchRewrite();
installRequestRewrite();

exports.installSmokeRewrites = async function () {
  installFetchRewrite();
  installRequestRewrite();
};

exports.allowSmokeHosts = async function (payload) {
  if (!payload || !payload.allowed || typeof payload.allowed.add !== 'function') {
    return payload;
  }

  installFetchRewrite();
  installRequestRewrite();

  const hosts = String(process.env.NODEBB_SMOKE_ALLOW_HOSTS || '')
    .split(',')
    .map(host => host.trim())
    .filter(Boolean);

  hosts.forEach((host) => {
    payload.allowed.add(host);
  });

  return payload;
};
EOF

    cat >"$WORK_DIR/nodebb-init-token.js" <<'EOF'
'use strict';

process.chdir('/usr/src/app');
process.env.CONFIG = '/opt/config/config.json';

const nconf = require('/usr/src/app/node_modules/nconf');
nconf.env({ separator: '__' });

const prestart = require('/usr/src/app/src/prestart');
prestart.loadConfig('/opt/config/config.json');

(async () => {
  const db = require('/usr/src/app/src/database');
  await db.init();
  await db.initSessionStore();

  const meta = require('/usr/src/app/src/meta');
  await meta.configs.init();
  await meta.configs.set('activitypubEnabled', 1);

  const pluginId = 'nodebb-plugin-smoke-allowlist';
  await db.sortedSetRemove('plugins:active', pluginId);
  const pluginCount = await db.sortedSetCard('plugins:active');
  await db.sortedSetAdd('plugins:active', pluginCount, pluginId);

  const api = require('/usr/src/app/src/api');
  const token = await api.utils.tokens.generate({ uid: 1, description: 'NodeBB smoke token' });
  console.log(token);
  process.exit(0);
})().catch((err) => {
  console.error(err.stack || err);
  process.exit(1);
});
EOF

    cat >"$WORK_DIR/nodebb-configure-category.js" <<'EOF'
'use strict';

process.chdir('/usr/src/app');
process.env.CONFIG = '/opt/config/config.json';

const nconf = require('/usr/src/app/node_modules/nconf');
nconf.env({ separator: '__' });

const prestart = require('/usr/src/app/src/prestart');
prestart.loadConfig('/opt/config/config.json');

(async () => {
  const cid = parseInt(process.env.NODEBB_CATEGORY_ID || '0', 10);
  if (!cid) {
    throw new Error('NODEBB_CATEGORY_ID is required');
  }

  const db = require('/usr/src/app/src/database');
  await db.init();
  await db.initSessionStore();

  const meta = require('/usr/src/app/src/meta');
  await meta.configs.init();

  const groups = require('/usr/src/app/src/groups');
  if (!await groups.exists('fediverse')) {
    await groups.create({
      name: 'fediverse',
      description: 'Federated ActivityPub actors',
      hidden: 1,
      private: 1,
      system: 1,
    });
  }

  const privileges = require('/usr/src/app/src/privileges');
  await privileges.categories.init();
  await privileges.categories.give([
    'find',
    'read',
    'topics:read',
    'topics:create',
    'topics:reply',
    'topics:tag',
    'posts:edit',
    'posts:delete',
    'posts:upvote',
    'posts:downvote',
    'topics:delete',
    'posts:view_deleted',
  ], cid, 'fediverse');

  process.exit(0);
})().catch((err) => {
  console.error(err.stack || err);
  process.exit(1);
});
EOF

    cat >"$WORK_DIR/nodebb-nginx.conf" <<EOF
events {}
http {
  server {
    listen 80;
    client_max_body_size 20m;

    location / {
      proxy_pass http://$PREFIX-nodebb:4567;
      proxy_http_version 1.1;
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto http;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection "upgrade";
    }
  }
}
EOF
}

start_nodebb() {
    mkdir -p "$WORK_DIR/nodebb-config"
    chmod 777 "$WORK_DIR" "$WORK_DIR/nodebb-config"
    write_nodebb_files

    docker rm -f \
        "$PREFIX-nodebb-proxy" \
        "$PREFIX-nodebb" \
        "$PREFIX-nodebb-setup" \
        "$PREFIX-nodebb-redis" >/dev/null 2>&1 || true

    docker run -d \
        --name "$PREFIX-nodebb-redis" \
        --network "$NETWORK" \
        "$REDIS_IMAGE" >/dev/null

    docker run --rm \
        --name "$PREFIX-nodebb-setup" \
        --network "$NETWORK" \
        -v "$WORK_DIR/nodebb-config:/opt/config" \
        -v "$WORK_DIR/nodebb-setup.json:/tmp/nodebb-setup.json:ro" \
        --entrypoint /bin/sh \
        "$NODEBB_IMAGE" \
        -lc 'SETUP_JSON="$(cat /tmp/nodebb-setup.json)"; ./nodebb setup "$SETUP_JSON" --config=/opt/config/config.json --skip-build' >/dev/null

    NODEBB_TOKEN="$(
        docker run --rm \
            --network "$NETWORK" \
            -v "$WORK_DIR/nodebb-config:/opt/config" \
            -v "$WORK_DIR/nodebb-init-token.js:/tmp/nodebb-init-token.js:ro" \
            -e "CI=$NODEBB_CI" \
            --entrypoint node \
            "$NODEBB_IMAGE" \
            /tmp/nodebb-init-token.js |
            tail -1
    )"

    if [ -z "$NODEBB_TOKEN" ]; then
        fail "Could not create NodeBB API token"
    fi

    docker run -d \
        --name "$PREFIX-nodebb" \
        --network "$NETWORK" \
        -e "NODE_ENV=$NODEBB_ENV" \
        -e "CI=$NODEBB_CI" \
        -e "NODEBB_SMOKE_ALLOW_HOSTS=$A_HOST,$B_HOST,$NODEBB_HOST" \
        -e "NODEBB_SMOKE_A_HOST=$A_HOST" \
        -e "NODEBB_SMOKE_A_PORT=4000" \
        -e "NODEBB_SMOKE_B_HOST=$B_HOST" \
        -e "NODEBB_SMOKE_B_PORT=4000" \
        -e "NODEBB_ADDITIONAL_PLUGINS=/tmp/nodebb-plugin-smoke-allowlist" \
        -v "$WORK_DIR/nodebb-config:/opt/config" \
        -v "$WORK_DIR/nodebb-plugin-smoke-allowlist:/tmp/nodebb-plugin-smoke-allowlist:ro" \
        "$NODEBB_IMAGE" >/dev/null

    docker run -d \
        --name "$PREFIX-nodebb-proxy" \
        --network "$NETWORK" \
        --network-alias "$NODEBB_HOST" \
        -p "127.0.0.1:$NODEBB_PORT:80" \
        -v "$WORK_DIR/nodebb-nginx.conf:/etc/nginx/nginx.conf:ro" \
        "$NGINX_IMAGE" >/dev/null

    wait_nodebb
}

configure_nodebb_category() {
    local cid="$1"

    docker run --rm \
        --network "$NETWORK" \
        -e "NODEBB_CATEGORY_ID=$cid" \
        -e "CI=$NODEBB_CI" \
        -v "$WORK_DIR/nodebb-config:/opt/config" \
        -v "$WORK_DIR/nodebb-configure-category.js:/tmp/nodebb-configure-category.js:ro" \
        --entrypoint node \
        "$NODEBB_IMAGE" \
        /tmp/nodebb-configure-category.js >/dev/null
}

docker rm -f \
    "$PREFIX-nodebb-proxy" \
    "$PREFIX-nodebb" \
    "$PREFIX-nodebb-setup" \
    "$PREFIX-nodebb-redis" >/dev/null 2>&1 || true

log "Bootstrapping Unfathomably smoke pair"
KEEP_SMOKE=1 \
SMOKE_PREFIX="$BE_PREFIX" \
SMOKE_NETWORK="$NETWORK" \
SMOKE_A_HOST="$A_HOST" \
SMOKE_B_HOST="$B_HOST" \
SMOKE_A_PORT="$A_PORT" \
SMOKE_B_PORT="$B_PORT" \
SMOKE_IMAGE="$IMAGE" \
SMOKE_USER_PASSWORD="$PASSWORD" \
bash build_scripts/two-instance-federation-smoke.sh >/tmp/unfathomably-nodebb-bootstrap.log 2>&1 || {
    cat /tmp/unfathomably-nodebb-bootstrap.log >&2 || true
    fail "Unfathomably bootstrap smoke failed"
}

# NodeBB-specific checks use instance A after the two-instance baseline. Stop
# instance B before NodeBB starts so its Node process has predictable memory.
docker stop -t 15 "$BE_PREFIX-b" >/dev/null 2>&1 || true

log "Starting NodeBB"
start_nodebb

log "Creating API credentials"
ALICE_TOKEN="$(be_token alice)"

log "Creating local group and NodeBB category"
BE_GROUP="$(
    http_form POST "$BASE_URL/api/v1/groups" "$ALICE_TOKEN" 200 \
        "display_name=Unfathomably NodeBB Smoke" \
        "name=unfathomably_nodebb_smoke"
)"
BE_GROUP_ID="$(json_get "$BE_GROUP" id)"
BE_GROUP_AP_ID="$(json_get "$BE_GROUP" ap_id)"

NODEBB_CATEGORY="$(
    nodebb_json POST /api/v3/categories 200 \
        '{"name":"NodeBB Smoke","description":"NodeBB smoke category"}'
)"
NODEBB_CATEGORY_ID="$(json_get "$NODEBB_CATEGORY" response.cid)"
NODEBB_CATEGORY_AP_ID="$NODEBB_AP_BASE/category/$NODEBB_CATEGORY_ID"
configure_nodebb_category "$NODEBB_CATEGORY_ID"

log "Following groups in both supported directions"
BE_REMOTE_NODEBB_GROUP="$(
    http_form GET "$BASE_URL/api/v1/groups/lookup?uri=$(urlencode "$NODEBB_CATEGORY_AP_ID")" \
        "$ALICE_TOKEN" \
        200
)"
BE_REMOTE_NODEBB_GROUP_ID="$(json_get "$BE_REMOTE_NODEBB_GROUP" id)"
BE_JOIN_NODEBB="$(
    http_form POST "$BASE_URL/api/v1/groups/$BE_REMOTE_NODEBB_GROUP_ID/join" \
        "$ALICE_TOKEN" \
        200
)"
json_assert "$BE_JOIN_NODEBB" 'data.get("member") is True or data.get("requested") is True' \
    "Unfathomably could not follow the NodeBB category"

log "Skipping NodeBB category follow of Unfathomably Group: official NodeBB category follows only account-style actors"

log "Testing NodeBB category topic delivery into Unfathomably"
NODEBB_TO_BE_TITLE="NodeBB to Unfathomably topic $(basename "$WORK_DIR")"
NODEBB_TO_BE_BODY="NodeBB top-level body $(basename "$WORK_DIR")"
NODEBB_TOPIC="$(
    nodebb_json POST /api/v3/topics 200 \
        "{\"cid\":$NODEBB_CATEGORY_ID,\"title\":\"$NODEBB_TO_BE_TITLE\",\"content\":\"$NODEBB_TO_BE_BODY\"}"
)"
NODEBB_TOPIC_ID="$(json_get "$NODEBB_TOPIC" response.tid)"
NODEBB_TOPIC_PID="$(json_get "$NODEBB_TOPIC" response.mainPost.pid)"
NODEBB_TOPIC_AP_ID="$NODEBB_AP_BASE/post/$NODEBB_TOPIC_PID"
BE_VIEW_OF_NODEBB_TOPIC_ID="$(
    resolve_be_status_id "$NODEBB_TOPIC_AP_ID" "$ALICE_TOKEN" "Unfathomably resolves NodeBB category topic"
)"

BE_LIKE_NODEBB="$(
    http_form POST "$BASE_URL/api/v1/statuses/$BE_VIEW_OF_NODEBB_TOPIC_ID/favourite" "$ALICE_TOKEN" 200
)"
json_assert "$BE_LIKE_NODEBB" 'data.get("favourited") is True' "Unfathomably could not like NodeBB topic"
poll_nodebb_json_assert GET \
    "/api/v3/posts/$NODEBB_TOPIC_PID" \
    200 \
    'int(data.get("response", {}).get("upvotes") or 0) >= 1' \
    "NodeBB sees Unfathomably like on NodeBB topic" >/dev/null

BE_UNLIKE_NODEBB="$(
    http_form POST "$BASE_URL/api/v1/statuses/$BE_VIEW_OF_NODEBB_TOPIC_ID/unfavourite" "$ALICE_TOKEN" 200
)"
json_assert "$BE_UNLIKE_NODEBB" 'data.get("favourited") is False' "Unfathomably could not unlike NodeBB topic"
poll_nodebb_json_assert GET \
    "/api/v3/posts/$NODEBB_TOPIC_PID" \
    200 \
    'int(data.get("response", {}).get("upvotes") or 0) == 0' \
    "NodeBB sees Unfathomably unlike on NodeBB topic" >/dev/null

BE_REPLY_TEXT="Unfathomably reply to NodeBB $(basename "$WORK_DIR")"
BE_REPLY="$(
    http_form POST "$BASE_URL/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$BE_REPLY_TEXT" \
        "in_reply_to_id=$BE_VIEW_OF_NODEBB_TOPIC_ID"
)"
BE_REPLY_ID="$(json_get "$BE_REPLY" id)"
BE_REPLY_AP_ID="$(json_get "$BE_REPLY" uri)"
NODEBB_VIEW_OF_BE_REPLY_PID="$(urlencode "$BE_REPLY_AP_ID")"

poll_nodebb_json_assert_when_visible GET \
    "/api/v3/posts/$NODEBB_VIEW_OF_BE_REPLY_PID" \
    200 \
    "'$BE_REPLY_TEXT' in str(data)" \
    "NodeBB sees Unfathomably reply under NodeBB topic" >/dev/null

http_form DELETE "$BASE_URL/api/v1/statuses/$BE_REPLY_ID" "$ALICE_TOKEN" 200 >/dev/null
poll_nodebb_post_absent_or_deleted \
    "/api/v3/posts/$NODEBB_VIEW_OF_BE_REPLY_PID" \
    "NodeBB sees Unfathomably deleted reply"

log "Testing Unfathomably group post delivery into NodeBB"
BE_TO_NODEBB_TEXT="Unfathomably to NodeBB post $(basename "$WORK_DIR")"
BE_TO_NODEBB_POST="$(
    http_form POST "$BASE_URL/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$BE_TO_NODEBB_TEXT" \
        "group_id=$BE_GROUP_ID"
)"
BE_TO_NODEBB_POST_ID="$(json_get "$BE_TO_NODEBB_POST" id)"
BE_TO_NODEBB_POST_AP_ID="$(json_get "$BE_TO_NODEBB_POST" uri)"
NODEBB_IMPORTED_BE_GROUP_POST=0

if NODEBB_VIEW_OF_BE_POST_PID="$(try_resolve_nodebb_post_id "$BE_TO_NODEBB_POST_AP_ID")"; then
    NODEBB_IMPORTED_BE_GROUP_POST=1
    NODEBB_VIEW_OF_BE_POST="$(
        poll_nodebb_json_assert GET \
            "/api/v3/posts/$NODEBB_VIEW_OF_BE_POST_PID" \
            200 \
            "'$BE_TO_NODEBB_TEXT' in str(data)" \
            "NodeBB sees Unfathomably group post"
    )"
    NODEBB_VIEW_OF_BE_POST_TID="$(json_get "$NODEBB_VIEW_OF_BE_POST" response.tid)"

    NODEBB_REPLY_TEXT="NodeBB reply to Unfathomably $(basename "$WORK_DIR")"
    NODEBB_REPLY="$(
        nodebb_json POST "/api/v3/topics/$NODEBB_VIEW_OF_BE_POST_TID" 200 \
            "{\"content\":\"$NODEBB_REPLY_TEXT\"}"
    )"
    NODEBB_REPLY_PID="$(json_get "$NODEBB_REPLY" response.pid)"
    NODEBB_REPLY_AP_ID="$NODEBB_AP_BASE/post/$NODEBB_REPLY_PID"
    BE_VIEW_OF_NODEBB_REPLY_ID="$(
        resolve_be_context_status_id \
            "$BE_TO_NODEBB_POST_ID" \
            "$NODEBB_REPLY_AP_ID" \
            "$ALICE_TOKEN" \
            "Unfathomably receives NodeBB reply under Unfathomably post"
    )"

    nodebb_json DELETE "/api/v3/posts/$NODEBB_REPLY_PID" 200 >/dev/null
    poll_http_status GET \
        "$BASE_URL/api/v1/statuses/$BE_VIEW_OF_NODEBB_REPLY_ID" \
        "$ALICE_TOKEN" \
        404 \
        "Unfathomably sees NodeBB deleted reply"

    NODEBB_LIKE_BE="$(
        nodebb_json PUT "/api/v3/posts/$NODEBB_VIEW_OF_BE_POST_PID/vote" 200 '{"delta":1}'
    )"
    json_assert "$NODEBB_LIKE_BE" 'data.get("status", {}).get("code") == "ok"' \
        "NodeBB could not like Unfathomably post"
    poll_json_assert GET \
        "$BASE_URL/api/v1/statuses/$BE_TO_NODEBB_POST_ID" \
        "$ALICE_TOKEN" \
        200 \
        'int(data.get("favourites_count") or 0) >= 1' \
        "Unfathomably sees NodeBB like on Unfathomably post" >/dev/null

    nodebb_json DELETE "/api/v3/posts/$NODEBB_VIEW_OF_BE_POST_PID/vote" 200 >/dev/null
    poll_be_object_unliked \
        "$BE_TO_NODEBB_POST_AP_ID" \
        "$NODEBB_AP_BASE/uid/1" \
        "Unfathomably sees NodeBB unlike on Unfathomably post"
else
    log "Skipping NodeBB reply/like tests for Unfathomably Group post: official NodeBB redirects remote Group objects to their origin instead of importing them as local posts"
fi

log "Deleting posts and unfollowing groups"
nodebb_json DELETE "/api/v3/topics/$NODEBB_TOPIC_ID" 200 >/dev/null
poll_nodebb_post_absent_or_deleted \
    "/api/v3/posts/$NODEBB_TOPIC_PID" \
    "NodeBB locally deletes its topic main post"
log "Skipping Unfathomably remote-delete check for NodeBB topic: official NodeBB API delete did not federate a Delete in the stock smoke path"

http_form DELETE "$BASE_URL/api/v1/statuses/$BE_TO_NODEBB_POST_ID" "$ALICE_TOKEN" 200 >/dev/null
if [ "$NODEBB_IMPORTED_BE_GROUP_POST" = "1" ]; then
    poll_nodebb_post_absent_or_deleted \
        "/api/v3/posts/$NODEBB_VIEW_OF_BE_POST_PID" \
        "NodeBB sees deleted Unfathomably post"
else
    log "Skipping NodeBB deleted-post visibility check for unsupported remote Group post import path"
fi

BE_LEAVE_NODEBB="$(
    http_form POST "$BASE_URL/api/v1/groups/$BE_REMOTE_NODEBB_GROUP_ID/leave" "$ALICE_TOKEN" 200
)"
json_assert "$BE_LEAVE_NODEBB" 'data.get("member") is False and data.get("requested") is False' \
    "Unfathomably could not unfollow NodeBB category"

log "Checking logs for obvious crashes"
for container in "$PREFIX-nodebb" "$PREFIX-nodebb-proxy" "$BE_PREFIX-a"; do
    if docker logs "$container" 2>&1 |
        grep -E "status=500|Internal Server Error|UnhandledPromiseRejection|uncaughtException|GenServer terminating|FunctionClauseError|UndefinedFunctionError|Protocol\\.UndefinedError" >/dev/null; then
        docker logs --tail 260 "$container" >&2
        fail "$container logged errors during NodeBB smoke run"
    fi
done

cat <<EOF

Unfathomably/NodeBB federation smoke test passed.

Covered:
  * supported: clean NodeBB Docker boot with Redis and internal proxy
  * supported: Unfathomably follow of a NodeBB category actor
  * not_supported: stock NodeBB categories do not follow remote ActivityPub Group actors
  * supported: NodeBB-to-Unfathomably category topic, like, unlike, reply, and reply Delete
  * not_supported: stock NodeBB redirects remote Group posts to their origin instead of importing them locally
  * not_supported: stock NodeBB API-driven deletes do not federate a remote Delete in this harness
  * supported: local NodeBB delete and Unfathomably-to-NodeBB Delete propagation checks
  * supported: Unfathomably unfollow of a NodeBB category actor
  * supported: basic log scan for 500/crash output

Run with KEEP_SMOKE=1 to leave both servers available for manual browser/API work.
EOF

# end of unfathomably-nodebb-smoke.sh
