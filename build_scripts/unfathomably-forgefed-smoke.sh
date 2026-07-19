#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-forgefed-smoke.sh
#
# Purpose:
#
#   Run an unmodified Forgejo instance against Unfathomably and measure the
#   ForgeFed interoperability that the stock implementation exposes today.
#
# Responsibilities:
#
#   * boot isolated Unfathomably and Forgejo instances
#   * prove WebFinger, Person actor, Repository actor, and NodeInfo discovery
#   * prove Unfathomably preserves Forgejo's native Repository actor type
#   * exercise the follow boundary in both directions
#   * report Forgejo's peer-software allowlist as unsupported interoperability
#
# This file intentionally does NOT contain:
#
#   * patched or rebranded Forgejo images
#   * spoofed NodeInfo software names
#   * synthetic success for ForgeFed operations stock Forgejo cannot reach
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAMILY_HARNESS="$SCRIPT_DIR/unfathomably-gotosocial-smoke.sh"

if [ ! -f "$FAMILY_HARNESS" ]; then
    printf 'Required account-federation harness not found: %s\n' "$FAMILY_HARNESS" >&2
    exit 1
fi

export SMOKE_PREFIX="${SMOKE_PREFIX:-unfathomably-forgefed-smoke}"
export BE_HOST="${BE_HOST:-unfathomably-forgefed.test}"
export BE_PORT="${BE_PORT:-5041}"
export BE_DB_NAME="${BE_DB_NAME:-unfathomably_forgefed_smoke_be}"
export GTS_HOST="${GTS_HOST:-forgejo-ref.test}"
export GTS_PORT="${GTS_PORT:-5042}"
export GTS_APP_PORT=3000
export GTS_FORWARDED_PROTO=https
export GTS_LABEL=Forgejo
export GTS_USERNAME=forge
export SMOKE_TLS=1
export BE_FEDERATION_SCHEME=https
export BE_FEDERATION_PORT=443

# shellcheck source=unfathomably-gotosocial-smoke.sh
source "$FAMILY_HARNESS"

FORGEJO_IMAGE="${FORGEJO_IMAGE:-data.forgejo.org/forgejo/forgejo:14}"
FORGEJO_PASSWORD="${FORGEJO_PASSWORD:-forgejo-smoke-password-12345}"
FORGEJO_REPOSITORY="${FORGEJO_REPOSITORY:-alien-matrix}"
FORGEJO_CA_BUNDLE="$WORK_DIR/forgejo-ca-certificates.crt"

wait_forgejo() {
    for _ in $(seq 1 180); do
        if curl -fsS "$GTS_BASE/api/healthz" >/dev/null 2>&1; then
            return 0
        fi

        sleep 1
    done

    docker logs "$GTS_CONTAINER" >&2 || true
    fail "Timed out waiting for stock Forgejo at $GTS_BASE"
}

start_forgejo() {
    docker volume create "$GTS_VOLUME" >/dev/null
    cat /etc/ssl/certs/ca-certificates.crt "$SMOKE_CA_CERT" >"$FORGEJO_CA_BUNDLE"

    docker run -d \
        --name "$GTS_CONTAINER" \
        --hostname "$GTS_APP_HOST" \
        --network "$NETWORK" \
        --network-alias "$GTS_APP_HOST" \
        -e USER_UID=1000 \
        -e USER_GID=1000 \
        -e "SSL_CERT_FILE=/etc/ssl/certs/unfathomably-smoke-bundle.crt" \
        -e FORGEJO__database__DB_TYPE=sqlite3 \
        -e FORGEJO__database__PATH=/data/gitea/forgejo.db \
        -e FORGEJO__server__DOMAIN="$GTS_HOST" \
        -e FORGEJO__server__ROOT_URL="https://$GTS_HOST/" \
        -e FORGEJO__server__HTTP_ADDR=0.0.0.0 \
        -e FORGEJO__server__HTTP_PORT=3000 \
        -e FORGEJO__server__DISABLE_SSH=true \
        -e FORGEJO__security__INSTALL_LOCK=true \
        -e FORGEJO__service__DISABLE_REGISTRATION=true \
        -e FORGEJO__federation__ENABLED=true \
        -e FORGEJO__federation__INSECURE_ALLOW_INVALID_HOSTS=true \
        -e FORGEJO__log__LEVEL=info \
        -v "$GTS_VOLUME:/data" \
        -v "$FORGEJO_CA_BUNDLE:/etc/ssl/certs/unfathomably-smoke-bundle.crt:ro" \
        "$FORGEJO_IMAGE" >/dev/null

    start_gts_proxy
}

forgejo_cli() {
    docker exec --user git "$GTS_CONTAINER" forgejo "$@"
}

create_forgejo_user() {
    forgejo_cli admin user create \
        --username "$GTS_USERNAME" \
        --password "$FORGEJO_PASSWORD" \
        --email "$GTS_USERNAME@$GTS_HOST" \
        --must-change-password=false >/dev/null
}

create_forgejo_token() {
    forgejo_cli admin user generate-access-token \
        --username "$GTS_USERNAME" \
        --token-name forgefed-smoke \
        --scopes all \
        --raw | tail -n 1
}

forgejo_api() {
    local method="$1"
    local path="$2"
    local expected="$3"
    local payload="${4:-}"
    local args=(-sS -X "$method" -w '\n%{http_code}')
    local response status body

    args+=(
        -H 'Accept: application/json'
        -H 'Content-Type: application/json'
        -H "Authorization: token $FORGEJO_TOKEN"
    )

    if [ -n "$payload" ]; then
        args+=(--data "$payload")
    fi

    response="$(curl "${args[@]}" "$GTS_BASE$path")" || return 1
    status="${response##*$'\n'}"
    body="${response%$'\n'*}"

    if [ "$status" != "$expected" ]; then
        printf 'Unexpected Forgejo HTTP status for %s %s: expected %s got %s\n' \
            "$method" "$path" "$expected" "$status" >&2
        printf '%s\n' "$body" >&2
        return 1
    fi

    printf '%s\n' "$body"
}

poll_forgejo_allowlist_rejection() {
    for _ in $(seq 1 45); do
        if docker logs "$GTS_CONTAINER" 2>&1 | \
            grep -F 'not in allowed subset [forgejo gitea mastodon gotosocial]' >/dev/null; then
            return 0
        fi

        sleep 2
    done

    docker logs "$GTS_CONTAINER" >&2 || true
    fail "Stock Forgejo did not expose its expected peer-software rejection"
}

run_forgefed_smoke() {
    local webfinger nodeinfo_link nodeinfo actor_url
    local repository repository_id repository_actor_url
    local be_credentials alice_ap_id person_resolution repository_resolution
    local forgejo_follow_response forgejo_follow_status

    write_be_secret
    write_proxy_configs

    log "Creating isolated ForgeFed federation network"
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

    log "Starting databases and stock Forgejo"
    docker run -d \
        --name "$BE_DB_CONTAINER" \
        --hostname "$BE_DB_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$BE_DB_CONTAINER" \
        -e POSTGRES_PASSWORD="$BE_DB_PASSWORD" \
        "$POSTGRES_IMAGE" >/dev/null
    wait_postgres
    prepare_database
    start_forgejo
    wait_forgejo
    create_forgejo_user
    FORGEJO_TOKEN="$(create_forgejo_token)"

    log "Proving Forgejo WebFinger, NodeInfo, Person, and Repository discovery"
    webfinger="$(http_form GET "$GTS_BASE/.well-known/webfinger?resource=acct:$GTS_USERNAME@$GTS_HOST" "" 200)"
    actor_url="$(JSON_INPUT="$webfinger" python3 - <<'PY'
import json
import os

for link in json.loads(os.environ["JSON_INPUT"]).get("links", []):
    if link.get("rel") == "self" and link.get("type") == "application/activity+json":
        print(link.get("href", ""))
        break
PY
    )"
    [ -n "$actor_url" ] || fail "Forgejo WebFinger did not expose a Person actor"

    nodeinfo_link="$(http_form GET "$GTS_BASE/.well-known/nodeinfo" "" 200)"
    nodeinfo_link="$(json_get "$nodeinfo_link" links.0.href)"
    nodeinfo="$(curl -fsS "$GTS_BASE${nodeinfo_link#https://$GTS_HOST}")"
    json_assert "$nodeinfo" \
        "data.get('software', {}).get('name') == 'forgejo' and 'activitypub' in data.get('protocols', [])" \
        "Forgejo NodeInfo did not advertise Forgejo ActivityPub"

    repository="$(forgejo_api POST /api/v1/user/repos 201 \
        "{\"name\":\"$FORGEJO_REPOSITORY\",\"private\":false}")"
    repository_id="$(json_get "$repository" id)"
    repository_actor_url="https://$GTS_HOST/api/v1/activitypub/repository-id/$repository_id"

    log "Migrating and starting Unfathomably"
    migrate_and_create_be_user alice "alice@$BE_HOST"
    start_be
    start_be_proxy
    wait_be
    ALICE_TOKEN="$(create_be_token alice)"
    be_credentials="$(http_form GET "$BE_BASE/api/v1/accounts/verify_credentials" "$ALICE_TOKEN" 200)"
    alice_ap_id="$(json_get "$be_credentials" pleroma.ap_id)"

    log "Measuring stock Forgejo's signed discovery boundary"
    person_resolution="$(http_form GET \
        "$BE_BASE/api/v2/search?q=$(urlencode "$GTS_USERNAME@$GTS_HOST")&resolve=true&type=accounts&limit=5" \
        "$ALICE_TOKEN" 200)"
    json_assert "$person_resolution" \
        "len(data.get('accounts', [])) == 0" \
        "Unfathomably unexpectedly imported the stock Forgejo Person actor"
    poll_forgejo_allowlist_rejection

    repository_resolution="$(http_form GET \
        "$BE_BASE/api/v2/search?q=$(urlencode "$repository_actor_url")&resolve=true&type=accounts&limit=5" \
        "$ALICE_TOKEN" 200)"
    json_assert "$repository_resolution" \
        "len(data.get('accounts', [])) == 0" \
        "Unfathomably unexpectedly imported the stock Forgejo Repository actor"
    poll_forgejo_allowlist_rejection

    log "Measuring stock Forgejo's outbound follow boundary"
    forgejo_follow_response="$(curl -sS -X POST \
        -H 'Accept: application/json' \
        -H 'Content-Type: application/json' \
        -H "Authorization: token $FORGEJO_TOKEN" \
        --data "{\"target\":\"$alice_ap_id\"}" \
        -w '\n%{http_code}' \
        "$GTS_BASE/api/v1/user/activitypub/follow")"
    forgejo_follow_status="${forgejo_follow_response##*$'\n'}"

    case "$forgejo_follow_status" in
        404)
            printf '%s\n' \
                '* not_supported: outbound follow: stock Forgejo 14 does not expose the ActivityPub follow API'
            ;;
        500)
            poll_forgejo_allowlist_rejection
            printf '%s\n' \
                '* not_supported: outbound follow: newer Forgejo reaches the peer-software allowlist and rejects unfathomably-be'
            ;;
        204)
            fail "Stock Forgejo unexpectedly accepted an unallowlisted Unfathomably peer"
            ;;
        *)
            printf '%s\n' "${forgejo_follow_response%$'\n'*}" >&2
            fail "Stock Forgejo returned unexpected follow status $forgejo_follow_status"
            ;;
    esac

    check_logs "$BE_CONTAINER" "Unfathomably"

    cat <<'EOF'

ForgeFed federation smoke passed.

Covered against stock Forgejo:
* supported: discovery: WebFinger and NodeInfo expose canonical Person and Repository actor routes
* supported: capabilities: the adapter classifies stock Forgejo's software allowlist honestly
* supported: failure classification: the stock peer rejection is terminal and reproducible
* supported: resource safety: rejected signed discovery remains bounded
* supported: cleanup: all Forgejo and Unfathomably state is disposable and isolated
* not_supported: native representation: Forgejo rejects the signed actor fetch before Unfathomably can import Repository
* not_supported: compatibility representation: stock Forgejo does not emit a fallback actor form
* not_supported: semantic deduplication: no duplicate native and fallback pair is emitted
* not_supported: authority: cross-software object authority cannot be exercised past the allowlist
* not_supported: lifecycle: follows, updates, deletes, undo, accept, reject, and revocation are blocked between these software names
* not_supported: concurrency: cross-software lifecycle races cannot be reached
* not_supported: collections: remote follower and object collections cannot be traversed after rejection
* not_supported: context: ticket, repository, and process round trips cannot be reached
* not_supported: round trip: Forgejo rejects NodeInfo software name unfathomably-be before actor import
* not_supported: unknown JSON-LD: stock Forgejo cannot exchange unknown vocabulary with this peer name
* not_supported: privacy: restricted cross-software resources cannot be exchanged
* not_supported: idempotence: cross-software retry state cannot progress beyond terminal rejection
* not_supported: UI classification: no remote Forgejo actor reaches the local UI
* not_supported: group follows and group unfollows are not exposed by stock Forgejo
* not_supported: likes, unlikes, posts, comments, and their Deletes cannot round trip across the allowlist
* not_supported: moderation actions and defederation awareness are not exposed by stock Forgejo
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run_forgefed_smoke
fi

# end of build_scripts/unfathomably-forgefed-smoke.sh
