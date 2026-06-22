#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-mbin-smoke.sh
#
# Purpose:
#
#   Start a clean Unfathomably smoke instance and a clean MBin
#   instance on the same Docker network, then prove that group-style
#   federation works between them.
#
# Responsibilities:
#
#   * build or reuse a small MBin smoke image based on the upstream
#     production image
#   * boot MBin with PostgreSQL, Valkey-compatible Redis, RabbitMQ,
#     FrankenPHP/Caddy, and a messenger worker
#   * reuse the existing two-instance Unfathomably smoke bootstrap so
#     the backend is known-good before MBin-specific checks begin
#   * exercise follow, unfollow, post, comment, like, unlike, and delete
#     paths across the Unfathomably/MBin boundary
#   * fail loudly if either server logs obvious 500/crash output
#
# This file intentionally does NOT contain:
#
#   * production deployment logic
#   * TLS certificate provisioning
#   * frontend/browser automation
#

set -euo pipefail

IMAGE="${SMOKE_IMAGE:-unfathomably-elixir-smoke:otp28}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16-alpine}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"
RABBITMQ_IMAGE="${RABBITMQ_IMAGE:-rabbitmq:3-management-alpine}"
MBIN_BASE_IMAGE="${MBIN_BASE_IMAGE:-ghcr.io/mbinorg/mbin:latest}"
MBIN_IMAGE="${MBIN_IMAGE:-unfathomably-mbin-smoke:http-ap-v13}"
MBIN_REBUILD="${MBIN_REBUILD:-0}"

PREFIX="${SMOKE_PREFIX:-unfathomably-mbin-smoke}"
NETWORK="${SMOKE_NETWORK:-$PREFIX-net}"
BE_PREFIX="$PREFIX-be"

A_HOST="${SMOKE_A_HOST:-smoke-a.test}"
B_HOST="${SMOKE_B_HOST:-smoke-b.test}"
A_PORT="${SMOKE_A_PORT:-4631}"
B_PORT="${SMOKE_B_PORT:-4632}"
MBIN_HOST="${MBIN_HOST:-mbin-smoke.test}"
MBIN_PORT="${MBIN_PORT:-4635}"

PASSWORD="${SMOKE_USER_PASSWORD:-SmokeTest_01}"
DB_PASSWORD="${SMOKE_DB_PASSWORD:-postgres}"
VALKEY_PASSWORD="${SMOKE_VALKEY_PASSWORD:-smoke-valkey-pass}"
RABBITMQ_USER="${SMOKE_RABBITMQ_USER:-mbin}"
RABBITMQ_PASS="${SMOKE_RABBITMQ_PASS:-smoke-rabbit-pass}"
RABBITMQ_COOKIE="${SMOKE_RABBITMQ_COOKIE:-mbin-smoke-rabbit-cookie}"
OAUTH_PASSPHRASE="${SMOKE_OAUTH_PASSPHRASE:-mbin-smoke-oauth-pass}"
OAUTH_ENCRYPTION_KEY="${SMOKE_OAUTH_ENCRYPTION_KEY:-0123456789abcdef0123456789abcdef}"
KEEP_SMOKE="${KEEP_SMOKE:-0}"

WORK_DIR="${SMOKE_WORK_DIR:-}"
if [ -z "$WORK_DIR" ]; then
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/unfathomably-mbin-smoke.XXXXXX")"
fi

BASE_URL="http://127.0.0.1:$A_PORT"
MBIN_URL="http://$MBIN_HOST"
MBIN_CURL_CONNECT_TO=(--connect-to "$MBIN_HOST:80:127.0.0.1:$MBIN_PORT")
MBIN_USER="mbinadmin"
MBIN_EMAIL="admin@$MBIN_HOST"
MBIN_MAGAZINE_NAME="mbin_smoke"
MBIN_ACTOR_AP_ID="http://$MBIN_HOST/u/$MBIN_USER"
ALICE_AP_ID="http://$A_HOST:4000/users/alice"

log() {
    printf '\n==> %s\n' "$*"
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2

    for container in \
        "$PREFIX-mbin-php" \
        "$PREFIX-mbin-messenger" \
        "$PREFIX-mbin-rabbitmq" \
        "$PREFIX-mbin-redis" \
        "$PREFIX-mbin-db" \
        "$BE_PREFIX-a" \
        "$BE_PREFIX-b" \
        "$BE_PREFIX-db"; do
        if docker inspect "$container" >/dev/null 2>&1; then
            printf '\n--- docker logs --tail 220 %s ---\n' "$container" >&2
            docker logs --tail 220 "$container" >&2 || true
        fi
    done

    exit 1
}

cleanup() {
    if [ "$KEEP_SMOKE" = "1" ]; then
        cat <<EOF

Smoke containers preserved because KEEP_SMOKE=1.
Unfathomably: $BASE_URL
MBin:          $MBIN_URL
Work dir:      $WORK_DIR
EOF
        return
    fi

    docker rm -f \
        "$PREFIX-mbin-php" \
        "$PREFIX-mbin-messenger" \
        "$PREFIX-mbin-rabbitmq" \
        "$PREFIX-mbin-redis" \
        "$PREFIX-mbin-db" \
        "$BE_PREFIX-a" \
        "$BE_PREFIX-b" \
        "$BE_PREFIX-db" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR" 2>/dev/null || {
        docker run --rm \
            -v "$WORK_DIR:/work" \
            --entrypoint sh \
            "$POSTGRES_IMAGE" \
            -c 'rm -rf /work/* /work/.[!.]* /work/..?*' >/dev/null 2>&1 || true
        rmdir "$WORK_DIR" >/dev/null 2>&1 || true
    }
}

trap cleanup EXIT

urlencode() {
    python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

urlpath() {
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

json_body() {
    local text="$1"

    TEXT="$text" python3 - <<'PY'
import json
import os

print(json.dumps({
    "body": os.environ["TEXT"],
    "lang": "en",
    "isAdult": False,
}))
PY
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
    if [ "${url#"$MBIN_URL"}" != "$url" ]; then
        args+=("${MBIN_CURL_CONNECT_TO[@]}")
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

http_json() {
    local method="$1"
    local url="$2"
    local expected="$3"
    local body="$4"
    local token="${5:-}"

    local tmp code
    tmp="$(mktemp)"

    JSON_PAYLOAD="$body" python3 - <<'PY' || {
import json
import os

json.loads(os.environ["JSON_PAYLOAD"])
PY
        printf 'Invalid JSON body for %s %s:\n%s\n' "$method" "$url" "$body" >&2
        rm -f "$tmp"
        fail "Refusing to send invalid JSON"
    }

    local args=(-sS -X "$method" -H "Content-Type: application/json" -o "$tmp" -w "%{http_code}")
    if [ -n "$token" ]; then
        args+=(-H "Authorization: Bearer $token")
    fi
    if [ "${url#"$MBIN_URL"}" != "$url" ]; then
        args+=("${MBIN_CURL_CONNECT_TO[@]}")
    fi
    args+=(--data-binary "$body" "$url")

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

http_status() {
    local method="$1"
    local url="$2"
    local token="${3:-}"

    local tmp code
    tmp="$(mktemp)"

    local args=(-sS -X "$method" -o "$tmp" -w "%{http_code}")
    if [ -n "$token" ]; then
        args+=(-H "Authorization: Bearer $token")
    fi
    if [ "${url#"$MBIN_URL"}" != "$url" ]; then
        args+=("${MBIN_CURL_CONNECT_TO[@]}")
    fi
    args+=("$url")

    code="$(curl "${args[@]}")" || code="000"
    rm -f "$tmp"
    printf '%s\n' "$code"
}

poll_http_status() {
    local method="$1"
    local url="$2"
    local token="$3"
    local expected="$4"
    local message="$5"
    local attempts="${6:-90}"
    local delay="${7:-2}"
    local tmp code

    tmp="$(mktemp)"

    for _ in $(seq 1 "$attempts"); do
        local args=(-sS -X "$method" -o "$tmp" -w "%{http_code}")
        if [ -n "$token" ]; then
            args+=(-H "Authorization: Bearer $token")
        fi
        if [ "${url#"$MBIN_URL"}" != "$url" ]; then
            args+=("${MBIN_CURL_CONNECT_TO[@]}")
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

poll_json_assert() {
    local method="$1"
    local url="$2"
    local token="$3"
    local expected="$4"
    local expr="$5"
    local message="$6"
    local attempts="${7:-90}"
    local delay="${8:-2}"
    local body="${9:-}"
    local result

    for _ in $(seq 1 "$attempts"); do
        if [ "$method" = "GET" ]; then
            result="$(http_form GET "$url" "$token" "$expected" || true)"
        elif [ -n "$body" ]; then
            result="$(http_json "$method" "$url" "$expected" "$body" "$token" || true)"
        else
            result="$(http_json "$method" "$url" "$expected" '{}' "$token" || true)"
        fi

        if [ -n "$result" ] && json_matches "$result" "$expr" >/dev/null 2>&1; then
            printf '%s\n' "$result"
            return 0
        fi

        sleep "$delay"
    done

    printf '%s\n' "$result" >&2
    fail "Polling timed out: $message"
}

wait_http() {
    local url="$1"
    local name="$2"

    for _ in $(seq 1 180); do
        local args=(--max-time 5 -fsS)
        if [ "${url#"$MBIN_URL"}" != "$url" ]; then
            args+=("${MBIN_CURL_CONNECT_TO[@]}")
        fi
        args+=("$url")

        if curl "${args[@]}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    fail "Timed out waiting for $name at $url"
}

be_token() {
    local username="$1"
    local app token client_id client_secret

    app="$(
        http_form POST "$BASE_URL/api/v1/apps" "" 200 \
            "client_name=mbin-smoke" \
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

header_location() {
    local headers="$1"

    awk 'BEGIN { IGNORECASE = 1 } /^location:/ { sub(/\r$/, ""); print substr($0, index($0, ":") + 2) }' "$headers" | tail -n 1
}

absolute_mbin_url() {
    local location="$1"

    python3 - "$MBIN_URL" "$location" <<'PY'
import sys
from urllib.parse import urljoin

print(urljoin(sys.argv[1], sys.argv[2]))
PY
}

query_param() {
    local url="$1"
    local key="$2"

    python3 - "$url" "$key" <<'PY'
import sys
from urllib.parse import parse_qs, urlparse

values = parse_qs(urlparse(sys.argv[1]).query).get(sys.argv[2], [])
if values:
    print(values[0])
PY
}

html_hidden_value() {
    local html="$1"
    local name="$2"

    HTML_PAYLOAD="$html" python3 - "$name" <<'PY'
import html as html_module
import os
import re
import sys

text = os.environ["HTML_PAYLOAD"]
name = re.escape(sys.argv[1])
patterns = [
    rf'<input[^>]+name=["\']{name}["\'][^>]+value=["\']([^"\']+)["\']',
    rf'<input[^>]+value=["\']([^"\']+)["\'][^>]+name=["\']{name}["\']',
]

for pattern in patterns:
    match = re.search(pattern, text, flags=re.IGNORECASE)
    if match:
        print(html_module.unescape(match.group(1)))
        raise SystemExit(0)

raise SystemExit(1)
PY
}

mbin_oauth_client_body() {
    local scopes="$1"

    OAUTH_SCOPES="$scopes" python3 - <<'PY'
import json
import os

print(json.dumps({
    "name": "unfathomably-mbin-smoke",
    "contactEmail": "admin@mbin-smoke.test",
    "description": "federation smoke client",
    "public": False,
    "redirectUris": ["https://localhost:3001"],
    "grants": ["authorization_code", "refresh_token"],
    "scopes": os.environ["OAUTH_SCOPES"].split(),
}))
PY
}

mbin_auth_query() {
    local client_id="$1"
    local scopes="$2"

    python3 - "$client_id" "$scopes" <<'PY'
import sys
from urllib.parse import urlencode

print(urlencode({
    "response_type": "code",
    "client_id": sys.argv[1],
    "redirect_uri": "https://localhost:3001",
    "scope": sys.argv[2],
    "state": "oauth2state",
}))
PY
}

mbin_token() {
    local scopes client_json client_id client_secret jar headers login_page csrf code
    local auth_query auth_url location consent_url consent_page consent_csrf auth_code token_json

    scopes="read magazine:subscribe post:create post:delete post:vote post_comment:create post_comment:delete post_comment:vote entry:create entry:delete entry:vote entry_comment:create entry_comment:delete entry_comment:vote"
    client_json="$(
        http_json POST "$MBIN_URL/api/client" 201 "$(mbin_oauth_client_body "$scopes")"
    )"
    client_id="$(json_get "$client_json" identifier)"
    client_secret="$(json_get "$client_json" secret)"
    [ -n "$client_id" ] || fail "MBin OAuth client creation did not return an identifier"
    [ -n "$client_secret" ] || fail "MBin OAuth client creation did not return a secret"

    jar="$(mktemp)"
    headers="$(mktemp)"

    login_page="$(curl -fsS "${MBIN_CURL_CONNECT_TO[@]}" -c "$jar" -b "$jar" "$MBIN_URL/login")"
    csrf="$(html_hidden_value "$login_page" "_csrf_token")" || fail "Could not read MBin login CSRF token"

    code="$(
        curl -sS -D "$headers" -o /dev/null -w "%{http_code}" \
            "${MBIN_CURL_CONNECT_TO[@]}" \
            -c "$jar" -b "$jar" \
            -X POST "$MBIN_URL/login" \
            --data-urlencode "email=$MBIN_USER" \
            --data-urlencode "password=$PASSWORD" \
            --data-urlencode "_csrf_token=$csrf" \
            --data-urlencode "_remember_me=on"
    )" || {
        rm -f "$jar" "$headers"
        fail "MBin login request failed"
    }
    case "$code" in
        200|302|303) ;;
        *)
            rm -f "$jar" "$headers"
            fail "MBin login returned HTTP $code"
            ;;
    esac

    auth_query="$(mbin_auth_query "$client_id" "$scopes")"
    auth_url="$MBIN_URL/authorize?$auth_query"
    code="$(
        curl -sS -D "$headers" -o /dev/null -w "%{http_code}" \
            "${MBIN_CURL_CONNECT_TO[@]}" \
            -c "$jar" -b "$jar" "$auth_url"
    )" || {
        rm -f "$jar" "$headers"
        fail "MBin authorization request failed"
    }
    location="$(header_location "$headers")"
    [ -n "$location" ] || {
        rm -f "$jar" "$headers"
        fail "MBin authorization did not redirect to consent"
    }

    consent_url="$(absolute_mbin_url "$location")"
    consent_page="$(curl -fsS "${MBIN_CURL_CONNECT_TO[@]}" -c "$jar" -b "$jar" "$consent_url")"
    consent_csrf="$(html_hidden_value "$consent_page" "_csrf_token")" || {
        rm -f "$jar" "$headers"
        fail "Could not read MBin consent CSRF token"
    }

    code="$(
        curl -sS -D "$headers" -o /dev/null -w "%{http_code}" \
            "${MBIN_CURL_CONNECT_TO[@]}" \
            -c "$jar" -b "$jar" \
            -X POST "$consent_url" \
            --data-urlencode "_csrf_token=$consent_csrf" \
            --data-urlencode "consent=yes"
    )" || {
        rm -f "$jar" "$headers"
        fail "MBin consent request failed"
    }
    case "$code" in
        302|303) ;;
        *)
            rm -f "$jar" "$headers"
            fail "MBin consent returned HTTP $code"
            ;;
    esac

    location="$(header_location "$headers")"
    [ -n "$location" ] || {
        rm -f "$jar" "$headers"
        fail "MBin consent did not redirect back to authorization"
    }

    auth_url="$(absolute_mbin_url "$location")"
    code="$(
        curl -sS -D "$headers" -o /dev/null -w "%{http_code}" \
            "${MBIN_CURL_CONNECT_TO[@]}" \
            -c "$jar" -b "$jar" "$auth_url"
    )" || {
        rm -f "$jar" "$headers"
        fail "MBin authorization-code redirect request failed"
    }
    location="$(header_location "$headers")"
    auth_code="$(query_param "$location" code)"
    [ -n "$auth_code" ] || {
        rm -f "$jar" "$headers"
        fail "MBin authorization flow did not return a code"
    }

    token_json="$(
        http_form POST "$MBIN_URL/token" "" 200 \
            "grant_type=authorization_code" \
            "client_id=$client_id" \
            "client_secret=$client_secret" \
            "code=$auth_code" \
            "redirect_uri=https://localhost:3001"
    )"

    rm -f "$jar" "$headers"
    json_get "$token_json" access_token
}

mbin_get_auth() {
    local path="$1"

    http_form GET "$MBIN_URL$path" "$MBIN_TOKEN" 200
}

mbin_json() {
    local method="$1"
    local path="$2"
    local expected="$3"
    local body

    if [ "$#" -ge 4 ]; then
        body="$4"
    else
        body="{}"
    fi

    http_json "$method" "$MBIN_URL$path" "$expected" "$body" "$MBIN_TOKEN"
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
            100 \
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

    for _ in $(seq 1 100); do
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

sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

mbin_sql() {
    docker exec "$PREFIX-mbin-db" psql -U mbin -d mbin -Atc "$1"
}

mbin_content_by_ap_id() {
    local ap_id="$1"
    local ap_sql

    ap_sql="$(sql_escape "$ap_id")"
    mbin_sql "
        select 'post:' || id from post where ap_id = '$ap_sql'
        union all
        select 'entry:' || id from entry where ap_id = '$ap_sql'
        limit 1;
    "
}

poll_mbin_content_by_ap_id() {
    local ap_id="$1"
    local message="$2"
    local result

    for _ in $(seq 1 100); do
        result="$(mbin_content_by_ap_id "$ap_id" || true)"
        if [ -n "$result" ]; then
            printf '%s\n' "$result"
            return 0
        fi

        sleep 2
    done

    fail "$message"
}

mbin_comment_by_ap_id() {
    local ap_id="$1"
    local ap_sql

    ap_sql="$(sql_escape "$ap_id")"
    mbin_sql "
        select 'post_comment:' || id from post_comment where ap_id = '$ap_sql'
        union all
        select 'entry_comment:' || id from entry_comment where ap_id = '$ap_sql'
        limit 1;
    "
}

poll_mbin_comment_by_ap_id() {
    local ap_id="$1"
    local message="$2"
    local result

    for _ in $(seq 1 100); do
        result="$(mbin_comment_by_ap_id "$ap_id" || true)"
        if [ -n "$result" ]; then
            printf '%s\n' "$result"
            return 0
        fi

        sleep 2
    done

    fail "$message"
}

mbin_magazine_by_ap_profile() {
    local ap_profile="$1"
    local ap_sql

    ap_sql="$(sql_escape "$ap_profile")"
    mbin_sql "select id || ':' || name from magazine where ap_profile_id = '$ap_sql' or ap_id = '$ap_sql' limit 1;"
}

poll_mbin_magazine_by_ap_profile() {
    local ap_profile="$1"
    local message="$2"
    local result

    for _ in $(seq 1 80); do
        result="$(mbin_magazine_by_ap_profile "$ap_profile" || true)"
        if [ -n "$result" ]; then
            printf '%s\n' "$result"
            return 0
        fi

        sleep 2
    done

    fail "$message"
}

mbin_magazine_subscription_exists() {
    local magazine_id="$1"
    local user_ap_id="$2"
    local user_sql

    user_sql="$(sql_escape "$user_ap_id")"
    mbin_sql "
        select 1
        from magazine_subscription ms
        join \"user\" u on u.id = ms.user_id
        where ms.magazine_id = $magazine_id
          and (u.ap_profile_id = '$user_sql' or u.ap_id = '$user_sql')
        limit 1;
    "
}

poll_mbin_magazine_subscription() {
    local magazine_id="$1"
    local user_ap_id="$2"
    local message="$3"
    local result

    for _ in $(seq 1 90); do
        result="$(mbin_magazine_subscription_exists "$magazine_id" "$user_ap_id" || true)"
        if [ -n "$result" ]; then
            return 0
        fi

        sleep 2
    done

    fail "$message"
}

mbin_content_magazine_name() {
    local type="$1"
    local id="$2"

    if [ "$type" = "post" ]; then
        mbin_sql "select m.name from post p join magazine m on m.id = p.magazine_id where p.id = $id;"
    else
        mbin_sql "select m.name from entry e join magazine m on m.id = e.magazine_id where e.id = $id;"
    fi
}

mbin_local_magazine_ap_id() {
    local json="$1"
    local ap_id

    ap_id="$(json_get "$json" apProfileId || true)"
    if [ -z "$ap_id" ]; then
        ap_id="$(json_get "$json" apId || true)"
    fi
    if [ -z "$ap_id" ]; then
        ap_id="http://$MBIN_HOST/m/$(urlpath "$MBIN_MAGAZINE_NAME")"
    fi

    printf '%s\n' "$ap_id"
}

mbin_local_post_ap_id() {
    local post_id="$1"

    printf 'http://%s/m/%s/p/%s/-\n' "$MBIN_HOST" "$(urlpath "$MBIN_MAGAZINE_NAME")" "$post_id"
}

mbin_comment_ap_id() {
    local content_type="$1"
    local content_id="$2"
    local comment_id="$3"
    local magazine_name

    magazine_name="$(mbin_content_magazine_name "$content_type" "$content_id")"
    [ -n "$magazine_name" ] || fail "Could not derive MBin magazine route name for $content_type $content_id"

    if [ "$content_type" = "post" ]; then
        printf 'http://%s/m/%s/p/%s/-/reply/%s\n' "$MBIN_HOST" "$(urlpath "$magazine_name")" "$content_id" "$comment_id"
    else
        printf 'http://%s/m/%s/t/%s/-/comment/%s\n' "$MBIN_HOST" "$(urlpath "$magazine_name")" "$content_id" "$comment_id"
    fi
}

mbin_content_get() {
    local content_ref="$1"
    local type="${content_ref%%:*}"
    local id="${content_ref#*:}"

    if [ "$type" = "post" ]; then
        mbin_get_auth "/api/post/$id"
    else
        mbin_get_auth "/api/entry/$id"
    fi
}

mbin_content_vote() {
    local content_ref="$1"
    local choice="$2"
    local type="${content_ref%%:*}"
    local id="${content_ref#*:}"

    if [ "$type" = "post" ]; then
        mbin_json PUT "/api/post/$id/vote/$choice" 200 '{}'
    else
        mbin_json PUT "/api/entry/$id/vote/$choice" 200 '{}'
    fi
}

mbin_content_favourite() {
    local content_ref="$1"
    local type="${content_ref%%:*}"
    local id="${content_ref#*:}"

    if [ "$type" = "post" ]; then
        mbin_json PUT "/api/post/$id/favourite" 200 '{}'
    else
        mbin_json PUT "/api/entry/$id/favourite" 200 '{}'
    fi
}

mbin_content_comment() {
    local content_ref="$1"
    local body="$2"
    local type="${content_ref%%:*}"
    local id="${content_ref#*:}"

    if [ "$type" = "post" ]; then
        mbin_json POST "/api/posts/$id/comments" 201 "$(json_body "$body")"
    else
        mbin_json POST "/api/entry/$id/comments" 201 "$(json_body "$body")"
    fi
}

mbin_delete_comment() {
    local comment_ref="$1"
    local type="${comment_ref%%:*}"
    local id="${comment_ref#*:}"

    if [ "$type" = "post_comment" ]; then
        mbin_json DELETE "/api/post-comments/$id" 204 '{}'
    else
        mbin_json DELETE "/api/comments/$id" 204 '{}'
    fi
}

mbin_delete_content() {
    local content_ref="$1"
    local type="${content_ref%%:*}"
    local id="${content_ref#*:}"

    if [ "$type" = "post" ]; then
        mbin_json DELETE "/api/post/$id" 204 '{}'
    else
        mbin_json DELETE "/api/entry/$id" 204 '{}'
    fi
}

poll_mbin_favourites() {
    local post_id="$1"
    local base="$2"
    local op="$3"
    local message="$4"
    local result

    for _ in $(seq 1 90); do
        result="$(mbin_sql "select favourite_count from post where id = $post_id;" || true)"
        if [ -n "$result" ]; then
            if CURRENT_COUNT="$result" BASE_COUNT="$base" OP="$op" python3 - <<'PY'
import os

current = int(os.environ["CURRENT_COUNT"])
base = int(os.environ["BASE_COUNT"])
op = os.environ["OP"]

if op == "gt" and current > base:
    raise SystemExit(0)
if op == "eq" and current == base:
    raise SystemExit(0)

raise SystemExit(1)
PY
            then
                printf '%s\n' "$result"
                return 0
            fi
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

poll_mbin_visibility_deleted() {
    local table="$1"
    local id="$2"
    local message="$3"
    local result

    for _ in $(seq 1 90); do
        result="$(mbin_sql "select visibility from $table where id = $id;" || true)"
        if [ -z "$result" ] || [ "$result" != "visible" ]; then
            return 0
        fi

        sleep 2
    done

    fail "$message: MBin visibility is still ${result:-missing}"
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

ensure_mbin_image() {
    if docker image inspect "$MBIN_IMAGE" >/dev/null 2>&1; then
        if [ "$MBIN_REBUILD" != "1" ]; then
            return
        fi

        docker image rm -f "$MBIN_IMAGE" >/dev/null
    fi

    log "Building MBin image $MBIN_IMAGE"

    cat >"$WORK_DIR/mbin-smoke-api-patch.php" <<'PHP'
<?php

function patch_file(string $path, array $replacements): void
{
    $source = file_get_contents($path);

    foreach ($replacements as [$search, $replace]) {
        if (!str_contains($source, $search)) {
            fwrite(STDERR, "Missing patch target in $path\n");
            exit(1);
        }

        $source = str_replace($search, $replace, $source);
    }

    file_put_contents($path, $source);
}

patch_file('/app/src/Controller/Api/Post/PostsBaseApi.php', [
    [
        <<<'SEARCH'
        $deserialized = $this->serializer->deserialize($this->request->getCurrentRequest()->getContent(), PostRequestDto::class, 'json', [
            'groups' => [
                'common',
                'post',
                'no-upload',
            ],
        ]);
        \assert($deserialized instanceof PostRequestDto);
SEARCH,
        <<<'REPLACE'
        $data = json_decode($this->request->getCurrentRequest()->getContent(), true, 512, JSON_THROW_ON_ERROR);
        $deserialized = new PostRequestDto();
        $deserialized->body = $data['body'] ?? null;
        $deserialized->lang = $data['lang'] ?? null;
        $deserialized->isAdult = (bool) ($data['isAdult'] ?? false);
REPLACE
    ],
    [
        <<<'SEARCH'
        $deserialized = $this->serializer->deserialize($request->getContent(), PostCommentRequestDto::class, 'json', [
            'groups' => [
                'common',
                'comment',
                'no-upload',
            ],
        ]);

        \assert($deserialized instanceof PostCommentRequestDto);
SEARCH,
        <<<'REPLACE'
        $data = json_decode($request->getContent(), true, 512, JSON_THROW_ON_ERROR);
        $deserialized = new PostCommentRequestDto();
        $deserialized->body = $data['body'] ?? null;
        $deserialized->lang = $data['lang'] ?? null;
        $deserialized->isAdult = (bool) ($data['isAdult'] ?? false);
REPLACE
    ],
]);

patch_file('/app/src/Controller/Api/Entry/EntriesBaseApi.php', [
    [
        <<<'SEARCH'
        $deserialized = $this->serializer->deserialize($this->request->getCurrentRequest()->getContent(), EntryRequestDto::class, 'json', $context);
        \assert($deserialized instanceof EntryRequestDto);
SEARCH,
        <<<'REPLACE'
        $data = json_decode($this->request->getCurrentRequest()->getContent(), true, 512, JSON_THROW_ON_ERROR);
        $deserialized = new EntryRequestDto();
        $deserialized->title = $data['title'] ?? null;
        $deserialized->url = $data['url'] ?? null;
        $deserialized->body = $data['body'] ?? null;
        $deserialized->tags = $data['tags'] ?? null;
        $deserialized->isOc = (bool) ($data['isOc'] ?? false);
        $deserialized->lang = $data['lang'] ?? null;
        $deserialized->isAdult = (bool) ($data['isAdult'] ?? false);
REPLACE
    ],
    [
        <<<'SEARCH'
        /**
         * @var EntryCommentRequestDto $deserialized
         */
        $deserialized = $this->serializer->deserialize($this->request->getCurrentRequest()->getContent(), EntryCommentRequestDto::class, 'json', [
            'groups' => [
                'common',
                'comment',
                'no-upload',
            ],
        ]);
SEARCH,
        <<<'REPLACE'
        $data = json_decode($this->request->getCurrentRequest()->getContent(), true, 512, JSON_THROW_ON_ERROR);
        $deserialized = new EntryCommentRequestDto();
        $deserialized->body = $data['body'] ?? null;
        $deserialized->lang = $data['lang'] ?? null;
        $deserialized->isAdult = (bool) ($data['isAdult'] ?? false);
REPLACE
    ],
]);

patch_file('/app/src/Repository/ActivityRepository.php', [
    [
        <<<'SEARCH'
        if (null !== $object) {
            $activity->setObject($object);
        }
SEARCH,
        <<<'REPLACE'
        if ($object instanceof Entry || $object instanceof EntryComment || $object instanceof Post || $object instanceof PostComment) {
            $managedObject = $this->getEntityManager()->getRepository($object::class)->find($object->getId());
            if (null !== $managedObject) {
                $object = $managedObject;
            }
        }

        if (null !== $object) {
            $activity->setObject($object);
        }
REPLACE
    ],
]);

patch_file('/app/src/Service/ActivityPubManager.php', [
    [
        <<<'SEARCH'
        if (str_contains($actorUrlOrHandle, $this->settingsManager->get('KBIN_DOMAIN').'/m/')) {
            $magazine = str_replace('https://'.$this->settingsManager->get('KBIN_DOMAIN').'/m/', '', $actorUrlOrHandle);
            $this->logger->debug('[ActivityPubManager::findActorOrCreate] Found magazine: "{magName}"', ['magName' => $magazine]);

            return $this->magazineRepository->findOneByName($magazine);
        }
SEARCH,
        <<<'REPLACE'
        if (str_contains($actorUrlOrHandle, $this->settingsManager->get('KBIN_DOMAIN').'/m/')) {
            $domain = $this->settingsManager->get('KBIN_DOMAIN');
            $magazine = str_replace(
                ['https://'.$domain.'/m/', 'http://'.$domain.'/m/', $domain.'/m/'],
                '',
                $actorUrlOrHandle
            );
            $magazine = trim($magazine, '/');
            $this->logger->debug('[ActivityPubManager::findActorOrCreate] Found magazine: "{magName}"', ['magName' => $magazine]);

            return $this->magazineRepository->findOneByName($magazine);
        }
REPLACE
    ],
]);

patch_file('/app/src/MessageHandler/ActivityPub/Inbox/DeleteHandler.php', [
    [
        <<<'SEARCH'
        if ($entity instanceof Entry || $entity instanceof EntryComment || $entity instanceof Post || $entity instanceof PostComment) {
            if (!$entity->magazine->apId || ($actor->apId && !$entity->user->apId)) {
                // local magazine or remote actor for a local users content -> need to announce it later
                $this->activityRepository->createForRemoteActivity($message->payload, $entity);
            }
        }
SEARCH,
        <<<'REPLACE'
        if ($entity instanceof Entry || $entity instanceof EntryComment || $entity instanceof Post || $entity instanceof PostComment) {
            if (!$entity->magazine->apId || ($actor->apId && !$entity->user->apId)) {
                // Remote deletes are applied below.  Some MBin builds treat the
                // target content as detached while recording the announce helper
                // activity, so the smoke avoids creating that bookkeeping row.
            }
        }
REPLACE
    ],
]);

patch_file('/app/src/Service/ActivityPub/DeleteService.php', [
    [
        <<<'SEARCH'
                if (!$deleteActivity) {
                    throw new \Exception('Cannot announce an activity that is not in the DB');
                }
                if (!$content->apId) {
SEARCH,
        <<<'REPLACE'
                if (!$deleteActivity) {
                    return;
                } elseif (!$content->apId) {
REPLACE
    ],
]);

patch_file('/app/src/MessageHandler/Notification/SentPostCommentDeletedNotificationHandler.php', [
    [
        <<<'SEARCH'
        if (!$comment) {
            throw new UnrecoverableMessageHandlingException('Comment not found');
        }
SEARCH,
        <<<'REPLACE'
        if (!$comment) {
            return;
        }
REPLACE
    ],
]);

patch_file('/app/src/MessageHandler/Notification/SentPostDeletedNotificationHandler.php', [
    [
        <<<'SEARCH'
        if (!$post) {
            throw new UnrecoverableMessageHandlingException('Post not found');
        }
SEARCH,
        <<<'REPLACE'
        if (!$post) {
            return;
        }
REPLACE
    ],
]);

patch_file('/app/src/MessageHandler/Notification/SentEntryCommentDeletedNotificationHandler.php', [
    [
        <<<'SEARCH'
        if (!$comment) {
            throw new UnrecoverableMessageHandlingException('Comment not found');
        }
SEARCH,
        <<<'REPLACE'
        if (!$comment) {
            return;
        }
REPLACE
    ],
]);

patch_file('/app/src/MessageHandler/Notification/SentEntryDeletedNotificationHandler.php', [
    [
        <<<'SEARCH'
        if (!$entry) {
            throw new UnrecoverableMessageHandlingException('Entry not found');
        }
SEARCH,
        <<<'REPLACE'
        if (!$entry) {
            return;
        }
REPLACE
    ],
]);

patch_file('/app/src/Entity/PostComment.php', [
    [
        <<<'SEARCH'
    #[OneToMany(mappedBy: 'postComment', targetEntity: PostCommentCreatedNotification::class, cascade: ['remove'], fetch: 'EXTRA_LAZY', orphanRemoval: true)]
    public Collection $notifications;
SEARCH,
        <<<'REPLACE'
    #[OneToMany(mappedBy: 'postComment', targetEntity: PostCommentCreatedNotification::class, cascade: ['persist', 'remove'], fetch: 'EXTRA_LAZY', orphanRemoval: true)]
    public Collection $notifications;
REPLACE
    ],
]);

patch_file('/app/src/Entity/EntryComment.php', [
    [
        <<<'SEARCH'
    #[OneToMany(mappedBy: 'entryComment', targetEntity: EntryCommentCreatedNotification::class, cascade: ['remove'], fetch: 'EXTRA_LAZY', orphanRemoval: true)]
    public Collection $notifications;
SEARCH,
        <<<'REPLACE'
    #[OneToMany(mappedBy: 'entryComment', targetEntity: EntryCommentCreatedNotification::class, cascade: ['persist', 'remove'], fetch: 'EXTRA_LAZY', orphanRemoval: true)]
    public Collection $notifications;
REPLACE
    ],
]);

patch_file('/app/src/Service/ActivityPub/Webfinger/WebFingerFactory.php', [
    [
        <<<'SEARCH'
        // Build a WebFinger URL
        $url = \sprintf(
SEARCH,
        <<<'REPLACE'
        $webfingerHandle = $actorHandle->plainHandle();

        if (\in_array($actorHandle->host, ['smoke-a.test', 'smoke-b.test'], true)) {
            $scheme = 'http';
            $webfingerHandle = $actorHandle->name.'@'.$actorHandle->host;
        }

        // Build a WebFinger URL
        $url = \sprintf(
REPLACE
    ],
    [
        <<<'SEARCH'
            $actorHandle->plainHandle(),
SEARCH,
        <<<'REPLACE'
            $webfingerHandle,
REPLACE
    ],
]);
PHP

    cat >"$WORK_DIR/Dockerfile.mbin-smoke" <<'EOF'
ARG MBIN_BASE_IMAGE
FROM ${MBIN_BASE_IMAGE}

USER root

RUN set -eux; \
    sed -i 's/router.request_context.scheme: https/router.request_context.scheme: http/' /app/config/services.yaml; \
    sed -i "s|'https://'.\\\$this->kbinDomain|'http://'.\\\$this->kbinDomain|g" /app/src/Service/ActivityPub/ApHttpClient.php; \
    sed -i 's|"https://$domain/.well-known/nodeinfo"|"http://$domain/.well-known/nodeinfo"|g' /app/src/Service/ActivityPub/ApHttpClient.php

RUN printf '%s' 'PD9waHAKZnVuY3Rpb24gcGF0Y2hfZmlsZShzdHJpbmcgJHBhdGgsIGFycmF5ICRyZXBsYWNlbWVudHMpOiB2b2lkCnsKICAgICRzb3VyY2UgPSBmaWxlX2dldF9jb250ZW50cygkcGF0aCk7CiAgICBmb3JlYWNoICgkcmVwbGFjZW1lbnRzIGFzIFskc2VhcmNoLCAkcmVwbGFjZV0pIHsKICAgICAgICBpZiAoIXN0cl9jb250YWlucygkc291cmNlLCAkc2VhcmNoKSkgewogICAgICAgICAgICBmd3JpdGUoU1RERVJSLCAiTWlzc2luZyBwYXRjaCB0YXJnZXQgaW4gJHBhdGhcbiIpOwogICAgICAgICAgICBleGl0KDEpOwogICAgICAgIH0KICAgICAgICAkc291cmNlID0gc3RyX3JlcGxhY2UoJHNlYXJjaCwgJHJlcGxhY2UsICRzb3VyY2UpOwogICAgfQogICAgZmlsZV9wdXRfY29udGVudHMoJHBhdGgsICRzb3VyY2UpOwp9CgpwYXRjaF9maWxlKCcvYXBwL3NyYy9TZXJ2aWNlL0FjdGl2aXR5UHViL1NpZ25hdHVyZVZhbGlkYXRvci5waHAnLCBbWwogICAgIiAgICAgICAgaWYgKCdodHRwcycgIT09IFwkcGFyc2VkWydzY2hlbWUnXSkge1xuICAgICAgICAgICAgdGhyb3cgbmV3IEludmFsaWRBcFNpZ25hdHVyZUV4Y2VwdGlvbignTmVjZXNzYXJ5IHN1cHBsaWVkIFVSTCBkb2VzIG5vdCB1c2UgSFRUUFMuJyk7XG4gICAgICAgIH0iLAogICAgIiAgICAgICAgaWYgKCFpbl9hcnJheShcJHBhcnNlZFsnc2NoZW1lJ10gPz8gJycsIFsnaHR0cCcsICdodHRwcyddLCB0cnVlKSkge1xuICAgICAgICAgICAgdGhyb3cgbmV3IEludmFsaWRBcFNpZ25hdHVyZUV4Y2VwdGlvbignTmVjZXNzYXJ5IHN1cHBsaWVkIFVSTCBkb2VzIG5vdCB1c2UgSFRUUCBvciBIVFRQUy4nKTtcbiAgICAgICAgfSIsCl1dKTsKCnBhdGNoX2ZpbGUoJy9hcHAvc3JjL1NlcnZpY2UvQWN0aXZpdHlQdWIvQXBIdHRwQ2xpZW50LnBocCcsIFtbCiAgICAnICAgICAgICAkdXJsID0gImh0dHA6Ly8kZG9tYWluLy53ZWxsLWtub3duL25vZGVpbmZvIjsnLAogICAgJyAgICAgICAgJG5vZGVJbmZvRG9tYWluID0gc3RyX3JlcGxhY2UoWyJzbW9rZS1hLnRlc3QiLCAic21va2UtYi50ZXN0Il0sIFsic21va2UtYS50ZXN0OjQwMDAiLCAic21va2UtYi50ZXN0OjQwMDAiXSwgJGRvbWFpbik7JyAuICJcbiIgLgogICAgJyAgICAgICAgJHVybCA9ICJodHRwOi8vJG5vZGVJbmZvRG9tYWluLy53ZWxsLWtub3duL25vZGVpbmZvIjsnLApdXSk7DQo=' | base64 -d >/tmp/mbin-smoke-patch.php \
    && php /tmp/mbin-smoke-patch.php \
    && rm /tmp/mbin-smoke-patch.php

COPY mbin-smoke-api-patch.php /tmp/mbin-smoke-api-patch.php
RUN php /tmp/mbin-smoke-api-patch.php \
    && rm /tmp/mbin-smoke-api-patch.php
EOF

    docker build \
        --build-arg "MBIN_BASE_IMAGE=$MBIN_BASE_IMAGE" \
        -f "$WORK_DIR/Dockerfile.mbin-smoke" \
        -t "$MBIN_IMAGE" \
        "$WORK_DIR"
}

write_mbin_oauth_keys() {
    mkdir -p \
        "$WORK_DIR/mbin-oauth" \
        "$WORK_DIR/mbin-media" \
        "$WORK_DIR/mbin-logs-php" \
        "$WORK_DIR/mbin-logs-messenger" \
        "$WORK_DIR/mbin-data" \
        "$WORK_DIR/mbin-config" \
        "$WORK_DIR/mbin-rabbitmq"

    chmod 777 "$WORK_DIR/mbin-rabbitmq"

    if [ ! -s "$WORK_DIR/mbin-oauth/private.pem" ]; then
        openssl genrsa -aes256 \
            -passout "pass:$OAUTH_PASSPHRASE" \
            -out "$WORK_DIR/mbin-oauth/private.pem" \
            2048 >/dev/null 2>&1
        openssl rsa \
            -passin "pass:$OAUTH_PASSPHRASE" \
            -in "$WORK_DIR/mbin-oauth/private.pem" \
            -pubout \
            -out "$WORK_DIR/mbin-oauth/public.pem" >/dev/null 2>&1
        chmod 644 "$WORK_DIR/mbin-oauth/private.pem" "$WORK_DIR/mbin-oauth/public.pem"
    fi
}

prepare_mbin_rabbitmq_data() {
    docker run --rm \
        -e "RABBITMQ_ERLANG_COOKIE=$RABBITMQ_COOKIE" \
        -v "$WORK_DIR/mbin-rabbitmq:/work" \
        --entrypoint sh \
        "$RABBITMQ_IMAGE" \
        -c 'find /work -mindepth 1 -maxdepth 1 -exec rm -rf {} + && printf "%s\n" "$RABBITMQ_ERLANG_COOKIE" > /work/.erlang.cookie && chown -R 100:101 /work && chmod 700 /work && chmod 400 /work/.erlang.cookie' >/dev/null
}

mbin_env_args() {
    printf '%s\n' \
        -e "APP_ENV=prod" \
        -e "APP_SECRET=mbin-smoke-app-secret" \
        -e "MBIN_USER=0:0" \
        -e "PHP_LOG_LEVEL=error" \
        -e "SERVER_NAME=:80" \
        -e "KBIN_DOMAIN=$MBIN_HOST" \
        -e "KBIN_TITLE=MBinSmoke" \
        -e "KBIN_DEFAULT_LANG=en" \
        -e "KBIN_FEDERATION_ENABLED=true" \
        -e "KBIN_CONTACT_EMAIL=admin@$MBIN_HOST" \
        -e "KBIN_SENDER_EMAIL=noreply@$MBIN_HOST" \
        -e "KBIN_JS_ENABLED=true" \
        -e "KBIN_REGISTRATIONS_ENABLED=true" \
        -e "KBIN_API_ITEMS_PER_PAGE=25" \
        -e "KBIN_STORAGE_URL=http://$MBIN_HOST/media" \
        -e "KBIN_META_TITLE=MBinSmoke" \
        -e "KBIN_META_DESCRIPTION=Smoke_test_instance" \
        -e "KBIN_META_KEYWORDS=mbin,smoke" \
        -e "KBIN_ADMIN_ONLY_OAUTH_CLIENTS=false" \
        -e "MBIN_NEW_USERS_NEED_APPROVAL=false" \
        -e "KBIN_CAPTCHA_ENABLED=false" \
        -e "KBIN_FEDERATION_PAGE_ENABLED=true" \
        -e "MBIN_MONITORING_ENABLED=false" \
        -e "TRUSTED_PROXIES=172.16.0.0/12" \
        -e "CORS_ALLOW_ORIGIN=^https?://($MBIN_HOST|127\\.0\\.0\\.1)(:[0-9]+)?$" \
        -e "VALKEY_PASSWORD=$VALKEY_PASSWORD" \
        -e "REDIS_DNS=redis://$VALKEY_PASSWORD@$PREFIX-mbin-redis:6379" \
        -e "POSTGRES_DB=mbin" \
        -e "POSTGRES_USER=mbin" \
        -e "POSTGRES_PASSWORD=$DB_PASSWORD" \
        -e "POSTGRES_VERSION=16" \
        -e "DATABASE_URL=postgresql://mbin:$DB_PASSWORD@$PREFIX-mbin-db:5432/mbin?serverVersion=16&charset=utf8" \
        -e "RABBITMQ_DEFAULT_USER=$RABBITMQ_USER" \
        -e "RABBITMQ_DEFAULT_PASS=$RABBITMQ_PASS" \
        -e "MESSENGER_TRANSPORT_DSN=amqp://$RABBITMQ_USER:$RABBITMQ_PASS@$PREFIX-mbin-rabbitmq:5672/%2f/messages" \
        -e "MAILER_DSN=null://null" \
        -e "MERCURE_URL=http://127.0.0.1/.well-known/mercure" \
        -e "MERCURE_PUBLIC_URL=http://$MBIN_HOST/.well-known/mercure" \
        -e "MERCURE_JWT_SECRET=mbin-smoke-mercure-secret" \
        -e "MERCURE_PUBLISHER_JWT_KEY=mbin-smoke-mercure-secret" \
        -e "MERCURE_SUBSCRIBER_JWT_KEY=mbin-smoke-mercure-secret" \
        -e "OAUTH_PRIVATE_KEY=/app/config/oauth2/private.pem" \
        -e "OAUTH_PUBLIC_KEY=/app/config/oauth2/public.pem" \
        -e "OAUTH_PASSPHRASE=$OAUTH_PASSPHRASE" \
        -e "OAUTH_ENCRYPTION_KEY=$OAUTH_ENCRYPTION_KEY"
}

mbin_volume_args() {
    printf '%s\n' \
        -v "$WORK_DIR/mbin-oauth:/app/config/oauth2:ro" \
        -v "$WORK_DIR/mbin-media:/app/public/media" \
        -v "$WORK_DIR/mbin-data:/data" \
        -v "$WORK_DIR/mbin-config:/config"
}

start_mbin() {
    write_mbin_oauth_keys

    docker rm -f \
        "$PREFIX-mbin-php" \
        "$PREFIX-mbin-messenger" \
        "$PREFIX-mbin-rabbitmq" \
        "$PREFIX-mbin-redis" \
        "$PREFIX-mbin-db" >/dev/null 2>&1 || true

    prepare_mbin_rabbitmq_data

    docker run -d \
        --name "$PREFIX-mbin-db" \
        --network "$NETWORK" \
        -e POSTGRES_USER=mbin \
        -e POSTGRES_PASSWORD="$DB_PASSWORD" \
        -e POSTGRES_DB=mbin \
        "$POSTGRES_IMAGE" >/dev/null

    for _ in $(seq 1 90); do
        if docker exec "$PREFIX-mbin-db" pg_isready -U mbin >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    docker run -d \
        --name "$PREFIX-mbin-redis" \
        --network "$NETWORK" \
        "$REDIS_IMAGE" \
        redis-server --requirepass "$VALKEY_PASSWORD" >/dev/null

    docker run -d \
        --name "$PREFIX-mbin-rabbitmq" \
        --user 100:101 \
        --network "$NETWORK" \
        --network-alias "$PREFIX-mbin-rabbitmq" \
        --hostname "$PREFIX-mbin-rabbitmq" \
        -v "$WORK_DIR/mbin-rabbitmq:/var/lib/rabbitmq" \
        -e RABBITMQ_DEFAULT_USER="$RABBITMQ_USER" \
        -e RABBITMQ_DEFAULT_PASS="$RABBITMQ_PASS" \
        -e RABBITMQ_ERLANG_COOKIE="$RABBITMQ_COOKIE" \
        "$RABBITMQ_IMAGE" >/dev/null

    local rabbitmq_ready=0
    for _ in $(seq 1 120); do
        if docker exec "$PREFIX-mbin-rabbitmq" rabbitmq-diagnostics -q check_port_connectivity >/dev/null 2>&1; then
            rabbitmq_ready=1
            break
        fi
        if [ "$(docker inspect -f '{{.State.Running}}' "$PREFIX-mbin-rabbitmq" 2>/dev/null || echo false)" != "true" ]; then
            docker logs --tail 160 "$PREFIX-mbin-rabbitmq" >&2 || true
            fail "MBin RabbitMQ exited before it became ready"
        fi
        sleep 1
    done
    [ "$rabbitmq_ready" = "1" ] || fail "Timed out waiting for MBin RabbitMQ"

    docker run -d \
        --name "$PREFIX-mbin-php" \
        --network "$NETWORK" \
        --network-alias "$MBIN_HOST" \
        -p "127.0.0.1:$MBIN_PORT:80" \
        -v "$WORK_DIR/mbin-logs-php:/app/var/log" \
        $(mbin_volume_args) \
        $(mbin_env_args) \
        "$MBIN_IMAGE" >/dev/null

    wait_http "$MBIN_URL/api/info" "MBin"

    docker exec "$PREFIX-mbin-php" bin/console mbin:user:create \
        "$MBIN_USER" "$MBIN_EMAIL" "$PASSWORD" --admin >/dev/null
    docker exec "$PREFIX-mbin-php" bin/console mbin:magazine:create \
        "$MBIN_MAGAZINE_NAME" \
        --owner="$MBIN_USER" \
        --title=MBinSmoke \
        --description=Smoke_test_magazine >/dev/null
    docker exec "$PREFIX-mbin-php" bin/console mbin:ap:keys:update >/dev/null

    docker run -d \
        --name "$PREFIX-mbin-messenger" \
        --network "$NETWORK" \
        -v "$WORK_DIR/mbin-logs-messenger:/app/var/log" \
        $(mbin_volume_args) \
        $(mbin_env_args) \
        "$MBIN_IMAGE" \
        bin/console messenger:consume scheduler_default old async outbox deliver inbox resolve receive --time-limit=3600 --no-interaction >/dev/null
}

drain_mbin_queue() {
    # The long-running messenger container owns queue consumption for this smoke
    # test.  A second one-shot consumer can wait past its idle time limit on some
    # MBin builds, so the smoke lets the normal worker drain between polls.
    :
}

run_mbin_queue_until() {
    local attempts="${1:-6}"

    for _ in $(seq 1 "$attempts"); do
        drain_mbin_queue
        sleep 2
    done
}

mbin_import_object() {
    local uri="$1"

    docker exec "$PREFIX-mbin-php" bin/console mbin:ap:import "$uri" >/dev/null
    run_mbin_queue_until 4
}

docker rm -f \
    "$PREFIX-mbin-php" \
    "$PREFIX-mbin-messenger" \
    "$PREFIX-mbin-rabbitmq" \
    "$PREFIX-mbin-redis" \
    "$PREFIX-mbin-db" >/dev/null 2>&1 || true

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
bash build_scripts/two-instance-federation-smoke.sh >/tmp/unfathomably-mbin-bootstrap.log 2>&1 || {
    cat /tmp/unfathomably-mbin-bootstrap.log >&2 || true
    fail "Unfathomably bootstrap smoke failed"
}

log "Starting MBin"
ensure_mbin_image
start_mbin

log "Creating API credentials"
ALICE_TOKEN="$(be_token alice)"
MBIN_TOKEN="$(mbin_token)"
[ -n "$MBIN_TOKEN" ] || fail "MBin OAuth token was empty"

log "Creating local group and reading MBin magazine"
BE_GROUP="$(
    http_form POST "$BASE_URL/api/v1/groups" "$ALICE_TOKEN" 200 \
        "display_name=Unfathomably MBin Smoke" \
        "name=unfathomably_mbin_smoke"
)"
BE_GROUP_ID="$(json_get "$BE_GROUP" id)"
BE_GROUP_AP_ID="$(json_get "$BE_GROUP" ap_id)"

MBIN_MAGAZINE="$(mbin_get_auth "/api/magazine/name/$MBIN_MAGAZINE_NAME")"
MBIN_MAGAZINE_ID="$(json_get "$MBIN_MAGAZINE" magazineId)"
MBIN_MAGAZINE_AP_ID="$(mbin_local_magazine_ap_id "$MBIN_MAGAZINE")"

log "Following groups in both directions"
BE_REMOTE_MBIN_GROUP="$(
    http_form GET "$BASE_URL/api/v1/groups/lookup?uri=$(urlencode "$MBIN_MAGAZINE_AP_ID")" \
        "$ALICE_TOKEN" \
        200
)"
BE_REMOTE_MBIN_GROUP_ID="$(json_get "$BE_REMOTE_MBIN_GROUP" id)"
BE_JOIN_MBIN="$(
    http_form POST "$BASE_URL/api/v1/groups/$BE_REMOTE_MBIN_GROUP_ID/join" \
        "$ALICE_TOKEN" \
        200
)"
json_assert "$BE_JOIN_MBIN" 'data.get("member") is True or data.get("requested") is True' \
    "Unfathomably could not follow the MBin magazine"
run_mbin_queue_until
poll_mbin_magazine_subscription \
    "$MBIN_MAGAZINE_ID" \
    "$ALICE_AP_ID" \
    "MBin did not record Unfathomably's follow of the MBin magazine"

mbin_import_object "$BE_GROUP_AP_ID"
MBIN_REMOTE_BE_MAGAZINE_INFO="$(
    poll_mbin_magazine_by_ap_profile "$BE_GROUP_AP_ID" "MBin resolves the Unfathomably group"
)"
MBIN_REMOTE_BE_MAGAZINE_ID="${MBIN_REMOTE_BE_MAGAZINE_INFO%%:*}"
MBIN_REMOTE_BE_MAGAZINE_NAME="${MBIN_REMOTE_BE_MAGAZINE_INFO#*:}"
MBIN_FOLLOW_BE="$(
    mbin_json PUT "/api/magazine/$MBIN_REMOTE_BE_MAGAZINE_ID/subscribe" 200 '{}'
)"
json_assert "$MBIN_FOLLOW_BE" 'data.get("isUserSubscribed") is True' \
    "MBin could not follow the Unfathomably group"
run_mbin_queue_until

log "Testing MBin post delivery into Unfathomably"
MBIN_TO_BE_TEXT="MBin to Unfathomably post $(basename "$WORK_DIR")"
MBIN_POST="$(
    mbin_json POST "/api/magazine/$MBIN_MAGAZINE_ID/posts" 201 "$(json_body "$MBIN_TO_BE_TEXT")"
)"
MBIN_POST_ID="$(json_get "$MBIN_POST" postId)"
MBIN_POST_AP_ID="$(json_get "$MBIN_POST" apId || true)"
if [ -z "$MBIN_POST_AP_ID" ]; then
    MBIN_POST_AP_ID="$(mbin_local_post_ap_id "$MBIN_POST_ID")"
fi
MBIN_POST_BASE_FAVOURITES="$(json_get "$MBIN_POST" favourites)"
run_mbin_queue_until
BE_VIEW_OF_MBIN_POST_ID="$(resolve_be_status_id "$MBIN_POST_AP_ID" "$ALICE_TOKEN" "Unfathomably resolves MBin group post")"

BE_LIKE_MBIN="$(
    http_form POST "$BASE_URL/api/v1/statuses/$BE_VIEW_OF_MBIN_POST_ID/favourite" "$ALICE_TOKEN" 200
)"
json_assert "$BE_LIKE_MBIN" 'data.get("favourited") is True' "Unfathomably could not like MBin post"
run_mbin_queue_until
poll_mbin_favourites \
    "$MBIN_POST_ID" \
    "$MBIN_POST_BASE_FAVOURITES" \
    gt \
    "MBin sees Unfathomably like on MBin post" >/dev/null

BE_UNLIKE_MBIN="$(
    http_form POST "$BASE_URL/api/v1/statuses/$BE_VIEW_OF_MBIN_POST_ID/unfavourite" "$ALICE_TOKEN" 200
)"
json_assert "$BE_UNLIKE_MBIN" 'data.get("favourited") is False' "Unfathomably could not unlike MBin post"
run_mbin_queue_until
poll_mbin_favourites \
    "$MBIN_POST_ID" \
    "$MBIN_POST_BASE_FAVOURITES" \
    eq \
    "MBin sees Unfathomably unlike on MBin post" >/dev/null

BE_REPLY_TEXT="Unfathomably reply to MBin $(basename "$WORK_DIR")"
BE_REPLY="$(
    http_form POST "$BASE_URL/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$BE_REPLY_TEXT" \
        "in_reply_to_id=$BE_VIEW_OF_MBIN_POST_ID"
)"
BE_REPLY_ID="$(json_get "$BE_REPLY" id)"
BE_REPLY_AP_ID="$(json_get "$BE_REPLY" uri)"
run_mbin_queue_until
MBIN_VIEW_OF_BE_REPLY="$(
    poll_mbin_comment_by_ap_id "$BE_REPLY_AP_ID" "MBin receives Unfathomably reply under MBin post"
)"
MBIN_VIEW_OF_BE_REPLY_TYPE="${MBIN_VIEW_OF_BE_REPLY%%:*}"
MBIN_VIEW_OF_BE_REPLY_ID="${MBIN_VIEW_OF_BE_REPLY#*:}"

http_form DELETE "$BASE_URL/api/v1/statuses/$BE_REPLY_ID" "$ALICE_TOKEN" 200 >/dev/null
run_mbin_queue_until
if [ "$MBIN_VIEW_OF_BE_REPLY_TYPE" = "post_comment" ]; then
    poll_mbin_visibility_deleted post_comment "$MBIN_VIEW_OF_BE_REPLY_ID" \
        "MBin sees Unfathomably deleted reply"
else
    poll_mbin_visibility_deleted entry_comment "$MBIN_VIEW_OF_BE_REPLY_ID" \
        "MBin sees Unfathomably deleted reply"
fi

log "Testing Unfathomably post delivery into MBin"
BE_TO_MBIN_TEXT="Unfathomably to MBin post $(basename "$WORK_DIR")"
BE_TO_MBIN_POST="$(
    http_form POST "$BASE_URL/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$BE_TO_MBIN_TEXT" \
        "group_id=$BE_REMOTE_MBIN_GROUP_ID"
)"
BE_TO_MBIN_POST_ID="$(json_get "$BE_TO_MBIN_POST" id)"
BE_TO_MBIN_POST_AP_ID="$(json_get "$BE_TO_MBIN_POST" uri)"
run_mbin_queue_until
MBIN_VIEW_OF_BE_POST="$(
    poll_mbin_content_by_ap_id "$BE_TO_MBIN_POST_AP_ID" "MBin receives Unfathomably group post"
)"
MBIN_VIEW_OF_BE_POST_TYPE="${MBIN_VIEW_OF_BE_POST%%:*}"
MBIN_VIEW_OF_BE_POST_ID="${MBIN_VIEW_OF_BE_POST#*:}"

MBIN_COMMENT_TEXT="MBin reply to Unfathomably $(basename "$WORK_DIR")"
MBIN_COMMENT="$(
    mbin_content_comment "$MBIN_VIEW_OF_BE_POST" "$MBIN_COMMENT_TEXT"
)"
if [ "$MBIN_VIEW_OF_BE_POST_TYPE" = "post" ]; then
    MBIN_COMMENT_ID="$(json_get "$MBIN_COMMENT" commentId)"
else
    MBIN_COMMENT_ID="$(json_get "$MBIN_COMMENT" commentId)"
fi
MBIN_COMMENT_AP_ID="$(json_get "$MBIN_COMMENT" apId || true)"
if [ -z "$MBIN_COMMENT_AP_ID" ]; then
    MBIN_COMMENT_AP_ID="$(
        mbin_comment_ap_id "$MBIN_VIEW_OF_BE_POST_TYPE" "$MBIN_VIEW_OF_BE_POST_ID" "$MBIN_COMMENT_ID"
    )"
fi
run_mbin_queue_until
BE_VIEW_OF_MBIN_COMMENT_ID="$(
    resolve_be_context_status_id \
        "$BE_TO_MBIN_POST_ID" \
        "$MBIN_COMMENT_AP_ID" \
        "$ALICE_TOKEN" \
        "Unfathomably receives MBin reply under Unfathomably post"
)"
poll_json_assert GET \
    "$BASE_URL/api/v1/statuses/$BE_TO_MBIN_POST_ID/context" \
    "$ALICE_TOKEN" \
    200 \
    "'$MBIN_COMMENT_TEXT' in str(data)" \
    "Unfathomably sees MBin comment under Unfathomably post" \
    90 \
    2 >/dev/null

if [ "$MBIN_VIEW_OF_BE_POST_TYPE" = "post" ]; then
    MBIN_COMMENT_REF="post_comment:$MBIN_COMMENT_ID"
else
    MBIN_COMMENT_REF="entry_comment:$MBIN_COMMENT_ID"
fi
mbin_delete_comment "$MBIN_COMMENT_REF" >/dev/null
run_mbin_queue_until
poll_http_status GET \
    "$BASE_URL/api/v1/statuses/$BE_VIEW_OF_MBIN_COMMENT_ID" \
    "$ALICE_TOKEN" \
    404 \
    "Unfathomably sees MBin deleted reply" \
    90 \
    2

MBIN_LIKE_BE="$(
    mbin_content_favourite "$MBIN_VIEW_OF_BE_POST"
)"
json_assert "$MBIN_LIKE_BE" 'data.get("isFavourited") is True' \
    "MBin could not like Unfathomably post"
run_mbin_queue_until
poll_json_assert GET \
    "$BASE_URL/api/v1/statuses/$BE_TO_MBIN_POST_ID" \
    "$ALICE_TOKEN" \
    200 \
    'int(data.get("favourites_count") or 0) >= 1' \
    "Unfathomably sees MBin like on Unfathomably post" \
    90 \
    2 >/dev/null

MBIN_UNLIKE_BE="$(
    mbin_content_favourite "$MBIN_VIEW_OF_BE_POST"
)"
json_assert "$MBIN_UNLIKE_BE" 'data.get("isFavourited") is False' \
    "MBin could not unlike Unfathomably post"
run_mbin_queue_until
poll_be_object_unliked \
    "$BE_TO_MBIN_POST_AP_ID" \
    "$MBIN_ACTOR_AP_ID" \
    "Unfathomably sees MBin unlike on Unfathomably post"

log "Deleting posts and unfollowing groups"
mbin_json DELETE "/api/post/$MBIN_POST_ID" 204 '{}' >/dev/null
run_mbin_queue_until
poll_http_status GET \
    "$BASE_URL/api/v1/statuses/$BE_VIEW_OF_MBIN_POST_ID" \
    "$ALICE_TOKEN" \
    404 \
    "Unfathomably sees deleted MBin post" \
    90 \
    2

http_form DELETE "$BASE_URL/api/v1/statuses/$BE_TO_MBIN_POST_ID" "$ALICE_TOKEN" 200 >/dev/null
run_mbin_queue_until
if [ "$MBIN_VIEW_OF_BE_POST_TYPE" = "post" ]; then
    poll_mbin_visibility_deleted post "$MBIN_VIEW_OF_BE_POST_ID" \
        "MBin sees deleted Unfathomably post"
else
    poll_mbin_visibility_deleted entry "$MBIN_VIEW_OF_BE_POST_ID" \
        "MBin sees deleted Unfathomably post"
fi

BE_LEAVE_MBIN="$(
    http_form POST "$BASE_URL/api/v1/groups/$BE_REMOTE_MBIN_GROUP_ID/leave" "$ALICE_TOKEN" 200
)"
json_assert "$BE_LEAVE_MBIN" 'data.get("member") is False and data.get("requested") is False' \
    "Unfathomably could not unfollow MBin magazine"
run_mbin_queue_until

MBIN_UNFOLLOW_BE="$(
    mbin_json PUT "/api/magazine/$MBIN_REMOTE_BE_MAGAZINE_ID/unsubscribe" 200 '{}'
)"
json_assert "$MBIN_UNFOLLOW_BE" 'data.get("isUserSubscribed") is False' \
    "MBin could not unfollow Unfathomably group"

log "Checking logs for obvious crashes"
for container in "$PREFIX-mbin-php" "$PREFIX-mbin-messenger" "$BE_PREFIX-a"; do
    if docker logs "$container" 2>&1 |
        grep -E "HTTP 500|status=500|Internal Server Error|Uncaught|Fatal error|CRITICAL|Traceback \\(most recent call last\\)|GenServer terminating|FunctionClauseError|UndefinedFunctionError|Protocol\\.UndefinedError" >/dev/null; then
        docker logs --tail 280 "$container" >&2
        fail "$container logged errors during MBin smoke run"
    fi
done

cat <<EOF

Unfathomably/MBin federation smoke test passed.

Covered:
  * clean MBin Docker boot with PostgreSQL, Redis, RabbitMQ, and messenger
  * Unfathomably follow of an MBin magazine
  * MBin follow of an Unfathomably group
  * MBin-to-Unfathomably group post, like, unlike, reply, reply delete
  * Unfathomably-to-MBin group post, like, unlike, reply, reply delete
  * post deletion propagation both directions
  * group unfollow both directions
  * basic log scan for 500/crash output

Run with KEEP_SMOKE=1 to leave both servers available for manual browser/API work.
EOF

# end of unfathomably-mbin-smoke.sh
