#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-ibis-smoke.sh
#
# Purpose:
#
#   Run an unmodified Ibis instance against Unfathomably and verify the
#   federation contract used by its encyclopedia instances, articles, edits,
#   and comments.
#
# Responsibilities:
#
#   * boot the official Ibis image and PostgreSQL on an isolated TLS network
#   * create wiki state through the stock Ibis HTTP API
#   * exercise instance and person follows, article updates, comments, Deletes,
#     Undo boundaries, collections, and concurrency behavior
#   * verify that Ibis Article and Patch vocabulary remains bounded and native
#   * report stock Ibis limitations without substituting synthetic activities
#
# This file intentionally does NOT contain:
#
#   * patched Ibis source or images
#   * hand-authored Ibis ActivityPub payloads
#   * browser automation or production credentials
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAMILY_HARNESS="$SCRIPT_DIR/unfathomably-gotosocial-smoke.sh"

if [ ! -f "$FAMILY_HARNESS" ]; then
    printf 'Required account-federation harness not found: %s\n' "$FAMILY_HARNESS" >&2
    exit 1
fi

export SMOKE_PREFIX="${SMOKE_PREFIX:-unfathomably-ibis-smoke}"
export BE_HOST="${BE_HOST:-unfathomably-ibis.example.com}"
export BE_PORT="${BE_PORT:-5051}"
export BE_DB_NAME="${BE_DB_NAME:-unfathomably_ibis_smoke_be}"
export GTS_HOST="${GTS_HOST:-ibis-ref.example.com}"
export GTS_PORT="${GTS_PORT:-5052}"
export GTS_APP_PORT=3000
export GTS_FORWARDED_PROTO=https
export GTS_LABEL=Ibis
export GTS_USERNAME=editor
export SMOKE_TLS=1
export BE_FEDERATION_SCHEME=https
export BE_FEDERATION_PORT=443

# shellcheck source-path=SCRIPTDIR
# shellcheck source=unfathomably-gotosocial-smoke.sh
source "$FAMILY_HARNESS"

IBIS_IMAGE="${IBIS_IMAGE:-nutomic/ibis:0.3.3}"
IBIS_DB_IMAGE="${IBIS_DB_IMAGE:-postgres:16-alpine}"
IBIS_DB_CONTAINER="${PREFIX}-ibis-db"
IBIS_DB_PASSWORD="${IBIS_DB_PASSWORD:-ibis-smoke-database-password}"
IBIS_PASSWORD="${IBIS_PASSWORD:-Ibis-smoke-password-12345}"
IBIS_CONFIG="$WORK_DIR/ibis-config.toml"
IBIS_CA_BUNDLE="$WORK_DIR/ibis-ca-bundle.crt"
IBIS_LOGIN_HEADERS="$WORK_DIR/ibis-login.headers"
IBIS_AUTH=""

poll_group_status_by_text() {
    local base="$1"
    local token="$2"
    local group_id="$3"
    local text="$4"
    local message="$5"
    local result=""
    local id=""

    for _ in $(seq 1 90); do
        result="$(http_form GET "$base/api/v1/timelines/group/$group_id?limit=40" \
            "$token" 200 || true)"

        id="$(
            JSON_INPUT="$result" EXPECTED_TEXT="$text" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
text = os.environ["EXPECTED_TEXT"]
for status in data:
    content = status.get("content") or status.get("text") or ""
    if text in content:
        print(status["id"])
        raise SystemExit(0)
raise SystemExit(1)
PY
        )" && {
            printf '%s\n' "$id"
            return 0
        }

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

poll_relationship_not_following() {
    local base="$1"
    local token="$2"
    local account_id="$3"
    local message="$4"

    poll_json_assert \
        "http_form GET '$base/api/v1/accounts/relationships?id[]=$account_id' '$token' 200" \
        'len(data) >= 1 and data[0].get("following") is not True and data[0].get("requested") is not True' \
        "$message" >/dev/null
}

poll_rejected_person_undo() {
    local actor_id="$1"
    local target_id="$2"
    local publish_count=""
    local rejected_delivery_count=""

    case "$actor_id$target_id$GTS_HOST" in
        *"'"*) fail "Unsafe quote in Ibis Person Undo assertion input" ;;
    esac

    for _ in $(seq 1 60); do
        publish_count="$(
            docker exec "$BE_DB_CONTAINER" \
                psql -U postgres -d "$BE_DB_NAME" -At \
                -c "SELECT count(*)
                      FROM oban_jobs
                     WHERE worker = 'Pleroma.Workers.PublisherWorker'
                       AND args->>'op' = 'publish'
                       AND args->'activity_data'->>'type' = 'Undo'
                       AND args->'activity_data'->'object'->>'type' = 'Follow'
                       AND args::text LIKE '%$actor_id%'
                       AND args::text LIKE '%$target_id%';"
        )"

        rejected_delivery_count="$(
            docker exec "$BE_DB_CONTAINER" \
                psql -U postgres -d "$BE_DB_NAME" -At \
                -c "SELECT count(*)
                      FROM oban_jobs
                     WHERE worker = 'Pleroma.Workers.PublisherWorker'
                       AND args->>'op' = 'publish_one'
                       AND args->'params'->>'inbox' LIKE 'https://$GTS_HOST/%'
                       AND errors::text LIKE '%500%';"
        )"

        if [ "$publish_count" -gt 0 ] && [ "$rejected_delivery_count" -gt 0 ]; then
            return 0
        fi

        sleep 1
    done

    fail "Unfathomably did not emit the Person Undo or observe stock Ibis rejecting it"
}

cleanup() {
    local incoming_status="$?"
    local status="${1:-$incoming_status}"

    if [ "$KEEP_CONTAINERS" = "1" ]; then
        printf '\nKEEP_CONTAINERS=1, leaving containers and work directory in place.\n' >&2
        exit "$status"
    fi

    docker rm -f \
        "$GTS_PROXY_CONTAINER" \
        "$GTS_CONTAINER" \
        "$IBIS_DB_CONTAINER" \
        "$BE_PROXY_CONTAINER" \
        "$BE_CONTAINER" \
        "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    docker volume rm "$GTS_VOLUME" >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR"
    exit "$status"
}

trap cleanup EXIT

write_ibis_config() {
    cat >"$IBIS_CONFIG" <<EOF
domain = "$GTS_HOST"

[database]
connection_url = "postgres://ibis:$IBIS_DB_PASSWORD@$IBIS_DB_CONTAINER:5432/ibis"
pool_size = 10

[setup]
admin_username = "editor"
admin_password = "$IBIS_PASSWORD"
group_name = "wiki"
wiki_bot_name = "wikibot"

[federation]
domain = "$GTS_HOST"

[options]
registration_open = true
email_required = false
EOF
}

prepare_ibis_ca_bundle() {
    if ! docker image inspect "$IBIS_IMAGE" >/dev/null 2>&1; then
        log "Pulling stock Ibis image $IBIS_IMAGE"
        docker pull "$IBIS_IMAGE" >/dev/null
    fi

    docker run --rm --entrypoint /bin/sh "$IBIS_IMAGE" \
        -c 'cat /etc/ssl/certs/ca-certificates.crt' >"$IBIS_CA_BUNDLE"
    cat "$SMOKE_CA_CERT" >>"$IBIS_CA_BUNDLE"
}

wait_ibis_postgres() {
    local stable=0

    for _ in $(seq 1 80); do
        if docker exec "$IBIS_DB_CONTAINER" pg_isready -U ibis -d ibis >/dev/null 2>&1; then
            stable=$((stable + 1))
            if [ "$stable" -ge 3 ]; then
                return 0
            fi
        else
            stable=0
        fi
        sleep 1
    done

    docker logs "$IBIS_DB_CONTAINER" >&2 || true
    fail "Ibis PostgreSQL did not become ready"
}

start_ibis() {
    docker run -d \
        --name "$IBIS_DB_CONTAINER" \
        --hostname "$IBIS_DB_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$IBIS_DB_CONTAINER" \
        -e POSTGRES_USER=ibis \
        -e POSTGRES_PASSWORD="$IBIS_DB_PASSWORD" \
        -e POSTGRES_DB=ibis \
        "$IBIS_DB_IMAGE" >/dev/null
    wait_ibis_postgres

    docker run -d \
        --name "$GTS_CONTAINER" \
        --hostname "$GTS_APP_HOST" \
        --network "$NETWORK" \
        --network-alias "$GTS_APP_HOST" \
        -e LEPTOS_SITE_ADDR=0.0.0.0:3000 \
        -e DANGER_FEDERATION_ALLOW_LOCAL_IP=1 \
        -e RUST_LOG=warn,ibis=info,activitypub_federation=info \
        -e SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
        -v "$IBIS_CONFIG:/config.toml:ro" \
        -v "$IBIS_CA_BUNDLE:/etc/ssl/certs/ca-certificates.crt:ro" \
        "$IBIS_IMAGE" >/dev/null

    start_gts_proxy
}

wait_ibis() {
    for _ in $(seq 1 180); do
        if curl -fsS "$GTS_BASE/api/v1/site" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    docker logs "$GTS_CONTAINER" >&2 || true
    fail "Timed out waiting for stock Ibis at $GTS_BASE"
}

ibis_request() {
    local method="$1"
    local path="$2"
    local expected="$3"
    shift 3

    local headers=(-H 'Accept: application/json')
    local args=(-sS -X "$method" -w '\n%{http_code}')

    if [ -n "$IBIS_AUTH" ]; then
        headers+=(-H "auth: $IBIS_AUTH")
    fi

    if [ "$method" != "GET" ]; then
        headers+=(-H 'Content-Type: application/x-www-form-urlencoded')
        for field in "$@"; do
            args+=(--data-urlencode "$field")
        done
    fi

    local response status body
    response="$(curl "${args[@]}" "${headers[@]}" "$GTS_BASE$path")" || return 1
    status="${response##*$'\n'}"
    body="${response%$'\n'*}"

    if [ "$status" != "$expected" ]; then
        printf 'Unexpected Ibis HTTP status for %s %s: expected %s got %s\n' \
            "$method" "$path" "$expected" "$status" >&2
        printf '%s\n' "$body" >&2
        return 1
    fi

    printf '%s\n' "$body"
}

login_ibis() {
    local response

    response="$(curl -sS -D "$IBIS_LOGIN_HEADERS" \
        -H 'Accept: application/json' \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode 'username_or_email=editor' \
        --data-urlencode "password=$IBIS_PASSWORD" \
        "$GTS_BASE/api/v1/account/login")"

    json_assert "$response" \
        "data.get('person', {}).get('username') == 'editor' and data.get('local_user', {}).get('admin') is True" \
        "Stock Ibis admin login did not return the seeded account"

    IBIS_AUTH="$({ tr -d '\r' <"$IBIS_LOGIN_HEADERS"; } | \
        sed -n 's/^set-cookie: auth=\([^;]*\).*/\1/ip' | head -n 1)"
    [ -n "$IBIS_AUTH" ] || fail "Stock Ibis login did not issue its auth token"
}

ibis_sql_value() {
    local sql="$1"

    docker exec "$IBIS_DB_CONTAINER" psql -U ibis -d ibis -Atq \
        -v ON_ERROR_STOP=1 -c "$sql" | tail -n 1
}

poll_ibis_sql() {
    local sql="$1"
    local expected="$2"
    local message="$3"
    local result=""

    for _ in $(seq 1 60); do
        result="$(ibis_sql_value "$sql" 2>/dev/null || true)"
        if [ "$result" = "$expected" ]; then
            return 0
        fi
        sleep 2
    done

    printf 'Expected %s, got %s\n' "$expected" "$result" >&2
    fail "$message"
}

poll_be_object_field() {
    local ap_id="$1"
    local expression="$2"
    local expected="$3"
    local message="$4"
    local result=""
    local escaped_ap_id="${ap_id//\'/\'\'}"

    for _ in $(seq 1 60); do
        result="$(docker exec "$BE_DB_CONTAINER" psql -U postgres -d "$BE_DB_NAME" -Atq \
            -c "SELECT $expression FROM objects WHERE data->>'id' = '$escaped_ap_id' LIMIT 1;" || true)"
        if [ "$result" = "$expected" ]; then
            return 0
        fi
        sleep 2
    done

    printf 'Expected %s, got %s\n' "$expected" "$result" >&2
    fail "$message"
}

run_ibis_smoke() {
    local nodeinfo_links nodeinfo group_actor group_webfinger group_json
    local person_json be_credentials alice_ap_id group group_actor_id
    local ibis_group_account_id ibis_group ibis_group_id ibis_person_account_id
    local article article_id article_ap_id latest_version article_status_id article_status
    local edits_collection all_articles updated_article updated_version
    local ibis_comment ibis_comment_id ibis_comment_ap_id ibis_comment_status_id ibis_comment_text
    local be_comment be_comment_id be_comment_ap_id be_comment_text
    local conflict_response removed_status

    write_ibis_config
    write_be_secret
    write_proxy_configs

    log "Creating isolated Ibis federation network"
    docker rm -f \
        "$GTS_PROXY_CONTAINER" \
        "$GTS_CONTAINER" \
        "$IBIS_DB_CONTAINER" \
        "$BE_PROXY_CONTAINER" \
        "$BE_CONTAINER" \
        "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    docker network create "$NETWORK" >/dev/null
    prepare_smoke_tls
    prepare_ibis_ca_bundle

    log "Starting PostgreSQL and stock Ibis $IBIS_IMAGE"
    docker run -d \
        --name "$BE_DB_CONTAINER" \
        --hostname "$BE_DB_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$BE_DB_CONTAINER" \
        -e POSTGRES_PASSWORD="$BE_DB_PASSWORD" \
        "$POSTGRES_IMAGE" >/dev/null
    wait_postgres
    prepare_database
    start_ibis
    wait_ibis
    login_ibis

    log "Proving Ibis discovery, actors, collections, and canonical IDs"
    nodeinfo_links="$(http_form GET "$GTS_BASE/.well-known/nodeinfo" "" 200)"
    nodeinfo="$(http_form GET "$GTS_BASE/nodeinfo/2.1.json" "" 200)"
    json_assert "$nodeinfo_links" \
        "any(item.get('href') == 'https://$GTS_HOST/nodeinfo/2.1.json' for item in data.get('links', []))" \
        "Ibis NodeInfo discovery did not expose its canonical HTTPS endpoint"
    json_assert "$nodeinfo" \
        "data.get('software', {}).get('name') == 'ibis' and data.get('software', {}).get('version') == '0.3.3' and 'activitypub' in data.get('protocols', [])" \
        "Ibis NodeInfo did not identify the stock application"

    group_actor="https://$GTS_HOST/"
    group_webfinger="$(http_form GET \
        "$GTS_BASE/.well-known/webfinger?resource=acct:wiki@$GTS_HOST" "" 200)"
    json_assert "$group_webfinger" \
        "any(item.get('href') == '$group_actor' and item.get('type') == 'application/activity+json' for item in data.get('links', []))" \
        "Ibis WebFinger did not expose the canonical instance actor"
    group_json="$(curl -fsS -H 'Accept: application/activity+json' "$GTS_BASE/")"
    json_assert "$group_json" \
        "data.get('id') == '$group_actor' and data.get('type') == 'Group' and data.get('preferredUsername') == 'wiki' and data.get('instances') == 'https://$GTS_HOST/linked_instances' and data.get('outbox') == 'https://$GTS_HOST/all_articles'" \
        "Ibis did not expose its complete native instance actor"
    curl -fsS -H 'Accept: application/ld+json; profile="https://www.w3.org/ns/activitystreams"' \
        "$GTS_BASE/" >/dev/null

    person_json="$(curl -fsS -H 'Accept: application/activity+json' "$GTS_BASE/user/editor")"
    json_assert "$person_json" \
        "data.get('id') == 'https://$GTS_HOST/user/editor' and data.get('type') == 'Person' and data.get('inbox') == 'https://$GTS_HOST/inbox'" \
        "Ibis did not expose its seeded Person actor"

    all_articles="$(curl -fsS -H 'Accept: application/activity+json' "$GTS_BASE/all_articles")"
    json_assert "$all_articles" \
        "data.get('type') == 'Collection' and data.get('id') == 'https://$GTS_HOST/all_articles' and data.get('totalItems') == 1 and len(data.get('items', [])) == 1 and data.get('items', [])[0].get('type') == 'Update' and data.get('items', [])[0].get('object', {}).get('name') == 'Main Page' and data.get('items', [])[0].get('object', {}).get('protected') is True" \
        "Ibis did not expose its protected bootstrap Article in the bounded collection"

    log "Migrating and starting Unfathomably"
    migrate_and_create_be_user alice "alice@$BE_HOST"
    start_be
    start_be_proxy
    wait_be
    ALICE_TOKEN="$(create_be_token alice)"
    be_credentials="$(http_form GET "$BE_BASE/api/v1/accounts/verify_credentials" "$ALICE_TOKEN" 200)"
    alice_ap_id="$(json_get "$be_credentials" pleroma.ap_id)"

    group="$(http_form POST "$BE_BASE/api/v1/groups" "$ALICE_TOKEN" 200 \
        'display_name=Unfathomably Ibis Group' \
        'name=unfathomably_ibis_group' \
        'note=Open group used by the Ibis federation smoke harness.' \
        'locked=false')"
    group_actor_id="$(json_get "$group" ap_id)"
    [ -n "$group_actor_id" ] || fail "Unfathomably did not create its local Group actor"

    log "Following the Ibis instance Group and Person actors"
    ibis_group_account_id="$(resolve_account_id "$BE_BASE" "$ALICE_TOKEN" \
        "wiki@$GTS_HOST" "Unfathomably could not resolve the Ibis instance actor")"
    [ -n "$ibis_group_account_id" ] || fail "Ibis Group account resolution returned no identifier"
    ibis_group="$(http_form GET \
        "$BE_BASE/api/v1/groups/lookup?uri=$(urlencode "$group_actor")" \
        "$ALICE_TOKEN" 200)"
    ibis_group_id="$(json_get "$ibis_group" id)"
    http_form POST "$BE_BASE/api/v1/groups/$ibis_group_id/join" "$ALICE_TOKEN" 200 >/dev/null
    poll_ibis_sql \
        "SELECT COUNT(*) FROM instance_follow f JOIN instance i ON i.id=f.instance_id JOIN person p ON p.id=f.follower_id WHERE i.local AND p.ap_id='$alice_ap_id' AND NOT f.pending" \
        1 "Ibis did not accept Unfathomably's instance Group follow"

    ibis_person_account_id="$(resolve_account_id "$BE_BASE" "$ALICE_TOKEN" \
        "editor@$GTS_HOST" "Unfathomably could not resolve the Ibis Person actor")"
    http_form POST "$BE_BASE/api/v1/accounts/$ibis_person_account_id/follow" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_ibis_sql \
        "SELECT COUNT(*) FROM person_follow f JOIN person followed ON followed.id=f.person_id JOIN person follower ON follower.id=f.follower_id WHERE followed.ap_id='$alice_ap_id' AND follower.ap_id='https://$GTS_HOST/user/editor'" \
        1 "Ibis did not record its stock reversed Person follow relationship"
    poll_ibis_sql \
        "SELECT COUNT(*) FROM person_follow f JOIN person followed ON followed.id=f.person_id JOIN person follower ON follower.id=f.follower_id WHERE followed.ap_id='https://$GTS_HOST/user/editor' AND follower.ap_id='$alice_ap_id'" \
        0 "Ibis unexpectedly recorded the Person follow in the correct direction"
    poll_relationship_following "$BE_BASE" "$ALICE_TOKEN" "$ibis_person_account_id" \
        "Unfathomably did not apply Ibis's Person follow Accept"

    log "Creating an Ibis Article and preserving its native wiki representation"
    article="$(ibis_request POST /api/v1/article 200 \
        'title=Alien Federation Wiki' \
        'text=Original Ibis wiki body.' \
        'summary=Create the stock federation article')"
    article_id="$(json_get "$article" article.id)"
    article_ap_id="$(json_get "$article" article.ap_id)"
    latest_version="$(json_get "$article" latest_version)"

    article_status_id="$(poll_group_status_by_text "$BE_BASE" "$ALICE_TOKEN" \
        "$ibis_group_id" \
        'Original Ibis wiki body' \
        "Unfathomably did not receive Ibis's native Article Update")"
    article_status="$(http_form GET "$BE_BASE/api/v1/statuses/$article_status_id" "$ALICE_TOKEN" 200)"
    json_assert "$article_status" \
        "data.get('uri') == '$article_ap_id' and data.get('pleroma', {}).get('native', {}).get('type') == 'Article' and data.get('pleroma', {}).get('native', {}).get('class') == 'status' and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('edits') == '$article_ap_id/edits' and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('latest_version') == '$latest_version'" \
        "Unfathomably did not expose the bounded native Ibis Article presentation"
    poll_be_object_field "$article_ap_id" "data->>'latestVersion'" "$latest_version" \
        "Unfathomably did not preserve the Ibis Article version"
    poll_be_object_field "$article_ap_id" "data->>'edits'" "$article_ap_id/edits" \
        "Unfathomably did not preserve the Ibis edits collection link"

    edits_collection="$(curl -fsS -H 'Accept: application/activity+json' \
        "$GTS_BASE${article_ap_id#https://"$GTS_HOST"}/edits")"
    json_assert "$edits_collection" \
        "data.get('type') == 'OrderedCollection' and data.get('id') == '$article_ap_id/edits' and data.get('totalItems') == 1 and len(data.get('items', [])) == 1 and data.get('items', [])[0].get('type') == 'Patch' and data.get('items', [])[0].get('object') == '$article_ap_id'" \
        "Ibis did not expose its native bounded Patch collection"

    log "Updating the Ibis Article and checking versioned lifecycle state"
    updated_article="$(ibis_request PATCH /api/v1/article 200 \
        "article_id=$article_id" \
        'new_text=Updated Ibis wiki body.' \
        'summary=Update through the stock Ibis API' \
        "previous_version_id=$latest_version")"
    json_assert "$updated_article" "data is None" \
        "Ibis returned a conflict for a sequential Article edit"
    updated_article="$(ibis_request GET "/api/v1/article?id=$article_id" 200)"
    updated_version="$(json_get "$updated_article" latest_version)"
    [ "$updated_version" != "$latest_version" ] || fail "Ibis did not advance its Article version"
    poll_json_assert \
        "http_form GET '$BE_BASE/api/v1/statuses/$article_status_id' '$ALICE_TOKEN' 200" \
        "'Updated Ibis wiki body' in (data.get('content') or '') and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('latest_version') == '$updated_version'" \
        "Unfathomably did not apply the complete Ibis Article Update" >/dev/null

    conflict_response="$(ibis_request PATCH /api/v1/article 200 \
        "article_id=$article_id" \
        'new_text=Conflicting stale Ibis body.' \
        'summary=Exercise the stock concurrency boundary' \
        "previous_version_id=$latest_version")"
    json_assert "$conflict_response" \
        "data is not None and data.get('article', {}).get('id') == int('$article_id') and data.get('previous_version_id') == '$updated_version'" \
        "Ibis did not classify the stale Article edit as a conflict"

    log "Round-tripping comments and comment Deletes"
    ibis_comment_text="Native Ibis comment $(basename "$WORK_DIR")"
    ibis_comment="$(ibis_request POST /api/v1/comment 200 \
        "content=$ibis_comment_text" \
        "article_id=$article_id")"
    ibis_comment_id="$(json_get "$ibis_comment" comment.id)"
    ibis_comment_ap_id="$(json_get "$ibis_comment" comment.ap_id)"
    poll_context_status_by_text "$BE_BASE" "$ALICE_TOKEN" "$article_status_id" \
        "$ibis_comment_text" "Unfathomably did not receive the native Ibis comment"
    ibis_comment_status_id="$(resolve_status_id "$BE_BASE" "$ALICE_TOKEN" \
        "$ibis_comment_ap_id" "Unfathomably could not resolve the native Ibis comment")"

    be_comment_text="Unfathomably reply to Ibis $(basename "$WORK_DIR")"
    be_comment="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$be_comment_text" "in_reply_to_id=$article_status_id")"
    be_comment_id="$(json_get "$be_comment" id)"
    be_comment_ap_id="$(json_get "$be_comment" uri)"
    poll_ibis_sql \
        "SELECT COUNT(*) FROM comment WHERE ap_id='$be_comment_ap_id' AND content LIKE '%Unfathomably reply to Ibis%' AND NOT deleted" \
        1 "Ibis did not retain the Unfathomably reply as native Comment state"

    http_form DELETE "$BE_BASE/api/v1/statuses/$be_comment_id" "$ALICE_TOKEN" 200 >/dev/null
    poll_ibis_sql \
        "SELECT COUNT(*) FROM comment WHERE ap_id='$be_comment_ap_id' AND deleted" \
        1 "Ibis did not apply Unfathomably's comment Delete"

    ibis_request PATCH /api/v1/comment 200 \
        "id=$ibis_comment_id" 'deleted=true' >/dev/null
    poll_status_missing "$BE_BASE" "$ALICE_TOKEN" "$ibis_comment_status_id" \
        "Unfathomably retained the deleted Ibis comment"

    log "Testing Article removal and the stock reversible Delete boundary"
    ibis_request POST /api/v1/article/remove 200 \
        "article_id=$article_id" 'remove=true' >/dev/null
    sleep 5
    removed_status="$(curl -sS -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer $ALICE_TOKEN" \
        "$BE_BASE/api/v1/statuses/$article_status_id")"
    [ "$removed_status" = "404" ] || [ "$removed_status" = "410" ] || \
        fail "Unfathomably retained the Ibis Article after its native Delete"

    ibis_request POST /api/v1/article/remove 200 \
        "article_id=$article_id" 'remove=false' >/dev/null
    sleep 5

    log "Cleaning up instance and Person follows"
    http_form POST "$BE_BASE/api/v1/groups/$ibis_group_id/leave" "$ALICE_TOKEN" 200 >/dev/null
    poll_ibis_sql \
        "SELECT COUNT(*) FROM instance_follow f JOIN instance i ON i.id=f.instance_id JOIN person p ON p.id=f.follower_id WHERE i.local AND p.ap_id='$alice_ap_id'" \
        0 "Ibis retained Unfathomably's undone instance Group follow"
    http_form POST "$BE_BASE/api/v1/accounts/$ibis_person_account_id/unfollow" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_relationship_not_following "$BE_BASE" "$ALICE_TOKEN" "$ibis_person_account_id" \
        "Unfathomably retained its local Ibis Person follow after unfollow"
    poll_rejected_person_undo "$alice_ap_id" "https://$GTS_HOST/user/editor"
    poll_ibis_sql \
        "SELECT COUNT(*) FROM person_follow f JOIN person followed ON followed.id=f.person_id JOIN person follower ON follower.id=f.follower_id WHERE followed.ap_id='$alice_ap_id' AND follower.ap_id='https://$GTS_HOST/user/editor'" \
        1 "Ibis unexpectedly changed its reversed Person follow after rejecting Undo"

    check_logs "$BE_CONTAINER" Unfathomably

    cat <<EOF

Ibis federation smoke passed.

Covered against stock Ibis $IBIS_IMAGE:
* supported: WebFinger, ActivityPub content negotiation, NodeInfo, and canonical HTTPS IDs
* supported: native instance Group and Person actor discovery
* supported: instance Group follows, Accepts, unfollows, and cleanup from Unfathomably
* stock_limitation: Ibis 0.3.3 stores Person follows backward and only implements Undo Follow for its instance actor
* supported: Unfathomably applies Ibis's Person Accept, clears its local relationship, and emits the standards-correct Person Undo
* supported: Article Updates preserve edits, latestVersion, protected state, media type, and unknown JSON-LD
* supported: inline Article and ordered Patch collections remain bounded without recursive fetching
* supported: native Article and Patch representations are semantically separated on the status surface
* supported: sequential edits advance versions and stale edits become native Ibis conflicts
* supported: comments and comment Deletes round-trip into native application state
* supported: stock Article removal emitted a Delete and returned HTTP $removed_status at Unfathomably
* not_supported: stock Ibis does not expose Like or Undo Like activities
* not_supported: stock Ibis has no actor Block, Undo Block, Flag, or federated moderation UI
* not_supported: Ibis protected Articles restrict editing but do not provide non-public visibility
* not_supported: stock Ibis only follows remote instance actors that expose its required instances collection
* not_supported: stock Ibis domain blocking is static configuration and gives the blocked peer no durable signal
* not_supported: Ibis Undo Delete restoration is measured separately because ActivityPub Delete is normally terminal
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run_ibis_smoke
fi

# end of build_scripts/unfathomably-ibis-smoke.sh
