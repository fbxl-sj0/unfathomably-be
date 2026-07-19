#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-mobilizon-smoke.sh
#
# Purpose:
#
#   Run stock Mobilizon against Unfathomably and exercise the federation
#   operations exposed by Mobilizon's Group, Post, Event, and Comment models.
#
# Responsibilities:
#
#   * build or use the checked-out upstream Mobilizon production image
#   * test Group follows and unfollows in both directions
#   * test Group posts, Events, comments, and Delete activities
#   * test federated reports in both directions and local actor suspension
#   * report social operations that stock Mobilizon does not implement
#
# This file intentionally does NOT contain:
#
#   * patched Mobilizon source or images
#   * browser automation or private production credentials
#   * claims that unsupported Like, Block, or defederation signals passed
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAMILY_HARNESS="$SCRIPT_DIR/unfathomably-gotosocial-smoke.sh"

if [ ! -f "$FAMILY_HARNESS" ]; then
    printf 'Required account-federation harness not found: %s\n' "$FAMILY_HARNESS" >&2
    exit 1
fi

export SMOKE_PREFIX="${SMOKE_PREFIX:-unfathomably-mobilizon-smoke}"
export BE_HOST="${BE_HOST:-unfathomably-mobilizon.test}"
export BE_PORT="${BE_PORT:-5019}"
export BE_DB_NAME="${BE_DB_NAME:-unfathomably_mobilizon_smoke_be}"
export GTS_HOST="${GTS_HOST:-mobilizon-ref.test}"
export GTS_PORT="${GTS_PORT:-5020}"
export GTS_APP_PORT=4000
export GTS_LABEL=Mobilizon
export GTS_USERNAME=organizer
# Match the image pinned by Mobilizon's maintained Docker deployment.  The old
# framasoft/mobilizon repository was removed from Docker Hub, so using its
# floating latest tag makes a clean smoke host fail before federation starts.
export GTS_IMAGE="${MOBILIZON_IMAGE:-docker.io/kaihuri/mobilizon:5.2.2}"
export SMOKE_TLS=1
export BE_FEDERATION_SCHEME=https
export BE_FEDERATION_PORT=443

# mobilizon_ctl reconstructs Mix task arguments from a single shell string.
# Keep this disposable password free of whitespace so the release CLI cannot
# split it into positional arguments while creating the test administrator.
export SMOKE_PASSWORD="${MOBILIZON_PASSWORD:-mobilizon-smoke-password-12345}"

# shellcheck source=unfathomably-gotosocial-smoke.sh
source "$FAMILY_HARNESS"

MOBILIZON_DB_CONTAINER="${SMOKE_PREFIX}-mobilizon-db"
MOBILIZON_DB_IMAGE="${MOBILIZON_DB_IMAGE:-postgis/postgis:15-3.4-alpine}"
MOBILIZON_DB_NAME="${MOBILIZON_DB_NAME:-mobilizon}"
MOBILIZON_DB_PASSWORD="${MOBILIZON_DB_PASSWORD:-mobilizon-smoke-database-password}"
MOBILIZON_EMAIL="${MOBILIZON_EMAIL:-admin@mobilizon-smoke.test}"
MOBILIZON_GROUP_NAME="${MOBILIZON_GROUP_NAME:-mobilizon_smoke_group}"
MOBILIZON_GROUP_ACTOR="https://$GTS_HOST/@$MOBILIZON_GROUP_NAME"
MOBILIZON_SMTP_CONTAINER="${SMOKE_PREFIX}-smtp"
MOBILIZON_SMTP_IMAGE="${MOBILIZON_SMTP_IMAGE:-axllent/mailpit:latest}"

cleanup_mobilizon_smoke() {
    local status="$?"

    if [ "$KEEP_CONTAINERS" = "1" ]; then
        cleanup "$status"
    fi

    docker rm -f "$MOBILIZON_SMTP_CONTAINER" "$MOBILIZON_DB_CONTAINER" >/dev/null 2>&1 || true
    cleanup "$status"
}

trap cleanup_mobilizon_smoke EXIT

mobilizon_graphql() {
    local token="$1"
    local query="$2"
    local variables="${3:-}"
    local payload response

    if [ -z "$variables" ]; then
        variables='{}'
    fi

    payload="$(GRAPHQL_QUERY="$query" GRAPHQL_VARIABLES="$variables" python3 - <<'PY'
import json
import os

print(json.dumps({
    "query": os.environ["GRAPHQL_QUERY"],
    "variables": json.loads(os.environ["GRAPHQL_VARIABLES"]),
}))
PY
)"
    response="$(http_json POST "$GTS_BASE/api" "$token" 200 "$payload")"

    if JSON_INPUT="$response" python3 - <<'PY'
import json
import os

raise SystemExit(0 if json.loads(os.environ["JSON_INPUT"]).get("errors") else 1)
PY
    then
        printf '%s\n' "$response" >&2
        fail "Mobilizon GraphQL returned an error"
    fi

    printf '%s\n' "$response"
}

poll_mobilizon_graphql() {
    local token="$1"
    local query="$2"
    local variables="$3"
    local expression="$4"
    local message="$5"
    local result=""

    for _ in $(seq 1 90); do
        result="$(mobilizon_graphql "$token" "$query" "$variables" 2>/dev/null || true)"

        if [ -n "$result" ] && JSON_INPUT="$result" python3 - "$expression" <<'PY'
import json
import os
import sys

data = json.loads(os.environ["JSON_INPUT"])
safe_builtins = {"all": all, "any": any, "int": int, "len": len, "str": str}

if not eval(sys.argv[1], {"__builtins__": safe_builtins}, {"data": data}):
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

poll_mobilizon_database() {
    local query="$1"
    local expected="$2"
    local message="$3"
    local result=""

    for _ in $(seq 1 90); do
        result="$(docker exec "$MOBILIZON_DB_CONTAINER" \
            psql -U postgres -d "$MOBILIZON_DB_NAME" -Atc "$query" 2>/dev/null || true)"

        if [ "$result" = "$expected" ]; then
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

poll_be_database() {
    local query="$1"
    local expected="$2"
    local message="$3"
    local result=""

    for _ in $(seq 1 90); do
        result="$(docker exec "$BE_DB_CONTAINER" \
            psql -U postgres -d "$BE_DB_NAME" -Atc "$query" 2>/dev/null || true)"

        if [ "$result" = "$expected" ]; then
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

wait_mobilizon() {
    local query='query { config { name } }'

    for _ in $(seq 1 180); do
        if mobilizon_graphql "" "$query" '{}' >/dev/null 2>&1; then
            return 0
        fi

        sleep 2
    done

    docker logs "$GTS_CONTAINER" >&2 || true
    fail "Timed out waiting for Mobilizon at $GTS_BASE"
}

start_mobilizon() {
    docker run -d \
        --name "$GTS_CONTAINER" \
        --hostname "$GTS_APP_HOST" \
        --network "$NETWORK" \
        --network-alias "$GTS_APP_HOST" \
        --user root \
        --entrypoint /bin/sh \
        -e MOBILIZON_INSTANCE_HOST="$GTS_HOST" \
        -e MOBILIZON_INSTANCE_NAME='Mobilizon federation smoke' \
        -e MOBILIZON_INSTANCE_EMAIL="noreply@$GTS_HOST" \
        -e MOBILIZON_INSTANCE_REGISTRATIONS_OPEN=false \
        -e MOBILIZON_INSTANCE_SECRET_KEY_BASE='mobilizon-smoke-secret-key-base-0123456789abcdefghijklmnopqrstuvwxyz' \
        -e MOBILIZON_INSTANCE_SECRET_KEY='mobilizon-smoke-guardian-secret-0123456789abcdefghijklmnopqrstuvwxyz' \
        -e MOBILIZON_DATABASE_HOST="$MOBILIZON_DB_CONTAINER" \
        -e MOBILIZON_DATABASE_PORT=5432 \
        -e MOBILIZON_DATABASE_USERNAME=postgres \
        -e MOBILIZON_DATABASE_PASSWORD="$MOBILIZON_DB_PASSWORD" \
        -e MOBILIZON_DATABASE_DBNAME="$MOBILIZON_DB_NAME" \
        -e MOBILIZON_SMTP_SERVER="$MOBILIZON_SMTP_CONTAINER" \
        -e MOBILIZON_SMTP_PORT=1025 \
        -e MOBILIZON_SMTP_USERNAME=mobilizon-smoke \
        -e MOBILIZON_SMTP_PASSWORD=mobilizon-smoke \
        -e MOBILIZON_SMTP_TLS=never \
        -e MOBILIZON_SMTP_SSL=false \
        -e MOBILIZON_SMTP_AUTH=never \
        -e MOBILIZON_LOGLEVEL=info \
        -e MOBILIZON_CA_CERT_PATH=/etc/ssl/certs/ca-certificates.crt \
        -e SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
        -v "$SMOKE_CA_CERT:/usr/local/share/ca-certificates/unfathomably-smoke.crt:ro" \
        "$GTS_IMAGE" \
        -c 'update-ca-certificates >/dev/null && exec ./docker-entrypoint.sh' >/dev/null

    start_gts_proxy
    wait_mobilizon
}

create_mobilizon_user() {
    local cli_log="$WORK_DIR/mobilizon-user-create.log"

    #
    # The release script defaults RELEASE_NODE to the bare release name, but
    # the running short-name node includes the container hostname.  Supplying
    # the complete node name keeps the CLI on its safe RPC path and avoids
    # starting a second endpoint inside the already-running container.  The
    # HTTP endpoint can become ready just before Erlang distribution accepts
    # RPC connections, so retry the idempotent first-time setup during that
    # short startup window.
    #
    for _ in $(seq 1 60); do
        if docker exec \
            -e "RELEASE_NODE=mobilizon@$GTS_APP_HOST" \
            "$GTS_CONTAINER" \
            /bin/mobilizon_ctl users.new \
            "$MOBILIZON_EMAIL" \
            --password "$PASSWORD" \
            --admin \
            --profile-username "$GTS_USERNAME" >"$cli_log" 2>&1
        then
            return 0
        fi

        sleep 2
    done

    tail -n 40 "$cli_log" >&2 || true
    fail "Mobilizon CLI did not become available for user creation"
}

poll_be_report_by_text() {
    local text="$1"
    local message="$2"
    local result=""

    for _ in $(seq 1 90); do
        result="$(docker exec "$BE_DB_CONTAINER" psql -U postgres -d "$BE_DB_NAME" -Atc \
            "SELECT data->>'content' FROM activities WHERE data->>'type' = 'Flag' ORDER BY inserted_at DESC LIMIT 20;" || true)"

        if [[ "$result" == *"$text"* ]]; then
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

resolve_be_account_by_acct() {
    local acct="$1"
    local expected_ap_id="$2"
    local message="$3"
    local result=""
    local id=""

    #
    # Generic search can rank a similarly named local group above a remote
    # Mobilizon actor.  The account lookup endpoint resolves the exact acct
    # address; additionally checking its ActivityPub ID prevents a successful
    # request from ever selecting the wrong actor.
    #
    for _ in $(seq 1 90); do
        result="$(http_form GET "$BE_BASE/api/v1/accounts/lookup?acct=$(urlencode "$acct")" "$ALICE_TOKEN" 200 || true)"
        id="$(JSON_INPUT="$result" EXPECTED_AP_ID="$expected_ap_id" python3 - <<'PY' 2>/dev/null || true
import json
import os

account = json.loads(os.environ["JSON_INPUT"])

if (account.get("pleroma") or {}).get("ap_id") == os.environ["EXPECTED_AP_ID"]:
    print(account["id"])
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

prepare_smoke_tls
write_be_secret
write_proxy_configs

log "Creating Docker network"
docker rm -f \
    "$GTS_PROXY_CONTAINER" \
    "$GTS_CONTAINER" \
    "$MOBILIZON_SMTP_CONTAINER" \
    "$MOBILIZON_DB_CONTAINER" \
    "$BE_PROXY_CONTAINER" \
    "$BE_CONTAINER" \
    "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
docker network rm "$NETWORK" >/dev/null 2>&1 || true
docker network create "$NETWORK" >/dev/null

log "Starting databases and stock Mobilizon"
docker run -d \
    --name "$BE_DB_CONTAINER" \
    --network "$NETWORK" \
    -e POSTGRES_PASSWORD="$BE_DB_PASSWORD" \
    "$POSTGRES_IMAGE" >/dev/null
docker run -d \
    --name "$MOBILIZON_DB_CONTAINER" \
    --network "$NETWORK" \
    -e POSTGRES_PASSWORD="$MOBILIZON_DB_PASSWORD" \
    -e POSTGRES_DB="$MOBILIZON_DB_NAME" \
    "$MOBILIZON_DB_IMAGE" >/dev/null
docker run -d \
    --name "$MOBILIZON_SMTP_CONTAINER" \
    --network "$NETWORK" \
    --network-alias "$MOBILIZON_SMTP_CONTAINER" \
    "$MOBILIZON_SMTP_IMAGE" >/dev/null

wait_postgres
prepare_database
start_mobilizon
create_mobilizon_user

log "Migrating and starting Unfathomably"
migrate_and_create_be_user alice "alice@$BE_HOST"
start_be
start_be_proxy
wait_be
ALICE_TOKEN="$(create_be_token alice)"

LOGIN_QUERY='mutation Login($email: String!, $password: String!) { login(email: $email, password: $password) { accessToken user { defaultActor { id url preferredUsername } } } }'
LOGIN_VARS="$(python3 - "$MOBILIZON_EMAIL" "$PASSWORD" <<'PY'
import json
import sys

print(json.dumps({"email": sys.argv[1], "password": sys.argv[2]}))
PY
)"
MOBILIZON_LOGIN="$(mobilizon_graphql "" "$LOGIN_QUERY" "$LOGIN_VARS")"
MOBILIZON_TOKEN="$(json_get "$MOBILIZON_LOGIN" data.login.accessToken)"
MOBILIZON_PERSON_ID="$(json_get "$MOBILIZON_LOGIN" data.login.user.defaultActor.id)"
MOBILIZON_PERSON_ACTOR="$(json_get "$MOBILIZON_LOGIN" data.login.user.defaultActor.url)"

log "Creating local Group actors"
BE_GROUP="$(http_form POST "$BE_BASE/api/v1/groups" "$ALICE_TOKEN" 200 \
    'display_name=Unfathomably Mobilizon Smoke' \
    'name=unfathomably_mobilizon_smoke' \
    'note=Open group used by the Mobilizon federation smoke.' \
    'locked=false')"
BE_GROUP_ACTOR="https://$BE_HOST/users/unfathomably_mobilizon_smoke"

CREATE_GROUP_QUERY='mutation CreateGroup($preferredUsername: String!, $name: String!) { createGroup(preferredUsername: $preferredUsername, name: $name, summary: "Mobilizon federation smoke group", visibility: PUBLIC, openness: OPEN) { id url preferredUsername followersCount } }'
CREATE_GROUP_VARS="$(python3 - "$MOBILIZON_GROUP_NAME" <<'PY'
import json
import sys

print(json.dumps({"preferredUsername": sys.argv[1], "name": "Mobilizon Smoke Group"}))
PY
)"
MOBILIZON_GROUP="$(mobilizon_graphql "$MOBILIZON_TOKEN" "$CREATE_GROUP_QUERY" "$CREATE_GROUP_VARS")"
MOBILIZON_GROUP_ID="$(json_get "$MOBILIZON_GROUP" data.createGroup.id)"
MOBILIZON_GROUP_ACTOR="$(json_get "$MOBILIZON_GROUP" data.createGroup.url)"

log "Testing Group follows in both directions"
MOBILIZON_GROUP_ACCOUNT_ID="$(resolve_be_account_by_acct \
    "$MOBILIZON_GROUP_NAME@$GTS_HOST" \
    "$MOBILIZON_GROUP_ACTOR" \
    "Unfathomably could not resolve the Mobilizon Group")"
BE_FOLLOW="$(http_form POST "$BE_BASE/api/v1/accounts/$MOBILIZON_GROUP_ACCOUNT_ID/follow" "$ALICE_TOKEN" 200)"
json_assert "$BE_FOLLOW" 'data.get("following") is True or data.get("requested") is True' "Unfathomably could not follow the Mobilizon Group"

GROUP_QUERY='query Group($id: ID!) { getGroup(id: $id) { followersCount } }'
GROUP_VARS="$(python3 - "$MOBILIZON_GROUP_ID" <<'PY'
import json
import sys

print(json.dumps({"id": sys.argv[1]}))
PY
)"
poll_mobilizon_graphql "$MOBILIZON_TOKEN" "$GROUP_QUERY" "$GROUP_VARS" \
    'int(data["data"]["getGroup"]["followersCount"] or 0) >= 1' \
    "Mobilizon did not retain the Unfathomably Group follower" >/dev/null

REMOTE_GROUP_QUERY='query RemoteGroup($name: String!) { group(preferredUsername: $name) { id url preferredUsername } }'
REMOTE_GROUP_VARS="$(python3 - "$BE_HOST" <<'PY'
import json
import sys

print(json.dumps({"name": "unfathomably_mobilizon_smoke@" + sys.argv[1]}))
PY
)"
REMOTE_BE_GROUP="$(mobilizon_graphql "$MOBILIZON_TOKEN" "$REMOTE_GROUP_QUERY" "$REMOTE_GROUP_VARS")"
REMOTE_BE_GROUP_ID="$(json_get "$REMOTE_BE_GROUP" data.group.id)"

FOLLOW_GROUP_QUERY='mutation FollowGroup($id: ID!) { followGroup(groupId: $id, notify: true) { id approved targetActor { id url } } }'
FOLLOW_GROUP_VARS="$(python3 - "$REMOTE_BE_GROUP_ID" <<'PY'
import json
import sys

print(json.dumps({"id": sys.argv[1]}))
PY
)"
MOBILIZON_FOLLOW="$(mobilizon_graphql "$MOBILIZON_TOKEN" "$FOLLOW_GROUP_QUERY" "$FOLLOW_GROUP_VARS")"
json_assert "$MOBILIZON_FOLLOW" \
    'data["data"]["followGroup"].get("id") and data["data"]["followGroup"]["targetActor"].get("url")' \
    "Mobilizon could not request a follow of the Unfathomably Group"
poll_be_database \
    "select count(*) from following_relationships f join users follower on follower.id = f.follower_id join users followed on followed.id = f.following_id where follower.ap_id = '$MOBILIZON_PERSON_ACTOR' and followed.ap_id = '$BE_GROUP_ACTOR' and f.state = 2" \
    1 \
    "Unfathomably did not accept the Mobilizon Group follow"
poll_mobilizon_database \
    "select count(*) from followers where actor_id = $MOBILIZON_PERSON_ID and target_actor_id = $REMOTE_BE_GROUP_ID and approved = true" \
    1 \
    "Mobilizon did not retain Unfathomably's Follow Accept"

log "Testing Mobilizon Group Post delivery and deletion"
POST_MARKER="Mobilizon group post $(basename "$WORK_DIR")"
CREATE_POST_QUERY='mutation CreatePost($group: ID!, $title: String!, $body: String!) { createPost(attributedToId: $group, title: $title, body: $body, draft: false, visibility: PUBLIC, language: "en") { id slug url title body } }'
CREATE_POST_VARS="$(python3 - "$MOBILIZON_GROUP_ID" "$POST_MARKER" <<'PY'
import json
import sys

print(json.dumps({
    "group": sys.argv[1],
    "title": sys.argv[2],
    "body": "<p>" + sys.argv[2] + " body</p>",
}))
PY
)"
MOBILIZON_POST="$(mobilizon_graphql "$MOBILIZON_TOKEN" "$CREATE_POST_QUERY" "$CREATE_POST_VARS")"
MOBILIZON_POST_ID="$(json_get "$MOBILIZON_POST" data.createPost.id)"
MOBILIZON_POST_URL="$(json_get "$MOBILIZON_POST" data.createPost.url)"
BE_POST_ID="$(poll_home_status_by_text "$BE_BASE" "$ALICE_TOKEN" "$POST_MARKER" "Unfathomably did not receive the Mobilizon Group Post")"

DELETE_POST_QUERY='mutation DeletePost($id: ID!) { deletePost(id: $id) { id } }'
DELETE_POST_VARS="$(python3 - "$MOBILIZON_POST_ID" <<'PY'
import json
import sys

print(json.dumps({"id": sys.argv[1]}))
PY
)"
mobilizon_graphql "$MOBILIZON_TOKEN" "$DELETE_POST_QUERY" "$DELETE_POST_VARS" >/dev/null
sleep 5
MOBILIZON_DELETED_POST_VIEW="$(http_form GET "$BE_BASE/api/v1/statuses/$BE_POST_ID" "$ALICE_TOKEN" 200)"
json_assert "$MOBILIZON_DELETED_POST_VIEW" \
    'data.get("id") and "Mobilizon group post" in data.get("content", "")' \
    "Unfathomably unexpectedly lost the Group Post without receiving its Delete"

log "Testing Mobilizon Event and comments in both directions"
EVENT_TITLE="Mobilizon Event $(basename "$WORK_DIR")"
EVENT_TIMES="$(python3 - <<'PY'
import datetime
import json

start = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=2)
end = start + datetime.timedelta(hours=1)
print(json.dumps({"begins": start.isoformat(), "ends": end.isoformat()}))
PY
)"
CREATE_EVENT_QUERY='mutation CreateEvent($title: String!, $begins: DateTime!, $ends: DateTime!, $organizer: ID!, $group: ID!) { createEvent(title: $title, description: "<p>Mobilizon federation Event</p>", beginsOn: $begins, endsOn: $ends, status: CONFIRMED, visibility: PUBLIC, joinOptions: FREE, organizerActorId: $organizer, attributedToId: $group, category: MEETING, draft: false, language: "en") { id uuid url title } }'
CREATE_EVENT_VARS="$(python3 - "$EVENT_TITLE" "$MOBILIZON_PERSON_ID" "$MOBILIZON_GROUP_ID" "$EVENT_TIMES" <<'PY'
import json
import sys

times = json.loads(sys.argv[4])
print(json.dumps({
    "title": sys.argv[1],
    "organizer": sys.argv[2],
    "group": sys.argv[3],
    "begins": times["begins"],
    "ends": times["ends"],
}))
PY
)"
MOBILIZON_EVENT="$(mobilizon_graphql "$MOBILIZON_TOKEN" "$CREATE_EVENT_QUERY" "$CREATE_EVENT_VARS")"
MOBILIZON_EVENT_ID="$(json_get "$MOBILIZON_EVENT" data.createEvent.id)"
MOBILIZON_EVENT_UUID="$(json_get "$MOBILIZON_EVENT" data.createEvent.uuid)"
MOBILIZON_EVENT_URL="$(json_get "$MOBILIZON_EVENT" data.createEvent.url)"
BE_EVENT_ID="$(resolve_status_id \
    "$BE_BASE" \
    "$ALICE_TOKEN" \
    "$MOBILIZON_EVENT_URL" \
    "Unfathomably did not receive the Mobilizon Event")"

log "Testing Mobilizon RSVP Join, Accept, and Leave federation"
BE_ALICE="$(http_form GET "$BE_BASE/api/v1/accounts/verify_credentials" "$ALICE_TOKEN" 200)"
BE_ALICE_URL="$(json_get "$BE_ALICE" url)"
BE_JOIN_EVENT="$(
    http_form POST "$BE_BASE/api/v1/pleroma/events/$BE_EVENT_ID/join" "$ALICE_TOKEN" 200
)"
json_assert "$BE_JOIN_EVENT" 'data.get("id") == "'$BE_EVENT_ID'"' \
    "Unfathomably could not join Mobilizon Event"

EVENT_PARTICIPANTS_QUERY='query EventParticipants($uuid: UUID!) { event(uuid: $uuid) { participants(page: 1, limit: 50) { total elements { actor { id url } role } } } }'
EVENT_PARTICIPANTS_VARS="$(python3 - "$MOBILIZON_EVENT_UUID" <<'PY'
import json
import sys

print(json.dumps({"uuid": sys.argv[1]}))
PY
)"
poll_mobilizon_graphql \
    "$MOBILIZON_TOKEN" \
    "$EVENT_PARTICIPANTS_QUERY" \
    "$EVENT_PARTICIPANTS_VARS" \
    "any(item.get('actor', {}).get('url') == '$BE_ALICE_URL' for item in data['data']['event']['participants']['elements'])" \
    "Mobilizon did not accept Unfathomably Event participation" >/dev/null
poll_json_assert \
    "http_form GET $BE_BASE/api/v1/pleroma/events/joined_events $ALICE_TOKEN 200" \
    "any(item.get('id') == '$BE_EVENT_ID' for item in data)" \
    "Unfathomably did not retain Mobilizon's Join Accept" >/dev/null

BE_LEAVE_EVENT="$(
    http_form POST "$BE_BASE/api/v1/pleroma/events/$BE_EVENT_ID/leave" "$ALICE_TOKEN" 200
)"
json_assert "$BE_LEAVE_EVENT" 'data.get("id") == "'$BE_EVENT_ID'"' \
    "Unfathomably could not leave Mobilizon Event"
poll_mobilizon_graphql \
    "$MOBILIZON_TOKEN" \
    "$EVENT_PARTICIPANTS_QUERY" \
    "$EVENT_PARTICIPANTS_VARS" \
    "not any(item.get('actor', {}).get('url') == '$BE_ALICE_URL' for item in data['data']['event']['participants']['elements'])" \
    "Mobilizon retained Unfathomably Event participation after Leave" >/dev/null
poll_json_assert \
    "http_form GET $BE_BASE/api/v1/pleroma/events/joined_events $ALICE_TOKEN 200" \
    "not any(item.get('id') == '$BE_EVENT_ID' for item in data)" \
    "Unfathomably retained the Mobilizon Event after Leave" >/dev/null

MOBILIZON_COMMENT_TEXT="Mobilizon comment to Unfathomably $(basename "$WORK_DIR")"
CREATE_COMMENT_QUERY='mutation CreateComment($event: ID!, $text: String!) { createComment(eventId: $event, text: $text, language: "en") { id uuid url text } }'
CREATE_COMMENT_VARS="$(python3 - "$MOBILIZON_EVENT_ID" "$MOBILIZON_COMMENT_TEXT" <<'PY'
import json
import sys

print(json.dumps({"event": sys.argv[1], "text": sys.argv[2]}))
PY
)"
MOBILIZON_COMMENT="$(mobilizon_graphql "$MOBILIZON_TOKEN" "$CREATE_COMMENT_QUERY" "$CREATE_COMMENT_VARS")"
MOBILIZON_COMMENT_ID="$(json_get "$MOBILIZON_COMMENT" data.createComment.id)"
MOBILIZON_COMMENT_URL="$(json_get "$MOBILIZON_COMMENT" data.createComment.url)"
BE_COMMENT_ID="$(resolve_status_id "$BE_BASE" "$ALICE_TOKEN" "$MOBILIZON_COMMENT_URL" "Unfathomably could not resolve the Mobilizon comment")"

BE_REPLY_TEXT="Unfathomably comment to Mobilizon $(basename "$WORK_DIR")"
BE_REPLY="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
    "status=$BE_REPLY_TEXT" \
    "in_reply_to_id=$BE_EVENT_ID" \
    "visibility=public")"
BE_REPLY_ID="$(json_get "$BE_REPLY" id)"
BE_REPLY_URI="$(json_get "$BE_REPLY" uri)"

EVENT_QUERY='query Event($uuid: UUID!) { event(uuid: $uuid) { comments { id url text deletedAt } } }'
EVENT_VARS="$(python3 - "$MOBILIZON_EVENT_UUID" <<'PY'
import json
import sys

print(json.dumps({"uuid": sys.argv[1]}))
PY
)"
poll_mobilizon_graphql "$MOBILIZON_TOKEN" "$EVENT_QUERY" "$EVENT_VARS" \
    "any('$BE_REPLY_TEXT' in (item.get('text') or '') for item in data['data']['event']['comments'])" \
    "Mobilizon did not receive the Unfathomably Event comment" >/dev/null

http_form DELETE "$BE_BASE/api/v1/statuses/$BE_REPLY_ID" "$ALICE_TOKEN" 200 >/dev/null
poll_mobilizon_graphql "$MOBILIZON_TOKEN" "$EVENT_QUERY" "$EVENT_VARS" \
    "not any(item.get('url') == '$BE_REPLY_URI' and item.get('deletedAt') is None for item in data['data']['event']['comments'])" \
    "Mobilizon retained the deleted Unfathomably Event comment" >/dev/null

DELETE_COMMENT_QUERY='mutation DeleteComment($id: ID!) { deleteComment(commentId: $id) { id deletedAt } }'
DELETE_COMMENT_VARS="$(python3 - "$MOBILIZON_COMMENT_ID" <<'PY'
import json
import sys

print(json.dumps({"id": sys.argv[1]}))
PY
)"
mobilizon_graphql "$MOBILIZON_TOKEN" "$DELETE_COMMENT_QUERY" "$DELETE_COMMENT_VARS" >/dev/null
poll_status_missing "$BE_BASE" "$ALICE_TOKEN" "$BE_COMMENT_ID" "Unfathomably retained the deleted Mobilizon comment"

log "Testing federated moderation reports in both directions"
BE_REPORT_TEXT="Unfathomably report to Mobilizon $(basename "$WORK_DIR")"
http_form POST "$BE_BASE/api/v1/reports" "$ALICE_TOKEN" 200 \
    "account_id=$MOBILIZON_GROUP_ACCOUNT_ID" \
    "status_ids[]=$BE_EVENT_ID" \
    "comment=$BE_REPORT_TEXT" \
    'forward=true' >/dev/null

REPORTS_QUERY='query Reports { reports(page: 1, limit: 20) { elements { id content uri } } }'
poll_mobilizon_graphql "$MOBILIZON_TOKEN" "$REPORTS_QUERY" '{}' \
    "any('$BE_REPORT_TEXT' in (item.get('content') or '') for item in data['data']['reports']['elements'])" \
    "Mobilizon did not receive the Unfathomably moderation report" >/dev/null

REMOTE_PERSON_QUERY='query RemotePerson($name: String!) { fetchPerson(preferredUsername: $name) { id url preferredUsername suspended } }'
REMOTE_PERSON_VARS="$(python3 - "$BE_HOST" <<'PY'
import json
import sys

print(json.dumps({"name": "alice@" + sys.argv[1]}))
PY
)"
REMOTE_BE_PERSON="$(mobilizon_graphql "$MOBILIZON_TOKEN" "$REMOTE_PERSON_QUERY" "$REMOTE_PERSON_VARS")"
REMOTE_BE_PERSON_ID="$(json_get "$REMOTE_BE_PERSON" data.fetchPerson.id)"

MOBILIZON_REPORT_TEXT="Mobilizon report to Unfathomably $(basename "$WORK_DIR")"
CREATE_REPORT_QUERY='mutation CreateReport($reported: ID!, $content: String!) { createReport(reportedId: $reported, content: $content, forward: true) { id content uri } }'
CREATE_REPORT_VARS="$(python3 - "$REMOTE_BE_PERSON_ID" "$MOBILIZON_REPORT_TEXT" <<'PY'
import json
import sys

print(json.dumps({"reported": sys.argv[1], "content": sys.argv[2]}))
PY
)"
mobilizon_graphql "$MOBILIZON_TOKEN" "$CREATE_REPORT_QUERY" "$CREATE_REPORT_VARS" >/dev/null
poll_be_report_by_text "$MOBILIZON_REPORT_TEXT" "Unfathomably did not receive the Mobilizon moderation report"

DELETE_EVENT_QUERY='mutation DeleteEvent($id: ID!) { deleteEvent(eventId: $id) { id } }'
DELETE_EVENT_VARS="$(python3 - "$MOBILIZON_EVENT_ID" <<'PY'
import json
import sys

print(json.dumps({"id": sys.argv[1]}))
PY
)"
mobilizon_graphql "$MOBILIZON_TOKEN" "$DELETE_EVENT_QUERY" "$DELETE_EVENT_VARS" >/dev/null
poll_status_missing "$BE_BASE" "$ALICE_TOKEN" "$BE_EVENT_ID" "Unfathomably retained the deleted Mobilizon Event"

log "Testing local moderation and Group unfollows"
http_form POST "$BE_BASE/api/v1/accounts/$MOBILIZON_GROUP_ACCOUNT_ID/unfollow" "$ALICE_TOKEN" 200 >/dev/null
poll_mobilizon_graphql "$MOBILIZON_TOKEN" "$GROUP_QUERY" "$GROUP_VARS" \
    'int(data["data"]["getGroup"]["followersCount"] or 0) == 0' \
    "Mobilizon retained the Unfathomably Group follow after Undo" >/dev/null

BE_REFOLLOW="$(http_form POST "$BE_BASE/api/v1/accounts/$MOBILIZON_GROUP_ACCOUNT_ID/follow" "$ALICE_TOKEN" 200)"
json_assert "$BE_REFOLLOW" \
    'data.get("following") is True or data.get("requested") is True' \
    "Unfathomably could not restore the Mobilizon Group follow before blocking"
poll_mobilizon_graphql "$MOBILIZON_TOKEN" "$GROUP_QUERY" "$GROUP_VARS" \
    'int(data["data"]["getGroup"]["followersCount"] or 0) >= 1' \
    "Mobilizon did not retain the restored Unfathomably Group follower" >/dev/null

BE_BLOCK="$(http_form POST "$BE_BASE/api/v1/accounts/$MOBILIZON_GROUP_ACCOUNT_ID/block" "$ALICE_TOKEN" 200)"
json_assert "$BE_BLOCK" 'data.get("blocking") is True' "Unfathomably did not retain its Mobilizon Group block"
http_form POST "$BE_BASE/api/v1/accounts/$MOBILIZON_GROUP_ACCOUNT_ID/unblock" "$ALICE_TOKEN" 200 >/dev/null

SUSPEND_QUERY='mutation Suspend($id: ID!) { suspendProfile(id: $id) { id } }'
SUSPEND_VARS="$(python3 - "$REMOTE_BE_PERSON_ID" <<'PY'
import json
import sys

print(json.dumps({"id": sys.argv[1]}))
PY
)"
mobilizon_graphql "$MOBILIZON_TOKEN" "$SUSPEND_QUERY" "$SUSPEND_VARS" >/dev/null
poll_mobilizon_graphql "$MOBILIZON_TOKEN" "$REMOTE_PERSON_QUERY" "$REMOTE_PERSON_VARS" \
    'data["data"]["fetchPerson"]["suspended"] is True' \
    "Mobilizon did not retain its local actor suspension" >/dev/null
printf 'not_supported: stock Mobilizon 5.2.2 returned HTTP 500 from unsuspendProfile; the disposable smoke database is discarded instead\n'

UNFOLLOW_GROUP_QUERY='mutation UnfollowGroup($id: ID!) { unfollowGroup(groupId: $id) { id targetActor { id } } }'
mobilizon_graphql "$MOBILIZON_TOKEN" "$UNFOLLOW_GROUP_QUERY" "$FOLLOW_GROUP_VARS" >/dev/null
poll_be_database \
    "select count(*) from following_relationships f join users follower on follower.id = f.follower_id join users followed on followed.id = f.following_id where follower.ap_id = '$MOBILIZON_PERSON_ACTOR' and followed.ap_id = '$BE_GROUP_ACTOR' and f.state = 2" \
    0 \
    "Unfathomably retained the Mobilizon Group follow after Undo"

check_logs "$BE_CONTAINER" "Unfathomably"
check_logs "$GTS_CONTAINER" "Mobilizon"

cat <<EOF

Mobilizon federation smoke passed.

Covered against stock Mobilizon:
* supported: Group follows and Group unfollows in both directions
* supported: Mobilizon Group Posts reach Unfathomably
* supported: Mobilizon Events and Deletes reach Unfathomably
* supported: Mobilizon Event RSVP Join, Accept, and Leave federation
* supported: Event comments and comment Deletes work in both directions
* supported: federated moderation reports are received in both directions
* supported: Unfathomably retains and reverses its local actor block
* supported: Mobilizon retains its local actor suspension
* not_supported: stock Mobilizon 5.2.2 returns HTTP 500 when unsuspendProfile reverses that suspension
* not_supported: Mobilizon Person actors cannot be followed or follow Person actors
* not_supported: Mobilizon does not implement ActivityPub Like or Undo Like
* not_supported: Mobilizon does not send or retain ActivityPub Block activities
* not_supported: Mobilizon does not deliver Group Post Deletes to external group followers
* not_supported: Mobilizon has no durable signal that a remote server defederated it
* verified Mobilizon Post URL: $MOBILIZON_POST_URL
* verified Mobilizon Event URL: $MOBILIZON_EVENT_URL
EOF

# end of build_scripts/unfathomably-mobilizon-smoke.sh
