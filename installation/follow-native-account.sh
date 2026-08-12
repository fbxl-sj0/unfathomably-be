#!/bin/sh

#
# Unfathomably native account follows
# ------------------------------------
#
# File: follow-native-account.sh
#
# Purpose:
#
#     Follow an existing projected account through the same authenticated
#     Mastodon API endpoint used by the web interface.
#
# Responsibilities:
#
#     - obtain a current OAuth token for one local account without printing it
#     - resolve the target's opaque public account identifier
#     - submit an idempotent follow request and report the relationship result
#
# This file intentionally does NOT contain:
#
#     - direct relationship or protocol-repository writes
#     - hard-coded account identifiers or credentials
#     - unfollow behavior
#

set -eu

if [ "$#" -ne 2 ]; then
    printf 'Usage: %s LOCAL_NICKNAME TARGET_NICKNAME\n' "$0" >&2
    exit 2
fi

local_nickname="$1"
target_nickname="$2"

validate_nickname()
{
    case "$1" in
        "" | *[!a-zA-Z0-9_-]*)
            return 1
            ;;
    esac

    return 0
}

if ! validate_nickname "$local_nickname"; then
    printf 'Invalid local nickname.\n' >&2
    exit 2
fi

if ! validate_nickname "$target_nickname"; then
    printf 'Invalid target nickname.\n' >&2
    exit 2
fi

API_ROOT="https://social.fbxl.net/api/v1/accounts"

oauth_token="$(
    runuser -u postgres -- psql -d pleroma -Atc \
        "SELECT token.token
           FROM oauth_tokens AS token
           JOIN users AS account ON account.id = token.user_id
          WHERE account.nickname = '$local_nickname'
            AND token.valid_until > NOW()
          ORDER BY token.updated_at DESC
          LIMIT 1;"
)"

if [ -z "$oauth_token" ]; then
    printf 'No active OAuth token is available for @%s.\n' "$local_nickname" >&2
    exit 1
fi

response_file="$(mktemp)"
trap 'rm -f "$response_file"' EXIT HUP INT TERM

lookup_status="$(
    curl --silent --show-error \
        --output "$response_file" \
        --write-out '%{http_code}' \
        --header "Authorization: Bearer $oauth_token" \
        "https://social.fbxl.net/api/v1/accounts/lookup?acct=$target_nickname"
)"

if [ "$lookup_status" != "200" ]; then
    printf 'Account lookup returned HTTP %s: ' "$lookup_status" >&2
    cat "$response_file" >&2
    printf '\n' >&2
    exit 1
fi

target_id="$(grep -o '"id":"[A-Za-z0-9]*"' "$response_file" | head -n 1 | cut -d '"' -f 4)"

if [ -z "$target_id" ]; then
    printf 'Account lookup did not return a valid public account ID.\n' >&2
    exit 1
fi

follow_status="$(
    curl --silent --show-error \
        --output "$response_file" \
        --write-out '%{http_code}' \
        --request POST \
        --header "Authorization: Bearer $oauth_token" \
        --header 'Content-Type: application/json' \
        --data '{}' \
        "$API_ROOT/$target_id/follow"
)"

printf 'follow_http=%s relationship=' "$follow_status"
cat "$response_file"
printf '\n'

if [ "$follow_status" != "200" ]; then
    exit 1
fi

# end of follow-native-account.sh
