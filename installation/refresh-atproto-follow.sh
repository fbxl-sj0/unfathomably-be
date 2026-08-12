#!/bin/sh

#
# Unfathomably ATProto PDS
# -----------------------
#
# File: refresh-atproto-follow.sh
#
# Purpose:
#
#     Republish a local follow that existed before its owner's ATProto account
#     was linked by refreshing it through the normal authenticated API.
#
# Responsibilities:
#
#     - resolve the local projected account for a requested ATProto DID
#     - call the same unfollow and follow endpoints used by the web interface
#     - retry the follow operation so a failed request does not leave it removed
#     - keep the local OAuth token out of command output
#
# This file intentionally does NOT contain:
#
#     - direct relationship or ATProto repository writes
#     - hard-coded account identifiers
#     - PDS session credentials
#

set -eu

if [ "$#" -ne 2 ]; then
    printf 'Usage: %s LOCAL_NICKNAME ATPROTO_DID\n' "$0" >&2
    exit 2
fi

nickname="$1"
target_did="$2"

case "$nickname" in
    "" | *[!a-zA-Z0-9_-]*)
        printf 'Invalid local nickname.\n' >&2
        exit 2
        ;;
esac

case "$target_did" in
    "" | *[!a-zA-Z0-9:._%-]*)
        printf 'Invalid ATProto DID.\n' >&2
        exit 2
        ;;
esac

case "$target_did" in
    did:plc:* | did:web:*)
        ;;

    *)
        printf 'Unsupported ATProto DID method.\n' >&2
        exit 2
        ;;
esac

API_ROOT="https://social.fbxl.net/api/v1/accounts"
MAXIMUM_FOLLOW_ATTEMPTS=3

oauth_token="$(
    runuser -u postgres -- psql -d pleroma -Atc \
        "SELECT token.token
           FROM oauth_tokens AS token
           JOIN users AS account ON account.id = token.user_id
          WHERE account.nickname = '$nickname'
            AND token.valid_until > NOW()
          ORDER BY token.updated_at DESC
          LIMIT 1;"
)"

target_nickname="$(
    runuser -u postgres -- psql -d pleroma -Atc \
        "SELECT account.nickname
           FROM atproto_identities AS identity
           JOIN users AS account ON account.id = identity.user_id
          WHERE identity.did = '$target_did'
          LIMIT 1;"
)"

if [ -z "$oauth_token" ]; then
    printf 'No active OAuth token is available for @%s.\n' "$nickname" >&2
    exit 1
fi

if [ -z "$target_nickname" ]; then
    printf 'No local ATProto projection exists for %s.\n' "$target_did" >&2
    exit 1
fi

response_file="$(mktemp)"
follow_restored="yes"

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
    rm -f "$response_file"
    exit 1
fi

target_id="$(grep -o '"id":"[A-Za-z0-9]*"' "$response_file" | head -n 1 | cut -d '"' -f 4)"

if [ -z "$target_id" ]; then
    printf 'Account lookup did not return a valid public account ID.\n' >&2
    rm -f "$response_file"
    exit 1
fi

post_relationship_action()
{
    action="$1"

    curl --silent --show-error \
        --output "$response_file" \
        --write-out '%{http_code}' \
        --request POST \
        --header "Authorization: Bearer $oauth_token" \
        --header 'Content-Type: application/json' \
        --data '{}' \
        "$API_ROOT/$target_id/$action"
}

restore_follow()
{
    attempt=1

    while [ "$attempt" -le "$MAXIMUM_FOLLOW_ATTEMPTS" ]; do
        status_code="$(post_relationship_action follow)"

        if [ "$status_code" = "200" ]; then
            follow_restored="yes"
            return 0
        fi

        sleep 2
        attempt=$((attempt + 1))
    done

    return 1
}

cleanup()
{
    if [ "$follow_restored" != "yes" ]; then
        restore_follow || true
    fi

    rm -f "$response_file"
}

trap cleanup EXIT HUP INT TERM

unfollow_status="$(post_relationship_action unfollow)"

if [ "$unfollow_status" != "200" ]; then
    printf 'Unfollow returned HTTP %s: ' "$unfollow_status" >&2
    cat "$response_file" >&2
    printf '\n' >&2
    exit 1
fi

follow_restored="no"

if ! restore_follow; then
    printf 'Follow could not be restored after %s attempts: ' "$MAXIMUM_FOLLOW_ATTEMPTS" >&2
    cat "$response_file" >&2
    printf '\n' >&2
    exit 1
fi

printf 'unfollow_http=%s follow_http=200\n' "$unfollow_status"

# end of refresh-atproto-follow.sh
