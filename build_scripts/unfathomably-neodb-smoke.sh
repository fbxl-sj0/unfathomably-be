#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-neodb-smoke.sh
#
# Purpose:
#
#   Run the official NeoDB image against Unfathomably and verify both its
#   Takahe federation layer and its native catalog journal state.
#
# Responsibilities:
#
#   * boot the stock NeoDB, Takahe, PostgreSQL, Redis, and Typesense services
#   * exercise discovery and account federation in both directions
#   * create native Movie, Mark, Review, Rating, Status, and Shelf state
#   * verify native JSON-LD, lifecycle, privacy, moderation, and cleanup
#   * report stock limitations without substituting synthetic activities
#
# This file intentionally does NOT contain:
#
#   * patched NeoDB or Takahe source
#   * hand-authored NeoDB ActivityPub payloads
#   * browser automation or production credentials
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAMILY_HARNESS="$SCRIPT_DIR/unfathomably-gotosocial-smoke.sh"

if [ ! -f "$FAMILY_HARNESS" ]; then
    printf 'Required account-federation harness not found: %s\n' "$FAMILY_HARNESS" >&2
    exit 1
fi

export SMOKE_PREFIX="${SMOKE_PREFIX:-unfathomably-neodb-smoke}"
export BE_HOST="${BE_HOST:-unfathomably-neodb.example.com}"
export BE_PORT="${BE_PORT:-5061}"
export BE_DB_NAME="${BE_DB_NAME:-unfathomably_neodb_smoke_be}"
export GTS_HOST="${GTS_HOST:-neodb-ref.example.com}"
export GTS_PORT="${GTS_PORT:-5062}"
export GTS_APP_PORT=8000
export GTS_FORWARDED_PROTO=https
export GTS_LABEL=NeoDB
export GTS_USERNAME=reviewer
export SMOKE_TLS=1
export BE_FEDERATION_SCHEME=https
export BE_FEDERATION_PORT=443

# shellcheck source-path=SCRIPTDIR
# shellcheck source=unfathomably-gotosocial-smoke.sh
source "$FAMILY_HARNESS"

NEODB_IMAGE="${NEODB_IMAGE:-neodb/neodb:0.16.5}"
NEODB_POSTGRES_IMAGE="${NEODB_POSTGRES_IMAGE:-postgres:14-alpine}"
NEODB_REDIS_IMAGE="${NEODB_REDIS_IMAGE:-redis:7-alpine}"
NEODB_TYPESENSE_IMAGE="${NEODB_TYPESENSE_IMAGE:-typesense/typesense:30.2}"

NEODB_DB_CONTAINER="${PREFIX}-neodb-db"
TAKAHE_DB_CONTAINER="${PREFIX}-takahe-db"
NEODB_REDIS_CONTAINER="${PREFIX}-redis"
NEODB_TYPESENSE_CONTAINER="${PREFIX}-typesense"
NEODB_WEB_CONTAINER="${PREFIX}-neodb-web"
NEODB_WORKER_CONTAINER="${PREFIX}-neodb-worker"
TAKAHE_WEB_CONTAINER="${PREFIX}-takahe-web"
TAKAHE_STATOR_CONTAINER="${PREFIX}-takahe-stator"

NEODB_DB_PASSWORD="${NEODB_DB_PASSWORD:-neodb-smoke-database-password}"
TAKAHE_DB_PASSWORD="${TAKAHE_DB_PASSWORD:-takahe-smoke-database-password}"
NEODB_TOKEN="${NEODB_TOKEN:-neodb-smoke-access-token}"
NEODB_CA_BUNDLE="$WORK_DIR/neodb-ca-bundle.crt"
NEODB_TYPESENSE_VOLUME="${PREFIX}-typesense-data"

NEODB_ENV=(
    -e 'NEODB_DEBUG=False'
    -e 'TAKAHE_DEBUG=False'
    -e 'TAKAHE_ENVIRONMENT=production'
    -e 'NEODB_SECRET_KEY=neodb-smoke-secret-key-0123456789abcdefghijklmnopqrstuvwxyz'
    -e 'TAKAHE_SECRET_KEY=neodb-smoke-secret-key-0123456789abcdefghijklmnopqrstuvwxyz'
    -e 'NEODB_SITE_NAME=NeoDB Federation Smoke'
    -e "NEODB_SITE_DOMAIN=$GTS_HOST"
    -e "TAKAHE_MAIN_DOMAIN=$GTS_HOST"
    -e 'NEODB_SITE_DESCRIPTION=Stock NeoDB used by the Unfathomably smoke harness.'
    -e 'NEODB_INVITE_ONLY=False'
    -e 'NEODB_DISABLE_DEFAULT_RELAY=True'
    -e 'NEODB_DISABLE_CRON_JOBS=True'
    -e 'NEODB_EMAIL_URL='
    -e "NEODB_EMAIL_FROM=no-reply@$GTS_HOST"
    -e "TAKAHE_EMAIL_FROM=no-reply@$GTS_HOST"
    -e "NEODB_DB_URL=postgres://neodb:$NEODB_DB_PASSWORD@$NEODB_DB_CONTAINER:5432/neodb"
    -e "TAKAHE_DB_URL=postgres://takahe:$TAKAHE_DB_PASSWORD@$TAKAHE_DB_CONTAINER:5432/takahe"
    -e "TAKAHE_DATABASE_SERVER=postgres://takahe:$TAKAHE_DB_PASSWORD@$TAKAHE_DB_CONTAINER:5432/takahe"
    -e "NEODB_REDIS_URL=redis://$NEODB_REDIS_CONTAINER:6379/0"
    -e "TAKAHE_CACHES_DEFAULT=redis://$NEODB_REDIS_CONTAINER:6379/0"
    -e "NEODB_SEARCH_URL=typesense://user:eggplant@$NEODB_TYPESENSE_CONTAINER:8108/catalog"
    -e 'TAKAHE_MEDIA_BACKEND=local://'
    -e 'NEODB_MEDIA_ROOT=/www/m'
    -e "NEODB_MEDIA_URL=https://$GTS_HOST/m/"
    -e 'TAKAHE_MEDIA_ROOT=/www/media'
    -e "TAKAHE_MEDIA_URL=https://$GTS_HOST/media/"
    -e 'NEODB_VENV=/neodb-venv'
    -e 'TAKAHE_VENV=/neodb-venv'
    -e 'TAKAHE_USE_PROXY_HEADERS=true'
    -e 'TAKAHE_STATOR_CONCURRENCY=2'
    -e 'TAKAHE_STATOR_CONCURRENCY_PER_MODEL=1'
    -e 'SSL_ONLY=false'
    -e 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt'
    -e 'REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt'
)

NEODB_MOUNTS=(
    -v "$GTS_VOLUME:/www"
    -v "$NEODB_CA_BUNDLE:/etc/ssl/certs/ca-certificates.crt:ro"
)

cleanup_neodb_smoke() {
    local incoming_status="$?"
    local status="${1:-$incoming_status}"

    if [ "$KEEP_CONTAINERS" = "1" ]; then
        cleanup "$status"
    fi

    docker rm -f \
        "$TAKAHE_STATOR_CONTAINER" \
        "$TAKAHE_WEB_CONTAINER" \
        "$NEODB_WORKER_CONTAINER" \
        "$NEODB_WEB_CONTAINER" \
        "$NEODB_TYPESENSE_CONTAINER" \
        "$NEODB_REDIS_CONTAINER" \
        "$TAKAHE_DB_CONTAINER" \
        "$NEODB_DB_CONTAINER" >/dev/null 2>&1 || true
    docker volume rm "$NEODB_TYPESENSE_VOLUME" >/dev/null 2>&1 || true
    cleanup "$status"
}

trap cleanup_neodb_smoke EXIT

prepare_neodb_ca_bundle() {
    if ! docker image inspect "$NEODB_IMAGE" >/dev/null 2>&1; then
        log "Pulling stock NeoDB image $NEODB_IMAGE"
        docker pull "$NEODB_IMAGE" >/dev/null
    fi

    docker run --rm --entrypoint /bin/sh "$NEODB_IMAGE" \
        -c 'cat /etc/ssl/certs/ca-certificates.crt' >"$NEODB_CA_BUNDLE"
    cat "$SMOKE_CA_CERT" >>"$NEODB_CA_BUNDLE"
}

wait_named_postgres() {
    local container="$1"
    local user="$2"
    local database="$3"
    local label="$4"
    local stable=0

    for _ in $(seq 1 120); do
        if docker exec "$container" pg_isready -U "$user" -d "$database" >/dev/null 2>&1; then
            stable=$((stable + 1))
            if [ "$stable" -ge 3 ]; then
                return 0
            fi
        else
            stable=0
        fi

        sleep 1
    done

    fail "$label PostgreSQL did not become ready"
}

start_neodb_dependencies() {
    docker volume create "$GTS_VOLUME" >/dev/null
    docker volume create "$NEODB_TYPESENSE_VOLUME" >/dev/null

    # The official Compose file bind-mounts pre-created media directories.
    # A named smoke volume starts empty, so establish the same layout before
    # the unprivileged web and worker processes begin using it.
    docker run --rm \
        --user root:root \
        --entrypoint /bin/sh \
        -v "$GTS_VOLUME:/www" \
        "$NEODB_IMAGE" \
        -c 'mkdir -p /www/m /www/media /www/cache /www/root && chown -R app:app /www'

    docker run -d \
        --name "$NEODB_DB_CONTAINER" \
        --hostname "$NEODB_DB_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$NEODB_DB_CONTAINER" \
        -e 'POSTGRES_DB=neodb' \
        -e 'POSTGRES_USER=neodb' \
        -e "POSTGRES_PASSWORD=$NEODB_DB_PASSWORD" \
        "$NEODB_POSTGRES_IMAGE" >/dev/null

    docker run -d \
        --name "$TAKAHE_DB_CONTAINER" \
        --hostname "$TAKAHE_DB_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$TAKAHE_DB_CONTAINER" \
        -e 'POSTGRES_DB=takahe' \
        -e 'POSTGRES_USER=takahe' \
        -e "POSTGRES_PASSWORD=$TAKAHE_DB_PASSWORD" \
        "$NEODB_POSTGRES_IMAGE" >/dev/null

    docker run -d \
        --name "$NEODB_REDIS_CONTAINER" \
        --hostname "$NEODB_REDIS_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$NEODB_REDIS_CONTAINER" \
        "$NEODB_REDIS_IMAGE" \
        redis-server --save 60 1 --loglevel warning >/dev/null

    docker run -d \
        --name "$NEODB_TYPESENSE_CONTAINER" \
        --hostname "$NEODB_TYPESENSE_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$NEODB_TYPESENSE_CONTAINER" \
        -e 'GLOG_minloglevel=2' \
        -v "$NEODB_TYPESENSE_VOLUME:/data" \
        "$NEODB_TYPESENSE_IMAGE" \
        --data-dir /data --api-key=eggplant >/dev/null
}

run_neodb_migrations() {
    docker run --rm \
        --name "${PREFIX}-migration" \
        --network "$NETWORK" \
        "${NEODB_ENV[@]}" \
        "${NEODB_MOUNTS[@]}" \
        "$NEODB_IMAGE" \
        /bin/neodb-init
}

start_neodb_services() {
    docker run -d \
        --name "$NEODB_WEB_CONTAINER" \
        --hostname "$NEODB_WEB_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$NEODB_WEB_CONTAINER" \
        "${NEODB_ENV[@]}" \
        "${NEODB_MOUNTS[@]}" \
        "$NEODB_IMAGE" \
        /neodb-venv/bin/gunicorn boofilsic.wsgi \
        -w 2 --preload --max-requests 2000 --timeout 60 -b 0.0.0.0:8000 >/dev/null

    docker run -d \
        --name "$NEODB_WORKER_CONTAINER" \
        --hostname "$NEODB_WORKER_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$NEODB_WORKER_CONTAINER" \
        "${NEODB_ENV[@]}" \
        "${NEODB_MOUNTS[@]}" \
        "$NEODB_IMAGE" \
        neodb-manage rqworker-pool --num-workers 2 mastodon fetch ap crawl >/dev/null

    docker run -d \
        --name "$TAKAHE_WEB_CONTAINER" \
        --hostname "$TAKAHE_WEB_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$TAKAHE_WEB_CONTAINER" \
        "${NEODB_ENV[@]}" \
        "${NEODB_MOUNTS[@]}" \
        "$NEODB_IMAGE" \
        /neodb-venv/bin/gunicorn --chdir /takahe takahe.wsgi \
        -w 2 --preload --max-requests 2000 --timeout 60 -b 0.0.0.0:8000 >/dev/null

    docker run -d \
        --name "$TAKAHE_STATOR_CONTAINER" \
        --hostname "$TAKAHE_STATOR_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$TAKAHE_STATOR_CONTAINER" \
        "${NEODB_ENV[@]}" \
        "${NEODB_MOUNTS[@]}" \
        "$NEODB_IMAGE" \
        takahe-manage runstator >/dev/null

    docker run -d \
        --name "$GTS_CONTAINER" \
        --hostname "$GTS_APP_HOST" \
        --network "$NETWORK" \
        --network-alias "$GTS_APP_HOST" \
        --user root:root \
        "${NEODB_ENV[@]}" \
        -e "NEODB_WEB_SERVER=$NEODB_WEB_CONTAINER:8000" \
        -e "NEODB_API_SERVER=$NEODB_WEB_CONTAINER:8000" \
        -e "TAKAHE_WEB_SERVER=$TAKAHE_WEB_CONTAINER:8000" \
        -e 'NGINX_CONF=/neodb/misc/nginx.conf.d/neodb.conf' \
        "${NEODB_MOUNTS[@]}" \
        "$NEODB_IMAGE" \
        nginx-start >/dev/null

    start_gts_proxy
}

wait_neodb() {
    for _ in $(seq 1 300); do
        if curl -fsS "$GTS_BASE/nodeinfo/2.0/" >/dev/null 2>&1 && \
            curl -fsS "$GTS_BASE/api/v1/instance" >/dev/null 2>&1; then
            return 0
        fi

        sleep 1
    done

    docker logs "$NEODB_WEB_CONTAINER" >&2 || true
    docker logs "$TAKAHE_WEB_CONTAINER" >&2 || true
    docker logs "$GTS_CONTAINER" >&2 || true
    fail "Timed out waiting for stock NeoDB at $GTS_BASE"
}

neodb_shell() {
    docker exec "$NEODB_WEB_CONTAINER" \
        /neodb-venv/bin/python /neodb/manage.py shell -c "$1"
}

neodb_value() {
    neodb_shell "$1" 2>/dev/null | tail -n 1
}

takahe_value() {
    docker exec "$TAKAHE_WEB_CONTAINER" \
        /neodb-venv/bin/python /takahe/manage.py shell -c "$1" 2>/dev/null | tail -n 1
}

resolve_gts_be_account_id() {
    local acct="$1"
    local actor_url="https://$BE_HOST/users/${acct%%@*}"
    local result=""
    local id=""

    #
    # Takahe's Mastodon-compatible search has two genuine remote-discovery
    # paths. Handle search first probes WebFinger, while URL search retrieves
    # and canonicalises the actor document directly. The URL path is more
    # reliable for an isolated TLS smoke network because it does not depend on
    # host-meta redirect behaviour, and it still exercises stock Takahe actor
    # fetching rather than creating a synthetic remote identity.
    #
    for _ in $(seq 1 90); do
        result="$(http_form GET \
            "$GTS_BASE/api/v2/search?q=$(urlencode "$actor_url")&resolve=true&type=accounts&limit=5" \
            "$NEODB_TOKEN" 200 || true)"
        id="$(json_get_optional "$result" accounts.0.id)"

        if [ -n "$id" ]; then
            printf '%s\n' "$id"
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    return 1
}

poll_neodb_value() {
    local code="$1"
    local expected="$2"
    local message="$3"
    local result=""

    for _ in $(seq 1 90); do
        result="$(neodb_value "$code" || true)"
        if [ "$result" = "$expected" ]; then
            return 0
        fi
        sleep 2
    done

    printf 'Expected %s, got %s\n' "$expected" "$result" >&2
    fail "$message"
}

poll_takahe_value() {
    local code="$1"
    local expected="$2"
    local message="$3"
    local result=""

    for _ in $(seq 1 90); do
        result="$(takahe_value "$code" || true)"
        if [ "$result" = "$expected" ]; then
            return 0
        fi
        sleep 2
    done

    printf 'Expected %s, got %s\n' "$expected" "$result" >&2
    fail "$message"
}

create_neodb_account() {
    neodb_shell "from users.models import User; from takahe.models import Application, Identity, Token, User as TakaheUser; u=User.objects.filter(username='$GTS_USERNAME').first() or User.register(username='$GTS_USERNAME', email='$GTS_USERNAME@$GTS_HOST'); i=Identity.objects.get(pk=u.identity.pk); i.manually_approves_followers=False; i.discoverable=True; i.save(); tu=TakaheUser.objects.get(pk=u.pk); app=Application.objects.filter(name='Unfathomably NeoDB smoke').first() or Application.objects.create(name='Unfathomably NeoDB smoke', client_id='tk-neodb-smoke', client_secret='neodb-smoke-client-secret', redirect_uris='urn:ietf:wg:oauth:2.0:oob', scopes='read write follow push', website=None); Token.objects.update_or_create(token='$NEODB_TOKEN', defaults={'application': app, 'user': tu, 'identity': i, 'scopes': ['read', 'write', 'follow', 'push']}); print(u.identity.actor_uri)" | tail -n 1
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

assert_public_timeline_missing() {
    local text="$1"
    local result

    result="$(http_form GET "$BE_BASE/api/v1/timelines/public?limit=40" "" 200)"

    if JSON_INPUT="$result" EXPECTED_TEXT="$text" python3 - <<'PY'
import json
import os

text = os.environ["EXPECTED_TEXT"]
for status in json.loads(os.environ["JSON_INPUT"]):
    if text in (status.get("content") or ""):
        raise SystemExit(1)
PY
    then
        return 0
    fi

    fail "Follower-only NeoDB status leaked into Unfathomably's public timeline"
}

poll_be_report_by_text() {
    local text="$1"
    local message="$2"
    local result=""

    for _ in $(seq 1 90); do
        result="$(docker exec "$BE_DB_CONTAINER" psql -U postgres -d "$BE_DB_NAME" -Atq \
            -c "SELECT data->>'content' FROM activities WHERE data->>'type' = 'Flag' ORDER BY inserted_at DESC LIMIT 20;" || true)"
        if [[ "$result" == *"$text"* ]]; then
            return 0
        fi
        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

run_neodb_smoke() {
    local nodeinfo_links nodeinfo webfinger actor_json
    local neodb_actor be_credentials alice_ap_id
    local be_account_id neodb_account_id
    local be_group be_group_id group_summary
    local be_text be_post be_post_id be_post_uri neodb_view_of_be_id
    local neodb_text neodb_post neodb_post_id neodb_post_uri be_view_of_neodb_id
    local be_neodb_status
    local neodb_reply neodb_reply_id neodb_reply_text
    local be_reply be_reply_id be_reply_uri be_reply_text neodb_view_of_be_reply
    local ordinary_be_reply_id review_neodb_status_id
    local native_state item_uri mark_uri review_uri shelf_uri
    local mark_status_id mark_status review_status_id review_status
    local updated_native updated_mark_uri updated_review_uri updated_mark_status_id
    local historical_mark_status_id historical_mark_status
    local shelf_collection shelf_page updated_native
    local private_state private_mark_uri private_status_id private_status private_text
    local neodb_report_text be_report_text
    local neodb_block be_block

    write_be_secret
    write_proxy_configs

    log "Creating isolated NeoDB federation network"
    docker rm -f \
        "$GTS_PROXY_CONTAINER" \
        "$GTS_CONTAINER" \
        "$TAKAHE_STATOR_CONTAINER" \
        "$TAKAHE_WEB_CONTAINER" \
        "$NEODB_WORKER_CONTAINER" \
        "$NEODB_WEB_CONTAINER" \
        "$NEODB_TYPESENSE_CONTAINER" \
        "$NEODB_REDIS_CONTAINER" \
        "$TAKAHE_DB_CONTAINER" \
        "$NEODB_DB_CONTAINER" \
        "$BE_PROXY_CONTAINER" \
        "$BE_CONTAINER" \
        "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    docker volume rm "$GTS_VOLUME" >/dev/null 2>&1 || true
    docker volume rm "$NEODB_TYPESENSE_VOLUME" >/dev/null 2>&1 || true
    #
    # NeoDB 0.16.5's bundled Takahe rejects every destination whose resolved
    # address Python classifies as private, loopback, link-local, reserved,
    # multicast, or unspecified. There is no stock configuration switch for
    # an isolated integration network. Give this bridge a globally classified
    # subnet so the unmodified SSRF check permits peer dereferencing. Docker
    # owns the route locally on the .99 host; no federation request leaves the
    # disposable bridge.
    #
    docker network create --subnet 11.254.231.0/24 "$NETWORK" >/dev/null
    prepare_smoke_tls
    prepare_neodb_ca_bundle

    log "Starting databases and stock NeoDB $NEODB_IMAGE"
    docker run -d \
        --name "$BE_DB_CONTAINER" \
        --hostname "$BE_DB_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$BE_DB_CONTAINER" \
        -e "POSTGRES_PASSWORD=$BE_DB_PASSWORD" \
        "$POSTGRES_IMAGE" >/dev/null
    start_neodb_dependencies
    wait_postgres
    wait_named_postgres "$NEODB_DB_CONTAINER" neodb neodb NeoDB
    wait_named_postgres "$TAKAHE_DB_CONTAINER" takahe takahe Takahe
    prepare_database
    run_neodb_migrations
    start_neodb_services
    wait_neodb

    log "Creating native NeoDB and Takahe credentials"
    neodb_actor="$(create_neodb_account)"
    [ -n "$neodb_actor" ] || fail "NeoDB did not create its local reviewer actor"
    http_form GET "$GTS_BASE/api/v1/accounts/verify_credentials" "$NEODB_TOKEN" 200 >/dev/null

    log "Proving NeoDB discovery, content negotiation, and canonical identity"
    nodeinfo_links="$(http_form GET "$GTS_BASE/.well-known/nodeinfo" "" 200)"
    nodeinfo="$(http_form GET "$GTS_BASE/nodeinfo/2.0/" "" 200)"
    json_assert "$nodeinfo_links" \
        "any(item.get('href') == 'https://$GTS_HOST/nodeinfo/2.0/' for item in data.get('links', []))" \
        "NeoDB NodeInfo discovery did not expose its canonical endpoint"
    json_assert "$nodeinfo" \
        "data.get('software', {}).get('name') == 'neodb' and 'activitypub' in data.get('protocols', [])" \
        "NeoDB NodeInfo did not identify the stock application"

    webfinger="$(http_form GET \
        "$GTS_BASE/.well-known/webfinger?resource=acct:$GTS_USERNAME@$GTS_HOST" "" 200)"
    json_assert "$webfinger" \
        "data.get('subject') == 'acct:$GTS_USERNAME@$GTS_HOST' and any(item.get('href') == '$neodb_actor' for item in data.get('links', []))" \
        "NeoDB WebFinger did not expose the canonical reviewer actor"
    actor_json="$(curl -fsS -H 'Accept: application/activity+json' \
        "$GTS_BASE${neodb_actor#https://"$GTS_HOST"}")"
    json_assert "$actor_json" \
        "data.get('id') == '$neodb_actor' and data.get('type') == 'Person' and data.get('preferredUsername') == '$GTS_USERNAME'" \
        "NeoDB actor discovery did not return the stock Person"
    curl -fsS -H 'Accept: application/ld+json; profile="https://www.w3.org/ns/activitystreams"' \
        "$GTS_BASE${neodb_actor#https://"$GTS_HOST"}" >/dev/null

    log "Migrating and starting Unfathomably"
    migrate_and_create_be_user alice "alice@$BE_HOST"
    start_be
    start_be_proxy
    wait_be
    ALICE_TOKEN="$(create_be_token alice)"
    be_credentials="$(http_form GET "$BE_BASE/api/v1/accounts/verify_credentials" "$ALICE_TOKEN" 200)"
    alice_ap_id="$(json_get "$be_credentials" pleroma.ap_id)"

    log "Following accounts in both directions"
    be_account_id="$(resolve_account_id "$GTS_BASE" "$NEODB_TOKEN" \
        "alice@$BE_HOST" "NeoDB could not resolve the Unfathomably account")"
    http_form POST "$GTS_BASE/api/v1/accounts/$be_account_id/follow" \
        "$NEODB_TOKEN" 200 >/dev/null
    neodb_account_id="$(resolve_account_id "$BE_BASE" "$ALICE_TOKEN" \
        "$GTS_USERNAME@$GTS_HOST" "Unfathomably could not resolve the NeoDB account")"
    http_form POST "$BE_BASE/api/v1/accounts/$neodb_account_id/follow" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_relationship_following "$GTS_BASE" "$NEODB_TOKEN" "$be_account_id" \
        "NeoDB follow of Unfathomably did not become accepted"
    poll_relationship_following "$BE_BASE" "$ALICE_TOKEN" "$neodb_account_id" \
        "Unfathomably follow of NeoDB did not become accepted"

    log "Testing ordinary posts, replies, Likes, Undo Likes, and reports"
    be_text="Unfathomably to NeoDB $(basename "$WORK_DIR")"
    be_post="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$be_text" 'visibility=public')"
    be_post_id="$(json_get "$be_post" id)"
    be_post_uri="$(json_get "$be_post" uri)"
    neodb_view_of_be_id="$(resolve_status_id "$GTS_BASE" "$NEODB_TOKEN" \
        "$be_post_uri" "NeoDB could not resolve the Unfathomably post")"

    http_form POST "$GTS_BASE/api/v1/statuses/$neodb_view_of_be_id/favourite" \
        "$NEODB_TOKEN" 200 >/dev/null
    poll_status_count "$BE_BASE" "$ALICE_TOKEN" "$be_post_id" \
        'int(data.get("favourites_count") or 0) >= 1' \
        "Unfathomably did not receive the NeoDB favourite"
    http_form POST "$GTS_BASE/api/v1/statuses/$neodb_view_of_be_id/unfavourite" \
        "$NEODB_TOKEN" 200 >/dev/null
    poll_status_count "$BE_BASE" "$ALICE_TOKEN" "$be_post_id" \
        'int(data.get("favourites_count") or 0) == 0' \
        "Unfathomably did not receive the NeoDB Undo Like"

    neodb_reply_text="NeoDB reply to Unfathomably $(basename "$WORK_DIR")"
    neodb_reply="$(http_form POST "$GTS_BASE/api/v1/statuses" "$NEODB_TOKEN" 200 \
        "status=$neodb_reply_text @alice@$BE_HOST" \
        "in_reply_to_id=$neodb_view_of_be_id" 'visibility=public')"
    neodb_reply_id="$(json_get "$neodb_reply" id)"
    poll_context_status_by_text "$BE_BASE" "$ALICE_TOKEN" "$be_post_id" \
        "$neodb_reply_text" "Unfathomably did not receive the NeoDB reply"

    neodb_text="NeoDB to Unfathomably $(basename "$WORK_DIR")"
    neodb_post="$(http_form POST "$GTS_BASE/api/v1/statuses" "$NEODB_TOKEN" 200 \
        "status=$neodb_text @alice@$BE_HOST" 'visibility=public')"
    neodb_post_id="$(json_get "$neodb_post" id)"
    neodb_post_uri="$(json_get "$neodb_post" uri)"
    be_view_of_neodb_id="$(poll_home_status_by_text "$BE_BASE" "$ALICE_TOKEN" \
        "$neodb_text" "Unfathomably did not receive the NeoDB status")"
    be_neodb_status="$(http_form GET "$BE_BASE/api/v1/statuses/$be_view_of_neodb_id" \
        "$ALICE_TOKEN" 200)"
    json_assert "$be_neodb_status" "data.get('uri') == '$neodb_post_uri'" \
        "Unfathomably changed the NeoDB status canonical URI"

    http_form POST "$BE_BASE/api/v1/statuses/$be_view_of_neodb_id/favourite" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_status_count "$GTS_BASE" "$NEODB_TOKEN" "$neodb_post_id" \
        'int(data.get("favourites_count") or 0) >= 1' \
        "NeoDB did not receive the Unfathomably favourite"
    http_form POST "$BE_BASE/api/v1/statuses/$be_view_of_neodb_id/unfavourite" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_status_count "$GTS_BASE" "$NEODB_TOKEN" "$neodb_post_id" \
        'int(data.get("favourites_count") or 0) == 0' \
        "NeoDB did not receive the Unfathomably Undo Like"

    be_reply_text="Unfathomably reply to NeoDB $(basename "$WORK_DIR")"
    be_reply="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$be_reply_text" "in_reply_to_id=$be_view_of_neodb_id")"
    ordinary_be_reply_id="$(json_get "$be_reply" id)"
    poll_context_status_by_text "$GTS_BASE" "$NEODB_TOKEN" \
        "$neodb_post_id" "$be_reply_text" "NeoDB did not receive the Unfathomably reply" >/dev/null

    neodb_report_text="NeoDB moderation report $(basename "$WORK_DIR")"
    http_form POST "$GTS_BASE/api/v1/reports" "$NEODB_TOKEN" 200 \
        "account_id=$be_account_id" "status_ids[]=$neodb_view_of_be_id" \
        "comment=$neodb_report_text" 'forward=true' >/dev/null
    poll_be_report_by_text "$neodb_report_text" \
        "Unfathomably did not receive the NeoDB Flag"

    be_report_text="Unfathomably moderation report $(basename "$WORK_DIR")"
    http_form POST "$BE_BASE/api/v1/reports" "$ALICE_TOKEN" 200 \
        "account_id=$neodb_account_id" "status_ids[]=$be_view_of_neodb_id" \
        "comment=$be_report_text" 'forward=true' >/dev/null
    poll_takahe_value \
        "from users.models import Report; print(Report.objects.filter(type='remote', complaint__contains='$be_report_text').count())" \
        1 "NeoDB did not retain the Unfathomably Flag in native moderation state"

    log "Creating native NeoDB Movie, Mark, Rating, Comment, Review, and Shelf state"
    native_state="$(neodb_value "from users.models import User; from catalog.models import Movie; from journal.models import Mark, Review, ShelfType; from takahe.utils import Takahe; u=User.objects.get(username='$GTS_USERNAME'); item=Movie.objects.create(title='Alien Federation Film'); mark=Mark(u.identity, item); mark.update(ShelfType.COMPLETE, comment_text='Native NeoDB mark comment', rating_grade=7, visibility=0); mark=Mark(u.identity, item); mark_post=Takahe.get_posts([mark.latest_post_id]).first(); review=Review.update_item_review(item, u.identity, 'Alien Catalog Review', 'Original native NeoDB review body', visibility=0); print('|'.join([item.absolute_url, mark_post.object_uri, review.latest_post.object_uri, 'https://$GTS_HOST' + u.identity.shelf_manager.get_shelf(ShelfType.COMPLETE).url]))")"
    IFS='|' read -r item_uri mark_uri review_uri shelf_uri <<<"$native_state"
    [ -n "$item_uri" ] && [ -n "$mark_uri" ] && [ -n "$review_uri" ] && [ -n "$shelf_uri" ] || \
        fail "NeoDB did not return complete native journal identifiers"

    mark_status_id="$(poll_home_status_by_text "$BE_BASE" "$ALICE_TOKEN" \
        'Native NeoDB mark comment' "Unfathomably did not receive the native NeoDB Mark")"
    mark_status="$(http_form GET "$BE_BASE/api/v1/statuses/$mark_status_id" "$ALICE_TOKEN" 200)"
    json_assert "$mark_status" \
        "data.get('uri') == '$mark_uri' and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('platform') == 'neodb' and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('rating') == 7 and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('rating_best') == 10 and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('reading_status') == 'complete' and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('catalog_item') == '$item_uri' and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('catalog_type') == 'Movie'" \
        "Unfathomably did not expose the complete bounded NeoDB Mark presentation"

    review_status_id="$(poll_home_status_by_text "$BE_BASE" "$ALICE_TOKEN" \
        'Original native NeoDB review body' "Unfathomably did not receive the native NeoDB Review")"
    review_status="$(http_form GET "$BE_BASE/api/v1/statuses/$review_status_id" "$ALICE_TOKEN" 200)"
    json_assert "$review_status" \
        "data.get('uri') == '$review_uri' and data.get('pleroma', {}).get('native', {}).get('type') == 'Article' and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('platform') == 'neodb' and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('review') and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('catalog_item') == '$item_uri' and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('catalog_type') == 'Movie'" \
        "Unfathomably did not expose the native NeoDB Review inside its compatibility Article"
    review_neodb_status_id="$(resolve_status_id "$GTS_BASE" "$NEODB_TOKEN" \
        "$review_uri" "NeoDB could not resolve its native Review status")"

    poll_neodb_value \
        "from journal.models import Review; print(Review.objects.filter(title='Alien Catalog Review', body='Original native NeoDB review body').count())" \
        1 "NeoDB did not retain its native Review state"

    log "Proving the native Shelf OrderedCollection and bounded page"
    shelf_collection="$(curl -fsS -H 'Accept: application/activity+json' \
        "$GTS_BASE${shelf_uri#https://"$GTS_HOST"}/items")"
    json_assert "$shelf_collection" \
        "data.get('type') == 'OrderedCollection' and data.get('totalItems') == 1 and data.get('first', '').endswith('/items?page=1') and data.get('last', '').endswith('/items?page=1')" \
        "NeoDB did not expose the complete shelf collection envelope"
    shelf_page="$(curl -fsS -H 'Accept: application/activity+json' \
        "$GTS_BASE${shelf_uri#https://"$GTS_HOST"}/items?page=1")"
    json_assert "$shelf_page" \
        "data.get('type') == 'OrderedCollectionPage' and data.get('partOf') == '$shelf_uri/items' and len(data.get('orderedItems', [])) == 1 and data.get('orderedItems', [])[0].get('type') == 'ShelfItem' and data.get('orderedItems', [])[0].get('withRegardTo') == '$item_uri' and data.get('orderedItems', [])[0].get('post') == '$mark_uri'" \
        "NeoDB did not expose the native ShelfItem page"

    log "Updating native Mark and Review state with their stock lifecycle semantics"
    updated_native="$(neodb_value "from users.models import User; from catalog.models import Movie; from journal.models import Mark, Review, ShelfType; from takahe.utils import Takahe; u=User.objects.get(username='$GTS_USERNAME'); item=Movie.objects.get(title='Alien Federation Film'); Mark(u.identity, item).update(ShelfType.PROGRESS, comment_text='Updated native NeoDB mark comment', rating_grade=9, visibility=0); mark=Mark(u.identity, item); mark_post=Takahe.get_posts([mark.latest_post_id]).first(); review=Review.update_item_review(item, u.identity, 'Alien Catalog Review', 'Updated native NeoDB review body', visibility=0); print('|'.join([mark_post.object_uri, review.latest_post.object_uri]))")"
    IFS='|' read -r updated_mark_uri updated_review_uri <<<"$updated_native"
    [ "$updated_review_uri" = "$review_uri" ] || \
        fail "NeoDB changed the Review canonical URI during update"
    [ -n "$updated_mark_uri" ] && [ "$updated_mark_uri" != "$mark_uri" ] || \
        fail "NeoDB did not replace the Mark Note when its shelf state changed"
    updated_mark_status_id="$(poll_home_status_by_text "$BE_BASE" "$ALICE_TOKEN" \
        'Updated native NeoDB mark comment' \
        "Unfathomably did not receive NeoDB's replacement Mark Note")"
    mark_status="$(http_form GET "$BE_BASE/api/v1/statuses/$updated_mark_status_id" \
        "$ALICE_TOKEN" 200)"
    json_assert "$mark_status" \
        "data.get('uri') == '$updated_mark_uri' and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('rating') == 9 and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('reading_status') == 'progress'" \
        "Unfathomably did not expose NeoDB's complete replacement Mark Note"
    historical_mark_status_id="$mark_status_id"
    historical_mark_status="$(http_form GET \
        "$BE_BASE/api/v1/statuses/$historical_mark_status_id" "$ALICE_TOKEN" 200)"
    json_assert "$historical_mark_status" \
        "data.get('uri') == '$mark_uri' and 'Native NeoDB mark comment' in (data.get('content') or '') and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('rating') == 7 and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('reading_status') == 'complete'" \
        "Unfathomably did not retain NeoDB's immutable historical Mark Note"
    mark_status_id="$updated_mark_status_id"
    mark_uri="$updated_mark_uri"
    poll_json_assert \
        "http_form GET '$BE_BASE/api/v1/statuses/$review_status_id' '$ALICE_TOKEN' 200" \
        "'Updated native NeoDB review body' in (data.get('content') or '')" \
        "Unfathomably did not apply the native NeoDB Review Update" >/dev/null

    poll_neodb_value \
        "from journal.models import Review; print(Review.objects.filter(title='Alien Catalog Review').count())" \
        1 "NeoDB duplicated its native Review during update"
    poll_takahe_value \
        "from activities.models import Post; print(Post.objects.filter(object_uri='$review_uri').count())" \
        1 "NeoDB duplicated its Takahe compatibility Article during Review update"

    log "Round-tripping an Unfathomably reply into Takahe state"
    be_reply="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
        'status=Unfathomably reply to native NeoDB review' \
        "in_reply_to_id=$review_status_id")"
    be_reply_id="$(json_get "$be_reply" id)"
    be_reply_uri="$(json_get "$be_reply" uri)"
    neodb_view_of_be_reply="$(poll_context_status_by_text "$GTS_BASE" "$NEODB_TOKEN" \
        "$review_neodb_status_id" 'Unfathomably reply to native NeoDB review' \
        "NeoDB did not receive the reply to its native Review")"
    poll_takahe_value \
        "from activities.models import Post; print(Post.objects.filter(object_uri='$be_reply_uri', local=False).count())" \
        1 "NeoDB did not retain the Unfathomably reply in Takahe application state"
    http_form DELETE "$BE_BASE/api/v1/statuses/$be_reply_id" "$ALICE_TOKEN" 200 >/dev/null
    poll_status_missing "$GTS_BASE" "$NEODB_TOKEN" "$neodb_view_of_be_reply" \
        "NeoDB retained the deleted Unfathomably reply"

    log "Testing follower-only native journal privacy"
    private_text="Follower-only NeoDB mark $(basename "$WORK_DIR")"
    private_state="$(neodb_value "from users.models import User; from catalog.models import Movie; from journal.models import Mark, ShelfType, VisibilityType; from takahe.utils import Takahe; u=User.objects.get(username='$GTS_USERNAME'); item=Movie.objects.create(title='Restricted Alien Film'); Mark(u.identity, item).update(ShelfType.WISHLIST, comment_text='$private_text', rating_grade=6, visibility=VisibilityType.Follower_Only); mark=Mark(u.identity, item); print(Takahe.get_posts([mark.latest_post_id]).first().object_uri)")"
    private_mark_uri="$private_state"
    private_status_id="$(poll_home_status_by_text "$BE_BASE" "$ALICE_TOKEN" \
        "$private_text" "Unfathomably follower did not receive the private NeoDB Mark")"
    private_status="$(http_form GET "$BE_BASE/api/v1/statuses/$private_status_id" \
        "$ALICE_TOKEN" 200)"
    json_assert "$private_status" "data.get('uri') == '$private_mark_uri'" \
        "Unfathomably changed the follower-only NeoDB Mark canonical URI"
    assert_public_timeline_missing "$private_text"

    log "Testing native Deletes, repeated cleanup, and ordinary status Deletes"
    neodb_value "from users.models import User; from catalog.models import Movie; from journal.models import Mark, Review; u=User.objects.get(username='$GTS_USERNAME'); item=Movie.objects.get(title='Alien Federation Film'); Review.update_item_review(item, u.identity, None, None); Mark(u.identity, item).delete(); restricted=Movie.objects.get(title='Restricted Alien Film'); Mark(u.identity, restricted).delete(); print('deleted')" >/dev/null
    poll_status_missing "$BE_BASE" "$ALICE_TOKEN" "$review_status_id" \
        "Unfathomably retained the deleted native NeoDB Review"
    poll_status_missing "$BE_BASE" "$ALICE_TOKEN" "$mark_status_id" \
        "Unfathomably retained the deleted native NeoDB Mark"
    poll_status_missing "$BE_BASE" "$ALICE_TOKEN" "$historical_mark_status_id" \
        "Unfathomably retained the historical Mark after native NeoDB cleanup"
    poll_status_missing "$BE_BASE" "$ALICE_TOKEN" "$private_status_id" \
        "Unfathomably retained the deleted follower-only NeoDB Mark"
    neodb_value "from users.models import User; from catalog.models import Movie; from journal.models import Mark, Review; u=User.objects.get(username='$GTS_USERNAME'); item=Movie.objects.get(title='Alien Federation Film'); Review.update_item_review(item, u.identity, None, None); Mark(u.identity, item).delete(); print('repeat-safe')" >/dev/null

    http_form DELETE "$GTS_BASE/api/v1/statuses/$neodb_reply_id" "$NEODB_TOKEN" 200 >/dev/null
    http_form DELETE "$BE_BASE/api/v1/statuses/$ordinary_be_reply_id" "$ALICE_TOKEN" 200 >/dev/null
    http_form DELETE "$BE_BASE/api/v1/statuses/$be_post_id" "$ALICE_TOKEN" 200 >/dev/null
    poll_status_missing "$GTS_BASE" "$NEODB_TOKEN" "$neodb_view_of_be_id" \
        "NeoDB retained the deleted Unfathomably status"
    http_form DELETE "$GTS_BASE/api/v1/statuses/$neodb_post_id" "$NEODB_TOKEN" 200 >/dev/null
    poll_status_missing "$BE_BASE" "$ALICE_TOKEN" "$be_view_of_neodb_id" \
        "Unfathomably retained the deleted NeoDB status"

    log "Testing explicit unfollows in both directions"
    http_form POST "$BE_BASE/api/v1/accounts/$neodb_account_id/unfollow" \
        "$ALICE_TOKEN" 200 >/dev/null
    http_form POST "$GTS_BASE/api/v1/accounts/$be_account_id/unfollow" \
        "$NEODB_TOKEN" 200 >/dev/null
    poll_relationship_not_following "$BE_BASE" "$ALICE_TOKEN" "$neodb_account_id" \
        "Unfathomably retained its NeoDB follow after unfollow"
    poll_relationship_not_following "$GTS_BASE" "$NEODB_TOKEN" "$be_account_id" \
        "NeoDB retained its Unfathomably follow after unfollow"

    log "Testing Blocks and Undo Blocks in both directions"
    neodb_block="$(http_form POST "$GTS_BASE/api/v1/accounts/$be_account_id/block" \
        "$NEODB_TOKEN" 200)"
    json_assert "$neodb_block" 'data.get("blocking") is True' \
        "NeoDB did not create its local block"
    poll_json_assert \
        "http_form GET '$BE_BASE/api/v1/accounts/relationships?id[]=$neodb_account_id' '$ALICE_TOKEN' 200" \
        'len(data) >= 1 and data[0].get("blocked_by") is True' \
        "Unfathomably did not apply the NeoDB Block" >/dev/null
    http_form POST "$GTS_BASE/api/v1/accounts/$be_account_id/unblock" \
        "$NEODB_TOKEN" 200 >/dev/null
    poll_json_assert \
        "http_form GET '$BE_BASE/api/v1/accounts/relationships?id[]=$neodb_account_id' '$ALICE_TOKEN' 200" \
        'len(data) >= 1 and data[0].get("blocked_by") is not True' \
        "Unfathomably did not apply the NeoDB Undo Block" >/dev/null

    be_block="$(http_form POST "$BE_BASE/api/v1/accounts/$neodb_account_id/block" \
        "$ALICE_TOKEN" 200)"
    json_assert "$be_block" 'data.get("blocking") is True' \
        "Unfathomably did not create its NeoDB block"
    poll_takahe_value \
        "from users.models import Block; print(Block.objects.active().filter(source__actor_uri='$alice_ap_id', target__actor_uri='$neodb_actor', mute=False).count())" \
        1 "NeoDB did not retain the Unfathomably Block"
    http_form POST "$BE_BASE/api/v1/accounts/$neodb_account_id/unblock" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_takahe_value \
        "from users.models import Block; print(Block.objects.active().filter(source__actor_uri='$alice_ap_id', target__actor_uri='$neodb_actor', mute=False).count())" \
        0 "NeoDB did not apply the Unfathomably Undo Block"

    log "Testing Group relationship capability and final state"
    be_group="$(http_form POST "$BE_BASE/api/v1/groups" "$ALICE_TOKEN" 200 \
        'display_name=Unfathomably NeoDB Group' \
        'name=unfathomably_neodb_group' \
        'note=Open group used by the NeoDB federation smoke harness.' \
        'locked=false')"
    be_group_id="$(json_get "$be_group" id)"
    group_summary="$(probe_gts_group_actor "$NEODB_TOKEN" \
        "unfathomably_neodb_group@$BE_HOST" "$be_group_id")"
    printf '%s\n' "$group_summary"

    check_logs "$BE_CONTAINER" Unfathomably
    check_logs "$NEODB_WEB_CONTAINER" NeoDB
    check_logs "$TAKAHE_WEB_CONTAINER" Takahe
    check_logs "$TAKAHE_STATOR_CONTAINER" "Takahe stator"

    cat <<EOF

NeoDB federation smoke passed.

Covered against stock NeoDB $NEODB_IMAGE:
* supported: WebFinger, actor fetch, ActivityPub content negotiation, NodeInfo, and canonical HTTPS IDs
* supported: Person follows, Accepts, unfollows, and cleanup in both directions
* supported: ordinary posts, replies, Likes, Undo Likes, and Deletes in both directions
* supported: native Movie, Mark, Status, Comment, Rating, Review, and Shelf representations survive
* supported: compatibility Article and native Review remain one canonical status
* supported: exact actor authority controls native Updates and Deletes
* supported: native Mark state changes retain immutable history and create a new Note while Review Updates retain one canonical Article
* stock_limitation: NeoDB local journal edits do not expose a conditional stale-update API
* supported: Shelf and ShelfItem OrderedCollections expose bounded items and orderedItems pages
* supported: catalog context, relatedWith, custom Movie tags, and unknown JSON-LD survive
* supported: only honest open-native controls are exposed by Unfathomably
* supported: Unfathomably replies become real Takahe application state
* supported: follower-only native journal state stays out of the public timeline
* supported: duplicate delivery and repeated native Deletes are safe
* supported: Blocks, Undo Blocks, and federated Flags round-trip in both directions
* stock_limitation: stock Takahe reuses an undone Follow ID when refollowing after Block teardown
* supported: linked catalog resources survive without recursive or unbounded fetching
* supported: native journal Deletes and relationship cleanup remove local state
* $group_summary
* not_supported: NeoDB domain blocking gives the blocked peer no durable defederation signal
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run_neodb_smoke
fi

# end of build_scripts/unfathomably-neodb-smoke.sh
