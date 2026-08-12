#!/bin/sh

#
# Unfathomably ATProto PDS
# -----------------------
#
# File: verify-atproto-deployment.sh
#
# Purpose:
#
#     Verify the live managed-account integration without starting a second
#     Pleroma application instance or exposing an OAuth token.
#
# Responsibilities:
#
#     - inspect the live service and database connection state
#     - confirm the managed-account configuration import
#     - call the authenticated link-state API when a valid token exists
#     - report the local ATProto link and PDS repository counts
#
# This file intentionally does NOT contain:
#
#     - service restarts or database writes
#     - account provisioning
#     - OAuth token output
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

PRODUCTION_CONFIG="/opt/pleroma/config/prod.secret.exs"
IMPORT_LINE='import_config "atproto-pds.secret.exs"'
LINK_STATE_URL="https://social.fbxl.net/api/v1/atproto/link"
PDS_HEALTH_URL="https://pds.fbxl.net/xrpc/_health"
PDS_REPOSITORIES_URL="https://pds.fbxl.net/xrpc/com.atproto.sync.listRepos?limit=100"

printf '%s\n' 'Service state:'
systemctl show pleroma -p ActiveState -p MainPID -p NRestarts
systemctl show unfathomably-atproto-pds -p ActiveState -p MainPID -p NRestarts

printf '\n%s\n' 'Database connections:'
runuser -u postgres -- psql -d pleroma -c \
    "SELECT COALESCE(state, 'unspecified') AS state, count(*) AS connections
       FROM pg_stat_activity
      WHERE datname = 'pleroma'
      GROUP BY state
      ORDER BY state;"

runuser -u postgres -- psql -d pleroma -c \
    "SELECT count(*) AS active_waiting_connections
       FROM pg_stat_activity
      WHERE datname = 'pleroma'
        AND state = 'active'
        AND wait_event IS NOT NULL;"

runuser -u postgres -- psql -d pleroma -c \
    "SELECT application_name,
            state,
            wait_event_type,
            wait_event,
            date_trunc('second', NOW() - query_start) AS query_age
       FROM pg_stat_activity
      WHERE datname = 'pleroma'
        AND pid <> pg_backend_pid()
        AND state <> 'idle'
      ORDER BY query_start;"

if ! grep -Fxq "$IMPORT_LINE" "$PRODUCTION_CONFIG"; then
    printf 'Managed ATProto configuration is not imported.\n' >&2
    exit 1
fi

printf '\n%s\n' 'Managed link rows:'
runuser -u postgres -- psql -d pleroma -c \
    "SELECT count(*) AS links,
            count(*) FILTER (WHERE managed) AS managed_links
       FROM atproto_links;"

printf '\n%s\n' 'Bounded ATProto working set:'
runuser -u postgres -- psql -d pleroma -c \
    "SELECT source,
            collection,
            local,
            count(*) AS records
       FROM atproto_records
      GROUP BY source, collection, local
      ORDER BY local, source, collection;"

printf '\n%s\n' 'Pending receiver work:'
runuser -u postgres -- psql -d pleroma -c \
    "SELECT state,
            CASE
              WHEN args #>> '{params,unfathomably:atproto_ingest}' = 'true'
                OR args #>> '{params,object,unfathomably:atproto,uri}' IS NOT NULL
                THEN 'atproto'
              ELSE 'other'
            END AS origin,
            min(attempt) AS minimum_attempt,
            max(attempt) AS maximum_attempt,
            count(*) AS jobs
       FROM oban_jobs
      WHERE worker = 'Pleroma.Workers.ReceiverWorker'
        AND state IN ('available', 'scheduled', 'executing', 'retryable', 'suspended')
      GROUP BY state, origin
      ORDER BY state, origin;"

printf '\n%s\n' 'Pending ATProto queue work:'
runuser -u postgres -- psql -d pleroma -c \
    "SELECT worker,
            state,
            count(*) AS jobs
       FROM oban_jobs
      WHERE queue = 'atproto'
        AND state IN ('available', 'scheduled', 'executing', 'retryable', 'suspended')
      GROUP BY worker, state
      ORDER BY worker, state;"

printf '\n%s\n' 'Selective native follows for the requested account:'
runuser -u postgres -- psql -d pleroma -c \
    "SELECT identity.user_id,
            followed.nickname,
            followed.is_active,
            identity.handle,
            identity.did,
            relationship.state
       FROM following_relationships AS relationship
       JOIN users AS follower ON follower.id = relationship.follower_id
       JOIN atproto_identities AS identity
         ON identity.user_id = relationship.following_id
       JOIN users AS followed ON followed.id = identity.user_id
      WHERE follower.nickname = '$nickname'
      ORDER BY identity.handle;"

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

printf '\n%s\n' 'Authenticated managed-account state:'

if [ -n "$oauth_token" ]; then
    curl --fail-with-body --silent --show-error \
        --header "Authorization: Bearer $oauth_token" \
        "$LINK_STATE_URL"
    printf '\n'
else
    printf 'No active OAuth token is available for @%s; API check skipped.\n' "$nickname"
fi

printf '\n%s\n' 'PDS health and repository list:'
curl --fail-with-body --silent --show-error "$PDS_HEALTH_URL"
printf '\n'
curl --fail-with-body --silent --show-error "$PDS_REPOSITORIES_URL"
printf '\n'

# end of verify-atproto-deployment.sh
