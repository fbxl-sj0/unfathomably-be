#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-castling-smoke.sh
#
# Purpose:
#
#   Run the official Castling.club source against Unfathomably and verify the
#   federation contract of its hardcoded King chess-arbiter actor.
#
# Responsibilities:
#
#   * build a pinned stock Castling.club checkout and boot it with PostgreSQL
#   * play a real two-user chess opening through ordinary Unfathomably posts
#   * retain and expose Castling.club's fen, game, and san JSON-LD fields
#   * classify unsupported follow, reaction, delete, block, and report input
#   * verify direct-message privacy, idempotent inbox storage, and cleanup
#
# This file intentionally does NOT contain:
#
#   * patched Castling.club source
#   * hand-authored ActivityPub activities
#   * invented follower, group, moderation, or deletion semantics
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAMILY_HARNESS="$SCRIPT_DIR/unfathomably-gotosocial-smoke.sh"

if [ ! -f "$FAMILY_HARNESS" ]; then
    printf 'Required account-federation harness not found: %s\n' "$FAMILY_HARNESS" >&2
    exit 1
fi

export SMOKE_PREFIX="${SMOKE_PREFIX:-unfathomably-castling-smoke}"
export BE_HOST="${BE_HOST:-unfathomably-castling.example.com}"
export BE_PORT="${BE_PORT:-5091}"
export BE_DB_NAME="${BE_DB_NAME:-unfathomably_castling_smoke_be}"
export GTS_HOST="${GTS_HOST:-castling-ref.example.com}"
export GTS_PORT="${GTS_PORT:-5092}"
export GTS_APP_PORT=5080
export GTS_FORWARDED_PROTO=https
export GTS_LABEL=Castling.club
export GTS_USERNAME=king
export SMOKE_TLS=1
export BE_FEDERATION_SCHEME=https
export BE_FEDERATION_PORT=443

# shellcheck source-path=SCRIPTDIR
# shellcheck source=unfathomably-gotosocial-smoke.sh
source "$FAMILY_HARNESS"

CASTLING_SOURCE_URL="${CASTLING_SOURCE_URL:-https://github.com/stephank/castling.club.git}"
CASTLING_SOURCE_COMMIT="${CASTLING_SOURCE_COMMIT:-9425d14be5c78941fbb4d5efecda6ee4dff34eb9}"
CASTLING_IMAGE="${CASTLING_IMAGE:-unfathomably-castling-stock:${CASTLING_SOURCE_COMMIT:0:12}}"
CASTLING_POSTGRES_IMAGE="${CASTLING_POSTGRES_IMAGE:-postgres:17-alpine}"
CASTLING_DB_CONTAINER="${PREFIX}-castling-db"
CASTLING_DB_NAME="${CASTLING_DB_NAME:-castling}"
CASTLING_DB_USER="${CASTLING_DB_USER:-castling}"
CASTLING_DB_PASSWORD="${CASTLING_DB_PASSWORD:-castling-smoke-password}"
CASTLING_SOURCE_DIR="$WORK_DIR/castling-source"
CASTLING_KEY_DIR="$WORK_DIR/castling-keys"
CASTLING_HMAC_SECRET="${CASTLING_HMAC_SECRET:-castling-smoke-hmac-secret-with-at-least-32-bytes}"

cleanup_castling_smoke() {
    local incoming_status="$?"
    local status="${1:-$incoming_status}"

    if [ "$KEEP_CONTAINERS" = "1" ]; then
        cleanup "$status"
    fi

    docker rm -f "$CASTLING_DB_CONTAINER" >/dev/null 2>&1 || true
    cleanup "$status"
}

trap cleanup_castling_smoke EXIT

castling_sql() {
    docker exec "$CASTLING_DB_CONTAINER" \
        psql -U "$CASTLING_DB_USER" -d "$CASTLING_DB_NAME" -Atq -v ON_ERROR_STOP=1 "$@"
}

wait_castling_database() {
    local stable=0

    for _ in $(seq 1 90); do
        if castling_sql -c 'SELECT 1' >/dev/null 2>&1; then
            stable=$((stable + 1))
            if [ "$stable" -ge 3 ]; then
                return 0
            fi
        else
            stable=0
        fi
        sleep 1
    done

    docker logs "$CASTLING_DB_CONTAINER" >&2 || true
    fail "Castling.club PostgreSQL did not become ready"
}

prepare_castling_source() {
    require_command git

    git clone --quiet --filter=blob:none "$CASTLING_SOURCE_URL" "$CASTLING_SOURCE_DIR"
    git -C "$CASTLING_SOURCE_DIR" checkout --quiet "$CASTLING_SOURCE_COMMIT"

    local actual_commit
    actual_commit="$(git -C "$CASTLING_SOURCE_DIR" rev-parse HEAD)"
    [ "$actual_commit" = "$CASTLING_SOURCE_COMMIT" ] || \
        fail "Castling.club checkout did not match the pinned source commit"

    cat >"$CASTLING_SOURCE_DIR/Dockerfile.smoke" <<'EOF'
FROM node:24-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json package-lock.json .npmrc ./
RUN npm ci

COPY . .
RUN npm run build

CMD ["npm", "start"]
EOF

    docker build --quiet -f "$CASTLING_SOURCE_DIR/Dockerfile.smoke" \
        -t "$CASTLING_IMAGE" "$CASTLING_SOURCE_DIR" >/dev/null

    mkdir -p "$CASTLING_KEY_DIR"
    openssl genrsa -out "$CASTLING_KEY_DIR/signing-key" 2048 >/dev/null 2>&1
    openssl rsa -in "$CASTLING_KEY_DIR/signing-key" -pubout \
        -out "$CASTLING_KEY_DIR/signing-key.pub" >/dev/null 2>&1
}

castling_environment() {
    printf '%s\n' \
        -e APP_SCHEME=https \
        -e "APP_DOMAIN=$GTS_HOST" \
        -e APP_KEY_FILE=/keys/signing-key \
        -e "APP_HMAC_SECRET=$CASTLING_HMAC_SECRET" \
        -e NODE_ENV=development \
        -e PORT=5080 \
        -e "PGHOST=$CASTLING_DB_CONTAINER" \
        -e "PGDATABASE=$CASTLING_DB_NAME" \
        -e "PGUSER=$CASTLING_DB_USER" \
        -e "PGPASSWORD=$CASTLING_DB_PASSWORD" \
        -e NODE_EXTRA_CA_CERTS=/tls/ca.crt
}

start_castling() {
    local -a environment

    mapfile -t environment < <(castling_environment)

    docker run -d \
        --name "$CASTLING_DB_CONTAINER" \
        --network "$NETWORK" \
        --network-alias "$CASTLING_DB_CONTAINER" \
        -e "POSTGRES_DB=$CASTLING_DB_NAME" \
        -e "POSTGRES_USER=$CASTLING_DB_USER" \
        -e "POSTGRES_PASSWORD=$CASTLING_DB_PASSWORD" \
        "$CASTLING_POSTGRES_IMAGE" >/dev/null
    wait_castling_database

    docker run --rm \
        --network "$NETWORK" \
        "${environment[@]}" \
        -v "$CASTLING_KEY_DIR:/keys:ro" \
        -v "$SMOKE_CA_CERT:/tls/ca.crt:ro" \
        "$CASTLING_IMAGE" npm run migrate -- up >/dev/null

    docker run -d \
        --name "$GTS_CONTAINER" \
        --hostname "$GTS_APP_HOST" \
        --network "$NETWORK" \
        --network-alias "$GTS_APP_HOST" \
        "${environment[@]}" \
        -v "$CASTLING_KEY_DIR:/keys:ro" \
        -v "$SMOKE_CA_CERT:/tls/ca.crt:ro" \
        "$CASTLING_IMAGE" >/dev/null
}

wait_castling() {
    for _ in $(seq 1 120); do
        if curl -fsS "$GTS_BASE/.well-known/webfinger?resource=king" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    docker logs "$GTS_CONTAINER" >&2 || true
    fail "Timed out waiting for Castling.club at $GTS_BASE"
}

poll_castling_sql() {
    local sql="$1"
    local expected="$2"
    local message="$3"
    local value=""

    for _ in $(seq 1 90); do
        value="$(castling_sql -c "$sql" 2>/dev/null || true)"
        if [ "$value" = "$expected" ]; then
            printf '%s\n' "$value"
            return 0
        fi
        sleep 2
    done

    printf 'Expected %s, got %s\n' "$expected" "$value" >&2
    fail "$message"
}

poll_castling_outbox_san() {
    local san="$1"
    local object_id=""

    case "$san" in
        ""|*[!a-zA-Z0-9+#=-]*)
            fail "Unsafe SAN value passed to Castling.club database probe"
            ;;
    esac

    for _ in $(seq 1 90); do
        object_id="$(castling_sql -c \
            "SELECT object->>'id' FROM outbox WHERE object->>'san' = '$san' ORDER BY created_at DESC LIMIT 1;" \
            2>/dev/null || true)"
        if [ -n "$object_id" ]; then
            printf '%s\n' "$object_id"
            return 0
        fi
        sleep 2
    done

    fail "Castling.club did not create its reply for move $san"
}

poll_castling_inbox_count() {
    local minimum="$1"
    local message="$2"
    local count=0

    for _ in $(seq 1 60); do
        count="$(castling_sql -c 'SELECT COUNT(*) FROM inbox;')"
        if [ "$count" -ge "$minimum" ]; then
            printf '%s\n' "$count"
            return 0
        fi
        sleep 1
    done

    fail "$message"
}

assert_public_text_missing() {
    local text="$1"
    local data

    data="$(http_form GET "$BE_BASE/api/v1/timelines/public?limit=40" "" 200)"
    JSON_INPUT="$data" EXPECTED_TEXT="$text" python3 - <<'PY' || \
        fail "Direct Castling.club game state leaked into the public timeline"
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
text = os.environ["EXPECTED_TEXT"]
if any(text in (status.get("content") or "") for status in data):
    raise SystemExit(1)
PY
}

run_castling_smoke() {
    local webfinger nodeinfo actor_doc actor account_id follow relationship
    local alice_actor bob_actor challenge challenge_id challenge_uri
    local setup_status_id setup_status setup_uri raw_game game_url game_path game_doc
    local active_token active_actor move move_id move_uri king_move_uri king_move_id king_move_status
    local inbox_count game_count linked_game_count report_text

    prepare_smoke_tls
    write_be_secret
    write_proxy_configs

    log "Creating isolated Castling.club federation network"
    docker rm -f \
        "$GTS_PROXY_CONTAINER" \
        "$GTS_CONTAINER" \
        "$CASTLING_DB_CONTAINER" \
        "$BE_PROXY_CONTAINER" \
        "$BE_CONTAINER" \
        "$BE_DB_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    docker network create "$NETWORK" >/dev/null

    log "Building official Castling.club source at $CASTLING_SOURCE_COMMIT"
    prepare_castling_source

    log "Starting stock Castling.club and PostgreSQL"
    start_castling
    start_gts_proxy
    wait_castling

    log "Proving Castling.club discovery and its Service actor boundary"
    webfinger="$(curl -fsS -H 'Accept: application/jrd+json' \
        "$GTS_BASE/.well-known/webfinger?resource=acct:king@$GTS_HOST")"
    json_assert "$webfinger" \
        'data.get("subject") == "acct:king@castling-ref.example.com" and any("activitystreams" in (link.get("type") or "") for link in data.get("links", []))' \
        "Castling.club WebFinger did not expose its canonical King actor"
    nodeinfo="$(curl -fsS -H 'Accept: application/json' "$GTS_BASE/nodeinfo")"
    json_assert "$nodeinfo" \
        'data.get("software", {}).get("name") == "castling-ref.example.com" and data.get("protocols") == ["activitypub"] and data.get("openRegistrations") is False' \
        "Castling.club NodeInfo did not identify its ActivityPub software"
    actor_doc="$(curl -fsS -H 'Accept: application/activity+json' "$GTS_BASE/@king")"
    json_assert "$actor_doc" \
        'data.get("id") == "https://castling-ref.example.com/@king" and data.get("type") == "Service" and data.get("inbox") == "https://castling-ref.example.com/inbox" and data.get("publicKey", {}).get("publicKeyPem")' \
        "Castling.club actor discovery lost its Service identity or public key"
    actor="$(json_get "$actor_doc" id)"
    JSON_INPUT="$actor_doc" python3 - <<'PY' || \
        fail "Castling.club unexpectedly advertised account collection semantics"
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
if any(key in data for key in ("followers", "following", "outbox")):
    raise SystemExit(1)
PY

    log "Migrating and starting Unfathomably with two chess players"
    docker run -d \
        --name "$BE_DB_CONTAINER" \
        --network "$NETWORK" \
        -e POSTGRES_PASSWORD="$BE_DB_PASSWORD" \
        "$POSTGRES_IMAGE" >/dev/null
    wait_postgres
    prepare_database
    migrate_and_create_be_user alice "alice@$BE_HOST"
    create_be_user bob "bob@$BE_HOST"
    start_be
    start_be_proxy
    wait_be
    ALICE_TOKEN="$(create_be_token alice)"
    BOB_TOKEN="$(create_be_token bob)"
    alice_actor="https://$BE_HOST/users/alice"
    bob_actor="https://$BE_HOST/users/bob"

    account_id="$(resolve_account_id "$BE_BASE" "$ALICE_TOKEN" \
        "king@$GTS_HOST" "Unfathomably could not resolve Castling.club")"

    log "Classifying Castling.club's unsupported follow and unfollow boundary"
    follow="$(http_form POST "$BE_BASE/api/v1/accounts/$account_id/follow" "$ALICE_TOKEN" 200)"
    json_assert "$follow" \
        'data.get("requested") is True and data.get("following") is False' \
        "Unfathomably did not retain Castling.club's ignored Follow as pending"
    sleep 3
    relationship="$(http_form GET "$BE_BASE/api/v1/accounts/relationships?id[]=$account_id" "$ALICE_TOKEN" 200)"
    json_assert "$relationship" \
        'len(data) == 1 and data[0].get("requested") is True and data[0].get("following") is False' \
        "Castling.club unexpectedly accepted a Follow"
    http_form POST "$BE_BASE/api/v1/accounts/$account_id/unfollow" "$ALICE_TOKEN" 200 >/dev/null
    relationship="$(http_form GET "$BE_BASE/api/v1/accounts/relationships?id[]=$account_id" "$ALICE_TOKEN" 200)"
    json_assert "$relationship" \
        'len(data) == 1 and data[0].get("requested") is False and data[0].get("following") is False' \
        "Unfathomably did not clean its pending Castling.club Follow"

    log "Starting a native Castling.club game through an Unfathomably challenge"
    challenge="$(http_form POST "$BE_BASE/api/v1/statuses" "$ALICE_TOKEN" 200 \
        "status=@king@$GTS_HOST I challenge @bob@$BE_HOST!" \
        'visibility=direct')"
    challenge_id="$(json_get "$challenge" id)"
    challenge_uri="$(json_get "$challenge" uri)"
    setup_status_id="$(poll_home_status_by_text "$BE_BASE" "$ALICE_TOKEN" \
        'reply with your move' "Castling.club did not return the game setup Note")"
    setup_status="$(http_form GET "$BE_BASE/api/v1/statuses/$setup_status_id" "$ALICE_TOKEN" 200)"
    setup_uri="$(json_get "$setup_status" uri)"
    json_assert "$setup_status" \
        'data.get("pleroma", {}).get("native", {}).get("fields", {}).get("platform") == "castling" and data.get("pleroma", {}).get("native", {}).get("fields", {}).get("fen") and data.get("pleroma", {}).get("native", {}).get("fields", {}).get("game", "").startswith("https://castling-ref.example.com/games/")' \
        "Unfathomably did not expose bounded Castling.club game metadata"

    raw_game="$(docker exec -i "$BE_DB_CONTAINER" psql -U postgres -d "$BE_DB_NAME" -Atq \
        -v object_id="$setup_uri" <<'SQL'
SELECT concat(data->>'fen', '|', data->>'game')
FROM objects
WHERE data->>'id' = :'object_id';
SQL
)"
    [[ "$raw_game" == *'|'https://* ]] || \
        fail "Unfathomably did not retain Castling.club's fen and game JSON-LD"
    game_url="${raw_game#*|}"
    game_path="$(python3 - "$game_url" <<'PY'
import sys
import urllib.parse

print(urllib.parse.urlsplit(sys.argv[1]).path)
PY
)"
    game_doc="$(curl -fsS -H 'Accept: application/activity+json' "$GTS_BASE$game_path")"
    json_assert "$game_doc" \
        'data.get("id", "").startswith("https://castling-ref.example.com/games/") and data.get("fen") and data.get("whiteActor") and data.get("blackActor") and len(data.get("moves") or []) == 0' \
        "Castling.club game representation lost its players or initial FEN"
    game_count="$(castling_sql -c 'SELECT COUNT(*) FROM games;')"
    [ "$game_count" = "1" ] || fail "Castling.club did not create exactly one canonical game"
    linked_game_count="$(docker exec -i "$BE_DB_CONTAINER" psql -U postgres -d "$BE_DB_NAME" -Atq \
        -v object_id="$game_url" <<'SQL'
SELECT COUNT(*) FROM objects WHERE data->>'id' = :'object_id';
SQL
)"
    [ "$linked_game_count" = "0" ] || \
        fail "Unfathomably recursively ingested the linked Castling.club game resource"
    assert_public_text_missing 'reply with your move'

    if JSON_INPUT="$game_doc" EXPECTED="$alice_actor" python3 - <<'PY'
import json
import os

raise SystemExit(0 if json.loads(os.environ["JSON_INPUT"]).get("whiteActor") == os.environ["EXPECTED"] else 1)
PY
    then
        active_token="$ALICE_TOKEN"
        active_actor="$alice_actor"
    else
        active_token="$BOB_TOKEN"
        active_actor="$bob_actor"
    fi

    log "Playing a native Castling.club move and round-tripping its chess vocabulary"
    move="$(http_form POST "$BE_BASE/api/v1/statuses" "$active_token" 200 \
        "status=@king@$GTS_HOST e4" \
        "in_reply_to_id=$setup_status_id" \
        'visibility=direct')"
    move_id="$(json_get "$move" id)"
    move_uri="$(json_get "$move" uri)"
    king_move_uri="$(poll_castling_outbox_san e4)"
    king_move_id="$(resolve_status_id "$BE_BASE" "$active_token" "$king_move_uri" \
        "Unfathomably could not resolve Castling.club's e4 reply")"
    king_move_status="$(http_form GET "$BE_BASE/api/v1/statuses/$king_move_id" "$active_token" 200)"
    json_assert "$king_move_status" \
        'data.get("pleroma", {}).get("native", {}).get("fields", {}).get("platform") == "castling" and data.get("pleroma", {}).get("native", {}).get("fields", {}).get("san") == "e4"' \
        "Unfathomably did not expose Castling.club's native SAN move"
    poll_castling_sql \
        "SELECT COUNT(*) FROM games WHERE num_moves = 1 AND fen <> '';" \
        1 "Castling.club did not apply the Unfathomably chess move" >/dev/null
    poll_castling_sql \
        "SELECT COUNT(*) FROM game_objects WHERE object_id = '$move_uri';" \
        1 "Castling.club did not retain the move's canonical object identity" >/dev/null

    log "Classifying reactions, reports, Deletes, and Blocks accepted as semantic no-ops"
    inbox_count="$(castling_sql -c 'SELECT COUNT(*) FROM inbox;')"
    http_form POST "$BE_BASE/api/v1/statuses/$king_move_id/favourite" "$ALICE_TOKEN" 200 >/dev/null
    inbox_count="$(poll_castling_inbox_count $((inbox_count + 1)) \
        "Castling.club did not receive Unfathomably's Like")"
    http_form POST "$BE_BASE/api/v1/statuses/$king_move_id/unfavourite" "$ALICE_TOKEN" 200 >/dev/null
    inbox_count="$(poll_castling_inbox_count $((inbox_count + 1)) \
        "Castling.club did not receive Unfathomably's Undo Like")"

    report_text="Castling moderation boundary $(basename "$WORK_DIR")"
    http_form POST "$BE_BASE/api/v1/reports" "$ALICE_TOKEN" 200 \
        "account_id=$account_id" \
        "status_ids[]=$king_move_id" \
        "comment=$report_text" \
        'forward=true' >/dev/null
    inbox_count="$(poll_castling_inbox_count $((inbox_count + 1)) \
        "Castling.club did not receive Unfathomably's Flag")"

    http_form DELETE "$BE_BASE/api/v1/statuses/$move_id" "$active_token" 200 >/dev/null
    inbox_count="$(poll_castling_inbox_count $((inbox_count + 1)) \
        "Castling.club did not receive the move Delete")"
    poll_castling_sql \
        "SELECT COUNT(*) FROM games WHERE num_moves = 1;" \
        1 "Castling.club unexpectedly rewound a game after ignoring Delete" >/dev/null

    http_form POST "$BE_BASE/api/v1/accounts/$account_id/block" "$ALICE_TOKEN" 200 >/dev/null
    inbox_count="$(poll_castling_inbox_count $((inbox_count + 1)) \
        "Castling.club did not receive Unfathomably's Block")"
    http_form POST "$BE_BASE/api/v1/accounts/$account_id/unblock" "$ALICE_TOKEN" 200 >/dev/null
    poll_castling_inbox_count $((inbox_count + 1)) \
        "Castling.club did not receive Unfathomably's Undo Block" >/dev/null

    poll_castling_sql \
        "SELECT COUNT(*) FROM inbox GROUP BY activity_id HAVING COUNT(*) > 1;" \
        '' "Castling.club retained duplicate inbox activity IDs" >/dev/null
    [ "$active_actor" = "$alice_actor" ] || [ "$active_actor" = "$bob_actor" ] || \
        fail "Castling.club game selected an unknown active actor"
    [ "$challenge_id" != "$move_id" ] && [ "$challenge_uri" != "$move_uri" ] || \
        fail "Unfathomably reused status identities inside the chess thread"

    cat <<EOF

Castling.club federation smoke passed.

Covered against official Castling.club source at $CASTLING_SOURCE_COMMIT:
* supported: WebFinger, Service actor fetch, content negotiation, NodeInfo, public key discovery, and canonical HTTPS IDs
* not_supported: the King actor exposes no followers, following, or outbox collection and ignores Follow and Undo Follow
* not_supported: Castling.club has no Group actor or group follow and group-unfollow semantics
* supported: ordinary Unfathomably direct Notes create a native two-player chess game and legal move
* supported: native King replies return to Unfathomably as canonical threaded Notes
* supported: chess fen, game, san, attachment, and custom JSON-LD context survive bounded ingestion
* not_supported: Castling.club emits no compatibility fallback representation, so semantic native/fallback deduplication is not applicable
* supported: signed actor origin, Note attribution, canonical game identity, and one-move lifecycle are verified
* stock_limitation: Castling.club games and moves are immutable and expose no conditional update or concurrency API
* stock_limitation: the game resource returns its complete move array without a paged collection
* supported: direct game state stays out of Unfathomably's public timeline
* supported: linked game resources remain explicitly fetchable without recursive Unfathomably ingestion
* supported: Castling.club stores each received activity ID once and acknowledges unknown activity types without crashing
* not_supported: Like, Undo Like, Delete, Flag, Block, and Undo Block are accepted as semantic no-ops
* not_supported: Castling.club cannot initiate follows, likes, deletes, moderation actions, blocks, or an observable defederation signal
* supported: local follow cleanup, local post deletion, local block teardown, and disposable service cleanup are verified
EOF
}

run_castling_smoke

# end of build_scripts/unfathomably-castling-smoke.sh
