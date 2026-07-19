#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-bookwyrm-smoke.sh
#
# Purpose:
#
#   Run an unmodified BookWyrm instance against Unfathomably and verify both
#   ActivityPub delivery and the resulting native application state.
#
# Responsibilities:
#
#   * build or reuse the checked-out upstream BookWyrm image
#   * exercise account relationships, statuses, native book statuses, and Likes
#   * prove native Review and compatibility Article semantic deduplication
#   * exercise replies, Updates, Deletes, Blocks, and federated reports
#   * keep unsupported Group and defederation behavior explicit
#
# This file intentionally does NOT contain:
#
#   * patched BookWyrm source or images
#   * browser automation or production credentials
#   * synthetic activities substituted for BookWyrm model behavior
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAMILY_HARNESS="$SCRIPT_DIR/unfathomably-gotosocial-smoke.sh"

if [ ! -f "$FAMILY_HARNESS" ]; then
    printf 'Required account-federation harness not found: %s\n' "$FAMILY_HARNESS" >&2
    exit 1
fi

export SMOKE_PREFIX="${SMOKE_PREFIX:-unfathomably-bookwyrm-smoke}"
export BE_HOST="${BE_HOST:-unfathomably-bookwyrm.test}"
export BE_PORT="${BE_PORT:-5031}"
export BE_DB_NAME="${BE_DB_NAME:-unfathomably_bookwyrm_smoke_be}"
export GTS_HOST="${GTS_HOST:-bookwyrm-ref.test}"
export GTS_PORT="${GTS_PORT:-5032}"
export GTS_APP_PORT=8000
export GTS_LABEL=BookWyrm
export GTS_USERNAME=reader
export SMOKE_TLS=1
export BE_FEDERATION_SCHEME=https
export BE_FEDERATION_PORT=443

# shellcheck source=unfathomably-gotosocial-smoke.sh
source "$FAMILY_HARNESS"

BOOKWYRM_SOURCE="${BOOKWYRM_SOURCE:-/home/jkfirth/unfathomably-smoke/reference/bookwyrm}"
BOOKWYRM_IMAGE="${BOOKWYRM_IMAGE:-unfathomably-bookwyrm-smoke:0.9.1}"
BOOKWYRM_DB_CONTAINER="${SMOKE_PREFIX}-bookwyrm-db"
BOOKWYRM_REDIS_ACTIVITY_CONTAINER="${SMOKE_PREFIX}-bookwyrm-redis-activity"
BOOKWYRM_REDIS_BROKER_CONTAINER="${SMOKE_PREFIX}-bookwyrm-redis-broker"
BOOKWYRM_WORKER_CONTAINER="${SMOKE_PREFIX}-bookwyrm-worker"
BOOKWYRM_DB_IMAGE="${BOOKWYRM_DB_IMAGE:-postgres:17-alpine}"
BOOKWYRM_REDIS_IMAGE="${BOOKWYRM_REDIS_IMAGE:-redis:7-alpine}"
BOOKWYRM_DB_NAME="${BOOKWYRM_DB_NAME:-bookwyrm}"
BOOKWYRM_DB_USER="${BOOKWYRM_DB_USER:-bookwyrm}"
BOOKWYRM_DB_PASSWORD="${BOOKWYRM_DB_PASSWORD:-bookwyrm-smoke-database-password}"
BOOKWYRM_REDIS_ACTIVITY_PASSWORD="${BOOKWYRM_REDIS_ACTIVITY_PASSWORD:-bookwyrm-smoke-activity-password}"
BOOKWYRM_REDIS_BROKER_PASSWORD="${BOOKWYRM_REDIS_BROKER_PASSWORD:-bookwyrm-smoke-broker-password}"
BOOKWYRM_PASSWORD="${BOOKWYRM_PASSWORD:-bookwyrm-smoke-password-12345}"
BOOKWYRM_ACTOR="https://$GTS_HOST/user/$GTS_USERNAME"

BOOKWYRM_ENV=(
    -e "DOMAIN=$GTS_HOST"
    -e 'ALLOWED_HOSTS=*'
    -e 'DEBUG=false'
    -e 'SECRET_KEY=bookwyrm-smoke-secret-key-0123456789abcdefghijklmnopqrstuvwxyz'
    -e 'LANGUAGE_CODE=en-us'
    -e 'DEFAULT_LANGUAGE=English'
    -e 'STATIC_ROOT=/app/static'
    -e 'MEDIA_ROOT=/app/images'
    -e 'ENABLE_PREVIEW_IMAGES=false'
    -e 'ENABLE_THUMBNAIL_GENERATION=false'
    -e 'EMAIL_BACKEND=django.core.mail.backends.console.EmailBackend'
    -e 'EMAIL_HOST=localhost'
    -e 'EMAIL_PORT=25'
    -e 'EMAIL_HOST_USER=bookwyrm-smoke'
    -e 'EMAIL_HOST_PASSWORD=bookwyrm-smoke'
    -e 'EMAIL_USE_TLS=false'
    -e 'EMAIL_USE_SSL=false'
    -e "POSTGRES_HOST=$BOOKWYRM_DB_CONTAINER"
    -e 'PGPORT=5432'
    -e "POSTGRES_DB=$BOOKWYRM_DB_NAME"
    -e "POSTGRES_USER=$BOOKWYRM_DB_USER"
    -e "POSTGRES_PASSWORD=$BOOKWYRM_DB_PASSWORD"
    -e "REDIS_ACTIVITY_HOST=$BOOKWYRM_REDIS_ACTIVITY_CONTAINER"
    -e 'REDIS_ACTIVITY_PORT=6379'
    -e "REDIS_ACTIVITY_PASSWORD=$BOOKWYRM_REDIS_ACTIVITY_PASSWORD"
    -e "REDIS_BROKER_HOST=$BOOKWYRM_REDIS_BROKER_CONTAINER"
    -e 'REDIS_BROKER_PORT=6379'
    -e "REDIS_BROKER_PASSWORD=$BOOKWYRM_REDIS_BROKER_PASSWORD"
    -e 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt'
    -e 'REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt'
)

cleanup_bookwyrm_smoke() {
    local status="$?"

    if [ "$KEEP_CONTAINERS" = "1" ]; then
        cleanup "$status"
    fi

    docker rm -f \
        "$BOOKWYRM_WORKER_CONTAINER" \
        "$BOOKWYRM_REDIS_BROKER_CONTAINER" \
        "$BOOKWYRM_REDIS_ACTIVITY_CONTAINER" \
        "$BOOKWYRM_DB_CONTAINER" >/dev/null 2>&1 || true
    cleanup "$status"
}

trap cleanup_bookwyrm_smoke EXIT

ensure_bookwyrm_image() {
    local compatible_dockerfile="$WORK_DIR/BookWyrm.Dockerfile"

    if docker image inspect "$BOOKWYRM_IMAGE" >/dev/null 2>&1; then
        return 0
    fi

    [ -f "$BOOKWYRM_SOURCE/Dockerfile" ] || \
        fail "BookWyrm source checkout not found at $BOOKWYRM_SOURCE"

    log "Building stock BookWyrm image from $BOOKWYRM_SOURCE"

    if docker buildx version >/dev/null 2>&1; then
        DOCKER_BUILDKIT=1 docker build -t "$BOOKWYRM_IMAGE" "$BOOKWYRM_SOURCE"
        return 0
    fi

    #
    # Some dedicated smoke hosts have Docker's classic builder but not the
    # optional buildx client. Cache mounts only affect build speed, so remove
    # those hints from a disposable Dockerfile instead of modifying upstream
    # BookWyrm or maintaining a forked image definition.
    #
    sed -E \
        's/^RUN (--mount=[^ ]+ )+/RUN /' \
        "$BOOKWYRM_SOURCE/Dockerfile" >"$compatible_dockerfile"
    DOCKER_BUILDKIT=0 docker build \
        -f "$compatible_dockerfile" \
        -t "$BOOKWYRM_IMAGE" \
        "$BOOKWYRM_SOURCE"
}

wait_bookwyrm_postgres() {
    local stable=0

    for _ in $(seq 1 120); do
        if docker exec "$BOOKWYRM_DB_CONTAINER" \
            pg_isready -U "$BOOKWYRM_DB_USER" -d "$BOOKWYRM_DB_NAME" >/dev/null 2>&1; then
            stable=$((stable + 1))

            if [ "$stable" -ge 3 ]; then
                return 0
            fi
        else
            stable=0
        fi

        sleep 1
    done

    fail "BookWyrm PostgreSQL did not become ready"
}

start_bookwyrm_dependencies() {
    docker run -d \
        --name "$BOOKWYRM_DB_CONTAINER" \
        --hostname "$BOOKWYRM_DB_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$BOOKWYRM_DB_CONTAINER" \
        -e "POSTGRES_DB=$BOOKWYRM_DB_NAME" \
        -e "POSTGRES_USER=$BOOKWYRM_DB_USER" \
        -e "POSTGRES_PASSWORD=$BOOKWYRM_DB_PASSWORD" \
        "$BOOKWYRM_DB_IMAGE" >/dev/null

    docker run -d \
        --name "$BOOKWYRM_REDIS_ACTIVITY_CONTAINER" \
        --hostname "$BOOKWYRM_REDIS_ACTIVITY_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$BOOKWYRM_REDIS_ACTIVITY_CONTAINER" \
        "$BOOKWYRM_REDIS_IMAGE" \
        redis-server --requirepass "$BOOKWYRM_REDIS_ACTIVITY_PASSWORD" >/dev/null

    docker run -d \
        --name "$BOOKWYRM_REDIS_BROKER_CONTAINER" \
        --hostname "$BOOKWYRM_REDIS_BROKER_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$BOOKWYRM_REDIS_BROKER_CONTAINER" \
        "$BOOKWYRM_REDIS_IMAGE" \
        redis-server --requirepass "$BOOKWYRM_REDIS_BROKER_PASSWORD" >/dev/null
}

start_bookwyrm() {
    docker run -d \
        --name "$GTS_CONTAINER" \
        --hostname "$GTS_APP_HOST" \
        --network "$NETWORK" \
        --network-alias "$GTS_APP_HOST" \
        --entrypoint /bin/bash \
        "${BOOKWYRM_ENV[@]}" \
        -v "$SMOKE_CA_CERT:/usr/local/share/ca-certificates/unfathomably-smoke.crt:ro" \
        "$BOOKWYRM_IMAGE" \
        -lc 'set -euo pipefail; export PATH=/venv/bin:$PATH; update-ca-certificates >/dev/null; exec /entrypoint.sh gunicorn bookwyrm.wsgi:application' >/dev/null

    start_gts_proxy
}

wait_bookwyrm() {
    for _ in $(seq 1 240); do
        if curl -fsS "$GTS_BASE/" >/dev/null 2>&1; then
            return 0
        fi

        sleep 1
    done

    docker logs "$GTS_CONTAINER" >&2 || true
    fail "Timed out waiting for BookWyrm at $GTS_BASE"
}

start_bookwyrm_worker() {
    docker run -d \
        --name "$BOOKWYRM_WORKER_CONTAINER" \
        --hostname "$BOOKWYRM_WORKER_CONTAINER" \
        --network "$NETWORK" \
        --entrypoint /bin/bash \
        "${BOOKWYRM_ENV[@]}" \
        -v "$SMOKE_CA_CERT:/usr/local/share/ca-certificates/unfathomably-smoke.crt:ro" \
        "$BOOKWYRM_IMAGE" \
        -lc 'set -euo pipefail; export PATH=/venv/bin:$PATH; update-ca-certificates >/dev/null; exec celery -A celerywyrm worker --pool=threads --concurrency=4 -l info -Q high_priority,medium_priority,low_priority,streams,images,suggested_users,email,connectors,lists,inbox,imports,import_triggered,broadcast,misc' >/dev/null
}

bookwyrm_shell() {
    docker exec "$GTS_CONTAINER" python manage.py shell -c "$1"
}

bookwyrm_value() {
    bookwyrm_shell "$1" 2>/dev/null | tail -n 1
}

poll_bookwyrm_value() {
    local code="$1"
    local expected="$2"
    local message="$3"
    local result=""

    for _ in $(seq 1 90); do
        result="$(bookwyrm_value "$code" || true)"

        if [ "$result" = "$expected" ]; then
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

create_bookwyrm_user() {
    bookwyrm_shell "from bookwyrm import models; site=models.SiteSettings.get(); site.install_mode=False; site.allow_registration=False; site.disable_federation=False; site.save(); user=models.User.objects.filter(localname='$GTS_USERNAME', local=True).first() or models.User.objects.create_user('$GTS_USERNAME@$GTS_HOST', '$GTS_USERNAME@$GTS_HOST', '$BOOKWYRM_PASSWORD', local=True, localname='$GTS_USERNAME', name='BookWyrm smoke reader', bookwyrm_user=True); user.manually_approves_followers=False; user.is_discoverable=True; user.save(broadcast=False); print(user.remote_id)" >/dev/null
}

resolve_alice_in_bookwyrm() {
    local alice_ap_id="$1"

    bookwyrm_value "from bookwyrm import activitypub, models; user=activitypub.resolve_remote_id('$alice_ap_id', model=models.User); print(user.remote_id)"
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

    fail "Follower-only BookWyrm status leaked into Unfathomably's public timeline"
}

run_bookwyrm_smoke() {
    local webfinger actor work
    local be_credentials alice_ap_id alice_in_bookwyrm
    local relationship
    local be_to_bw_text be_to_bw_post be_to_bw_id be_to_bw_uri
    local native_text native_updated_text native_data native_uri work_uri edition_uri
    local be_native_id be_native_status
    local be_reply_text be_reply be_reply_id be_reply_uri
    local bw_comment_text bw_comment_data bw_comment_uri be_comment_id
    local private_text private_data private_uri be_private_id
    local be_report_text bw_report_text

    ensure_bookwyrm_image
    write_be_secret
    write_proxy_configs

    log "Creating isolated BookWyrm federation network"
    docker rm -f \
        "$BOOKWYRM_WORKER_CONTAINER" \
        "$BOOKWYRM_REDIS_BROKER_CONTAINER" \
        "$BOOKWYRM_REDIS_ACTIVITY_CONTAINER" \
        "$BOOKWYRM_DB_CONTAINER" \
        "$GTS_PROXY_CONTAINER" \
        "$GTS_CONTAINER" \
        "$BE_PROXY_CONTAINER" \
        "$BE_CONTAINER" \
        "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    docker network create "$NETWORK" >/dev/null
    prepare_smoke_tls

    log "Starting databases and stock BookWyrm"
    docker run -d \
        --name "$BE_DB_CONTAINER" \
        --hostname "$BE_DB_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$BE_DB_CONTAINER" \
        -e POSTGRES_PASSWORD="$BE_DB_PASSWORD" \
        "$POSTGRES_IMAGE" >/dev/null
    start_bookwyrm_dependencies
    wait_postgres
    wait_bookwyrm_postgres
    prepare_database
    start_bookwyrm
    wait_bookwyrm
    create_bookwyrm_user
    start_bookwyrm_worker

    log "Proving BookWyrm WebFinger, actor, and native Work discovery"
    webfinger="$(http_form GET "$GTS_BASE/.well-known/webfinger?resource=acct:$GTS_USERNAME@$GTS_HOST" "" 200)"
    json_assert "$webfinger" \
        "data.get('subject') == 'acct:$GTS_USERNAME@$GTS_HOST' and any(item.get('href') == '$BOOKWYRM_ACTOR' for item in data.get('links', []))" \
        "BookWyrm WebFinger did not expose the canonical reader actor"
    actor="$(curl -fsS -H 'Accept: application/activity+json' "$GTS_BASE/user/$GTS_USERNAME")"
    json_assert "$actor" \
        "data.get('id') == '$BOOKWYRM_ACTOR' and data.get('type') == 'Person'" \
        "BookWyrm actor discovery did not return a Person"

    log "Migrating and starting Unfathomably"
    migrate_and_create_be_user alice "alice@$BE_HOST"
    start_be
    start_be_proxy
    wait_be
    ALICE_TOKEN="$(create_be_token alice)"
    be_credentials="$(http_form GET "$BE_BASE/api/v1/accounts/verify_credentials" "$ALICE_TOKEN" 200)"
    alice_ap_id="$(json_get "$be_credentials" pleroma.ap_id)"

    log "Following accounts in both directions using native BookWyrm relationships"
    alice_in_bookwyrm="$(resolve_alice_in_bookwyrm "$alice_ap_id")"
    [ "$alice_in_bookwyrm" = "$alice_ap_id" ] || fail "BookWyrm resolved the wrong Unfathomably actor"
    bookwyrm_shell "from bookwyrm import models; reader=models.User.objects.get(remote_id='$BOOKWYRM_ACTOR'); alice=models.User.objects.get(remote_id='$alice_ap_id'); models.UserFollowRequest.objects.get_or_create(user_subject=reader, user_object=alice)" >/dev/null

    GTS_ACCOUNT_ID="$(resolve_account_id "$BE_BASE" "$ALICE_TOKEN" "$GTS_USERNAME@$GTS_HOST" "Unfathomably could not resolve the BookWyrm reader")"
    http_form POST "$BE_BASE/api/v1/accounts/$GTS_ACCOUNT_ID/follow" "$ALICE_TOKEN" 200 >/dev/null

    poll_bookwyrm_value \
        "from bookwyrm import models; print(models.UserFollows.objects.filter(user_subject__remote_id='$BOOKWYRM_ACTOR', user_object__remote_id='$alice_ap_id').count())" \
        1 "BookWyrm did not record its accepted follow of Unfathomably"
    poll_bookwyrm_value \
        "from bookwyrm import models; print(models.UserFollows.objects.filter(user_subject__remote_id='$alice_ap_id', user_object__remote_id='$BOOKWYRM_ACTOR').count())" \
        1 "BookWyrm did not accept Unfathomably's follow"
    relationship="$(poll_json_assert \
        "http_form GET '$BE_BASE/api/v1/accounts/relationships?id[]=$GTS_ACCOUNT_ID' '$ALICE_TOKEN' 200" \
        'len(data) == 1 and data[0].get("following") is True and data[0].get("followed_by") is True' \
        "Unfathomably did not record both BookWyrm relationship directions")"

    log "Creating a native Review and its compatibility Article in BookWyrm"
    native_text="BookWyrm native review $(basename "$WORK_DIR")"
    native_data="$(bookwyrm_value "import json; from bookwyrm import models; reader=models.User.objects.get(remote_id='$BOOKWYRM_ACTOR'); alice=models.User.objects.get(remote_id='$alice_ap_id'); work=models.Work(title='Alien federation work', last_edited_by=reader); work.save(broadcast=False); edition=models.Edition(title='Alien federation edition', parent_work=work, last_edited_by=reader); edition.save(broadcast=False); review=models.Review(user=reader, book=edition, name='Alien review', content='$native_text', rating=4.5, reading_status='read', privacy='public'); review.save(broadcast=False); review.mention_users.add(alice); review.save(created=True); print(json.dumps({'review': review.remote_id, 'work': work.remote_id, 'edition': edition.remote_id}))")"
    native_uri="$(json_get "$native_data" review)"
    work_uri="$(json_get "$native_data" work)"
    edition_uri="$(json_get "$native_data" edition)"

    work="$(curl -fsS -H 'Accept: application/activity+json' "${GTS_BASE}${work_uri#https://$GTS_HOST}")"
    json_assert "$work" \
        "data.get('id') == '$work_uri' and data.get('type') == 'Work'" \
        "BookWyrm did not expose its Work in native ActivityPub form"
    be_native_id="$(poll_home_status_by_text "$BE_BASE" "$ALICE_TOKEN" "$native_text" "Unfathomably did not receive the BookWyrm Review")"
    be_native_status="$(http_form GET "$BE_BASE/api/v1/statuses/$be_native_id" "$ALICE_TOKEN" 200)"
    json_assert "$be_native_status" \
        "data.get('uri') == '$native_uri' and data.get('account', {}).get('statuses_count') == 1 and data.get('pleroma', {}).get('native', {}).get('type') == 'Review' and data.get('pleroma', {}).get('native', {}).get('class') == 'status' and data.get('pleroma', {}).get('native', {}).get('controls') == ['open'] and str(data.get('pleroma', {}).get('native', {}).get('fields', {}).get('rating')) in ['4.5', '4.50'] and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('in_reply_to_book') == '$edition_uri'" \
        "Unfathomably did not preserve and classify BookWyrm Review metadata"

    #
    # BookWyrm intentionally ignores unrelated top-level Notes. A reply to an
    # existing native status is one of its documented compatibility forms, so
    # use that real acceptance path to prove Unfathomably-to-BookWyrm state.
    #
    log "Delivering an Unfathomably reply into native BookWyrm state"
    be_to_bw_text="Unfathomably to BookWyrm $(basename "$WORK_DIR")"
    be_to_bw_post="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$be_to_bw_text" \
        "in_reply_to_id=$be_native_id" \
        'visibility=public')"
    be_to_bw_id="$(json_get "$be_to_bw_post" id)"
    be_to_bw_uri="$(json_get "$be_to_bw_post" uri)"
    poll_bookwyrm_value \
        "from bookwyrm import models; print(models.Status.objects.filter(remote_id='$be_to_bw_uri', deleted=False, reply_parent__remote_id='$native_uri').count())" \
        1 "BookWyrm did not retain the Unfathomably reply"

    log "Updating the native Review"
    native_updated_text="$native_text updated"
    bookwyrm_shell "from bookwyrm import models; review=models.Status.objects.select_subclasses().get(remote_id='$native_uri'); review.content='$native_updated_text'; review.save()" >/dev/null
    poll_json_assert \
        "http_form GET '$BE_BASE/api/v1/statuses/$be_native_id' '$ALICE_TOKEN' 200" \
        "'$native_updated_text' in (data.get('content') or '')" \
        "Unfathomably did not apply the BookWyrm Review Update" >/dev/null

    log "Testing Likes and Undo Likes in both directions"
    http_form POST "$BE_BASE/api/v1/statuses/$be_native_id/favourite" "$ALICE_TOKEN" 200 >/dev/null
    poll_bookwyrm_value \
        "from bookwyrm import models; print(models.Favorite.objects.filter(user__remote_id='$alice_ap_id', status__remote_id='$native_uri').count())" \
        1 "BookWyrm did not receive Unfathomably's Like"
    http_form POST "$BE_BASE/api/v1/statuses/$be_native_id/unfavourite" "$ALICE_TOKEN" 200 >/dev/null
    poll_bookwyrm_value \
        "from bookwyrm import models; print(models.Favorite.objects.filter(user__remote_id='$alice_ap_id', status__remote_id='$native_uri').count())" \
        0 "BookWyrm did not receive Unfathomably's Undo Like"

    bookwyrm_shell "from bookwyrm import models; reader=models.User.objects.get(remote_id='$BOOKWYRM_ACTOR'); status=models.Status.objects.get(remote_id='$be_to_bw_uri'); models.Favorite.objects.get_or_create(user=reader, status=status)" >/dev/null
    poll_status_count "$BE_BASE" "$ALICE_TOKEN" "$be_to_bw_id" \
        'int(data.get("favourites_count") or 0) == 1' \
        "Unfathomably did not receive BookWyrm's Like"
    bookwyrm_shell "from bookwyrm import models; models.Favorite.objects.get(user__remote_id='$BOOKWYRM_ACTOR', status__remote_id='$be_to_bw_uri').delete()" >/dev/null
    poll_status_count "$BE_BASE" "$ALICE_TOKEN" "$be_to_bw_id" \
        'int(data.get("favourites_count") or 0) == 0' \
        "Unfathomably did not receive BookWyrm's Undo Like"

    log "Testing replies and reply Deletes in both directions"
    be_reply_text="Unfathomably reply to BookWyrm $(basename "$WORK_DIR")"
    be_reply="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$be_reply_text" \
        "in_reply_to_id=$be_native_id")"
    be_reply_id="$(json_get "$be_reply" id)"
    be_reply_uri="$(json_get "$be_reply" uri)"
    poll_bookwyrm_value \
        "from bookwyrm import models; print(models.Status.objects.filter(remote_id='$be_reply_uri', deleted=False, reply_parent__remote_id='$native_uri').count())" \
        1 "BookWyrm did not retain Unfathomably's reply"
    http_form DELETE "$BE_BASE/api/v1/statuses/$be_reply_id" "$ALICE_TOKEN" 200 >/dev/null
    poll_bookwyrm_value \
        "from bookwyrm import models; print(models.Status.objects.filter(remote_id='$be_reply_uri', deleted=True).count())" \
        1 "BookWyrm did not tombstone Unfathomably's deleted reply"

    bw_comment_text="BookWyrm native comment $(basename "$WORK_DIR")"
    bw_comment_data="$(bookwyrm_value "import json; from bookwyrm import models; reader=models.User.objects.get(remote_id='$BOOKWYRM_ACTOR'); alice=models.User.objects.get(remote_id='$alice_ap_id'); parent=models.Status.objects.get(remote_id='$be_to_bw_uri'); edition=models.Edition.objects.get(remote_id='$edition_uri'); comment=models.Comment(user=reader, book=edition, reply_parent=parent, content='$bw_comment_text', reading_status='reading', progress=12, progress_mode='PG', privacy='public'); comment.save(broadcast=False); comment.mention_users.add(alice); comment.save(created=True); print(json.dumps({'comment': comment.remote_id}))")"
    bw_comment_uri="$(json_get "$bw_comment_data" comment)"
    poll_context_status_by_text "$BE_BASE" "$ALICE_TOKEN" "$be_to_bw_id" "$bw_comment_text" \
        "Unfathomably did not receive the native BookWyrm Comment"
    be_comment_id="$(resolve_status_id "$BE_BASE" "$ALICE_TOKEN" "$bw_comment_uri" "Unfathomably could not resolve the BookWyrm Comment")"
    bookwyrm_shell "from bookwyrm import models; models.Status.objects.select_subclasses().get(remote_id='$bw_comment_uri').delete()" >/dev/null
    poll_status_missing "$BE_BASE" "$ALICE_TOKEN" "$be_comment_id" \
        "Unfathomably retained the deleted BookWyrm Comment"

    log "Testing follower-only privacy outside public caches"
    private_text="BookWyrm follower-only review $(basename "$WORK_DIR")"
    private_data="$(bookwyrm_value "import json; from bookwyrm import models; reader=models.User.objects.get(remote_id='$BOOKWYRM_ACTOR'); alice=models.User.objects.get(remote_id='$alice_ap_id'); edition=models.Edition.objects.get(remote_id='$edition_uri'); review=models.Review(user=reader, book=edition, name='Restricted review', content='$private_text', rating=3.5, privacy='followers'); review.save(broadcast=False); review.mention_users.add(alice); review.save(created=True); print(json.dumps({'review': review.remote_id}))")"
    private_uri="$(json_get "$private_data" review)"
    be_private_id="$(poll_home_status_by_text "$BE_BASE" "$ALICE_TOKEN" "$private_text" "Unfathomably follower did not receive the restricted BookWyrm Review")"
    assert_public_timeline_missing "$private_text"
    bookwyrm_shell "from bookwyrm import models; models.Status.objects.select_subclasses().get(remote_id='$private_uri').delete()" >/dev/null
    poll_status_missing "$BE_BASE" "$ALICE_TOKEN" "$be_private_id" \
        "Unfathomably retained the deleted restricted BookWyrm Review"

    log "Testing federated moderation reports in both directions"
    be_report_text="Unfathomably report to BookWyrm $(basename "$WORK_DIR")"
    http_form POST "$BE_BASE/api/v1/reports" "$ALICE_TOKEN" 200 \
        "account_id=$GTS_ACCOUNT_ID" \
        "status_ids[]=$be_native_id" \
        "comment=$be_report_text" \
        'forward=true' >/dev/null
    poll_bookwyrm_value \
        "from bookwyrm import models; print(models.Report.objects.filter(note__contains='$be_report_text').count())" \
        1 "BookWyrm did not receive Unfathomably's federated report"

    bw_report_text="BookWyrm report to Unfathomably $(basename "$WORK_DIR")"
    bookwyrm_shell "from bookwyrm import models; reader=models.User.objects.get(remote_id='$BOOKWYRM_ACTOR'); alice=models.User.objects.get(remote_id='$alice_ap_id'); report=models.Report(user=reader, reported_user=alice, note='$bw_report_text', allow_broadcast=True); report.save()" >/dev/null
    poll_be_report_by_text "$bw_report_text" \
        "Unfathomably did not receive BookWyrm's federated report"

    log "Testing status Deletes"
    http_form DELETE "$BE_BASE/api/v1/statuses/$be_to_bw_id" "$ALICE_TOKEN" 200 >/dev/null
    poll_bookwyrm_value \
        "from bookwyrm import models; print(models.Status.objects.filter(remote_id='$be_to_bw_uri', deleted=True).count())" \
        1 "BookWyrm retained the deleted Unfathomably status"
    bookwyrm_shell "from bookwyrm import models; models.Status.objects.select_subclasses().get(remote_id='$native_uri').delete()" >/dev/null
    poll_status_missing "$BE_BASE" "$ALICE_TOKEN" "$be_native_id" \
        "Unfathomably retained the deleted BookWyrm Review"

    log "Unfollowing accounts in both directions"
    bookwyrm_shell "from bookwyrm import models; models.UserFollows.objects.get(user_subject__remote_id='$BOOKWYRM_ACTOR', user_object__remote_id='$alice_ap_id').delete()" >/dev/null
    http_form POST "$BE_BASE/api/v1/accounts/$GTS_ACCOUNT_ID/unfollow" "$ALICE_TOKEN" 200 >/dev/null
    poll_bookwyrm_value \
        "from bookwyrm import models; print(models.UserFollows.objects.filter(user_subject__remote_id='$alice_ap_id', user_object__remote_id='$BOOKWYRM_ACTOR').count())" \
        0 "BookWyrm retained Unfathomably's undone follow"
    poll_json_assert \
        "http_form GET '$BE_BASE/api/v1/accounts/relationships?id[]=$GTS_ACCOUNT_ID' '$ALICE_TOKEN' 200" \
        'len(data) == 1 and data[0].get("following") is False and data[0].get("followed_by") is False' \
        "Unfathomably retained a BookWyrm follow after both Undo activities" >/dev/null

    log "Testing Blocks and Undo Blocks in both directions"
    http_form POST "$BE_BASE/api/v1/accounts/$GTS_ACCOUNT_ID/block" "$ALICE_TOKEN" 200 >/dev/null
    poll_bookwyrm_value \
        "from bookwyrm import models; print(models.UserBlocks.objects.filter(user_subject__remote_id='$alice_ap_id', user_object__remote_id='$BOOKWYRM_ACTOR').count())" \
        1 "BookWyrm did not receive Unfathomably's Block"
    http_form POST "$BE_BASE/api/v1/accounts/$GTS_ACCOUNT_ID/unblock" "$ALICE_TOKEN" 200 >/dev/null
    poll_bookwyrm_value \
        "from bookwyrm import models; print(models.UserBlocks.objects.filter(user_subject__remote_id='$alice_ap_id', user_object__remote_id='$BOOKWYRM_ACTOR').count())" \
        0 "BookWyrm did not receive Unfathomably's Undo Block"

    bookwyrm_shell "from bookwyrm import models; reader=models.User.objects.get(remote_id='$BOOKWYRM_ACTOR'); alice=models.User.objects.get(remote_id='$alice_ap_id'); models.UserBlocks.objects.get_or_create(user_subject=reader, user_object=alice)" >/dev/null
    poll_json_assert \
        "http_form GET '$BE_BASE/api/v1/accounts/relationships?id[]=$GTS_ACCOUNT_ID' '$ALICE_TOKEN' 200" \
        'len(data) == 1 and data[0].get("blocked_by") is True' \
        "Unfathomably did not record BookWyrm's Block" >/dev/null
    bookwyrm_shell "from bookwyrm import models; models.UserBlocks.objects.get(user_subject__remote_id='$BOOKWYRM_ACTOR', user_object__remote_id='$alice_ap_id').delete()" >/dev/null
    poll_json_assert \
        "http_form GET '$BE_BASE/api/v1/accounts/relationships?id[]=$GTS_ACCOUNT_ID' '$ALICE_TOKEN' 200" \
        'len(data) == 1 and data[0].get("blocked_by") is False' \
        "Unfathomably did not clear BookWyrm's Undo Block" >/dev/null

    check_logs "$BE_CONTAINER" Unfathomably
    check_logs "$GTS_CONTAINER" BookWyrm
    check_logs "$BOOKWYRM_WORKER_CONTAINER" "BookWyrm worker"

    cat <<EOF

BookWyrm federation smoke passed.

Covered against stock BookWyrm:
* supported: WebFinger, Person actor discovery, and canonical HTTPS identifiers
* supported: account follows, accepts, unfollows, and cleanup in both directions
* supported: standard Note reply ingestion into native BookWyrm state
* supported: native Review plus Article fallback semantic deduplication
* supported: Work discovery and preserved Review rating, reading state, and inReplyToBook vocabulary
* supported: Review Update and timestamped lifecycle handling
* supported: Likes and Undo Likes in both directions
* supported: replies and reply Deletes in both directions
* supported: status Deletes in both directions
* supported: follower-only delivery without public timeline leakage
* supported: Blocks and Undo Blocks in both directions
* supported: federated moderation reports are received in both directions
* supported: UI metadata classifies Review as a native status with only the honest open control
* not_supported: BookWyrm does not expose Group-specific follow or group-unfollow semantics
* not_supported: BookWyrm does not receive a durable signal that a remote server defederated it
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run_bookwyrm_smoke
fi

# end of build_scripts/unfathomably-bookwyrm-smoke.sh
