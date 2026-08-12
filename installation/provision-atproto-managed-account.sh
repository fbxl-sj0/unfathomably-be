#!/bin/sh

#
# Unfathomably ATProto PDS
# -----------------------
#
# File: provision-atproto-managed-account.sh
#
# Purpose:
#
#     Create a managed ATProto identity through the same authenticated API
#     used by the Unfathomably settings interface.
#
# Responsibilities:
#
#     - locate a current OAuth token without printing it
#     - call the managed-account provisioning endpoint exactly once
#     - print the endpoint response, including the one-time PDS password
#
# This file intentionally does NOT contain:
#
#     - PDS administration credentials
#     - direct database writes
#     - follow, post, or repository mutation logic
#

set -eu

if [ "$#" -ne 1 ]; then
    printf 'Usage: %s LOCAL_NICKNAME\n' "$0" >&2
    exit 2
fi

nickname="$1"

case "$nickname" in
    "" | *[!a-zA-Z0-9_-]*)
        printf 'Invalid local nickname.\n' >&2
        exit 2
        ;;
esac

PROVISION_URL="https://social.fbxl.net/api/v1/atproto/provision"

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

if [ -z "$oauth_token" ]; then
    printf 'No active OAuth token is available for @%s.\n' "$nickname" >&2
    exit 1
fi

response_file="$(mktemp)"
trap 'rm -f "$response_file"' EXIT HUP INT TERM

status_code="$(
    curl --silent --show-error \
        --output "$response_file" \
        --write-out '%{http_code}' \
        --request POST \
        --header "Authorization: Bearer $oauth_token" \
        --header 'Content-Type: application/json' \
        --data '{}' \
        "$PROVISION_URL"
)"

if [ "$status_code" != "200" ]; then
    printf 'Provisioning returned HTTP %s: ' "$status_code" >&2
    cat "$response_file" >&2
    printf '\n' >&2
    exit 1
fi

cat "$response_file"
printf '\n'

# end of provision-atproto-managed-account.sh
