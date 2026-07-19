#!/usr/bin/env bash

#
# Project: Unfathomably federation smoke tests
# ------------------------------------------------------------
#
# File: unfathomably-mitra-smoke.sh
#
# Purpose:
#
#   Run a stock Mitra peer through the established account-federation smoke
#   harness. Mitra exposes the Mastodon-compatible operations used by that
#   harness, while this adapter owns Mitra's container and account bootstrap.
#
# Responsibilities:
#
#   * configure an isolated Mitra instance on the shared smoke network
#   * create the Mitra database and local test account
#   * obtain a Mitra password-grant access token
#   * reuse the proven bidirectional follow, post, reply, reaction, delete,
#     unfollow, and Group actor checks
#
# This file intentionally does NOT contain:
#
#   * a second copy of the account-federation assertions
#   * production Mitra configuration
#   * changes to the stock Mitra image
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAMILY_HARNESS="$SCRIPT_DIR/unfathomably-gotosocial-smoke.sh"

if [ ! -f "$FAMILY_HARNESS" ]; then
    printf 'Required account-federation harness not found: %s\n' "$FAMILY_HARNESS" >&2
    exit 1
fi

export SMOKE_PREFIX="${SMOKE_PREFIX:-unfathomably-mitra-smoke}"
export BE_HOST="${BE_HOST:-unfathomably-mitra.test}"
export BE_PORT="${BE_PORT:-5003}"
export BE_DB_NAME="${BE_DB_NAME:-unfathomably_mitra_smoke_be}"
export GTS_HOST="${GTS_HOST:-mitra-ref.test}"
export GTS_PORT="${GTS_PORT:-5004}"
export GTS_APP_PORT="${GTS_APP_PORT:-8380}"
export GTS_LABEL="${GTS_LABEL:-Mitra}"
export GTS_USERNAME="${GTS_USERNAME:-mitra}"
export GTS_GROUP_NAME="${GTS_GROUP_NAME:-unfathomably_mitra_smoke}"
export GTS_SEARCH_WITH_ACCOUNT_TYPE=0
export GTS_SEARCH_WITH_STATUS_TYPE=0
export GTS_LOOKUP_BE_BY_ACTOR_URL=1
export GTS_EMPTY_POST_JSON=1
export GTS_FORM_URLENCODE=1
export GTS_IMAGE="${MITRA_IMAGE:-codeberg.org/silverpill/mitra:latest}"

# shellcheck source=unfathomably-gotosocial-smoke.sh
source "$FAMILY_HARNESS"

MITRA_DB_NAME="${MITRA_DB_NAME:-mitra_smoke}"
MITRA_CONFIG="$WORK_DIR/mitra/config.yaml"

start_gotosocial() {
    docker volume create "$GTS_VOLUME" >/dev/null
    mkdir -p "$(dirname "$MITRA_CONFIG")"

    docker exec "$BE_DB_CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 \
        -c "CREATE DATABASE $MITRA_DB_NAME;" >/dev/null

    cat >"$MITRA_CONFIG" <<EOF
database_url: postgres://postgres:$BE_DB_PASSWORD@$BE_DB_CONTAINER:5432/$MITRA_DB_NAME
storage_dir: /var/lib/mitra
web_client_dir: null
http_host: 0.0.0.0
http_port: $GTS_APP_PORT
instance_url: http://$GTS_HOST
instance_title: Unfathomably Mitra Smoke
instance_short_description: Local federation compatibility peer
instance_description: Local federation compatibility peer
registration:
  type: open
  default_role: user
federation:
  enabled: true
  ssrf_protection_enabled: false
EOF

    docker run -d \
        --name "$GTS_CONTAINER" \
        --hostname "$GTS_APP_HOST" \
        --network "$NETWORK" \
        --network-alias "$GTS_APP_HOST" \
        -v "$MITRA_CONFIG:/etc/mitra/config.yaml:ro" \
        -v "$GTS_VOLUME:/var/lib/mitra" \
        "$GTS_IMAGE" >/dev/null
}

create_gts_user() {
    local username="$1"
    local payload

    payload="$(MITRA_USERNAME="$username" MITRA_PASSWORD="$PASSWORD" python3 - <<'PY'
import json
import os

print(json.dumps({
    "username": os.environ["MITRA_USERNAME"],
    "password": os.environ["MITRA_PASSWORD"],
}))
PY
)"

    http_json POST "$GTS_BASE/api/v1/accounts" "" 201 "$payload" >/dev/null
}

create_gts_token() {
    local username="$1"
    local payload token

    payload="$(MITRA_USERNAME="$username" MITRA_PASSWORD="$PASSWORD" python3 - <<'PY'
import json
import os

print(json.dumps({
    "grant_type": "password",
    "username": os.environ["MITRA_USERNAME"],
    "password": os.environ["MITRA_PASSWORD"],
}))
PY
)"
    token="$(http_json POST "$GTS_BASE/oauth/token" "" 200 "$payload")"
    json_get "$token" access_token
}

run_account_peer_smoke

# end of build_scripts/unfathomably-mitra-smoke.sh
