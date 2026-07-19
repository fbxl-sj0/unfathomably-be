#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-manyfold-smoke.sh
#
# Purpose:
#
#   Run an unmodified Manyfold instance against Unfathomably and verify that
#   followable 3D-model actors retain their native meaning across federation.
#
# Responsibilities:
#
#   * boot the official Manyfold solo image on an isolated TLS network
#   * create stock User, Creator, Collection, and Model application state
#   * exercise account and group relationships in both directions
#   * prove native actor updates and compatibility Note handling
#   * exercise native comments, Likes, Deletes, reports, and domain blocks
#   * keep unsupported stock Manyfold behavior explicit
#
# This file intentionally does NOT contain:
#
#   * patched Manyfold source or images
#   * synthetic activities substituted for Manyfold model behavior
#   * browser automation or production credentials
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAMILY_HARNESS="$SCRIPT_DIR/unfathomably-gotosocial-smoke.sh"

if [ ! -f "$FAMILY_HARNESS" ]; then
    printf 'Required account-federation harness not found: %s\n' "$FAMILY_HARNESS" >&2
    exit 1
fi

export SMOKE_PREFIX="${SMOKE_PREFIX:-unfathomably-manyfold-smoke}"
export BE_HOST="${BE_HOST:-unfathomably-manyfold.example.com}"
export BE_PORT="${BE_PORT:-5041}"
export BE_DB_NAME="${BE_DB_NAME:-unfathomably_manyfold_smoke_be}"
export GTS_HOST="${GTS_HOST:-manyfold-ref.example.com}"
export GTS_PORT="${GTS_PORT:-5042}"
export GTS_APP_PORT=3214
export GTS_FORWARDED_PROTO=https
export GTS_LABEL=Manyfold
export GTS_USERNAME=maker
export SMOKE_TLS=1
export BE_FEDERATION_SCHEME=https
export BE_FEDERATION_PORT=443

# shellcheck source-path=SCRIPTDIR
# shellcheck source=unfathomably-gotosocial-smoke.sh
source "$FAMILY_HARNESS"

MANYFOLD_IMAGE="${MANYFOLD_IMAGE:-manyfold3d/manyfold-solo:0.146.0}"
MANYFOLD_PASSWORD="${MANYFOLD_PASSWORD:-Manyfold-smoke-password-12345}"
MANYFOLD_SEED="$WORK_DIR/manyfold-seed.rb"
MANYFOLD_SEED_CONTAINER_PATH=/tmp/unfathomably-manyfold-seed.rb
MANYFOLD_CA_BUNDLE="$WORK_DIR/manyfold-ca-bundle.crt"
MANYFOLD_MODELS=/config/models

write_manyfold_seed() {
    cat >"$MANYFOLD_SEED" <<'RUBY'
#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-manyfold-seed.rb
#
# Purpose:
#
#   Create native Manyfold state used by the stock federation adapter.
#
# Responsibilities:
#
#   * create one local user and the four followable actor families
#   * expose a public model and retain a private-model privacy control
#   * avoid enqueuing publication jobs before remote followers exist
#
# This file intentionally does NOT contain hand-authored ActivityPub payloads.
#

maker = User.create!(
  username: "maker",
  email: "maker@manyfold-ref.test",
  password: ENV.fetch("MANYFOLD_PASSWORD"),
  password_confirmation: ENV.fetch("MANYFOLD_PASSWORD"),
  approved: true
)

creator = Creator.create!(
  name: "Alien Model Maker",
  caption: "Native Manyfold creator",
  notes: "Creator metadata retained by Unfathomably",
  indexable: "yes",
  permission_preset: :private,
  links_attributes: [
    {
      url: "https://resources.invalid/manyfold-creator",
      text: "External creator resource"
    }
  ]
)

collection = Collection.create!(
  name: "Alien Model Collection",
  caption: "Native Manyfold collection",
  notes: "Collection context retained by Unfathomably",
  creator: creator,
  indexable: "yes",
  permission_preset: :private
)

library = Library.create!(name: "Smoke Models", path: "/config/models")

model = Model.create!(
  name: "Alien Federation Model",
  library: library,
  path: "alien-model",
  license: "MIT",
  caption: "Native Manyfold model",
  notes: "Original model notes",
  creator: creator,
  collections: [collection],
  indexable: "yes",
  tag_list: "alien smoke",
  permission_preset: :private,
  links_attributes: [
    {
      url: "https://resources.invalid/manyfold-model",
      text: "External model resource"
    }
  ]
)

private_model = Model.create!(
  name: "Restricted Alien Model",
  library: library,
  path: "restricted-model",
  license: "MIT",
  caption: "Private Manyfold model",
  notes: "This model must not be publicly retrievable",
  creator: creator,
  indexable: "yes",
  permission_preset: :private
)

#
# Direct permission grants use Manyfold's own Caber model. Granting only after
# all relationships have been assembled prevents publication callbacks from
# observing a half-created model or collection.
#
creator.grant_permission_to("view", nil)
collection.grant_permission_to("view", nil)
model.grant_permission_to("view", nil)

[maker, creator, collection, model, private_model].each(&:reload)

puts JSON.generate(
  user_actor: maker.federails_actor.federated_url,
  user_username: maker.username,
  creator_actor: creator.federails_actor.federated_url,
  creator_username: creator.slug,
  collection_actor: collection.federails_actor.federated_url,
  collection_username: collection.public_id,
  model_actor: model.federails_actor.federated_url,
  model_username: model.public_id,
  private_model_actor: private_model.federails_actor.federated_url,
  private_model_username: private_model.public_id
)

# end of unfathomably-manyfold-seed.rb
RUBY
}

prepare_manyfold_ca_bundle() {
    if ! docker image inspect "$MANYFOLD_IMAGE" >/dev/null 2>&1; then
        log "Pulling stock Manyfold image $MANYFOLD_IMAGE"
        docker pull "$MANYFOLD_IMAGE" >/dev/null
    fi

    #
    # The official solo image includes Alpine's CA bundle but intentionally
    # omits the update-ca-certificates utility. Preserve public trust for JSON-
    # LD contexts and append the isolated smoke CA in a disposable host file.
    #
    docker run --rm --entrypoint /bin/sh "$MANYFOLD_IMAGE" \
        -c 'cat /etc/ssl/certs/ca-certificates.crt' >"$MANYFOLD_CA_BUNDLE"
    cat "$SMOKE_CA_CERT" >>"$MANYFOLD_CA_BUNDLE"
}

start_manyfold() {
    docker volume create "$GTS_VOLUME" >/dev/null

    docker run -d \
        --name "$GTS_CONTAINER" \
        --hostname "$GTS_APP_HOST" \
        --network "$NETWORK" \
        --network-alias "$GTS_APP_HOST" \
        -e 'SECRET_KEY_BASE=manyfold-smoke-secret-key-0123456789abcdefghijklmnopqrstuvwxyz' \
        -e 'FEDERATION=enabled' \
        -e 'MULTIUSER=enabled' \
        -e "PUBLIC_HOSTNAME=$GTS_HOST" \
        -e 'HTTPS_ONLY=enabled' \
        -e 'PUID=0' \
        -e 'PGID=0' \
        -e "MANYFOLD_PASSWORD=$MANYFOLD_PASSWORD" \
        -e 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' \
        -v "$GTS_VOLUME:/config" \
        -v "$MANYFOLD_CA_BUNDLE:/etc/ssl/certs/ca-certificates.crt:ro" \
        -v "$MANYFOLD_SEED:$MANYFOLD_SEED_CONTAINER_PATH:ro" \
        "$MANYFOLD_IMAGE" >/dev/null

    start_gts_proxy
}

wait_manyfold() {
    for _ in $(seq 1 240); do
        if curl -fsS "$GTS_BASE/" >/dev/null 2>&1; then
            return 0
        fi

        sleep 1
    done

    docker logs "$GTS_CONTAINER" >&2 || true
    fail "Timed out waiting for Manyfold at $GTS_BASE"
}

manyfold_runner() {
    local code="$1"
    shift

    docker exec "$@" "$GTS_CONTAINER" bundle exec rails runner "$code" 2>/dev/null | tail -n 1
}

manyfold_sql_value() {
    local sql="$1"
    local arg1="${2:-}"
    local arg2="${3:-}"
    local arg3="${4:-}"

    docker exec \
        -e "MANYFOLD_SQL=$sql" \
        -e "MANYFOLD_ARG1=$arg1" \
        -e "MANYFOLD_ARG2=$arg2" \
        -e "MANYFOLD_ARG3=$arg3" \
        "$GTS_CONTAINER" \
        bundle exec ruby -rsqlite3 -e '
          database = SQLite3::Database.new("/config/manyfold.sqlite3")
          sql = ENV.fetch("MANYFOLD_SQL")
          bind_count = sql.count("?")
          binds = ENV.values_at("MANYFOLD_ARG1", "MANYFOLD_ARG2", "MANYFOLD_ARG3").first(bind_count)
          value = database.get_first_value(sql, binds)
          puts(value.nil? ? "" : value)
        ' 2>/dev/null | tail -n 1
}

poll_manyfold_sql() {
    local sql="$1"
    local expected="$2"
    local message="$3"
    local arg1="${4:-}"
    local arg2="${5:-}"
    local arg3="${6:-}"
    local result=""

    for _ in $(seq 1 60); do
        result="$(manyfold_sql_value "$sql" "$arg1" "$arg2" "$arg3" || true)"

        if [ "$result" = "$expected" ]; then
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

assert_manyfold_sql() {
    local sql="$1"
    local expected="$2"
    local message="$3"
    local arg1="${4:-}"
    local arg2="${5:-}"
    local arg3="${6:-}"
    local result

    result="$(manyfold_sql_value "$sql" "$arg1" "$arg2" "$arg3")"
    [ "$result" = "$expected" ] || {
        printf 'Expected %s, got %s\n' "$expected" "$result" >&2
        fail "$message"
    }
}

manyfold_follow_count() {
    local source_actor="$1"
    local target_actor="$2"
    local source_uuid="${source_actor##*/}"
    local target_uuid="${target_actor##*/}"
    local source_id target_id

    source_id="$(manyfold_sql_value \
        'SELECT id FROM federails_actors WHERE federated_url = ? OR uuid = ? LIMIT 1' \
        "$source_actor" "$source_uuid")"
    target_id="$(manyfold_sql_value \
        'SELECT id FROM federails_actors WHERE federated_url = ? OR uuid = ? LIMIT 1' \
        "$target_actor" "$target_uuid")"

    if [ -z "$source_id" ] || [ -z "$target_id" ]; then
        printf '0\n'
        return 0
    fi

    manyfold_sql_value \
        'SELECT COUNT(*) FROM federails_followings WHERE actor_id = ? AND target_actor_id = ? AND status = 1' \
        "$source_id" "$target_id"
}

poll_manyfold_follow() {
    local source_actor="$1"
    local target_actor="$2"
    local expected="$3"
    local message="$4"
    local result=""

    for _ in $(seq 1 60); do
        result="$(manyfold_follow_count "$source_actor" "$target_actor" || true)"

        if [ "$result" = "$expected" ]; then
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

poll_be_actor_extension() {
    local actor="$1"
    local expression="$2"
    local expected="$3"
    local message="$4"
    local result=""

    for _ in $(seq 1 60); do
        result="$(docker exec "$BE_DB_CONTAINER" psql -U postgres -d "$BE_DB_NAME" -Atq \
            -c "SELECT $expression FROM users WHERE ap_id = '$actor' LIMIT 1;" || true)"

        if [ "$result" = "$expected" ]; then
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "$message"
}

assert_home_timeline_missing() {
    local text="$1"
    local message="$2"
    local result

    result="$(http_form GET "$BE_BASE/api/v1/timelines/home?limit=40" "$ALICE_TOKEN" 200)"

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

    fail "$message"
}

assert_context_count() {
    local parent_id="$1"
    local text="$2"
    local expected="$3"
    local message="$4"
    local result count

    result="$(http_form GET "$BE_BASE/api/v1/statuses/$parent_id/context" "$ALICE_TOKEN" 200)"
    count="$(JSON_INPUT="$result" EXPECTED_TEXT="$text" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
text = os.environ["EXPECTED_TEXT"]
statuses = data.get("ancestors", []) + data.get("descendants", [])
print(sum(text in (status.get("content") or "") for status in statuses))
PY
)"

    [ "$count" = "$expected" ] || fail "$message"
}

run_manyfold_smoke() {
    local seed nodeinfo_links nodeinfo actor webfinger private_status
    local be_credentials alice_ap_id group group_actor
    local maker_account_id model_account_id creator_account_id collection_account_id
    local model_account creator_account collection_account maker_account
    local updated_name updated_notes fallback_status_id
    local top_level_text top_level top_level_id top_level_uri
    local be_comment_text be_comment be_comment_id be_comment_uri
    local manyfold_comment_text manyfold_comment_uri manyfold_comment_id
    local report_text local_report_text flag_count_before flag_count_after
    local blocked_inbound_text blocked_inbound blocked_inbound_id blocked_inbound_uri
    local blocked_outbound_text blocked_outbound_uri
    local tombstone_status

    write_manyfold_seed
    write_be_secret
    write_proxy_configs

    log "Creating isolated Manyfold federation network"
    docker rm -f \
        "$GTS_PROXY_CONTAINER" \
        "$GTS_CONTAINER" \
        "$BE_PROXY_CONTAINER" \
        "$BE_CONTAINER" \
        "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    docker volume rm "$GTS_VOLUME" >/dev/null 2>&1 || true
    docker network create "$NETWORK" >/dev/null
    prepare_smoke_tls
    prepare_manyfold_ca_bundle

    log "Starting PostgreSQL and stock Manyfold $MANYFOLD_IMAGE"
    docker run -d \
        --name "$BE_DB_CONTAINER" \
        --hostname "$BE_DB_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$BE_DB_CONTAINER" \
        -e POSTGRES_PASSWORD="$BE_DB_PASSWORD" \
        "$POSTGRES_IMAGE" >/dev/null
    wait_postgres
    prepare_database
    start_manyfold
    wait_manyfold

    log "Creating native Manyfold user, creator, collection, and model state"
    docker exec "$GTS_CONTAINER" mkdir -p \
        "$MANYFOLD_MODELS/alien-model" \
        "$MANYFOLD_MODELS/restricted-model"
    seed="$(docker exec "$GTS_CONTAINER" bundle exec rails runner \
        "$MANYFOLD_SEED_CONTAINER_PATH" 2>/dev/null | tail -n 1)"

    MANYFOLD_USER_ACTOR="$(json_get "$seed" user_actor)"
    MANYFOLD_USER_USERNAME="$(json_get "$seed" user_username)"
    MANYFOLD_CREATOR_ACTOR="$(json_get "$seed" creator_actor)"
    MANYFOLD_CREATOR_USERNAME="$(json_get "$seed" creator_username)"
    MANYFOLD_COLLECTION_ACTOR="$(json_get "$seed" collection_actor)"
    MANYFOLD_COLLECTION_USERNAME="$(json_get "$seed" collection_username)"
    MANYFOLD_MODEL_ACTOR="$(json_get "$seed" model_actor)"
    MANYFOLD_MODEL_USERNAME="$(json_get "$seed" model_username)"
    MANYFOLD_PRIVATE_MODEL_ACTOR="$(json_get "$seed" private_model_actor)"

    log "Proving Manyfold discovery, canonical IDs, and privacy"
    webfinger="$(http_form GET \
        "$GTS_BASE/.well-known/webfinger?resource=acct:$MANYFOLD_MODEL_USERNAME@$GTS_HOST" \
        "" 200)"
    json_assert "$webfinger" \
        "data.get('subject') == 'acct:$MANYFOLD_MODEL_USERNAME@$GTS_HOST' and any(item.get('href') == '$MANYFOLD_MODEL_ACTOR' for item in data.get('links', []))" \
        "Manyfold WebFinger did not expose the canonical model actor"

    actor="$(curl -fsS -H 'Accept: application/activity+json' \
        "$GTS_BASE${MANYFOLD_MODEL_ACTOR#https://"$GTS_HOST"}")"
    json_assert "$actor" \
        "data.get('id') == '$MANYFOLD_MODEL_ACTOR' and data.get('type') == 'Service' and data.get('f3di:concreteType') == '3DModel' and data.get('spdx:license', {}).get('spdx:licenseId') == 'MIT' and any(item.get('@id') == '$MANYFOLD_COLLECTION_ACTOR' for item in data.get('context', [])) and any(item.get('href') == 'https://resources.invalid/manyfold-model' for item in data.get('attachment', []))" \
        "Manyfold did not expose its complete native 3DModel representation"
    curl -fsS -H 'Accept: application/ld+json; profile="https://www.w3.org/ns/activitystreams"' \
        "$GTS_BASE${MANYFOLD_MODEL_ACTOR#https://"$GTS_HOST"}" >/dev/null

    nodeinfo_links="$(http_form GET "$GTS_BASE/.well-known/nodeinfo" "" 200)"
    nodeinfo="$(http_form GET "$GTS_BASE/nodeinfo/2.0" "" 200)"
    json_assert "$nodeinfo_links" \
        "any(item.get('href') == 'https://$GTS_HOST/nodeinfo/2.0' for item in data.get('links', []))" \
        "Manyfold NodeInfo discovery did not use its canonical HTTPS URL"
    json_assert "$nodeinfo" \
        "data.get('software', {}).get('name') == 'manyfold'" \
        "Manyfold NodeInfo did not identify the stock application"

    private_status="$(curl -sS -o /dev/null -w '%{http_code}' \
        -H 'Accept: application/activity+json' \
        "$GTS_BASE${MANYFOLD_PRIVATE_MODEL_ACTOR#https://"$GTS_HOST"}")"
    [ "$private_status" = "404" ] || \
        fail "Private Manyfold model was publicly retrievable with HTTP $private_status"

    log "Migrating and starting Unfathomably"
    migrate_and_create_be_user alice "alice@$BE_HOST"
    start_be
    start_be_proxy
    wait_be
    ALICE_TOKEN="$(create_be_token alice)"
    be_credentials="$(http_form GET "$BE_BASE/api/v1/accounts/verify_credentials" "$ALICE_TOKEN" 200)"
    alice_ap_id="$(json_get "$be_credentials" pleroma.ap_id)"

    group="$(http_form POST "$BE_BASE/api/v1/groups" "$ALICE_TOKEN" 200 \
        'display_name=Unfathomably Manyfold Group' \
        'name=unfathomably_manyfold_group' \
        'note=Open group used by the Manyfold federation smoke harness.' \
        'locked=false')"
    group_actor="$(json_get "$group" ap_id)"

    log "Following accounts in both directions using native relationships"
    manyfold_runner \
        'maker=User.find_by!(username: "maker"); target=Federails::Actor.find_or_create_by_federation_url(ENV.fetch("TARGET_ACTOR")); maker.follow(target) unless maker.following?(target); puts maker.following?(target)' \
        -e "TARGET_ACTOR=$alice_ap_id" >/dev/null

    maker_account_id="$(resolve_account_id "$BE_BASE" "$ALICE_TOKEN" \
        "$MANYFOLD_USER_USERNAME@$GTS_HOST" \
        "Unfathomably could not resolve the Manyfold user")"
    http_form POST "$BE_BASE/api/v1/accounts/$maker_account_id/follow" "$ALICE_TOKEN" 200 >/dev/null

    poll_manyfold_follow "$MANYFOLD_USER_ACTOR" "$alice_ap_id" 1 \
        "Manyfold did not record its accepted follow of Unfathomably"
    poll_manyfold_follow "$alice_ap_id" "$MANYFOLD_USER_ACTOR" 1 \
        "Manyfold did not accept Unfathomably's follow"
    poll_relationship_following "$BE_BASE" "$ALICE_TOKEN" "$maker_account_id" \
        "Unfathomably's follow of the Manyfold user was not accepted"

    log "Resolving and following the native model actor"
    model_account_id="$(resolve_account_id "$BE_BASE" "$ALICE_TOKEN" \
        "$MANYFOLD_MODEL_USERNAME@$GTS_HOST" \
        "Unfathomably could not resolve the Manyfold model")"
    http_form POST "$BE_BASE/api/v1/accounts/$model_account_id/follow" "$ALICE_TOKEN" 200 >/dev/null
    poll_manyfold_follow "$alice_ap_id" "$MANYFOLD_MODEL_ACTOR" 1 \
        "Manyfold did not accept Unfathomably's model follow"
    poll_relationship_following "$BE_BASE" "$ALICE_TOKEN" "$model_account_id" \
        "Unfathomably's Manyfold model follow was not accepted"

    log "Following Group actors and proving group-specific cleanup paths"
    manyfold_runner \
        'maker=User.find_by!(username: "maker"); target=Federails::Actor.find_or_create_by_federation_url(ENV.fetch("TARGET_ACTOR")); maker.follow(target) unless maker.following?(target); puts maker.following?(target)' \
        -e "TARGET_ACTOR=$group_actor" >/dev/null
    collection_account_id="$(resolve_account_id "$BE_BASE" "$ALICE_TOKEN" \
        "$MANYFOLD_COLLECTION_USERNAME@$GTS_HOST" \
        "Unfathomably could not resolve the Manyfold Collection actor")"
    MANYFOLD_REMOTE_GROUP="$(http_form GET \
        "$BE_BASE/api/v1/groups/lookup?uri=$(urlencode "$MANYFOLD_COLLECTION_ACTOR")" \
        "$ALICE_TOKEN" 200)"
    MANYFOLD_REMOTE_GROUP_ID="$(json_get "$MANYFOLD_REMOTE_GROUP" id)"
    http_form POST "$BE_BASE/api/v1/groups/$MANYFOLD_REMOTE_GROUP_ID/join" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_manyfold_follow "$MANYFOLD_USER_ACTOR" "$group_actor" 1 \
        "Manyfold did not record its accepted follow of the Unfathomably Group"
    poll_manyfold_follow "$alice_ap_id" "$MANYFOLD_COLLECTION_ACTOR" 1 \
        "Manyfold did not accept Unfathomably's Collection Group follow"

    log "Checking native UI classification for every Manyfold actor family"
    creator_account_id="$(resolve_account_id "$BE_BASE" "$ALICE_TOKEN" \
        "$MANYFOLD_CREATOR_USERNAME@$GTS_HOST" \
        "Unfathomably could not resolve the Manyfold Creator actor")"
    http_form POST "$BE_BASE/api/v1/accounts/$creator_account_id/follow" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_manyfold_follow "$alice_ap_id" "$MANYFOLD_CREATOR_ACTOR" 1 \
        "Manyfold did not accept Unfathomably's Creator follow"
    poll_relationship_following "$BE_BASE" "$ALICE_TOKEN" "$creator_account_id" \
        "Unfathomably's Manyfold Creator follow was not accepted"
    model_account="$(http_form GET "$BE_BASE/api/v1/accounts/$model_account_id" "$ALICE_TOKEN" 200)"
    creator_account="$(http_form GET "$BE_BASE/api/v1/accounts/$creator_account_id" "$ALICE_TOKEN" 200)"
    collection_account="$(http_form GET "$BE_BASE/api/v1/accounts/$collection_account_id" "$ALICE_TOKEN" 200)"
    maker_account="$(http_form GET "$BE_BASE/api/v1/accounts/$maker_account_id" "$ALICE_TOKEN" 200)"
    json_assert "$model_account" \
        "data.get('pleroma', {}).get('native', {}).get('type') == '3DModel' and data.get('pleroma', {}).get('native', {}).get('class') == 'resource' and data.get('pleroma', {}).get('native', {}).get('controls') == ['open'] and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('license') == 'MIT' and '$MANYFOLD_COLLECTION_ACTOR' in data.get('pleroma', {}).get('native', {}).get('fields', {}).get('collections', []) and '$MANYFOLD_CREATOR_ACTOR' in data.get('pleroma', {}).get('native', {}).get('fields', {}).get('attributed_to', [])" \
        "Unfathomably did not classify the Manyfold model as a native resource"
    json_assert "$creator_account" \
        "data.get('pleroma', {}).get('native', {}).get('type') == 'Creator'" \
        "Unfathomably did not classify the Manyfold Creator actor"
    json_assert "$collection_account" \
        "data.get('pleroma', {}).get('native', {}).get('type') == 'Collection' and data.get('pleroma', {}).get('native', {}).get('class') == 'collection'" \
        "Unfathomably did not classify the Manyfold Collection actor"
    json_assert "$maker_account" \
        "data.get('pleroma', {}).get('native', {}).get('type') == 'User'" \
        "Unfathomably did not classify the Manyfold User actor"
    poll_be_actor_extension "$MANYFOLD_MODEL_ACTOR" \
        "actor_extensions->'attachment'->0->>'href'" \
        'https://resources.invalid/manyfold-model' \
        "Unfathomably did not preserve the bounded external Manyfold Link"

    log "Updating native Manyfold model state and receiving its compatibility Note"
    updated_name="Alien Federation Model $(basename "$WORK_DIR")"
    updated_notes="Updated native model notes $(basename "$WORK_DIR")"
    manyfold_runner \
        'model=Model.find_by!(public_id: ENV.fetch("MODEL_USERNAME")); Federails::Activity.where(entity: model.federails_actor).update_all(created_at: 16.minutes.ago); model.update!(name: ENV.fetch("UPDATED_NAME"), notes: ENV.fetch("UPDATED_NOTES")); puts model.federails_actor.federated_url' \
        -e "MODEL_USERNAME=$MANYFOLD_MODEL_USERNAME" \
        -e "UPDATED_NAME=$updated_name" \
        -e "UPDATED_NOTES=$updated_notes" >/dev/null

    poll_json_assert \
        "http_form GET '$BE_BASE/api/v1/accounts/$model_account_id' '$ALICE_TOKEN' 200" \
        "'$updated_name' == data.get('display_name')" \
        "Unfathomably did not apply the native Manyfold actor Update" >/dev/null
    poll_be_actor_extension "$MANYFOLD_MODEL_ACTOR" \
        "actor_extensions->>'content'" "$updated_notes" \
        "Unfathomably did not preserve updated Manyfold content metadata"
    fallback_status_id="$(poll_home_status_by_text "$BE_BASE" "$ALICE_TOKEN" \
        "$updated_name" \
        "Unfathomably did not receive Manyfold's compatibility Note")"
    assert_context_count "$fallback_status_id" "$updated_name" 0 \
        "Manyfold native actor and compatibility Note were duplicated on the status surface"

    log "Proving that unrelated top-level Notes are not native Manyfold comments"
    top_level_text="Unrelated Unfathomably post $(basename "$WORK_DIR")"
    top_level="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$top_level_text" 'visibility=public')"
    top_level_id="$(json_get "$top_level" id)"
    top_level_uri="$(json_get "$top_level" uri)"
    sleep 4
    assert_manyfold_sql \
        'SELECT COUNT(*) FROM comments WHERE federated_url = ?' 0 \
        "Manyfold incorrectly converted an unrelated top-level Note into a comment" \
        "$top_level_uri"
    http_form DELETE "$BE_BASE/api/v1/statuses/$top_level_id" "$ALICE_TOKEN" 200 >/dev/null

    log "Testing Unfathomably replies as native Manyfold comments"
    be_comment_text="Unfathomably native Manyfold comment $(basename "$WORK_DIR")"
    be_comment="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$be_comment_text" \
        "in_reply_to_id=$fallback_status_id")"
    be_comment_id="$(json_get "$be_comment" id)"
    be_comment_uri="$(json_get "$be_comment" uri)"
    poll_manyfold_sql \
        'SELECT COUNT(*) FROM comments WHERE federated_url = ? AND comment LIKE ?' 1 \
        "Manyfold did not retain the Unfathomably reply as native Comment state" \
        "$be_comment_uri" "%$be_comment_text%"
    http_form DELETE "$BE_BASE/api/v1/statuses/$be_comment_id" "$ALICE_TOKEN" 200 >/dev/null
    poll_manyfold_sql \
        'SELECT COUNT(*) FROM comments WHERE federated_url = ?' 0 \
        "Manyfold retained the deleted Unfathomably comment" \
        "$be_comment_uri"

    log "Testing Manyfold comments and its malformed Delete boundary"
    manyfold_comment_text="Manyfold native comment $(basename "$WORK_DIR")"
    manyfold_comment_uri="$(manyfold_runner \
        'maker=User.find_by!(username: "maker"); model=Model.find_by!(public_id: ENV.fetch("MODEL_USERNAME")); comment=Comment.create!(commenter: maker, commentable: model, comment: ENV.fetch("COMMENT_TEXT"), system: false); puts comment.federated_url' \
        -e "MODEL_USERNAME=$MANYFOLD_MODEL_USERNAME" \
        -e "COMMENT_TEXT=$manyfold_comment_text")"
    poll_context_status_by_text "$BE_BASE" "$ALICE_TOKEN" "$fallback_status_id" \
        "$manyfold_comment_text" \
        "Unfathomably did not receive the native Manyfold Comment"
    manyfold_comment_id="$(resolve_status_id "$BE_BASE" "$ALICE_TOKEN" \
        "$manyfold_comment_uri" \
        "Unfathomably could not resolve the native Manyfold Comment")"
    manyfold_delete="$(manyfold_runner \
        'public_id=ENV.fetch("COMMENT_URI").split("/").last; comment=Comment.find_by!(public_id: public_id); comment_id=comment.id; comment.destroy!; activity=Federails::Activity.find_by!(action: "Delete", entity_type: "Comment", entity_id: comment_id); payload=Federails::ServerController.renderer.new.render(template: "federails/server/activities/show", assigns: {activity: activity}, format: :json); puts payload' \
        -e "COMMENT_URI=$manyfold_comment_uri")"
    json_assert "$manyfold_delete" \
        "data.get('type') == 'Delete' and 'object' not in data" \
        "Stock Manyfold unexpectedly changed its objectless Comment Delete boundary"
    sleep 4
    retained_comment="$(http_form GET \
        "$BE_BASE/api/v1/statuses/$manyfold_comment_id" "$ALICE_TOKEN" 200)"
    json_assert "$retained_comment" \
        "'$manyfold_comment_text' in (data.get('content') or '')" \
        "Unfathomably accepted an unsafe objectless Manyfold Delete"

    log "Testing Likes and documenting stock Manyfold Undo limitations"
    http_form POST "$BE_BASE/api/v1/statuses/$fallback_status_id/favourite" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_manyfold_sql \
        'SELECT like_count FROM models WHERE public_id = ?' 1 \
        "Manyfold did not apply Unfathomably's Like to native model state" \
        "$MANYFOLD_MODEL_USERNAME"
    http_form POST "$BE_BASE/api/v1/statuses/$fallback_status_id/unfavourite" \
        "$ALICE_TOKEN" 200 >/dev/null
    sleep 4
    assert_manyfold_sql \
        'SELECT like_count FROM models WHERE public_id = ?' 1 \
        "Stock Manyfold unexpectedly changed its documented unhandled Undo Like boundary" \
        "$MANYFOLD_MODEL_USERNAME"

    manyfold_runner \
        'maker=User.find_by!(username: "maker"); model=Model.find_by!(public_id: ENV.fetch("MODEL_USERNAME")); maker.liked_list.models << model unless maker.liked?(model); puts model.reload.like_count' \
        -e "MODEL_USERNAME=$MANYFOLD_MODEL_USERNAME" >/dev/null
    poll_status_count "$BE_BASE" "$ALICE_TOKEN" "$fallback_status_id" \
        'int(data.get("favourites_count") or 0) == 1' \
        "Unfathomably did not receive Manyfold's native Like"
    manyfold_runner \
        'maker=User.find_by!(username: "maker"); model=Model.find_by!(public_id: ENV.fetch("MODEL_USERNAME")); maker.liked_list.list_items.find_by(listable: model)&.destroy!; model.update_like_count!; puts model.reload.like_count' \
        -e "MODEL_USERNAME=$MANYFOLD_MODEL_USERNAME" >/dev/null
    sleep 4
    poll_status_count "$BE_BASE" "$ALICE_TOKEN" "$fallback_status_id" \
        'int(data.get("favourites_count") or 0) == 1' \
        "Stock Manyfold unexpectedly emitted Undo when removing its native liked-list item"

    log "Testing federated moderation reception and outgoing-report boundary"
    report_text="Unfathomably report to Manyfold $(basename "$WORK_DIR")"
    report_count_before="$(manyfold_sql_value \
        'SELECT COUNT(*) FROM federails_moderation_reports')"
    http_form POST "$BE_BASE/api/v1/reports" "$ALICE_TOKEN" 200 \
        "account_id=$model_account_id" \
        "status_ids[]=$fallback_status_id" \
        "comment=$report_text" \
        'forward=true' >/dev/null

    report_attempted=0
    for _ in $(seq 1 30); do
        if docker logs "$GTS_CONTAINER" 2>&1 | \
            grep -F 'Report recieved:' | grep -F "$report_text" >/dev/null; then
            report_attempted=1
            break
        fi
        sleep 2
    done
    [ "$report_attempted" = "1" ] || \
        fail "Unfathomably did not deliver its federated report to Manyfold"
    assert_manyfold_sql \
        'SELECT COUNT(*) FROM federails_moderation_reports' "$report_count_before" \
        "Stock Manyfold unexpectedly accepted a Flag after dereferencing its object"

    local_report_text="Manyfold local report boundary $(basename "$WORK_DIR")"
    flag_count_before="$(manyfold_sql_value \
        'SELECT COUNT(*) FROM federails_activities WHERE action = "Flag"')"
    manyfold_runner \
        'maker=User.find_by!(username: "maker"); target=Federails::Actor.find_or_create_by_federation_url(ENV.fetch("TARGET_ACTOR")); Federails::Moderation::Report.create!(federails_actor: maker.federails_actor, object: target, content: ENV.fetch("REPORT_TEXT")); puts "created"' \
        -e "TARGET_ACTOR=$alice_ap_id" \
        -e "REPORT_TEXT=$local_report_text" >/dev/null
    flag_count_after="$(manyfold_sql_value \
        'SELECT COUNT(*) FROM federails_activities WHERE action = "Flag"')"
    [ "$flag_count_before" = "$flag_count_after" ] || \
        fail "Stock Manyfold unexpectedly changed its local-only report boundary"

    log "Testing domain blocking in both transport directions"
    manyfold_runner \
        'Federails::Moderation::DomainBlock.find_or_create_by!(domain: ENV.fetch("BLOCKED_DOMAIN")); puts "blocked"' \
        -e "BLOCKED_DOMAIN=$BE_HOST" >/dev/null
    blocked_inbound_text="Blocked inbound comment $(basename "$WORK_DIR")"
    blocked_inbound="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$blocked_inbound_text" \
        "in_reply_to_id=$fallback_status_id")"
    blocked_inbound_id="$(json_get "$blocked_inbound" id)"
    blocked_inbound_uri="$(json_get "$blocked_inbound" uri)"
    sleep 4
    assert_manyfold_sql \
        'SELECT COUNT(*) FROM comments WHERE federated_url = ?' 0 \
        "Manyfold accepted an activity from a domain it had blocked" \
        "$blocked_inbound_uri"

    blocked_outbound_text="Blocked outbound Manyfold comment $(basename "$WORK_DIR")"
    blocked_outbound_uri="$(manyfold_runner \
        'maker=User.find_by!(username: "maker"); model=Model.find_by!(public_id: ENV.fetch("MODEL_USERNAME")); comment=Comment.create!(commenter: maker, commentable: model, comment: ENV.fetch("COMMENT_TEXT"), system: false); puts comment.federated_url' \
        -e "MODEL_USERNAME=$MANYFOLD_MODEL_USERNAME" \
        -e "COMMENT_TEXT=$blocked_outbound_text")"
    sleep 4
    assert_home_timeline_missing "$blocked_outbound_text" \
        "Manyfold sent an activity to a domain it had blocked"
    manyfold_runner \
        'Federails::Moderation::DomainBlock.find_by!(domain: ENV.fetch("BLOCKED_DOMAIN")).destroy!; puts "unblocked"' \
        -e "BLOCKED_DOMAIN=$BE_HOST" >/dev/null
    http_form DELETE "$BE_BASE/api/v1/statuses/$blocked_inbound_id" "$ALICE_TOKEN" 200 >/dev/null
    manyfold_runner \
        'public_id=ENV.fetch("COMMENT_URI").split("/").last; Comment.find_by!(public_id: public_id).destroy!; puts "deleted"' \
        -e "COMMENT_URI=$blocked_outbound_uri" >/dev/null

    log "Testing account and group unfollow cleanup in both directions"
    manyfold_runner \
        'maker=User.find_by!(username: "maker"); target=Federails::Actor.find_or_create_by_federation_url(ENV.fetch("TARGET_ACTOR")); maker.unfollow(target); puts maker.following?(target)' \
        -e "TARGET_ACTOR=$alice_ap_id" >/dev/null
    http_form POST "$BE_BASE/api/v1/accounts/$maker_account_id/unfollow" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_manyfold_follow "$MANYFOLD_USER_ACTOR" "$alice_ap_id" 0 \
        "Manyfold retained its undone Unfathomably account follow"
    poll_manyfold_follow "$alice_ap_id" "$MANYFOLD_USER_ACTOR" 0 \
        "Manyfold retained Unfathomably's undone account follow"

    manyfold_runner \
        'maker=User.find_by!(username: "maker"); target=Federails::Actor.find_or_create_by_federation_url(ENV.fetch("TARGET_ACTOR")); maker.unfollow(target); puts maker.following?(target)' \
        -e "TARGET_ACTOR=$group_actor" >/dev/null
    http_form POST "$BE_BASE/api/v1/groups/$MANYFOLD_REMOTE_GROUP_ID/leave" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_manyfold_follow "$MANYFOLD_USER_ACTOR" "$group_actor" 0 \
        "Manyfold retained its undone Unfathomably Group follow"
    poll_manyfold_follow "$alice_ap_id" "$MANYFOLD_COLLECTION_ACTOR" 0 \
        "Manyfold retained Unfathomably's undone Collection Group follow"

    log "Testing native model and compatibility Note deletion"
    manyfold_runner \
        'Model.find_by!(public_id: ENV.fetch("MODEL_USERNAME")).destroy!; puts "deleted"' \
        -e "MODEL_USERNAME=$MANYFOLD_MODEL_USERNAME" >/dev/null
    poll_status_missing "$BE_BASE" "$ALICE_TOKEN" "$fallback_status_id" \
        "Unfathomably retained the deleted Manyfold compatibility Note"
    model_account_file="$WORK_DIR/deleted-model-account.json"
    model_account_deleted=0
    for _ in $(seq 1 60); do
        model_account_status="$(curl -sS -o "$model_account_file" -w '%{http_code}' \
            -H "Authorization: Bearer $ALICE_TOKEN" \
            "$BE_BASE/api/v1/accounts/$model_account_id")"
        if [ "$model_account_status" = "404" ] || [ "$model_account_status" = "410" ]; then
            model_account_deleted=1
            break
        fi
        if [ "$model_account_status" = "200" ] && MODEL_ACCOUNT_FILE="$model_account_file" python3 - <<'PY'
import json
import os

with open(os.environ["MODEL_ACCOUNT_FILE"], encoding="utf-8") as handle:
    account = json.load(handle)

raise SystemExit(0 if account.get("pleroma", {}).get("is_active") is False else 1)
PY
        then
            model_account_deleted=1
            break
        fi
        sleep 2
    done
    [ "$model_account_deleted" = "1" ] || \
        fail "Unfathomably did not hide or deactivate the deleted Manyfold actor"
    tombstone_status="$(curl -sS -o /dev/null -w '%{http_code}' \
        -H 'Accept: application/activity+json' \
        "$GTS_BASE${MANYFOLD_MODEL_ACTOR#https://"$GTS_HOST"}")"
    [ "$tombstone_status" = "410" ] || [ "$tombstone_status" = "404" ] || \
        fail "Deleted Manyfold model remained retrievable with HTTP $tombstone_status"

    http_form POST "$BE_BASE/api/v1/accounts/$creator_account_id/unfollow" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_manyfold_follow "$alice_ap_id" "$MANYFOLD_CREATOR_ACTOR" 0 \
        "Manyfold retained Unfathomably's undone Creator follow"

    check_logs "$BE_CONTAINER" Unfathomably
    check_logs "$GTS_CONTAINER" Manyfold

    cat <<EOF

Manyfold federation smoke passed.

Covered against stock Manyfold $MANYFOLD_IMAGE:
* supported: WebFinger, ActivityPub content negotiation, NodeInfo, and canonical HTTPS IDs
* supported: native User, Creator, Collection, and 3DModel actor classification
* supported: bounded f3di, SPDX, collection context, attribution, and external Link preservation
* supported: private models are excluded from public ActivityPub retrieval
* supported: bidirectional account follows, accepts, unfollows, and cleanup
* supported: Collection Group follows and group unfollows in both ecosystems
* supported: native model Update plus compatibility Note without duplicate status presentation
* supported: Unfathomably replies round-trip into native Manyfold Comment state
* supported: native Manyfold comments reach Unfathomably
* supported: status and actor Deletes remove the compatibility Note and tombstone the model
* supported: Likes are applied in both directions
* supported: Manyfold domain blocks suppress both inbound and outbound delivery
* supported: linked resources are preserved without being required for actor ingestion
* not_supported: stock Manyfold ignores Undo Like and its native unlike does not emit Undo
* not_supported: stock Manyfold ignores unrelated top-level Notes rather than importing them as comments
* not_supported: stock Manyfold emits Comment Delete without an object, which Unfathomably safely rejects
* not_supported: stock Manyfold has no actor-level Block or Undo Block state
* not_supported: stock Federails dereferences a Flag object before its moderation handler expects the URI
* not_supported: stock Manyfold reports are local moderation records and do not emit Flag
* not_supported: Manyfold domain blocking intentionally gives the blocked peer no durable defederation signal
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run_manyfold_smoke
fi

# end of build_scripts/unfathomably-manyfold-smoke.sh
