#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-fedigroups-smoke.sh
#
# Purpose:
#
#   Run the upstream FediGroups bot on a stock GoToSocial group account and
#   exercise that emulated-group contract against Unfathomably.
#
# Responsibilities:
#
#   * build and run the real upstream FediGroups daemon
#   * test member follow-back, leave, sharing, announcements, and moderation
#   * test posts, replies, deletes, likes, and unlikes through the group account
#   * report operations that an emulated Mastodon-API group cannot observe
#
# This file intentionally does NOT contain:
#
#   * a synthetic ActivityPub Group actor
#   * patched FediGroups or GoToSocial source
#   * production bot credentials or configuration
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAMILY_HARNESS="$SCRIPT_DIR/unfathomably-gotosocial-smoke.sh"

if [ ! -f "$FAMILY_HARNESS" ]; then
    printf 'Required account-federation harness not found: %s\n' "$FAMILY_HARNESS" >&2
    exit 1
fi

export SMOKE_PREFIX="${SMOKE_PREFIX:-unfathomably-fedgroups-smoke}"
export BE_HOST="${BE_HOST:-unfathomably-fedgroups.test}"
export BE_PORT="${BE_PORT:-5015}"
export BE_DB_NAME="${BE_DB_NAME:-unfathomably_fedigroups_smoke_be}"
export GTS_HOST="${GTS_HOST:-fedigroups-ref.test}"
export GTS_PORT="${GTS_PORT:-5016}"
export GTS_APP_PORT="${GTS_APP_PORT:-8080}"
export GTS_LABEL=FediGroups
export GTS_USERNAME="${FEDIGROUPS_USERNAME:-groupbot}"
export GTS_GROUP_NAME="${GTS_GROUP_NAME:-unfathomably_fedigroups_native_group}"
export GTS_PROXY_USER_AGENT="${GTS_PROXY_USER_AGENT:-FediGroups federation smoke}"

# shellcheck source=unfathomably-gotosocial-smoke.sh
source "$FAMILY_HARNESS"

FEDIGROUPS_GIT_URL="${FEDIGROUPS_GIT_URL:-https://git.ondrovo.com/MightyPork/group-actor.git}"
FEDIGROUPS_GIT_REF="${FEDIGROUPS_GIT_REF:-master}"
FEDIGROUPS_IMAGE="${FEDIGROUPS_IMAGE:-unfathomably-fedigroups-smoke:upstream}"
FEDIGROUPS_CONTAINER="${PREFIX}-fedigroups"
FEDIGROUPS_CONFIG_DIR="$WORK_DIR/fedigroups"
FEDIGROUPS_GROUP_DIR="$FEDIGROUPS_CONFIG_DIR/groups/$GTS_USERNAME@$GTS_HOST"

cleanup() {
    local status="$?"

    if [ "$KEEP_CONTAINERS" = "1" ]; then
        printf '\nKEEP_CONTAINERS=1, leaving containers and work directory in place.\n' >&2
        exit "$status"
    fi

    docker rm -f \
        "$FEDIGROUPS_CONTAINER" \
        "$GTS_PROXY_CONTAINER" \
        "$GTS_CONTAINER" \
        "$BE_PROXY_CONTAINER" \
        "$BE_CONTAINER" \
        "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    docker volume rm "$GTS_VOLUME" >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR"
    exit "$status"
}

ensure_fedigroups_image() {
    local build_context="$WORK_DIR/fedigroups-image"

    if docker image inspect "$FEDIGROUPS_IMAGE" >/dev/null 2>&1; then
        return 0
    fi

    mkdir -p "$build_context"
    log "Building upstream FediGroups from $FEDIGROUPS_GIT_URL#$FEDIGROUPS_GIT_REF"

    docker build -t "$FEDIGROUPS_IMAGE" -f - "$build_context" <<EOF
FROM rust:1.88-bookworm AS build
RUN cargo install --locked --git $FEDIGROUPS_GIT_URL --branch $FEDIGROUPS_GIT_REF --root /opt/fedigroups

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /opt/fedigroups/bin/fedigroups /usr/local/bin/fedigroups
WORKDIR /work
ENTRYPOINT ["fedigroups"]
EOF
}

write_fedigroups_config() {
    local token="$1"

    mkdir -p "$FEDIGROUPS_GROUP_DIR"

    cat >"$FEDIGROUPS_CONFIG_DIR/groups.json" <<EOF
{
  "groups_dir": "groups",
  "locales_dir": "locales",
  "validate_locales": false,
  "max_catchup_notifs": 50,
  "max_catchup_statuses": 50,
  "delay_fetch_page_s": 0.05,
  "delay_after_post_s": 0.05,
  "delay_reopen_closed_s": 0.5,
  "delay_reopen_error_s": 1.0,
  "socket_alive_timeout_s": 15.0,
  "socket_retire_time_s": 60.0
}
EOF

    cat >"$FEDIGROUPS_GROUP_DIR/config.json" <<EOF
{
  "enabled": true,
  "locale": "en",
  "acct": "$GTS_USERNAME@$GTS_HOST",
  "character_limit": 5000,
  "appdata": {
    "base": "http://$GTS_HOST",
    "client_id": "unfathomably-fedigroups-smoke",
    "client_secret": "unfathomably-fedigroups-smoke",
    "redirect": "urn:ietf:wg:oauth:2.0:oob",
    "token": "$token"
  }
}
EOF

    cat >"$FEDIGROUPS_GROUP_DIR/control.json" <<EOF
{
  "group_tags": ["fedigroupssmoke"],
  "admin_users": ["alice@$BE_HOST"],
  "member_users": [],
  "banned_users": [],
  "optout_users": [],
  "member_only": false,
  "banned_servers": []
}
EOF

    cat >"$FEDIGROUPS_GROUP_DIR/state.json" <<'EOF'
{
  "last_notif_ts": 0,
  "last_status_ts": 0
}
EOF
}

start_fedigroups() {
    ensure_fedigroups_image

    #
    # Upstream v0.4.6 starts at debug level. A second -v advances past the
    # five-entry log-level array because its clamp includes the array length.
    # One -v enables trace output without triggering that startup panic.
    #
    docker run -d \
        --name "$FEDIGROUPS_CONTAINER" \
        --hostname "$FEDIGROUPS_CONTAINER" \
        --network "$NETWORK" \
        -v "$FEDIGROUPS_CONFIG_DIR:/work" \
        "$FEDIGROUPS_IMAGE" -v >/dev/null
}

poll_relationship_value() {
    local base="$1"
    local token="$2"
    local account_id="$3"
    local field="$4"
    local expected="$5"
    local message="$6"

    poll_json_assert \
        "http_form GET '$base/api/v1/accounts/relationships?id[]=$account_id' '$token' 200" \
        "len(data) >= 1 and data[0].get('$field') is $expected" \
        "$message" >/dev/null
}

poll_fedigroups_control() {
    local expression="$1"
    local message="$2"
    local value=""

    for _ in $(seq 1 90); do
        value="$(cat "$FEDIGROUPS_GROUP_DIR/control.json" 2>/dev/null || true)"

        if [ -n "$value" ] && JSON_INPUT="$value" python3 - "$expression" <<'PY'
import json
import os
import sys

data = json.loads(os.environ["JSON_INPUT"])
if not eval(sys.argv[1], {"__builtins__": {}}, {"data": data}):
    raise SystemExit(1)
PY
        then
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$value" >&2
    fail "$message"
}

write_be_secret
write_proxy_configs

log "Creating Docker network"
docker rm -f \
    "$FEDIGROUPS_CONTAINER" \
    "$GTS_PROXY_CONTAINER" \
    "$GTS_CONTAINER" \
    "$BE_PROXY_CONTAINER" \
    "$BE_CONTAINER" \
    "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
docker network rm "$NETWORK" >/dev/null 2>&1 || true
docker volume rm "$GTS_VOLUME" >/dev/null 2>&1 || true
docker network create "$NETWORK" >/dev/null

log "Starting database and stock GoToSocial host for FediGroups"
docker run -d \
    --name "$BE_DB_CONTAINER" \
    --network "$NETWORK" \
    -e POSTGRES_PASSWORD="$BE_DB_PASSWORD" \
    "$POSTGRES_IMAGE" >/dev/null

wait_postgres
prepare_database
start_gotosocial
start_gts_proxy
wait_gotosocial
create_gts_user "$GTS_USERNAME" "$GTS_USERNAME@$GTS_HOST"
GTS_TOKEN="$(create_gts_token "$GTS_USERNAME" "$GTS_USERNAME@$GTS_HOST")"
GTS_CREDENTIALS="$(http_form PATCH "$GTS_BASE/api/v1/accounts/update_credentials" \
    "$GTS_TOKEN" 200 "locked=false")"
json_assert "$GTS_CREDENTIALS" 'data.get("locked") is False' \
    "FediGroups smoke account could not be unlocked"
write_fedigroups_config "$GTS_TOKEN"

log "Migrating and starting Unfathomably"
migrate_and_create_be_user alice "alice@$BE_HOST"
create_be_user bob "bob@$BE_HOST"
start_be
start_be_proxy
wait_be
ALICE_TOKEN="$(create_be_token alice)"
BOB_TOKEN="$(create_be_token bob)"
start_fedigroups

log "Testing FediGroups member follow-back"
FEDIGROUPS_ACCOUNT_ID="$(resolve_account_id "$BE_BASE" "$ALICE_TOKEN" \
    "http://$GTS_HOST/users/$GTS_USERNAME" \
    "Unfathomably could not resolve the FediGroups account")"
ALICE_FOLLOW="$(http_form POST "$BE_BASE/api/v1/accounts/$FEDIGROUPS_ACCOUNT_ID/follow" "$ALICE_TOKEN" 200)"
json_assert "$ALICE_FOLLOW" \
    'data.get("following") is True or data.get("requested") is True' \
    "Unfathomably could not follow FediGroups"

GTS_ALICE_ID="$(resolve_account_id "$GTS_BASE" "$GTS_TOKEN" "alice@$BE_HOST" \
    "FediGroups host could not resolve Alice")"
poll_relationship_following "$GTS_BASE" "$GTS_TOKEN" "$GTS_ALICE_ID" \
    "FediGroups did not follow its new member back"
poll_relationship_value "$BE_BASE" "$ALICE_TOKEN" "$FEDIGROUPS_ACCOUNT_ID" followed_by True \
    "Unfathomably did not register the FediGroups follow-back"
poll_fedigroups_control \
    "'alice@$BE_HOST' in data.get('member_users', [])" \
    "FediGroups did not retain Alice as a member"
BE_WELCOME_ID="$(poll_home_status_by_text "$BE_BASE" "$ALICE_TOKEN" \
    'Welcome to the group!' \
    "Unfathomably did not receive the FediGroups welcome message")"

log "Testing group sharing, likes, replies, and deletes"
BE_SHARED_TEXT="FediGroups shared post $(basename "$WORK_DIR")"
BE_SHARED="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
    "status=$BE_SHARED_TEXT #fedigroupssmoke")"
BE_SHARED_ID="$(json_get "$BE_SHARED" id)"
BE_SHARED_URI="$(json_get "$BE_SHARED" uri)"
GTS_SHARED_ID="$(resolve_status_id "$GTS_BASE" "$GTS_TOKEN" "$BE_SHARED_URI" \
    "FediGroups host could not resolve the shared post")"
poll_json_assert \
    "http_form GET '$GTS_BASE/api/v1/statuses/$GTS_SHARED_ID' '$GTS_TOKEN' 200" \
    'data.get("reblogged") is True' \
    "FediGroups did not boost the mentioned member post" >/dev/null

GTS_LIKE="$(http_form POST "$GTS_BASE/api/v1/statuses/$GTS_SHARED_ID/favourite" "$GTS_TOKEN" 200)"
json_assert "$GTS_LIKE" 'data.get("favourited") is True' \
    "FediGroups account could not Like the Unfathomably post"
poll_status_count "$BE_BASE" "$ALICE_TOKEN" "$BE_SHARED_ID" \
    'int(data.get("favourites_count") or 0) >= 1' \
    "Unfathomably did not receive the FediGroups Like"
http_form POST "$GTS_BASE/api/v1/statuses/$GTS_SHARED_ID/unfavourite" "$GTS_TOKEN" 200 >/dev/null
poll_status_count "$BE_BASE" "$ALICE_TOKEN" "$BE_SHARED_ID" \
    'int(data.get("favourites_count") or 0) == 0' \
    "Unfathomably did not receive the FediGroups Undo Like"

GROUP_REPLY_TEXT="FediGroups account reply $(basename "$WORK_DIR")"
GROUP_REPLY="$(http_form POST "$GTS_BASE/api/v1/statuses" "$GTS_TOKEN" 200 \
    "status=$GROUP_REPLY_TEXT" \
    "in_reply_to_id=$GTS_SHARED_ID")"
GROUP_REPLY_ID="$(json_get "$GROUP_REPLY" id)"
GROUP_REPLY_URI="$(json_get "$GROUP_REPLY" uri)"
poll_context_status_by_text "$BE_BASE" "$ALICE_TOKEN" "$BE_SHARED_ID" "$GROUP_REPLY_TEXT" \
    "Unfathomably did not receive the FediGroups account reply"
BE_GROUP_REPLY_ID="$(resolve_status_id "$BE_BASE" "$ALICE_TOKEN" "$GROUP_REPLY_URI" \
    "Unfathomably could not resolve the FediGroups account reply")"
http_form DELETE "$GTS_BASE/api/v1/statuses/$GROUP_REPLY_ID" "$GTS_TOKEN" 200 >/dev/null
poll_status_missing "$BE_BASE" "$ALICE_TOKEN" "$BE_GROUP_REPLY_ID" \
    "Unfathomably retained the deleted FediGroups account reply"

log "Testing FediGroups announcement creation and deletion"
ANNOUNCEMENT_TEXT="FediGroups announcement $(basename "$WORK_DIR")"
http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
    "status=/announce $ANNOUNCEMENT_TEXT" \
    "in_reply_to_id=$BE_WELCOME_ID" >/dev/null
BE_ANNOUNCEMENT_ID="$(poll_account_status_by_text "$BE_BASE" "$ALICE_TOKEN" \
    "$FEDIGROUPS_ACCOUNT_ID" "$ANNOUNCEMENT_TEXT" \
    "Unfathomably did not receive the FediGroups announcement")"

BE_LIKE="$(http_form POST "$BE_BASE/api/v1/statuses/$BE_ANNOUNCEMENT_ID/favourite" "$ALICE_TOKEN" 200)"
json_assert "$BE_LIKE" 'data.get("favourited") is True' \
    "Unfathomably could not Like the FediGroups announcement"
BE_ANNOUNCEMENT="$(http_form GET "$BE_BASE/api/v1/statuses/$BE_ANNOUNCEMENT_ID" "$ALICE_TOKEN" 200)"
GTS_ANNOUNCEMENT_ID="$(resolve_status_id "$GTS_BASE" "$GTS_TOKEN" "$(json_get "$BE_ANNOUNCEMENT" uri)" \
    "FediGroups host could not resolve its announcement")"
poll_status_count "$GTS_BASE" "$GTS_TOKEN" "$GTS_ANNOUNCEMENT_ID" \
    'int(data.get("favourites_count") or 0) >= 1' \
    "FediGroups host did not receive the Unfathomably Like"
http_form POST "$BE_BASE/api/v1/statuses/$BE_ANNOUNCEMENT_ID/unfavourite" "$ALICE_TOKEN" 200 >/dev/null
poll_status_count "$GTS_BASE" "$GTS_TOKEN" "$GTS_ANNOUNCEMENT_ID" \
    'int(data.get("favourites_count") or 0) == 0' \
    "FediGroups host did not receive the Unfathomably Undo Like"

http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
    "status=/delete" \
    "in_reply_to_id=$BE_ANNOUNCEMENT_ID" >/dev/null
poll_status_missing "$BE_BASE" "$ALICE_TOKEN" "$BE_ANNOUNCEMENT_ID" \
    "Unfathomably retained the FediGroups announcement after the admin delete command"

log "Testing FediGroups member moderation"
BOB_GROUP_ID="$(resolve_account_id "$BE_BASE" "$BOB_TOKEN" "$GTS_USERNAME@$GTS_HOST" \
    "Bob could not resolve FediGroups")"
http_form POST "$BE_BASE/api/v1/accounts/$BOB_GROUP_ID/follow" "$BOB_TOKEN" 200 >/dev/null
GTS_BOB_ID="$(resolve_account_id "$GTS_BASE" "$GTS_TOKEN" "bob@$BE_HOST" \
    "FediGroups host could not resolve Bob")"
poll_relationship_following "$GTS_BASE" "$GTS_TOKEN" "$GTS_BOB_ID" \
    "FediGroups did not follow Bob back"

http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
    "status=/ban bob@$BE_HOST" \
    "in_reply_to_id=$BE_WELCOME_ID" >/dev/null
poll_fedigroups_control \
    "'bob@$BE_HOST' in data.get('banned_users', [])" \
    "FediGroups did not retain the moderated member ban"
poll_relationship_value "$GTS_BASE" "$GTS_TOKEN" "$GTS_BOB_ID" following False \
    "FediGroups retained its follow of the banned member"

BOB_BLOCK="$(http_form POST "$BE_BASE/api/v1/accounts/$BOB_GROUP_ID/block" "$BOB_TOKEN" 200)"
json_assert "$BOB_BLOCK" 'data.get("blocking") is True' \
    "Unfathomably did not retain Bob's local FediGroups block"
http_form POST "$BE_BASE/api/v1/accounts/$BOB_GROUP_ID/unblock" "$BOB_TOKEN" 200 >/dev/null

log "Testing group leave and unfollow"
http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
    "status=/leave" \
    "in_reply_to_id=$BE_WELCOME_ID" >/dev/null
poll_relationship_value "$GTS_BASE" "$GTS_TOKEN" "$GTS_ALICE_ID" following False \
    "FediGroups retained its follow after Alice left the group"
http_form POST "$BE_BASE/api/v1/accounts/$FEDIGROUPS_ACCOUNT_ID/unfollow" "$ALICE_TOKEN" 200 >/dev/null
poll_relationship_value "$BE_BASE" "$ALICE_TOKEN" "$FEDIGROUPS_ACCOUNT_ID" following False \
    "Unfathomably retained its FediGroups follow after unfollow"

check_logs "$BE_CONTAINER" "Unfathomably"
check_logs "$GTS_CONTAINER" "FediGroups GoToSocial host"
check_logs "$FEDIGROUPS_CONTAINER" "FediGroups daemon"

cat <<EOF

FediGroups federation smoke passed.

Covered against the real upstream FediGroups daemon:
* supported: member follow, automatic follow-back, leave, and unfollow
* supported: member hashtag posts are boosted to the emulated group
* supported: group announcements are created and deleted by admin commands
* supported: comments and comment deletes from the underlying group account
* supported: Likes and Undo Likes in both directions
* supported: member moderation bans and local account blocking
* not_supported: FediGroups is a Person-account bot, not an ActivityPub Group actor
* not_supported: FediGroups does not send ActivityPub Block for its member bans
* not_supported: FediGroups cannot know that another server defederated it
EOF

# end of build_scripts/unfathomably-fedigroups-smoke.sh
