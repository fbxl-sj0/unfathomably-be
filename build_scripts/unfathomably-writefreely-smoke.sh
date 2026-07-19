#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-writefreely-smoke.sh
#
# Purpose:
#
#   Run a stock single-user WriteFreely blog against Unfathomably and prove
#   the federation operations implemented by WriteFreely's collection actor.
#
# Responsibilities:
#
#   * create an isolated WriteFreely SQLite instance and author
#   * test follow, unfollow, article delivery, Like, Undo Like, and Delete
#   * report unsupported social and moderation operations explicitly
#   * check both services for crash-class failures
#
# This file intentionally does NOT contain:
#
#   * production WriteFreely configuration
#   * patched WriteFreely source or images
#   * Mastodon API assumptions
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAMILY_HARNESS="$SCRIPT_DIR/unfathomably-gotosocial-smoke.sh"

if [ ! -f "$FAMILY_HARNESS" ]; then
    printf 'Required account-federation harness not found: %s\n' "$FAMILY_HARNESS" >&2
    exit 1
fi

export SMOKE_PREFIX="${SMOKE_PREFIX:-unfathomably-writefreely-smoke}"
export BE_HOST="${BE_HOST:-unfathomably-writefreely.test}"
export BE_PORT="${BE_PORT:-5011}"
export BE_DB_NAME="${BE_DB_NAME:-unfathomably_writefreely_smoke_be}"
export GTS_HOST="${GTS_HOST:-writefreely-ref.test}"
export GTS_PORT="${GTS_PORT:-5012}"
export GTS_APP_PORT="${GTS_APP_PORT:-8080}"
export GTS_LABEL=WriteFreely
export GTS_USERNAME="${WRITEFREELY_USERNAME:-writer}"
export GTS_IMAGE="${WRITEFREELY_IMAGE:-writeas/writefreely:latest}"

# shellcheck source=unfathomably-gotosocial-smoke.sh
source "$FAMILY_HARNESS"

WF_DATA_VOLUME="${PREFIX}-writefreely-data"
WF_CONFIG="$WORK_DIR/writefreely/config.ini"
WF_ACTOR="http://$GTS_HOST/api/collections/$GTS_USERNAME"

# The shared harness owns one peer volume. WriteFreely separates its keyring
# from its database, so its cleanup extends the shared contract by one volume.
cleanup() {
    local status="$?"

    if [ "$KEEP_CONTAINERS" = "1" ]; then
        printf '\nKEEP_CONTAINERS=1, leaving containers and work directory in place.\n' >&2
        exit "$status"
    fi

    docker rm -f \
        "$GTS_PROXY_CONTAINER" \
        "$GTS_CONTAINER" \
        "$BE_PROXY_CONTAINER" \
        "$BE_CONTAINER" \
        "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    docker volume rm "$GTS_VOLUME" "$WF_DATA_VOLUME" >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR"
    exit "$status"
}

write_wf_config() {
    mkdir -p "$(dirname "$WF_CONFIG")"

    cat >"$WF_CONFIG" <<EOF
[server]
port                  = $GTS_APP_PORT
bind                  = 0.0.0.0
templates_parent_dir  = /go
static_parent_dir     = /go
pages_parent_dir      = /go
keys_parent_dir       = /go/keys
hash_seed             = unfathomably-writefreely-smoke

[database]
type                  = sqlite3
filename              = /data/writefreely.db

[app]
site_name             = Unfathomably WriteFreely Smoke
site_description      = Local federation compatibility peer
host                  = http://$GTS_HOST
theme                 = write
editor                = pad
single_user           = true
open_registration     = false
open_deletion         = false
min_username_len      = 3
max_blogs             = 1
federation            = true
public_stats          = true
private               = false
local_timeline        = true
default_visibility    = public
update_checks         = false
EOF
}

wf_run_once() {
    docker run --rm \
        --network "$NETWORK" \
        -v "$WF_CONFIG:/go/config.ini:ro" \
        -v "$GTS_VOLUME:/go/keys" \
        -v "$WF_DATA_VOLUME:/data" \
        "$GTS_IMAGE" "$@"
}

start_writefreely() {
    docker volume create "$GTS_VOLUME" >/dev/null
    docker volume create "$WF_DATA_VOLUME" >/dev/null

    # The official image runs as Alpine's daemon user (uid 2).
    docker run --rm -v "$GTS_VOLUME:/keys" -v "$WF_DATA_VOLUME:/data" \
        alpine:3.21 chown -R 2:2 /keys /data

    wf_run_once --init-db >/dev/null
    wf_run_once --gen-keys >/dev/null
    wf_run_once --create-admin "$GTS_USERNAME:$PASSWORD" >/dev/null

    docker run -d \
        --name "$GTS_CONTAINER" \
        --hostname "$GTS_APP_HOST" \
        --network "$NETWORK" \
        --network-alias "$GTS_APP_HOST" \
        -v "$WF_CONFIG:/go/config.ini:ro" \
        -v "$GTS_VOLUME:/go/keys" \
        -v "$WF_DATA_VOLUME:/data" \
        "$GTS_IMAGE" >/dev/null
}

wait_writefreely() {
    for _ in $(seq 1 90); do
        if curl -fsS "$GTS_BASE/.well-known/webfinger?resource=acct:$GTS_USERNAME@$GTS_HOST" >/dev/null 2>&1; then
            return 0
        fi

        sleep 2
    done

    docker logs "$GTS_CONTAINER" >&2 || true
    fail "Timed out waiting for WriteFreely at $GTS_BASE"
}

wf_json() {
    local method="$1"
    local path="$2"
    local token="$3"
    local expected="$4"
    local payload="${5:-}"
    local args=(-sS -X "$method" -w '\n%{http_code}' -H 'Accept: application/json')

    if [ -n "$token" ]; then
        # WriteFreely access tokens are sent raw, without the Bearer scheme.
        args+=(-H "Authorization: $token")
    fi

    if [ -n "$payload" ]; then
        args+=(-H 'Content-Type: application/json' --data "$payload")
    fi

    local response status body
    response="$(curl "${args[@]}" "$GTS_BASE$path")" || return 1
    status="${response##*$'\n'}"
    body="${response%$'\n'*}"

    if [ "$status" != "$expected" ]; then
        printf 'Unexpected WriteFreely HTTP status for %s %s: expected %s got %s\n' \
            "$method" "$path" "$expected" "$status" >&2
        printf '%s\n' "$body" >&2
        return 1
    fi

    printf '%s\n' "$body"
}

create_wf_token() {
    local payload result

    payload="$(WF_USER="$GTS_USERNAME" WF_PASSWORD="$PASSWORD" python3 - <<'PY'
import json
import os

print(json.dumps({
    "alias": os.environ["WF_USER"],
    "pass": os.environ["WF_PASSWORD"],
}))
PY
)"
    result="$(wf_json POST /auth/login "" 200 "$payload")"
    json_get "$result" data.access_token
}

poll_wf_followers() {
    local count="$1"
    local message="$2"

    poll_json_assert \
        "curl -fsS -H 'Accept: application/activity+json' '$GTS_BASE/api/collections/$GTS_USERNAME/followers'" \
        "int(data.get('totalItems') or 0) == $count" \
        "$message" >/dev/null
}

write_be_secret
write_proxy_configs
write_wf_config

log "Creating Docker network"
docker rm -f \
    "$GTS_PROXY_CONTAINER" \
    "$GTS_CONTAINER" \
    "$BE_PROXY_CONTAINER" \
    "$BE_CONTAINER" \
    "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
docker network rm "$NETWORK" >/dev/null 2>&1 || true
docker volume rm "$GTS_VOLUME" "$WF_DATA_VOLUME" >/dev/null 2>&1 || true
docker network create "$NETWORK" >/dev/null

log "Starting database and stock WriteFreely"
docker run -d \
    --name "$BE_DB_CONTAINER" \
    --network "$NETWORK" \
    -e POSTGRES_PASSWORD="$BE_DB_PASSWORD" \
    "$POSTGRES_IMAGE" >/dev/null

wait_postgres
prepare_database
start_writefreely
start_gts_proxy
wait_writefreely
WF_TOKEN="$(create_wf_token)"

log "Migrating and starting Unfathomably"
migrate_and_create_be_user alice "alice@$BE_HOST"
start_be
start_be_proxy
wait_be
ALICE_TOKEN="$(create_be_token alice)"

log "Following WriteFreely from Unfathomably"
WF_ACCOUNT_ID="$(resolve_account_id "$BE_BASE" "$ALICE_TOKEN" "$WF_ACTOR" "Unfathomably could not resolve the WriteFreely actor")"
WF_FOLLOW="$(http_form POST "$BE_BASE/api/v1/accounts/$WF_ACCOUNT_ID/follow" "$ALICE_TOKEN" 200)"
json_assert "$WF_FOLLOW" 'data.get("following") is True or data.get("requested") is True' "Unfathomably could not follow WriteFreely"
poll_wf_followers 1 "WriteFreely did not register its Unfathomably follower"

log "Testing WriteFreely article delivery, Like, Undo Like, and Delete"
WF_TITLE="WriteFreely to Unfathomably $(basename "$WORK_DIR")"
WF_POST_PAYLOAD="$(WF_TITLE="$WF_TITLE" python3 - <<'PY'
import json
import os

print(json.dumps({
    "title": os.environ["WF_TITLE"],
    "body": "Long-form ActivityPub smoke article.",
}))
PY
)"
WF_POST="$(wf_json POST "/api/collections/$GTS_USERNAME/posts" "$WF_TOKEN" 201 "$WF_POST_PAYLOAD")"
WF_POST_ID="$(json_get "$WF_POST" data.id)"
BE_VIEW_ID="$(poll_home_status_by_text "$BE_BASE" "$ALICE_TOKEN" "$WF_TITLE" "Unfathomably did not receive the WriteFreely article")"

BE_LIKE="$(http_form POST "$BE_BASE/api/v1/statuses/$BE_VIEW_ID/favourite" "$ALICE_TOKEN" 200)"
json_assert "$BE_LIKE" 'data.get("favourited") is True' "Unfathomably could not Like the WriteFreely article"

BE_UNLIKE="$(http_form POST "$BE_BASE/api/v1/statuses/$BE_VIEW_ID/unfavourite" "$ALICE_TOKEN" 200)"
json_assert "$BE_UNLIKE" 'data.get("favourited") is False' "Unfathomably could not Undo Like on WriteFreely"

# WriteFreely acknowledges both activities, but its database and public Note
# representation have no field for retaining a remote Like.  The actions above
# still exercise Unfathomably's outgoing federation path without claiming that
# the peer exposes state it does not implement.

# WriteFreely has no Create callback in its inbox. Sending a reply still
# verifies that Unfathomably produces a valid outgoing Note without mistaking
# WriteFreely's HTTP 200 acknowledgement for stored comment support.
BE_REPLY_TEXT="Unfathomably reply unsupported by WriteFreely $(basename "$WORK_DIR")"
BE_REPLY="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
    "status=$BE_REPLY_TEXT" \
    "in_reply_to_id=$BE_VIEW_ID")"
BE_REPLY_ID="$(json_get "$BE_REPLY" id)"
http_form DELETE "$BE_BASE/api/v1/statuses/$BE_REPLY_ID" "$ALICE_TOKEN" 200 >/dev/null

wf_json DELETE "/api/posts/$WF_POST_ID" "$WF_TOKEN" 204 >/dev/null
poll_status_missing "$BE_BASE" "$ALICE_TOKEN" "$BE_VIEW_ID" "Unfathomably retained the deleted WriteFreely article"

log "Testing WriteFreely unfollow and Unfathomably block state"
http_form POST "$BE_BASE/api/v1/accounts/$WF_ACCOUNT_ID/unfollow" "$ALICE_TOKEN" 200 >/dev/null
poll_wf_followers 0 "WriteFreely retained the Unfathomably follower after Undo Follow"

BE_BLOCK="$(http_form POST "$BE_BASE/api/v1/accounts/$WF_ACCOUNT_ID/block" "$ALICE_TOKEN" 200)"
json_assert "$BE_BLOCK" 'data.get("blocking") is True' "Unfathomably did not retain its WriteFreely block"
http_form POST "$BE_BASE/api/v1/accounts/$WF_ACCOUNT_ID/unblock" "$ALICE_TOKEN" 200 >/dev/null

check_logs "$BE_CONTAINER" "Unfathomably"
check_logs "$GTS_CONTAINER" "WriteFreely"

cat <<EOF

WriteFreely federation smoke passed.

Covered against stock WriteFreely:
* supported: Unfathomably follows and unfollows a WriteFreely blog actor
* supported: WriteFreely article delivery into Unfathomably
* supported: WriteFreely sends Delete and Unfathomably removes the article
* supported: Unfathomably locally blocks and unblocks WriteFreely
* not_supported: WriteFreely acknowledges but does not retain Like or Undo Like
* not_supported: WriteFreely does not follow remote Person or Group actors
* not_supported: WriteFreely does not store inbound Note replies
* not_supported: WriteFreely does not publish comments
* not_supported: WriteFreely does not implement federated moderation actions
* not_supported: WriteFreely has no durable signal that a remote server defederated it
EOF

# end of build_scripts/unfathomably-writefreely-smoke.sh
