#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-xwiki-smoke.sh
#
# Purpose:
#
#   Run a pinned stock XWiki ActivityPub application against Unfathomably and
#   verify the federation behavior exposed by its real actors and collections.
#
# Responsibilities:
#
#   * build the pinned unmodified XWiki ActivityPub extension and run its tests
#   * provision the matching stock XWiki Standard distribution and real users
#   * exercise Person and Group-target follows, posts, replies, and Likes
#   * measure unsupported Undo, Delete, moderation, and Wiki actor behavior
#   * preserve the distinction between transport receipt and native state
#
# This file intentionally does NOT contain:
#
#   * patched XWiki or ActivityPub extension source
#   * hand-authored activities attributed to XWiki outside its C2S outbox
#   * production XWiki credentials or deployment settings
#   * hidden success for ActivityPub types the stock extension cannot parse
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAMILY_HARNESS="$SCRIPT_DIR/unfathomably-gotosocial-smoke.sh"

if [ ! -f "$FAMILY_HARNESS" ]; then
    printf 'Required account-federation harness not found: %s\n' "$FAMILY_HARNESS" >&2
    exit 1
fi

export SMOKE_PREFIX="${SMOKE_PREFIX:-unfathomably-xwiki-smoke}"
export BE_HOST="${BE_HOST:-unfathomably-xwiki.test}"
export BE_PORT="${BE_PORT:-5136}"
export BE_DB_NAME="${BE_DB_NAME:-unfathomably_xwiki_smoke_be}"
export GTS_HOST="${GTS_HOST:-xwiki-ref.test}"
export GTS_PORT="${GTS_PORT:-5137}"
export GTS_APP_PORT=8080
export GTS_LABEL=XWiki
export GTS_USERNAME=Alice

# shellcheck source-path=SCRIPTDIR
# shellcheck source=unfathomably-gotosocial-smoke.sh
source "$FAMILY_HARNESS"

XWIKI_SOURCE_URL="${XWIKI_SOURCE_URL:-https://github.com/xwiki-contrib/application-activitypub.git}"
XWIKI_SOURCE_COMMIT="${XWIKI_SOURCE_COMMIT:-5d12be8811617d6833dd101b021f83a68b339449}"
XWIKI_ACTIVITYPUB_VERSION="${XWIKI_ACTIVITYPUB_VERSION:-1.7.12-SNAPSHOT}"
XWIKI_VERSION="${XWIKI_VERSION:-12.10.11}"
XWIKI_IMAGE="${XWIKI_IMAGE:-xwiki:12.10.11-postgres-tomcat}"
XWIKI_POSTGRES_IMAGE="${XWIKI_POSTGRES_IMAGE:-postgres:13-alpine}"
XWIKI_MAVEN_IMAGE="${XWIKI_MAVEN_IMAGE:-maven:3.8.8-eclipse-temurin-8}"
XWIKI_MAVEN_CACHE="${XWIKI_MAVEN_CACHE:-${XDG_CACHE_HOME:-/tmp}/unfathomably-xwiki-maven}"
XWIKI_SOURCE_DIR="$WORK_DIR/xwiki-activitypub-source"
XWIKI_BUILD_MARKER="$XWIKI_MAVEN_CACHE/unfathomably-xwiki-$XWIKI_SOURCE_COMMIT.complete"
XWIKI_SETTINGS="$XWIKI_MAVEN_CACHE/settings-xwiki.xml"
XWIKI_DB_CONTAINER="${PREFIX}-xwiki-db"
XWIKI_DB_VOLUME="${PREFIX}-xwiki-postgres"
XWIKI_APP_VOLUME="$GTS_VOLUME"
XWIKI_DB_USER=xwiki
XWIKI_DB_PASSWORD=xwiki-smoke-postgres-password
XWIKI_DB_NAME=xwiki
XWIKI_SUPERADMIN_PASSWORD=SmokeSuperadmin_01
XWIKI_ADMIN_PASSWORD=SmokeAdmin_01
XWIKI_ALICE_PASSWORD=AliceSmoke_01
XWIKI_FLAVOR_ID=org.xwiki.platform:xwiki-platform-distribution-flavor-mainwiki
XWIKI_ACTIVITYPUB_ID=org.xwiki.contrib:activitypub-ui

# ------------------------------------------------------------------------------
# Disposable service lifecycle
# ------------------------------------------------------------------------------

cleanup_xwiki_smoke() {
    local incoming_status="$?"
    local status="${1:-$incoming_status}"

    if [ "$KEEP_CONTAINERS" = "1" ]; then
        cleanup "$status"
    fi

    docker rm -f \
        "$GTS_PROXY_CONTAINER" \
        "$GTS_CONTAINER" \
        "$XWIKI_DB_CONTAINER" >/dev/null 2>&1 || true
    docker volume rm \
        "$XWIKI_APP_VOLUME" \
        "$XWIKI_DB_VOLUME" >/dev/null 2>&1 || true
    cleanup "$status"
}

trap cleanup_xwiki_smoke EXIT

checkout_pinned_xwiki_source() {
    local actual_commit

    git clone --quiet --filter=blob:none --no-checkout \
        "$XWIKI_SOURCE_URL" "$XWIKI_SOURCE_DIR"
    git -C "$XWIKI_SOURCE_DIR" fetch --quiet --depth=1 \
        origin "$XWIKI_SOURCE_COMMIT"
    git -C "$XWIKI_SOURCE_DIR" checkout --quiet --detach \
        "$XWIKI_SOURCE_COMMIT"

    actual_commit="$(git -C "$XWIKI_SOURCE_DIR" rev-parse HEAD)"
    [ "$actual_commit" = "$XWIKI_SOURCE_COMMIT" ] || \
        fail "Pinned XWiki checkout resolved to $actual_commit"
}

write_xwiki_maven_settings() {
    mkdir -p "$XWIKI_MAVEN_CACHE"

    cat >"$XWIKI_SETTINGS" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0 https://maven.apache.org/xsd/settings-1.0.0.xsd">
  <profiles>
    <profile>
      <id>xwiki-public</id>
      <repositories>
        <repository>
          <id>xwiki-public</id>
          <url>https://nexus.xwiki.org/nexus/content/groups/public</url>
          <releases><enabled>true</enabled></releases>
          <snapshots><enabled>true</enabled></snapshots>
        </repository>
      </repositories>
      <pluginRepositories>
        <pluginRepository>
          <id>xwiki-public-plugins</id>
          <url>https://nexus.xwiki.org/nexus/content/groups/public</url>
          <releases><enabled>true</enabled></releases>
          <snapshots><enabled>true</enabled></snapshots>
        </pluginRepository>
      </pluginRepositories>
    </profile>
  </profiles>
  <activeProfiles><activeProfile>xwiki-public</activeProfile></activeProfiles>
</settings>
EOF
}

prepare_xwiki_extension() {
    local xar="$XWIKI_MAVEN_CACHE/repository/org/xwiki/contrib/activitypub-ui/$XWIKI_ACTIVITYPUB_VERSION/activitypub-ui-$XWIKI_ACTIVITYPUB_VERSION.xar"

    if [ -f "$XWIKI_BUILD_MARKER" ] && [ -f "$xar" ]; then
        log "Reusing tested pinned XWiki ActivityPub artifacts"
        return 0
    fi

    checkout_pinned_xwiki_source
    write_xwiki_maven_settings
    log "Building and testing pinned stock XWiki ActivityPub $XWIKI_SOURCE_COMMIT"
    docker run --rm \
        --user "$(id -u):$(id -g)" \
        -e HOME=/tmp \
        -e MAVEN_CONFIG=/tmp/m2 \
        -v "$XWIKI_SOURCE_DIR:/work" \
        -v "$XWIKI_MAVEN_CACHE:/tmp/m2" \
        -w /work \
        "$XWIKI_MAVEN_IMAGE" \
        mvn -B -ntp -U \
            -s /tmp/m2/settings-xwiki.xml \
            -Dmaven.repo.local=/tmp/m2/repository \
            install

    [ -f "$xar" ] || fail "XWiki ActivityPub build did not install its XAR"
    printf '%s\n' "$XWIKI_SOURCE_COMMIT" >"$XWIKI_BUILD_MARKER"
}

configure_xwiki_proxy_timeout() {
    #
    # Installing the Standard flavor is a synchronous stock Extension Manager
    # job that can legitimately take several minutes. The family proxy's
    # ordinary request timeout is too short for that one administrative call.
    #
    python3 - "$GTS_NGINX_CONF" "$GTS_APP_HOST" "$GTS_APP_PORT" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
needle = f"        proxy_pass http://{sys.argv[2]}:{sys.argv[3]};"
text = path.read_text(encoding="utf-8")
if text.count(needle) != 1:
    raise SystemExit("XWiki proxy_pass stanza changed")
replacement = needle + "\n        proxy_read_timeout 900s;\n        proxy_send_timeout 900s;"
path.write_text(text.replace(needle, replacement), encoding="utf-8")
PY
}

wait_xwiki_postgres() {
    local stable=0

    for _ in $(seq 1 120); do
        if docker exec "$XWIKI_DB_CONTAINER" \
            pg_isready -U "$XWIKI_DB_USER" -d "$XWIKI_DB_NAME" >/dev/null 2>&1; then
            stable=$((stable + 1))
            if [ "$stable" -ge 3 ]; then
                return 0
            fi
        else
            stable=0
        fi
        sleep 1
    done

    fail "XWiki PostgreSQL did not become ready"
}

wait_xwiki() {
    local require_auth="${1:-0}"
    local -a auth=()

    if [ "$require_auth" = "1" ]; then
        auth=(-u "superadmin:$XWIKI_SUPERADMIN_PASSWORD")
    fi

    for _ in $(seq 1 180); do
        if curl -fsS "${auth[@]}" "$GTS_BASE/xwiki/rest" >/dev/null 2>&1; then
            return 0
        fi

        if ! docker inspect "$GTS_CONTAINER" \
            --format '{{.State.Running}}' 2>/dev/null | grep -qx true; then
            docker logs "$GTS_CONTAINER" >&2 || true
            fail "XWiki exited before becoming ready"
        fi
        sleep 2
    done

    docker logs "$GTS_CONTAINER" >&2 || true
    fail "Timed out waiting for XWiki at $GTS_BASE/xwiki"
}

configure_xwiki() {
    docker exec "$GTS_CONTAINER" bash -lc "
        set -e
        cfg=/usr/local/xwiki/data/xwiki.cfg
        props=/usr/local/xwiki/data/xwiki.properties
        grep -qxF 'xwiki.superadminpassword=$XWIKI_SUPERADMIN_PASSWORD' \"\$cfg\" ||
            printf '\\nxwiki.superadminpassword=$XWIKI_SUPERADMIN_PASSWORD\\n' >>\"\$cfg\"
        grep -qxF 'extension.repositories=smoke-local:maven:file:///tmp/xwiki-maven,maven-xwiki:maven:https://nexus.xwiki.org/nexus/content/groups/public' \"\$props\" ||
            printf '\\nextension.repositories=smoke-local:maven:file:///tmp/xwiki-maven,maven-xwiki:maven:https://nexus.xwiki.org/nexus/content/groups/public\\n' >>\"\$props\"
        grep -qxF 'distribution.automaticStartOnMainWiki=false' \"\$props\" ||
            printf 'distribution.automaticStartOnMainWiki=false\\n' >>\"\$props\"
        grep -qxF 'distribution.automaticStartOnWiki=false' \"\$props\" ||
            printf 'distribution.automaticStartOnWiki=false\\n' >>\"\$props\"
    "

    docker restart "$GTS_CONTAINER" >/dev/null
    wait_xwiki 1
}

start_xwiki() {
    docker volume create "$XWIKI_APP_VOLUME" >/dev/null
    docker volume create "$XWIKI_DB_VOLUME" >/dev/null

    docker run -d \
        --name "$XWIKI_DB_CONTAINER" \
        --network "$NETWORK" \
        -e POSTGRES_USER="$XWIKI_DB_USER" \
        -e POSTGRES_PASSWORD="$XWIKI_DB_PASSWORD" \
        -e POSTGRES_DB="$XWIKI_DB_NAME" \
        -e POSTGRES_INITDB_ARGS=--encoding=UTF8 \
        -v "$XWIKI_DB_VOLUME:/var/lib/postgresql/data" \
        "$XWIKI_POSTGRES_IMAGE" >/dev/null

    wait_xwiki_postgres

    docker run -d \
        --name "$GTS_CONTAINER" \
        --hostname "$GTS_APP_HOST" \
        --network "$NETWORK" \
        --network-alias "$GTS_APP_HOST" \
        -e DB_USER="$XWIKI_DB_USER" \
        -e DB_PASSWORD="$XWIKI_DB_PASSWORD" \
        -e DB_DATABASE="$XWIKI_DB_NAME" \
        -e DB_HOST="$XWIKI_DB_CONTAINER" \
        -e CONTEXT_PATH=xwiki \
        -e JAVA_OPTS='-Xms256m -Xmx1536m' \
        -v "$XWIKI_APP_VOLUME:/usr/local/xwiki" \
        -v "$XWIKI_MAVEN_CACHE/repository:/tmp/xwiki-maven:ro" \
        "$XWIKI_IMAGE" >/dev/null

    start_gts_proxy
    wait_xwiki
    configure_xwiki
}

# ------------------------------------------------------------------------------
# Stock XWiki provisioning
# ------------------------------------------------------------------------------

xwiki_install_extension() {
    local job_id="$1"
    local extension_id="$2"
    local extension_version="$3"
    local request="$WORK_DIR/xwiki-install-$job_id-request.xml"
    local response="$WORK_DIR/xwiki-install-$job_id-response.xml"
    local http_status

    cat >"$request" <<EOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<jobRequest xmlns="http://www.xwiki.org">
  <id><element>extension</element><element>provision</element><element>$job_id</element></id>
  <interactive>false</interactive><remote>false</remote><verbose>true</verbose>
  <property><key>extensions</key><value><list xmlns="" xmlns:ns2="http://www.xwiki.org">
   <org.xwiki.extension.ExtensionId>
    <id>$extension_id</id>
    <version class="org.xwiki.extension.version.internal.DefaultVersion" serialization="custom">
     <org.xwiki.extension.version.internal.DefaultVersion><string>$extension_version</string></org.xwiki.extension.version.internal.DefaultVersion>
    </version>
   </org.xwiki.extension.ExtensionId>
  </list></value></property>
  <property><key>extensions.excluded</key><value><set xmlns="" xmlns:ns2="http://www.xwiki.org"/></value></property>
  <property><key>interactive</key><value><boolean xmlns="" xmlns:ns2="http://www.xwiki.org">false</boolean></value></property>
  <property><key>namespaces</key><value><list xmlns="" xmlns:ns2="http://www.xwiki.org"><string>wiki:xwiki</string></list></value></property>
</jobRequest>
EOF

    http_status="$(curl -sS --max-time 900 \
        -o "$response" -w '%{http_code}' \
        -u "superadmin:$XWIKI_SUPERADMIN_PASSWORD" \
        -H 'Content-Type: application/xml' \
        -X PUT --data-binary @"$request" \
        "$GTS_BASE/xwiki/rest/jobs?jobType=install&async=false")"

    if [ "$http_status" != 200 ] || \
        ! grep -q '<state>FINISHED</state>' "$response" || \
        grep -q '<level>error</level>' "$response"; then
        tail -c 16000 "$response" >&2 || true
        fail "XWiki extension job $job_id did not finish cleanly"
    fi
}

xwiki_create_stock_users() {
    local page="$WORK_DIR/xwiki-user-bootstrap.xml"
    local endpoint="$GTS_BASE/xwiki/rest/wikis/xwiki/spaces/XWiki/pages/SmokeUserBootstrap"
    local code

    cat >"$page" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<page xmlns="http://www.xwiki.org">
  <title>Smoke user bootstrap</title>
  <syntax>xwiki/2.1</syntax>
  <content>{{velocity}}Smoke user result: $xwiki.createUser(false){{/velocity}}</content>
</page>
EOF

    code="$(curl -sS -o "$WORK_DIR/xwiki-bootstrap-put.out" -w '%{http_code}' \
        -u "superadmin:$XWIKI_SUPERADMIN_PASSWORD" \
        -H 'Content-Type: application/xml' \
        -X PUT --data-binary @"$page" "$endpoint")"
    case "$code" in
        201|202|204) ;;
        *) fail "Could not create the temporary XWiki user bootstrap page" ;;
    esac

    xwiki_create_stock_user Admin "$XWIKI_ADMIN_PASSWORD"
    xwiki_create_stock_user Alice "$XWIKI_ALICE_PASSWORD"

    code="$(curl -sS -o "$WORK_DIR/xwiki-bootstrap-delete.out" -w '%{http_code}' \
        -u "superadmin:$XWIKI_SUPERADMIN_PASSWORD" \
        -X DELETE "$endpoint")"
    case "$code" in
        202|204) ;;
        *) fail "Could not remove the temporary XWiki user bootstrap page" ;;
    esac
}

xwiki_create_stock_user() {
    local name="$1"
    local password="$2"
    local lower result user_status

    lower="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    result="$(curl -sS -G \
        -u "superadmin:$XWIKI_SUPERADMIN_PASSWORD" \
        --data-urlencode "xwikiname=$name" \
        --data-urlencode "register_password=$password" \
        --data-urlencode "register2_password=$password" \
        --data-urlencode "register_email=$lower@smoke.invalid" \
        --data-urlencode "register_first_name=$name" \
        --data-urlencode 'register_last_name=Smoke' \
        --data-urlencode 'template=XWiki.XWikiUserTemplate' \
        "$GTS_BASE/xwiki/bin/view/XWiki/SmokeUserBootstrap")"

    [[ "$result" == *'Smoke user result: 1'* ]] || \
        fail "XWiki did not create stock user $name"

    user_status="$(curl -sS -o /dev/null -w '%{http_code}' \
        -u "superadmin:$XWIKI_SUPERADMIN_PASSWORD" \
        "$GTS_BASE/xwiki/rest/wikis/xwiki/spaces/XWiki/pages/$name")"
    [ "$user_status" = 200 ] || fail "XWiki user page $name is missing"
}

provision_xwiki() {
    log "Installing the stock XWiki Standard $XWIKI_VERSION flavor"
    xwiki_install_extension \
        unfathomably-xwiki-flavor \
        "$XWIKI_FLAVOR_ID" \
        "$XWIKI_VERSION"

    log "Creating real stock XWiki Admin and Alice users"
    xwiki_create_stock_users

    log "Installing pinned stock XWiki ActivityPub $XWIKI_ACTIVITYPUB_VERSION"
    xwiki_install_extension \
        unfathomably-xwiki-activitypub \
        "$XWIKI_ACTIVITYPUB_ID" \
        "$XWIKI_ACTIVITYPUB_VERSION"

    docker restart "$GTS_CONTAINER" >/dev/null
    wait_xwiki 1
}

# ------------------------------------------------------------------------------
# XWiki ActivityPub helpers
# ------------------------------------------------------------------------------

xwiki_local_url() {
    local canonical_url="$1"

    python3 - "$GTS_BASE" "$GTS_HOST" "$canonical_url" <<'PY'
import sys
import urllib.parse

base, expected_host, canonical = sys.argv[1:]
parsed = urllib.parse.urlparse(canonical)
if parsed.scheme not in {"http", "https"} or parsed.hostname != expected_host:
    raise SystemExit(f"Refusing non-XWiki URL: {canonical}")
path = parsed.path or "/"
if parsed.query:
    path += "?" + parsed.query
print(base + path)
PY
}

xwiki_json() {
    local canonical_url="$1"

    curl -fsS \
        -u "Alice:$XWIKI_ALICE_PASSWORD" \
        -H 'Accept: application/ld+json' \
        "$(xwiki_local_url "$canonical_url")"
}

xwiki_outbox_activity() {
    local outbox_uri="$1"
    local payload="$2"
    local body="$WORK_DIR/xwiki-outbox-response.$RANDOM.json"
    local status

    status="$(curl -sS -o "$body" -w '%{http_code}' \
        -u "Alice:$XWIKI_ALICE_PASSWORD" \
        -H 'Accept: application/ld+json' \
        -H 'Content-Type: application/activity+json' \
        -X POST --data-binary "$payload" \
        "$(xwiki_local_url "$outbox_uri")")"

    if [ "$status" != 200 ]; then
        printf 'XWiki outbox response (%s):\n' "$status" >&2
        cat "$body" >&2 || true
        fail "XWiki rejected a supported C2S activity"
    fi

    cat "$body"
    rm -f "$body"
}

xwiki_unsupported_outbox_status() {
    local outbox_uri="$1"
    local payload="$2"
    local body="$WORK_DIR/xwiki-unsupported-response.$RANDOM.out"
    local status

    status="$(curl -sS -o "$body" -w '%{http_code}' \
        -u "Alice:$XWIKI_ALICE_PASSWORD" \
        -H 'Accept: application/ld+json' \
        -H 'Content-Type: application/activity+json' \
        -X POST --data-binary "$payload" \
        "$(xwiki_local_url "$outbox_uri")" || true)"
    rm -f "$body"
    printf '%s\n' "$status"
}

xwiki_collection_item_matches() {
    local item="$1"
    local expression="$2"

    JSON_INPUT="$item" python3 - "$expression" <<'PY'
import json
import os
import sys

item = json.loads(os.environ["JSON_INPUT"])

def values(value):
    return value if isinstance(value, list) else [value]

def identifier(value):
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        return value.get("id") or value.get("@id")
    return None

def type_is(value, expected):
    return isinstance(value, dict) and expected in values(value.get("type", []))

def contains_text(value, expected):
    if isinstance(value, str):
        return expected in value
    if isinstance(value, list):
        return any(contains_text(item, expected) for item in value)
    if isinstance(value, dict):
        return any(contains_text(item, expected) for item in value.values())
    return False

scope = {
    "contains_text": contains_text,
    "identifier": identifier,
    "item": item,
    "type_is": type_is,
    "values": values,
}
safe_builtins = {"all": all, "any": any, "len": len, "str": str}
raise SystemExit(0 if eval(sys.argv[1], {"__builtins__": safe_builtins}, scope) else 1)
PY
}

smoke_peer_json() {
    local canonical_url="$1"
    local mapping kind local_url

    mapping="$(python3 - \
        "$BE_BASE" "$BE_HOST" "$GTS_BASE" "$GTS_HOST" "$canonical_url" <<'PY'
import sys
import urllib.parse

be_base, be_host, xwiki_base, xwiki_host, canonical = sys.argv[1:]
parsed = urllib.parse.urlparse(canonical)
if parsed.scheme not in {"http", "https"}:
    raise SystemExit(f"Refusing non-HTTP collection item: {canonical}")

path = parsed.path or "/"
if parsed.query:
    path += "?" + parsed.query

if parsed.hostname == xwiki_host:
    print("xwiki\t" + xwiki_base + path)
elif parsed.hostname == be_host:
    print("unfathomably\t" + be_base + path)
else:
    raise SystemExit(f"Refusing unknown collection item host: {canonical}")
PY
)" || return 1

    kind="${mapping%%$'\t'*}"
    local_url="${mapping#*$'\t'}"

    case "$kind" in
        xwiki)
            curl -fsS --max-time 15 --max-filesize 1048576 \
                -u "Alice:$XWIKI_ALICE_PASSWORD" \
                -H 'Accept: application/ld+json' "$local_url"
            ;;
        unfathomably)
            curl -fsS --max-time 15 --max-filesize 1048576 \
                -H 'Accept: application/ld+json' "$local_url"
            ;;
        *)
            return 1
            ;;
    esac
}

xwiki_collection_find() {
    local collection_uri="$1"
    local expression="$2"
    local payload encoded_item item item_uri fetched_item

    payload="$(xwiki_json "$collection_uri")" || return 1

    while IFS= read -r encoded_item; do
        [ -n "$encoded_item" ] || continue
        item="$(printf '%s' "$encoded_item" | base64 --decode)" || continue
        item_uri="$(JSON_INPUT="$item" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
if isinstance(data, str):
    print(data)
elif isinstance(data, dict) and not data.get("type"):
    print(data.get("id") or data.get("@id") or "")
PY
)" || true

        if [ -n "$item_uri" ]; then
            fetched_item="$(smoke_peer_json "$item_uri" 2>/dev/null || true)"
            if [ -n "$fetched_item" ]; then
                item="$fetched_item"
            fi
        fi

        if xwiki_collection_item_matches "$item" "$expression"; then
            printf '%s\n' "$item"
            return 0
        fi
    done < <(JSON_INPUT="$payload" python3 - <<'PY'
import base64
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
items = data.get("orderedItems", data.get("items", []))
if not isinstance(items, list):
    items = [items]

# A smoke collection should remain small. This bound also prevents a malformed
# local collection from triggering unbounded dereference work.
for item in items[:200]:
    encoded = json.dumps(item, separators=(",", ":")).encode("utf-8")
    print(base64.b64encode(encoded).decode("ascii"))
PY
)

    return 1
}

poll_xwiki_activity() {
    local collection_uri="$1"
    local expression="$2"
    local message="$3"
    local result=""

    for _ in $(seq 1 90); do
        result="$(xwiki_collection_find "$collection_uri" "$expression" 2>/dev/null || true)"
        if [ -n "$result" ]; then
            printf '%s\n' "$result"
            return 0
        fi
        sleep 2
    done

    printf 'Last XWiki collection state for %s:\n' "$collection_uri" >&2
    xwiki_json "$collection_uri" >&2 || true
    printf '\nRecent XWiki proxy requests:\n' >&2
    docker logs --tail 80 "$GTS_PROXY_CONTAINER" >&2 || true
    printf '\nRecent XWiki logs:\n' >&2
    docker logs --tail 80 "$GTS_CONTAINER" >&2 || true
    printf '\nRecent Unfathomably logs:\n' >&2
    docker logs --tail 80 "$BE_CONTAINER" >&2 || true
    fail "$message"
}

poll_xwiki_collection_membership() {
    local collection_uri="$1"
    local item_uri="$2"
    local expected="$3"
    local message="$4"
    local present=false

    for _ in $(seq 1 90); do
        if xwiki_collection_find \
            "$collection_uri" \
            "identifier(item) == '$item_uri'" >/dev/null 2>&1; then
            present=true
        else
            present=false
        fi

        if [ "$present" = "$expected" ]; then
            return 0
        fi
        sleep 2
    done

    fail "$message; observed membership was $present"
}

poll_be_group_membership() {
    local group_id="$1"
    local acct="$2"
    local expected="$3"
    local message="$4"
    local result=""

    for _ in $(seq 1 90); do
        result="$(http_form GET \
            "$BE_BASE/api/v1/groups/$group_id/memberships" \
            "$ALICE_TOKEN" 200 || true)"

        if JSON_INPUT="$result" EXPECTED_ACCT="$acct" EXPECTED_PRESENT="$expected" \
            python3 - <<'PY'
import json
import os

memberships = json.loads(os.environ["JSON_INPUT"])
acct = os.environ["EXPECTED_ACCT"]
present = any(
    item.get("account", {}).get("acct") == acct
    for item in memberships
)
expected = os.environ["EXPECTED_PRESENT"] == "true"
raise SystemExit(0 if present == expected else 1)
PY
        then
            return 0
        fi
        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

be_create_activity_uri_for_object() {
    local object_uri="$1"
    local activity_uri

    case "$object_uri" in
        "$BE_FEDERATION_SCHEME://$BE_HOST/objects/"*) ;;
        *) fail "Refusing to query a non-local object URI: $object_uri" ;;
    esac

    activity_uri="$(printf '%s\n' \
        "SELECT CASE WHEN count(*) = 1 THEN min(data->>'id') ELSE '' END
         FROM activities
         WHERE data->>'type' = 'Create'
           AND associated_object_id(data) = :'object_uri';" | \
        docker exec -i "$BE_DB_CONTAINER" \
            psql -U postgres -d "$BE_DB_NAME" -Atq -v ON_ERROR_STOP=1 \
            -v object_uri="$object_uri")"
    [ -n "$activity_uri" ] || \
        fail "Could not correlate local object $object_uri with one Create activity"
    printf '%s\n' "$activity_uri"
}

be_object_count_with_content() {
    local content="$1"

    printf '%s\n' \
        "SELECT count(*)
         FROM objects
         WHERE position(:'content' in coalesce(data->>'content', '')) > 0;" | \
        docker exec -i "$BE_DB_CONTAINER" \
            psql -U postgres -d "$BE_DB_NAME" -Atq -v ON_ERROR_STOP=1 \
            -v content="$content"
}

container_log_count() {
    local container="$1"
    local text="$2"

    docker logs "$container" 2>&1 | grep -Fc -- "$text" || true
}

poll_container_log_growth() {
    local container="$1"
    local text="$2"
    local before="$3"
    local message="$4"
    local count=""

    for _ in $(seq 1 90); do
        count="$(container_log_count "$container" "$text")"
        if [ "$count" -gt "$before" ]; then
            return 0
        fi
        sleep 2
    done

    fail "$message"
}

enable_be_xwiki_defederation() {
    case "$GTS_HOST" in
        ""|*[!a-zA-Z0-9.-]*)
            fail "Unsafe XWiki host passed to the defederation probe: $GTS_HOST"
            ;;
    esac

    cat >>"$BE_SECRET" <<EOF

# The final probe deliberately rejects the stock XWiki peer. It runs after all
# supported round trips because this policy applies to every incoming object.
config :pleroma, :mrf,
  policies: [Pleroma.Web.ActivityPub.MRF.SimplePolicy]

config :pleroma, :mrf_simple,
  reject: [{"$GTS_HOST", "XWiki smoke defederation probe"}]
EOF

    docker restart "$BE_CONTAINER" >/dev/null
    wait_be
}

poll_xwiki_object_like_count() {
    local object_uri="$1"
    local expected="$2"
    local message="$3"
    local object likes_uri likes count=""

    for _ in $(seq 1 90); do
        object="$(xwiki_json "$object_uri" 2>/dev/null || true)"
        likes_uri="$(json_get_optional "$object" likes 2>/dev/null || true)"

        if [ -n "$likes_uri" ]; then
            if [[ "$likes_uri" == \{* ]]; then
                likes="$likes_uri"
            else
                likes="$(xwiki_json "$likes_uri" 2>/dev/null || true)"
            fi
            count="$(json_get_optional "$likes" totalItems 2>/dev/null || true)"
        else
            count=0
        fi

        if [ "$count" = "$expected" ]; then
            return 0
        fi
        sleep 2
    done

    fail "$message; observed Like count was ${count:-unknown}"
}

xwiki_create_like_wrapper() {
    local page="$WORK_DIR/xwiki-like-wrapper.xml"
    local endpoint="$GTS_BASE/xwiki/rest/wikis/xwiki/spaces/XWiki/pages/SmokeLikeAction"
    local status

    cat >"$page" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<page xmlns="http://www.xwiki.org">
  <title>Smoke Like action</title>
  <syntax>xwiki/2.1</syntax>
  <content>{{velocity}}#template("activitypub/likeAction.vm"){{/velocity}}</content>
</page>
EOF

    status="$(curl -sS -o "$WORK_DIR/xwiki-like-wrapper-put.out" -w '%{http_code}' \
        -u "superadmin:$XWIKI_SUPERADMIN_PASSWORD" \
        -H 'Content-Type: application/xml' \
        -X PUT --data-binary @"$page" "$endpoint")"
    case "$status" in
        201|202|204) ;;
        *) fail "Could not create the temporary XWiki Like action wrapper" ;;
    esac
}

xwiki_like_activity() {
    local activity_id="$1"
    local home token result

    home="$(curl -fsS -u "Alice:$XWIKI_ALICE_PASSWORD" \
        "$GTS_BASE/xwiki/bin/view/Main/WebHome")"
    token="$(HTML_INPUT="$home" python3 - <<'PY'
import os
import re

match = re.search(r'data-xwiki-form-token=["\x27]([^"\x27]+)', os.environ["HTML_INPUT"])
print(match.group(1) if match else "")
PY
)"
    [ -n "$token" ] || fail "XWiki did not expose Alice's CSRF token"

    result="$(curl -fsS \
        -u "Alice:$XWIKI_ALICE_PASSWORD" \
        -H 'Accept: application/json' \
        --data-urlencode "form_token=$token" \
        --data-urlencode "activityId=$activity_id" \
        "$GTS_BASE/xwiki/bin/get/XWiki/SmokeLikeAction?outputSyntax=plain")"
    json_assert "$result" 'data.get("success") is True' \
        "XWiki's stock Like action did not succeed"
}

xwiki_remove_like_wrapper() {
    local endpoint="$GTS_BASE/xwiki/rest/wikis/xwiki/spaces/XWiki/pages/SmokeLikeAction"
    local status

    status="$(curl -sS -o "$WORK_DIR/xwiki-like-wrapper-delete.out" -w '%{http_code}' \
        -u "superadmin:$XWIKI_SUPERADMIN_PASSWORD" \
        -X DELETE "$endpoint")"
    case "$status" in
        202|204) ;;
        *) fail "Could not remove the temporary XWiki Like action wrapper" ;;
    esac
}

poll_proxy_posts() {
    local path="$1"
    local before="$2"
    local message="$3"
    local count=""

    for _ in $(seq 1 90); do
        count="$(docker logs "$GTS_PROXY_CONTAINER" 2>&1 | \
            grep -Fc "POST $path " || true)"
        if [ "$count" -gt "$before" ]; then
            return 0
        fi
        sleep 2
    done

    fail "$message"
}

# ------------------------------------------------------------------------------
# Native federation matrix
# ------------------------------------------------------------------------------

run_xwiki_smoke() {
    local actor actor_probe_status webfinger_status xwiki_actor xwiki_inbox xwiki_inbox_path
    local xwiki_outbox
    local xwiki_followers xwiki_following be_credentials alice_ap_id xwiki_account_id
    local xwiki_source
    local be_actor be_inbox be_inbox_path before_outgoing_follow after_outgoing_follow
    local follow_payload follow_response be_follow relationship
    local be_group be_group_id be_group_ap_id group_follow_payload group_follow_status
    local be_post_text be_post be_post_id be_post_uri be_inbox_create be_inbox_create_id
    local xwiki_post_text xwiki_post_payload xwiki_post_response xwiki_post_uri
    local be_view_of_xwiki_id xwiki_reply_text xwiki_reply_payload xwiki_reply_response
    local xwiki_reply_id be_reply_text be_reply be_reply_id be_reply_uri
    local be_reply_activity_uri
    local unsupported_post_delete_status unsupported_comment_delete_status
    local before_unlike_log before_comment_delete_log before_post_delete_log
    local before_flag before_flag_log before_block before_block_log
    local before_unfollow_log report relationship_after_block
    local defederated_post_text defederated_post_payload defederated_post_response
    local defederated_activity_id mrf_state object_count group_summary

    prepare_xwiki_extension

    write_be_secret
    write_proxy_configs
    configure_xwiki_proxy_timeout

    log "Creating Docker network"
    docker rm -f \
        "$GTS_PROXY_CONTAINER" \
        "$GTS_CONTAINER" \
        "$XWIKI_DB_CONTAINER" \
        "$BE_PROXY_CONTAINER" \
        "$BE_CONTAINER" \
        "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    docker volume rm \
        "$XWIKI_APP_VOLUME" \
        "$XWIKI_DB_VOLUME" >/dev/null 2>&1 || true
    docker network create "$NETWORK" >/dev/null

    log "Starting stock XWiki and Unfathomably databases"
    docker run -d \
        --name "$BE_DB_CONTAINER" \
        --network "$NETWORK" \
        -e POSTGRES_PASSWORD="$BE_DB_PASSWORD" \
        "$POSTGRES_IMAGE" >/dev/null
    wait_postgres
    prepare_database
    start_xwiki
    provision_xwiki

    log "Migrating and starting Unfathomably"
    migrate_and_create_be_user alice "alice@$BE_HOST"
    start_be
    start_be_proxy
    wait_be
    ALICE_TOKEN="$(create_be_token alice)"
    be_credentials="$(http_form GET \
        "$BE_BASE/api/v1/accounts/verify_credentials" "$ALICE_TOKEN" 200)"
    alice_ap_id="$(json_get "$be_credentials" url)"
    be_actor="$(curl -fsS -H 'Accept: application/ld+json' "$BE_BASE/users/alice")"
    be_inbox="$(json_get "$be_actor" inbox)"
    be_inbox_path="$(python3 - "$be_inbox" <<'PY'
import sys
import urllib.parse

print(urllib.parse.urlparse(sys.argv[1]).path)
PY
)"

    log "Verifying the stock XWiki Person and Wiki actor surfaces"
    actor="$(curl -fsS \
        -H 'Accept: application/ld+json' \
        "$GTS_BASE/xwiki/activitypub/Person/XWiki.Alice")"
    json_assert "$actor" \
        "data.get('type') == 'Person' and data.get('preferredUsername') == 'Alice' and data.get('publicKey', {}).get('publicKeyPem') and data.get('inbox') and data.get('outbox') and data.get('followers') and data.get('following')" \
        "XWiki did not expose Alice as a complete ActivityPub Person"
    xwiki_actor="$(json_get "$actor" id)"
    xwiki_inbox="$(json_get "$actor" inbox)"
    xwiki_inbox_path="$(python3 - "$xwiki_inbox" <<'PY'
import sys
import urllib.parse

parsed = urllib.parse.urlparse(sys.argv[1])
path = parsed.path or "/"
if parsed.query:
    path += "?" + parsed.query
print(path)
PY
)"
    xwiki_outbox="$(json_get "$actor" outbox)"
    xwiki_followers="$(json_get "$actor" followers)"
    xwiki_following="$(json_get "$actor" following)"

    actor_probe_status="$(curl -sS -o "$WORK_DIR/xwiki-service-actor.out" -w '%{http_code}' \
        -H 'Accept: application/ld+json' \
        "$GTS_BASE/xwiki/activitypub/Service/xwiki" || true)"
    [ "$actor_probe_status" = 500 ] || \
        fail "Stock XWiki Wiki Service actor boundary changed: HTTP $actor_probe_status"

    webfinger_status="$(curl -sS -o "$WORK_DIR/xwiki-webfinger.out" -w '%{http_code}' \
        "$GTS_BASE/.well-known/webfinger?resource=acct%3AAlice%40$GTS_HOST" || true)"
    [ "$webfinger_status" = 404 ] || \
        fail "Stock XWiki WebFinger boundary changed: HTTP $webfinger_status"

    log "Measuring XWiki's outbound Person Follow transport boundary"
    before_outgoing_follow="$(docker logs "$BE_PROXY_CONTAINER" 2>&1 | \
        grep -Fc "POST $be_inbox_path " || true)"
    follow_payload="$(python3 - "$xwiki_actor" "$alice_ap_id" <<'PY'
import json
import sys

actor, target = sys.argv[1:]
print(json.dumps({
    "@context": "https://www.w3.org/ns/activitystreams",
    "type": "Follow",
    "actor": actor,
    "object": target,
    "to": target,
}))
PY
)"
    follow_response="$(xwiki_outbox_activity "$xwiki_outbox" "$follow_payload")"
    json_assert "$follow_response" \
        "data.get('type') in ('Follow', 'Accept')" \
        "XWiki did not process its outgoing Person Follow"
    after_outgoing_follow="$(docker logs "$BE_PROXY_CONTAINER" 2>&1 | \
        grep -Fc "POST $be_inbox_path " || true)"
    [ "$after_outgoing_follow" = "$before_outgoing_follow" ] || \
        fail "Stock XWiki unexpectedly transported its C2S Person Follow"

    xwiki_account_id="$(resolve_account_id \
        "$BE_BASE" "$ALICE_TOKEN" "$xwiki_actor" \
        "Unfathomably could not resolve XWiki after its outgoing Follow")"
    xwiki_source="$(http_form GET \
        "$BE_BASE/api/v1/sources/$xwiki_account_id" "$ALICE_TOKEN" 200)"
    json_assert "$xwiki_source" \
        "data.get('platform') == 'xwiki' and data.get('platform_family') == 'publishing'" \
        "Unfathomably did not classify XWiki as a publishing source"
    poll_xwiki_collection_membership \
        "$xwiki_following" "$alice_ap_id" true \
        "XWiki did not retain its local-only outgoing Follow state"
    relationship="$(http_form GET \
        "$BE_BASE/api/v1/accounts/relationships?id[]=$xwiki_account_id" \
        "$ALICE_TOKEN" 200)"
    json_assert "$relationship" \
        'len(data) == 1 and data[0].get("followed_by") is not True' \
        "Unfathomably unexpectedly retained XWiki's untransported Follow"

    log "Following XWiki from Unfathomably"
    be_follow="$(http_form POST \
        "$BE_BASE/api/v1/accounts/$xwiki_account_id/follow" "$ALICE_TOKEN" 200)"
    json_assert "$be_follow" \
        'data.get("following") is True or data.get("requested") is True' \
        "Unfathomably could not follow XWiki"
    poll_relationship_following \
        "$BE_BASE" "$ALICE_TOKEN" "$xwiki_account_id" \
        "XWiki did not accept Unfathomably's Follow"
    poll_xwiki_collection_membership \
        "$xwiki_followers" "$alice_ap_id" true \
        "XWiki did not retain Unfathomably as Alice's follower"

    log "Measuring XWiki's Group-target Follow boundary"
    be_group="$(http_form POST "$BE_BASE/api/v1/groups" "$ALICE_TOKEN" 200 \
        'display_name=Unfathomably XWiki Smoke' \
        'name=unfathomably_xwiki_smoke' \
        'note=Open group used by the XWiki stock federation harness.' \
        'locked=false')"
    be_group_id="$(json_get "$be_group" id)"
    be_group_ap_id="$(json_get "$be_group" url)"
    group_follow_payload="$(python3 - "$xwiki_actor" "$be_group_ap_id" <<'PY'
import json
import sys

actor, target = sys.argv[1:]
print(json.dumps({
    "@context": "https://www.w3.org/ns/activitystreams",
    "type": "Follow",
    "actor": actor,
    "object": target,
    "to": target,
}))
PY
)"
    group_follow_status="$(xwiki_unsupported_outbox_status \
        "$xwiki_outbox" "$group_follow_payload")"
    [ "$group_follow_status" = 501 ] || \
        fail "Stock XWiki Group-target Follow boundary changed: HTTP $group_follow_status"
    poll_xwiki_collection_membership \
        "$xwiki_following" "$be_group_ap_id" false \
        "Stock XWiki unexpectedly retained its rejected Group-target Follow"
    poll_be_group_membership \
        "$be_group_id" "Alice@$GTS_HOST" false \
        "Unfathomably unexpectedly retained XWiki's rejected Group membership"

    log "Testing Unfathomably post delivery into XWiki"
    be_post_text="Unfathomably to XWiki smoke $(basename "$WORK_DIR")"
    be_post="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$be_post_text" 'visibility=public' "to[]=$xwiki_actor")"
    be_post_id="$(json_get "$be_post" id)"
    be_post_uri="$(json_get "$be_post" uri)"
    be_inbox_create="$(poll_xwiki_activity \
        "$xwiki_inbox" \
        "type_is(item, 'Create') and contains_text(item, '$be_post_text')" \
        "XWiki did not retain Unfathomably's Create activity")"
    be_inbox_create_id="$(json_get "$be_inbox_create" id)"

    log "Testing native XWiki post delivery into Unfathomably"
    xwiki_post_text="XWiki to Unfathomably smoke $(basename "$WORK_DIR")"
    xwiki_post_payload="$(python3 - \
        "$xwiki_actor" "$alice_ap_id" "$xwiki_post_text" <<'PY'
import json
import sys

actor, target, content = sys.argv[1:]
print(json.dumps({
    "@context": "https://www.w3.org/ns/activitystreams",
    "type": "Create",
    "actor": actor,
    "to": [target],
    "object": {
        "type": "Note",
        "attributedTo": [actor],
        "to": [target],
        "content": content,
    },
}))
PY
)"
    xwiki_post_response="$(xwiki_outbox_activity "$xwiki_outbox" "$xwiki_post_payload")"
    xwiki_post_uri="$(json_get "$xwiki_post_response" object.id)"
    be_view_of_xwiki_id="$(poll_home_status_by_text \
        "$BE_BASE" "$ALICE_TOKEN" "$xwiki_post_text" \
        "Unfathomably did not receive XWiki's native Note")"

    log "Testing replies in both supported directions"
    xwiki_reply_text="XWiki reply to Unfathomably $(basename "$WORK_DIR")"
    xwiki_reply_payload="$(python3 - \
        "$xwiki_actor" "$alice_ap_id" "$be_post_uri" "$xwiki_reply_text" <<'PY'
import json
import sys

actor, target, parent, content = sys.argv[1:]
print(json.dumps({
    "@context": "https://www.w3.org/ns/activitystreams",
    "type": "Create",
    "actor": actor,
    "to": [target],
    "object": {
        "type": "Note",
        "attributedTo": [actor],
        "to": [target],
        "inReplyTo": parent,
        "content": content,
    },
}))
PY
)"
    xwiki_reply_response="$(xwiki_outbox_activity "$xwiki_outbox" "$xwiki_reply_payload")"
    xwiki_reply_id="$(json_get "$xwiki_reply_response" object.id)"
    poll_context_status_by_text \
        "$BE_BASE" "$ALICE_TOKEN" "$be_post_id" "$xwiki_reply_text" \
        "Unfathomably did not receive XWiki's reply" >/dev/null

    be_reply_text="Unfathomably reply to XWiki $(basename "$WORK_DIR")"
    be_reply="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$be_reply_text" \
        "in_reply_to_id=$be_view_of_xwiki_id")"
    be_reply_id="$(json_get "$be_reply" id)"
    be_reply_uri="$(json_get "$be_reply" uri)"
    be_reply_activity_uri="$(be_create_activity_uri_for_object "$be_reply_uri")"
    poll_xwiki_collection_membership \
        "$xwiki_inbox" "$be_reply_activity_uri" true \
        "XWiki did not retain Unfathomably's private reply Create"

    log "Testing Likes and the stock Undo Like boundary"
    xwiki_create_like_wrapper
    xwiki_like_activity "$be_inbox_create_id"
    poll_status_count \
        "$BE_BASE" "$ALICE_TOKEN" "$be_post_id" \
        'int(data.get("favourites_count") or 0) >= 1' \
        "Unfathomably did not receive XWiki's Like"

    http_form POST \
        "$BE_BASE/api/v1/statuses/$be_view_of_xwiki_id/favourite" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_xwiki_object_like_count \
        "$xwiki_post_uri" 1 \
        "XWiki did not retain Unfathomably's incoming Like"
    before_unlike_log="$(container_log_count \
        "$GTS_CONTAINER" 'ActivityPub Object type [Undo] not found.')"
    http_form POST \
        "$BE_BASE/api/v1/statuses/$be_view_of_xwiki_id/unfavourite" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_container_log_growth \
        "$GTS_CONTAINER" 'ActivityPub Object type [Undo] not found.' \
        "$before_unlike_log" \
        "XWiki did not parse Unfathomably's incoming Undo Like"
    poll_xwiki_object_like_count \
        "$xwiki_post_uri" 1 \
        "Stock XWiki unexpectedly removed a Like despite having no Undo handler"
    xwiki_remove_like_wrapper

    log "Measuring unsupported post and comment Deletes"
    unsupported_comment_delete_status="$(xwiki_unsupported_outbox_status \
        "$xwiki_outbox" \
        "{\"@context\":\"https://www.w3.org/ns/activitystreams\",\"type\":\"Delete\",\"actor\":\"$xwiki_actor\",\"object\":\"$xwiki_reply_id\"}")"
    case "$unsupported_comment_delete_status" in
        400|404|500|501) ;;
        *) fail "Stock XWiki unexpectedly accepted an outgoing comment Delete: HTTP $unsupported_comment_delete_status" ;;
    esac
    unsupported_post_delete_status="$(xwiki_unsupported_outbox_status \
        "$xwiki_outbox" \
        "{\"@context\":\"https://www.w3.org/ns/activitystreams\",\"type\":\"Delete\",\"actor\":\"$xwiki_actor\",\"object\":\"$xwiki_post_uri\"}")"
    case "$unsupported_post_delete_status" in
        400|404|500|501) ;;
        *) fail "Stock XWiki unexpectedly accepted an outgoing post Delete: HTTP $unsupported_post_delete_status" ;;
    esac

    before_comment_delete_log="$(container_log_count \
        "$GTS_CONTAINER" 'ActivityPub Object type [Delete] not found.')"
    http_form DELETE \
        "$BE_BASE/api/v1/statuses/$be_reply_id" "$ALICE_TOKEN" 200 >/dev/null
    poll_container_log_growth \
        "$GTS_CONTAINER" 'ActivityPub Object type [Delete] not found.' \
        "$before_comment_delete_log" \
        "XWiki did not parse Unfathomably's incoming comment Delete"
    poll_xwiki_collection_membership \
        "$xwiki_inbox" "$be_reply_activity_uri" true \
        "XWiki unexpectedly removed the reply Create despite lacking Delete handling"
    before_post_delete_log="$(container_log_count \
        "$GTS_CONTAINER" 'ActivityPub Object type [Delete] not found.')"
    http_form DELETE \
        "$BE_BASE/api/v1/statuses/$be_post_id" "$ALICE_TOKEN" 200 >/dev/null
    poll_container_log_growth \
        "$GTS_CONTAINER" 'ActivityPub Object type [Delete] not found.' \
        "$before_post_delete_log" \
        "XWiki did not parse Unfathomably's incoming post Delete"
    poll_xwiki_collection_membership \
        "$xwiki_inbox" "$be_inbox_create_id" true \
        "XWiki unexpectedly removed the post Create despite lacking Delete handling"

    log "Testing moderation and Block transport boundaries"
    before_flag="$(docker logs "$GTS_PROXY_CONTAINER" 2>&1 | \
        grep -Fc "POST $xwiki_inbox_path " || true)"
    before_flag_log="$(container_log_count \
        "$GTS_CONTAINER" 'ActivityPub Object type [Flag] not found.')"
    report="$(http_form POST "$BE_BASE/api/v1/reports" "$ALICE_TOKEN" 200 \
        "account_id=$xwiki_account_id" \
        "status_ids[]=$be_view_of_xwiki_id" \
        'comment=XWiki moderation transport smoke' \
        'forward=true')"
    json_assert "$report" 'data.get("id") is not None' \
        "Unfathomably did not create its local report"
    poll_proxy_posts \
        "$xwiki_inbox_path" "$before_flag" \
        "XWiki did not receive Unfathomably's Flag transport"
    poll_container_log_growth \
        "$GTS_CONTAINER" 'ActivityPub Object type [Flag] not found.' \
        "$before_flag_log" \
        "XWiki did not parse Unfathomably's incoming Flag"

    before_block="$(docker logs "$GTS_PROXY_CONTAINER" 2>&1 | \
        grep -Fc "POST $xwiki_inbox_path " || true)"
    before_block_log="$(container_log_count \
        "$GTS_CONTAINER" 'ActivityPub Object type [Block] not found.')"
    relationship_after_block="$(http_form POST \
        "$BE_BASE/api/v1/accounts/$xwiki_account_id/block" "$ALICE_TOKEN" 200)"
    json_assert "$relationship_after_block" 'data.get("blocking") is True' \
        "Unfathomably did not retain its local XWiki Block"
    poll_proxy_posts \
        "$xwiki_inbox_path" "$before_block" \
        "XWiki did not receive Unfathomably's Block transport"
    poll_container_log_growth \
        "$GTS_CONTAINER" 'ActivityPub Object type [Block] not found.' \
        "$before_block_log" \
        "XWiki did not parse Unfathomably's incoming Block"
    http_form POST \
        "$BE_BASE/api/v1/accounts/$xwiki_account_id/unblock" "$ALICE_TOKEN" 200 >/dev/null

    log "Measuring XWiki's missing Undo Follow and defederation awareness"
    be_follow="$(http_form POST \
        "$BE_BASE/api/v1/accounts/$xwiki_account_id/follow" "$ALICE_TOKEN" 200)"
    json_assert "$be_follow" \
        'data.get("following") is True or data.get("requested") is True' \
        "Unfathomably could not restore its XWiki Follow after Unblock"
    poll_relationship_following \
        "$BE_BASE" "$ALICE_TOKEN" "$xwiki_account_id" \
        "XWiki did not accept Unfathomably's restored Follow"
    before_unfollow_log="$(container_log_count \
        "$GTS_CONTAINER" 'ActivityPub Object type [Undo] not found.')"
    http_form POST \
        "$BE_BASE/api/v1/accounts/$xwiki_account_id/unfollow" "$ALICE_TOKEN" 200 >/dev/null
    poll_container_log_growth \
        "$GTS_CONTAINER" 'ActivityPub Object type [Undo] not found.' \
        "$before_unfollow_log" \
        "XWiki did not parse Unfathomably's incoming Undo Follow"
    relationship="$(http_form GET \
        "$BE_BASE/api/v1/accounts/relationships?id[]=$xwiki_account_id" \
        "$ALICE_TOKEN" 200)"
    json_assert "$relationship" \
        'len(data) == 1 and data[0].get("following") is not True' \
        "Unfathomably did not clear its local XWiki Follow"
    poll_xwiki_collection_membership \
        "$xwiki_followers" "$alice_ap_id" true \
        "Stock XWiki unexpectedly applied Undo Follow without an Undo handler"

    enable_be_xwiki_defederation
    defederated_post_text="XWiki defederation-awareness probe $(basename "$WORK_DIR")"
    defederated_post_payload="$(python3 - \
        "$xwiki_actor" "$alice_ap_id" "$defederated_post_text" <<'PY'
import json
import sys

actor, target, content = sys.argv[1:]
print(json.dumps({
    "@context": "https://www.w3.org/ns/activitystreams",
    "type": "Create",
    "actor": actor,
    "to": [target],
    "object": {
        "type": "Note",
        "attributedTo": [actor],
        "to": [target],
        "content": content,
    },
}))
PY
)"
    defederated_post_response="$(xwiki_outbox_activity \
        "$xwiki_outbox" "$defederated_post_payload")"
    json_assert "$defederated_post_response" \
        "data.get('type') == 'Create' and data.get('id') and data.get('object', {}).get('id')" \
        "XWiki did not retain its outgoing delivery attempt"
    defederated_activity_id="$(json_get "$defederated_post_response" id)"
    poll_xwiki_collection_membership \
        "$xwiki_outbox" "$defederated_activity_id" true \
        "XWiki did not retain its defederated delivery attempt in the outbox"
    poll_container_log_growth \
        "$BE_CONTAINER" "$defederated_post_text" 0 \
        "Unfathomably did not receive XWiki's defederation probe"
    mrf_state="$(curl -fsS "$BE_BASE/nodeinfo/2.1.json")"
    json_assert "$mrf_state" \
        "'$GTS_HOST' in data.get('metadata', {}).get('federation', {}).get('mrf_simple', {}).get('reject', []) and 'SimplePolicy' in data.get('metadata', {}).get('federation', {}).get('mrf_policies', []) and data.get('metadata', {}).get('federation', {}).get('mrf_simple_info', {}).get('reject', {}).get('$GTS_HOST', {}).get('reason') == 'XWiki smoke defederation probe'" \
        "Unfathomably did not disclose the active XWiki defederation policy"
    object_count="$(be_object_count_with_content "$defederated_post_text")"
    [ "$object_count" = 0 ] || \
        fail "Unfathomably stored XWiki's defederated post"

    group_summary="not_supported: stock XWiki rejects Group-target Follow with HTTP 501, and its generated Wiki Service actor URL fails with a stock ClassCastException"

    check_logs "$BE_CONTAINER" "Unfathomably"
    if docker logs "$GTS_CONTAINER" 2>&1 | \
        grep -Ei 'OutOfMemoryError|StackOverflowError|segmentation fault|(^|[[:space:]])fatal error' >/dev/null; then
        docker logs "$GTS_CONTAINER" >&2 || true
        fail "XWiki emitted a crash-class log line"
    fi

    cat <<EOF

XWiki federation smoke passed.

Covered against pinned stock XWiki ActivityPub $XWIKI_ACTIVITYPUB_VERSION:
* supported: pinned source build and its Maven test suite complete before deployment
* supported: stock Standard flavor, real XWiki users, ActivityPub extension, and cold restart
* supported: complete Person actor, inbox, outbox, following, followers, and public key surfaces
* supported: direct Person actor discovery, publishing-source classification, and accepted Unfathomably-to-XWiki Follow
* stock_limitation: XWiki exposes no WebFinger endpoint
* stock_limitation: XWiki's C2S Follow mutates its local following collection but never transports the Follow to the remote inbox
* $group_summary
* supported: posts and replies are delivered and retained in both directions
* supported: XWiki sends Like and retains an incoming Like in native collection state
* not_supported: stock XWiki has no Undo entity or handler, so it cannot send Unlike or Unfollow and cannot apply incoming Undo Like, Undo Follow, or Undo Block
* not_supported: stock XWiki has no Delete entity or handler; outgoing post/comment Delete is rejected and incoming Delete leaves the original Create retained
* not_supported: stock XWiki has no Block or Flag entity, handler, moderation model, or outgoing moderation action; incoming transport reaches the inbox endpoint but cannot become native state
* stock_limitation: XWiki's generated Wiki Service actor URL returns HTTP 500 because an EntityReference is cast to WikiReference, so reverse Group-actor follow cannot be exercised
* stock_limitation: Unfathomably's real SimplePolicy rejects the final XWiki Create and stores no object, while XWiki retains the outbox attempt but exposes no federation-health or defederation state
* supported: temporary user-bootstrap and Like-template wrapper pages are removed, and disposable peer state is cleaned up
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run_xwiki_smoke
fi

# end of build_scripts/unfathomably-xwiki-smoke.sh
