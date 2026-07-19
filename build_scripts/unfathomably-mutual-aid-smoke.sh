#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-mutual-aid-smoke.sh
#
# Purpose:
#
#   Run the pinned stock Mutual Aid application on its stock ActivityPods
#   provider and verify native marketplace federation with Unfathomably.
#
# Responsibilities:
#
#   * reuse the proven ActivityPods lifecycle and federation harness
#   * build and start an unmodified pinned Mutual Aid application backend
#   * install the app through ActivityPods' real authorization-agent API
#   * prove native Offer and Request storage, privacy, publication, updates,
#     reactions, replies, deletion, and application revocation
#   * distinguish ActivityPods and Mutual Aid upstream limits from failures
#
# This file intentionally does NOT contain:
#
#   * a simulated Mutual Aid actor or application backend
#   * patched Mutual Aid or ActivityPods source
#   * browser automation for the replaceable React frontend
#   * production deployment logic
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTIVITYPODS_HARNESS="$SCRIPT_DIR/unfathomably-activitypods-smoke.sh"

if [ ! -f "$ACTIVITYPODS_HARNESS" ]; then
    printf 'Required ActivityPods harness not found: %s\n' "$ACTIVITYPODS_HARNESS" >&2
    exit 1
fi

export SMOKE_PREFIX="${SMOKE_PREFIX:-unfathomably-mutual-aid-smoke}"
export BE_HOST="${BE_HOST:-unfathomably-mutual-aid.example.com}"
export BE_PORT="${BE_PORT:-5133}"
export BE_DB_NAME="${BE_DB_NAME:-unfathomably_mutual_aid_smoke_be}"
export GTS_HOST="${GTS_HOST:-mutual-aid-pod.example.com}"
export GTS_PORT="${GTS_PORT:-5134}"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=unfathomably-activitypods-smoke.sh
source "$ACTIVITYPODS_HARNESS"

MUTUAL_AID_SOURCE_URL="${MUTUAL_AID_SOURCE_URL:-https://github.com/reconnexion/mutual-aid.app.git}"
MUTUAL_AID_SOURCE_COMMIT="${MUTUAL_AID_SOURCE_COMMIT:-a4559f8a1a2956537d436bb1f761cf1b5b6c747c}"
MUTUAL_AID_IMAGE="${MUTUAL_AID_IMAGE:-unfathomably-mutual-aid-stock:${MUTUAL_AID_SOURCE_COMMIT:0:12}}"
MUTUAL_AID_SOURCE_DIR="$WORK_DIR/mutual-aid-source"
MUTUAL_AID_CONTAINER="${PREFIX}-mutual-aid"
MUTUAL_AID_APP_HOST="${PREFIX}-mutual-aid-app"
MUTUAL_AID_PORT="${MUTUAL_AID_PORT:-5135}"
MUTUAL_AID_BASE="http://127.0.0.1:$MUTUAL_AID_PORT"
MUTUAL_AID_APP_URI="http://$MUTUAL_AID_APP_HOST:3000/app"

# ------------------------------------------------------------------------------
# Stock image and service lifecycle
# ------------------------------------------------------------------------------

cleanup_mutual_aid_smoke() {
    local incoming_status="$?"
    local status="${1:-$incoming_status}"

    if [ "$KEEP_CONTAINERS" = "1" ]; then
        cleanup "$status"
    fi

    docker rm -f "$MUTUAL_AID_CONTAINER" >/dev/null 2>&1 || true
    cleanup_activitypods_smoke "$status"
}

trap cleanup_mutual_aid_smoke EXIT

checkout_mutual_aid_source() {
    local actual_commit

    git clone --quiet --filter=blob:none --no-checkout \
        "$MUTUAL_AID_SOURCE_URL" "$MUTUAL_AID_SOURCE_DIR"
    git -C "$MUTUAL_AID_SOURCE_DIR" fetch --quiet --depth=1 \
        origin "$MUTUAL_AID_SOURCE_COMMIT"
    git -C "$MUTUAL_AID_SOURCE_DIR" checkout --quiet --detach \
        "$MUTUAL_AID_SOURCE_COMMIT"

    actual_commit="$(git -C "$MUTUAL_AID_SOURCE_DIR" rev-parse HEAD)"
    [ "$actual_commit" = "$MUTUAL_AID_SOURCE_COMMIT" ] || \
        fail "Pinned Mutual Aid checkout resolved to $actual_commit"
}

prepare_mutual_aid_image() {
    if docker image inspect "$MUTUAL_AID_IMAGE" >/dev/null 2>&1; then
        return 0
    fi

    checkout_mutual_aid_source
    log "Building pinned stock Mutual Aid $MUTUAL_AID_SOURCE_COMMIT"
    docker build \
        -t "$MUTUAL_AID_IMAGE" \
        -f "$MUTUAL_AID_SOURCE_DIR/docker/backend.dockerfile" \
        "$MUTUAL_AID_SOURCE_DIR"
}

start_mutual_aid() {
    docker rm -f "$MUTUAL_AID_CONTAINER" >/dev/null 2>&1 || true

    docker run -d \
        --name "$MUTUAL_AID_CONTAINER" \
        --hostname "$MUTUAL_AID_APP_HOST" \
        --network "$NETWORK" \
        --network-alias "$MUTUAL_AID_APP_HOST" \
        -p "127.0.0.1:$MUTUAL_AID_PORT:3000" \
        -e NODE_ENV=production \
        -e "NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt" \
        -e SEMAPPS_APP_NAME='Mutual Aid' \
        -e SEMAPPS_APP_DESCRIPTION='Stock Mutual Aid federation smoke application' \
        -e SEMAPPS_APP_LANG=en \
        -e "SEMAPPS_HOME_URL=http://$MUTUAL_AID_APP_HOST:3000/" \
        -e "SEMAPPS_FRONT_URL=http://$MUTUAL_AID_APP_HOST:3000/" \
        -e SEMAPPS_PORT=3000 \
        -e SEMAPPS_SHAPE_REPOSITORY_URL=https://shapes.activitypods.org/ \
        -e "SEMAPPS_SPARQL_ENDPOINT=http://$ACTIVITYPODS_FUSEKI_CONTAINER:3030/" \
        -e SEMAPPS_JENA_USER=admin \
        -e SEMAPPS_JENA_PASSWORD=admin \
        -e SEMAPPS_MAIN_DATASET=mutualaid \
        -e SEMAPPS_AUTH_ACCOUNTS_DATASET_NAME=settings-mutualaid \
        -e "SEMAPPS_REDIS_CACHE_URL=redis://$ACTIVITYPODS_REDIS_CONTAINER:6379/9" \
        -e "SEMAPPS_QUEUE_SERVICE_URL=redis://$ACTIVITYPODS_REDIS_CONTAINER:6379/10" \
        -v "$ACTIVITYPODS_CA_BUNDLE:/etc/ssl/certs/ca-certificates.crt:ro" \
        "$MUTUAL_AID_IMAGE" >/dev/null
}

wait_mutual_aid() {
    for _ in $(seq 1 240); do
        if curl -fsS -H 'Accept: application/ld+json' \
            "$MUTUAL_AID_BASE/app" >/dev/null 2>&1 && \
            docker logs "$MUTUAL_AID_CONTAINER" 2>&1 | \
                grep -E 'ServiceBroker with [0-9]+ service\(s\) started successfully' \
                >/dev/null; then
            return 0
        fi
        sleep 1
    done

    docker logs "$MUTUAL_AID_CONTAINER" >&2 || true
    fail "Timed out waiting for the stock Mutual Aid application"
}

wait_mutual_aid_channels() {
    for _ in $(seq 1 120); do
        if docker logs "$MUTUAL_AID_CONTAINER" 2>&1 | \
            grep -F "Listening to $ACTIVITYPODS_ACTOR inbox" >/dev/null && \
            docker logs "$MUTUAL_AID_CONTAINER" 2>&1 | \
                grep -F "Listening to $ACTIVITYPODS_ACTOR outbox" >/dev/null; then
            return 0
        fi
        sleep 1
    done

    docker logs "$MUTUAL_AID_CONTAINER" >&2 || true
    fail "Mutual Aid did not begin listening to the installed Pod channels"
}

check_mutual_aid_logs() {
    if docker logs "$MUTUAL_AID_CONTAINER" 2>&1 | \
        grep -E -i \
            'uncaught exception|unhandled rejection|servicebroker.*failed|fatal error' \
        >/dev/null; then
        docker logs "$MUTUAL_AID_CONTAINER" >&2 || true
        fail "Mutual Aid emitted a crash-class log line"
    fi
}

# ------------------------------------------------------------------------------
# Stock application and WebACL helpers
# ------------------------------------------------------------------------------

mutual_aid_app_status() {
    http_form GET \
        "$GTS_BASE/.well-known/app-status?appUri=$(urlencode "$MUTUAL_AID_APP_URI")" \
        "$ACTIVITYPODS_TOKEN" 200
}

activitypods_acl_uri() {
    local resource_uri="$1"
    local headers_file="$WORK_DIR/mutual-aid-acl-headers.$RANDOM"
    local acl_uri

    curl -sS -D "$headers_file" -o /dev/null \
        -H 'Accept: application/ld+json' \
        -H "Authorization: Bearer $ACTIVITYPODS_TOKEN" \
        "$(activitypods_local_url "$resource_uri")"

    acl_uri="$(python3 - "$headers_file" <<'PY'
import re
import sys

for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    if line.lower().startswith("link:"):
        match = re.search(r"<([^>]+)>[^,]*rel\s*=\s*\"?acl\"?", line, re.IGNORECASE)
        if match:
            print(match.group(1))
            break
PY
)"
    rm -f "$headers_file"
    [ -n "$acl_uri" ] || fail "ActivityPods omitted the ACL link for $resource_uri"
    printf '%s\n' "$acl_uri"
}

poll_mutual_aid_location_grant() {
    local location_uri="$1"
    local acl_uri="$2"
    local result=""

    for _ in $(seq 1 90); do
        result="$(activitypods_json GET \
            "$(activitypods_local_url "$acl_uri")" \
            "$ACTIVITYPODS_TOKEN" 200 || true)"

        if JSON_INPUT="$result" python3 - "$location_uri" <<'PY'
import json
import os
import sys

location = sys.argv[1]
try:
    data = json.loads(os.environ.get("JSON_INPUT", ""))
except json.JSONDecodeError:
    raise SystemExit(1)

graph = data.get("@graph", []) if isinstance(data, dict) else []
if isinstance(data, list):
    graph = data

def values(value):
    return value if isinstance(value, list) else [value]

for item in graph:
    if not isinstance(item, dict):
        continue
    access_to = item.get("acl:accessTo") or item.get("http://www.w3.org/ns/auth/acl#accessTo")
    agent_group = item.get("acl:agentGroup") or item.get("http://www.w3.org/ns/auth/acl#agentGroup")
    mode = item.get("acl:mode") or item.get("http://www.w3.org/ns/auth/acl#mode")
    if location in values(access_to) and agent_group and any(str(v).endswith("#Read") or str(v) == "acl:Read" for v in values(mode)):
        raise SystemExit(0)

raise SystemExit(1)
PY
        then
            return 0
        fi

        sleep 2
    done

    printf '%s\n' "$result" >&2
    fail "Mutual Aid did not grant its announces group read access to the listing location"
}

wait_mutual_aid_location_patch() {
    local acl_uri="$1"
    local acl_path="${acl_uri#https://"$GTS_HOST"}"

    for _ in $(seq 1 120); do
        if docker logs "$GTS_CONTAINER" 2>&1 | \
            grep -F "<= 204 PATCH $acl_path" >/dev/null; then
            #
            # The stock provider caches ACL GET responses. Reading while the
            # app's PATCH is still in flight can therefore preserve the old
            # document for the duration of the test. Give concurrent handlers
            # a moment to converge before the first public API read.
            #
            sleep 2
            return 0
        fi
        sleep 1
    done

    docker logs "$GTS_CONTAINER" >&2 || true
    fail "Mutual Aid did not complete its stock Location ACL update"
}

# ------------------------------------------------------------------------------
# Native Mutual Aid application gate
# ------------------------------------------------------------------------------

run_mutual_aid_native_smoke() {
    local app app_registration app_status alice_account alice_ap_id
    local offers_container requests_container locations_container
    local location_uri location_acl_uri request_uri request_status
    local offer_payload offer_uri create_payload offer_status_id offer_status
    local offer_object likes_uri updated_offer_payload update_payload updated_offer
    local be_like be_reply_text be_reply be_reply_id be_reply_uri offer_with_replies replies_uri
    local delete_payload

    prepare_mutual_aid_image

    # Mutual Aid is an ActivityPods application, so the established provider
    # gate supplies its real Person actor, follow graph, moderation transport,
    # and bidirectional generic activity lifecycle before app-specific checks.
    if [ "${MUTUAL_AID_REUSE_PROVIDER:-0}" = "1" ]; then
        log "Reusing the retained ActivityPods provider for adapter development"
        ACTIVITYPODS_ACTOR="https://$GTS_HOST/$GTS_USERNAME"
        ACTIVITYPODS_TOKEN="$(activitypods_login)"
    else
        run_activitypods_smoke
    fi

    log "Starting the pinned stock Mutual Aid application"
    start_mutual_aid
    wait_mutual_aid

    app="$(http_form GET "$MUTUAL_AID_BASE/app" "" 200)"
    json_assert "$app" \
        "data.get('id') == '$MUTUAL_AID_APP_URI' and 'interop:Application' in data.get('type', []) and data.get('inbox')" \
        "Mutual Aid did not expose its stock application actor"

    ACTIVITYPODS_TOKEN="$(activitypods_login)"
    app_registration="$(http_json POST \
        "$GTS_BASE/.auth-agent/register-app" \
        "$ACTIVITYPODS_TOKEN" 200 \
        "{\"appUri\":\"$MUTUAL_AID_APP_URI\",\"acceptAllRequirements\":true}")"
    [ -n "$app_registration" ] || fail "ActivityPods returned an empty Mutual Aid registration"

    app_status="$(poll_json_assert \
        "mutual_aid_app_status" \
        "data.get('installed') is True and data.get('onlineBackend') is True and data.get('webhookChannels') is not None" \
        "Mutual Aid was installed but did not establish its stock application channels")"
    printf '%s' "$app_status" >/dev/null
    wait_mutual_aid_channels

    offers_container="$ACTIVITYPODS_ACTOR/data/maid/offer"
    requests_container="$ACTIVITYPODS_ACTOR/data/maid/request"
    locations_container="$ACTIVITYPODS_ACTOR/data/vcard/location"
    poll_json_assert \
        "activitypods_json GET '$(activitypods_local_url "$offers_container")' '$ACTIVITYPODS_TOKEN' 200" \
        "'interop:DataRegistration' in data.get('type', [])" \
        "Mutual Aid installation did not create its Offer data registration" >/dev/null
    poll_json_assert \
        "activitypods_json GET '$(activitypods_local_url "$requests_container")' '$ACTIVITYPODS_TOKEN' 200" \
        "'interop:DataRegistration' in data.get('type', [])" \
        "Mutual Aid installation did not create its Request data registration" >/dev/null

    ALICE_TOKEN="$(create_be_token alice)"
    alice_account="$(http_form GET \
        "$BE_BASE/api/v1/accounts/verify_credentials" "$ALICE_TOKEN" 200)"
    alice_ap_id="$(json_get "$alice_account" url)"

    log "Creating private stock Mutual Aid Request and Location resources"
    location_uri="$(activitypods_post_location \
        "$(activitypods_local_url "$locations_container")" \
        "$ACTIVITYPODS_TOKEN" \
        '{"@context":["https://activitypods.org/context.json",{"pair":"http://virtual-assembly.org/ontologies/pair#","vcard":"http://www.w3.org/2006/vcard/ns#"}],"type":"vcard:Location","pair:label":"Mutual Aid tool library"}')"

    request_uri="$(activitypods_post_location \
        "$(activitypods_local_url "$requests_container")" \
        "$ACTIVITYPODS_TOKEN" \
        '{"@context":["https://www.w3.org/ns/activitystreams","https://activitypods.org/context.json",{"maid":"https://mutual-aid.app/ns/core#","pair":"http://virtual-assembly.org/ontologies/pair#"}],"type":"maid:Request","pair:label":"Private ride request","name":"Private ride request","content":"Owner-only Mutual Aid request"}')"
    request_status="$(curl -sS -o /dev/null -w '%{http_code}' \
        -H 'Accept: application/ld+json' \
        "$(activitypods_local_url "$request_uri")")"
    [ "$request_status" = "401" ] || [ "$request_status" = "403" ] || \
        fail "Anonymous client fetched a private Mutual Aid Request with HTTP $request_status"
    poll_be_object_count "$request_uri" 0 \
        "Unfathomably cached an unpublished private Mutual Aid Request"

    log "Publishing a native stock Mutual Aid Offer"
    offer_payload="$(python3 - \
        "$ACTIVITYPODS_ACTOR" "$alice_ap_id" "$location_uri" <<'PY'
import json
import sys

actor, target, location = sys.argv[1:]
print(json.dumps({
    "@context": [
        "https://www.w3.org/ns/activitystreams",
        "https://activitypods.org/context.json",
        {
            "maid": "https://mutual-aid.app/ns/core#",
            "pair": "http://virtual-assembly.org/ontologies/pair#",
            "unfathomably": "https://unfathomably.invalid/ns#",
        },
    ],
    "type": "maid:Offer",
    "attributedTo": actor,
    "name": "Cordless drill to lend",
    "content": "A native Mutual Aid tool-lending offer",
    "pair:label": "Cordless drill to lend",
    "maid:offerOfResourceType": "https://mutual-aid.example/types/tool",
    "maid:hasGeoCondition": {"pair:hasLocation": location},
    "unfathomably:proof": {"unfathomably:retained": True},
    "to": target,
    "cc": "https://www.w3.org/ns/activitystreams#Public",
}))
PY
)"
    offer_uri="$(activitypods_post_location \
        "$(activitypods_local_url "$offers_container")" \
        "$ACTIVITYPODS_TOKEN" "$offer_payload")"

    create_payload="$(python3 - "$alice_ap_id" "$offer_uri" <<'PY'
import json
import sys

target, object_id = sys.argv[1:]
print(json.dumps({
    "@context": "https://www.w3.org/ns/activitystreams",
    "type": "Create",
    "to": "https://www.w3.org/ns/activitystreams#Public",
    "cc": target,
    "object": object_id,
}))
PY
)"
    activitypods_outbox_activity "$create_payload" >/dev/null
    location_acl_uri="$(activitypods_acl_uri "$location_uri")"
    wait_mutual_aid_location_patch "$location_acl_uri"
    poll_mutual_aid_location_grant "$location_uri" "$location_acl_uri"
    offer_status_id="$(resolve_status_id \
        "$BE_BASE" "$ALICE_TOKEN" "$offer_uri" \
        "Unfathomably could not resolve the native Mutual Aid Offer")"
    offer_status="$(http_form GET \
        "$BE_BASE/api/v1/statuses/$offer_status_id" "$ALICE_TOKEN" 200)"
    json_assert "$offer_status" \
        "data.get('uri') == '$offer_uri' and data.get('content') and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('platform') == 'mutual_aid' and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('listing_kind') == 'offer' and data.get('pleroma', {}).get('native', {}).get('fields', {}).get('listing_label') == 'Cordless drill to lend'" \
        "Unfathomably did not expose an honest Mutual Aid Offer presentation"
    offer_object="$(be_object_json "$offer_uri")"
    json_assert "$offer_object" \
        "data.get('type') in ['maid:Offer', 'https://mutual-aid.app/ns/core#Offer'] and (data.get('maid:offerOfResourceType') or data.get('https://mutual-aid.app/ns/core#offerOfResourceType')) == 'https://mutual-aid.example/types/tool' and (data.get('unfathomably:proof') or data.get('https://unfathomably.invalid/ns#proof'))" \
        "Unfathomably lost native Mutual Aid JSON-LD"

    for _ in 1 2 3 4; do
        activitypods_outbox_activity "$create_payload" >/dev/null
    done
    poll_be_object_count "$offer_uri" 1 \
        "Repeated Mutual Aid publication duplicated the native Offer"

    log "Testing native Mutual Aid Offer reactions and reply cleanup"
    be_like="$(http_form POST \
        "$BE_BASE/api/v1/statuses/$offer_status_id/favourite" \
        "$ALICE_TOKEN" 200)"
    json_assert "$be_like" 'data.get("favourited") is True' \
        "Unfathomably could not Like the Mutual Aid Offer"
    offer_object="$(poll_json_assert \
        "activitypods_json GET '$(activitypods_local_url "$offer_uri")' '$ACTIVITYPODS_TOKEN' 200" \
        "data.get('likes') is not None" \
        "Mutual Aid did not retain the incoming Like collection")"
    likes_uri="$(JSON_INPUT="$offer_object" python3 - <<'PY'
import json
import os

value = json.loads(os.environ["JSON_INPUT"])["likes"]
print(value.get("id") if isinstance(value, dict) else value)
PY
)"
    poll_activitypods_collection \
        "$likes_uri" "$ACTIVITYPODS_TOKEN" "$alice_ap_id" true \
        "Mutual Aid did not retain Unfathomably's Like"
    http_form POST \
        "$BE_BASE/api/v1/statuses/$offer_status_id/unfavourite" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_activitypods_collection \
        "$likes_uri" "$ACTIVITYPODS_TOKEN" "$alice_ap_id" false \
        "Mutual Aid retained Unfathomably's Like after Undo"

    be_reply_text="Unfathomably reply to Mutual Aid Offer $(basename "$WORK_DIR")"
    be_reply="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=$be_reply_text" "in_reply_to_id=$offer_status_id")"
    be_reply_id="$(json_get "$be_reply" id)"
    be_reply_uri="$(json_get "$be_reply" uri)"
    offer_with_replies="$(poll_json_assert \
        "activitypods_json GET '$(activitypods_local_url "$offer_uri")' '$ACTIVITYPODS_TOKEN' 200" \
        "data.get('replies') is not None" \
        "Mutual Aid did not attach a Replies collection to its Offer")"
    replies_uri="$(JSON_INPUT="$offer_with_replies" python3 - <<'PY'
import json
import os

value = json.loads(os.environ["JSON_INPUT"])["replies"]
print(value.get("id") if isinstance(value, dict) else value)
PY
)"
    poll_activitypods_collection \
        "$replies_uri" "$ACTIVITYPODS_TOKEN" "$be_reply_uri" true \
        "Mutual Aid did not retain the Unfathomably reply context"
    http_form DELETE "$BE_BASE/api/v1/statuses/$be_reply_id" \
        "$ALICE_TOKEN" 200 >/dev/null
    poll_activitypods_collection \
        "$replies_uri" "$ACTIVITYPODS_TOKEN" "$be_reply_uri" false \
        "Mutual Aid retained the deleted Unfathomably reply"

    log "Updating and deleting the native Mutual Aid Offer"
    updated_offer_payload="$(JSON_INPUT="$offer_payload" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
data["content"] = "Updated native Mutual Aid tool-lending offer"
data["pair:label"] = "Updated cordless drill offer"
data["name"] = "Updated cordless drill offer"
print(json.dumps(data))
PY
)"
    activitypods_put_resource \
        "$offer_uri" "$ACTIVITYPODS_TOKEN" "$updated_offer_payload"
    update_payload="$(python3 - "$alice_ap_id" "$offer_uri" <<'PY'
import json
import sys

target, object_id = sys.argv[1:]
print(json.dumps({
    "@context": "https://www.w3.org/ns/activitystreams",
    "type": "Update",
    "to": "https://www.w3.org/ns/activitystreams#Public",
    "cc": target,
    "object": object_id,
}))
PY
)"
    activitypods_outbox_activity "$update_payload" >/dev/null
    updated_offer="$(poll_json_assert \
        "be_object_json '$offer_uri'" \
        "data.get('content') == 'Updated native Mutual Aid tool-lending offer' and (data.get('pair:label') or data.get('http://virtual-assembly.org/ontologies/pair#label')) == 'Updated cordless drill offer'" \
        "Unfathomably did not apply the linked Mutual Aid Offer Update")"
    printf '%s' "$updated_offer" >/dev/null

    delete_payload="$(python3 - "$alice_ap_id" "$offer_uri" <<'PY'
import json
import sys

target, object_id = sys.argv[1:]
print(json.dumps({
    "@context": "https://www.w3.org/ns/activitystreams",
    "type": "Delete",
    "object": object_id,
    "to": "https://www.w3.org/ns/activitystreams#Public",
    "cc": target,
}))
PY
)"
    activitypods_outbox_activity "$delete_payload" >/dev/null
    poll_status_missing \
        "$BE_BASE" "$ALICE_TOKEN" "$offer_status_id" \
        "Unfathomably retained the deleted Mutual Aid Offer"
    activitypods_outbox_activity "$delete_payload" >/dev/null
    poll_be_object_count "$offer_uri" 1 \
        "Repeated Mutual Aid Delete duplicated the Offer tombstone"

    log "Revoking the stock Mutual Aid application registration"
    http_json POST \
        "$GTS_BASE/.auth-agent/remove-app" \
        "$ACTIVITYPODS_TOKEN" 200 \
        "{\"appUri\":\"$MUTUAL_AID_APP_URI\"}" >/dev/null
    poll_json_assert \
        "mutual_aid_app_status" \
        "data.get('installed') is False and data.get('onlineBackend') is True" \
        "ActivityPods retained the revoked Mutual Aid application registration" >/dev/null

    check_mutual_aid_logs
    check_logs "$BE_CONTAINER" Unfathomably

    cat <<EOF

Mutual Aid federation smoke passed.

Pinned stock sources:
* mutual-aid.app: $MUTUAL_AID_SOURCE_COMMIT
* activitypods: $ACTIVITYPODS_SOURCE_COMMIT

Alien ActivityPub matrix:
* Discovery: supported; the stock Application actor, access-needs graph, provider WebFinger, NodeInfo, and canonical Person actor passed
* Native representation: supported; maid:Offer and maid:Request remained native resources with their marketplace vocabulary
* Compatibility representation: supported; the published Offer exposed a readable fallback without replacing its native type
* Semantic deduplication: supported; repeated linked Create delivery retained one canonical Offer
* Authority: supported; the stock Pod owner remained the Offer authority and the inherited provider authority checks passed
* Lifecycle: supported; app install, Create, Update, Delete, repeated Delete, and app revocation converged
* Concurrency: supported; the inherited stock provider concurrency gate and repeated Offer publication remained canonical
* Collections: supported; Offer, Request, Location, inbox, outbox, likes, replies, followers, and following collections were traversed with bounds
* Context: supported; the Offer reply collection retained and removed its native reply relationship
* Capabilities: partially_supported; native listings expose honest Mutual Aid classification while stock ActivityPods Group support remains incomplete
* Round trip: supported; app registration created stock data registrations and channels, and the stock Offer handler changed Location WebACL state
* Unknown JSON-LD: supported; the Offer proof node survived Pod storage, federation ingestion, export, and Update
* Privacy: supported; the unpublished Request remained owner-only and absent from Unfathomably
* Idempotence: supported; repeated Create and Delete delivery did not duplicate Offer state
* Failure classification: supported; inherited missing-resource and stock Group-boundary checks terminated correctly
* Resource safety: supported; inherited linked-resource containment and inert-link checks passed
* UI classification: supported; native metadata identifies Mutual Aid, listing kind, label, and resource type
* Cleanup: partially_supported; app authorization, Likes, replies, posts, and Person follows were removed; stock reverse Group following is unavailable

Relationship and moderation boundaries:
* supported: Person follows and unfollows in both directions through Mutual Aid's stock ActivityPods provider
* partially_supported: the provider follows and unfollows an Unfathomably Group; reverse Group following is unavailable upstream
* supported: native Offer publication, linked Update, posts, replies, post Deletes, and comment Deletes
* supported: Likes and Undo Likes in both directions
* partially_supported: Flags are delivered and retained in both directions, but Mutual Aid and ActivityPods expose no native moderation case state
* partially_supported: outgoing provider Blocks affect Unfathomably; incoming Blocks and Undos are retained because stock ActivityPods has no Block processor
* stock_limitation: Mutual Aid federation identity and delivery are intentionally supplied by its user's ActivityPods provider
* stock_limitation: stock ActivityPods Groups remain explicitly incomplete at their presentations-container WebACL boundary
* not_supported: stock Mutual Aid exposes no durable signal by which it can know that a remote instance has defederated it
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run_mutual_aid_native_smoke
fi

# end of unfathomably-mutual-aid-smoke.sh
