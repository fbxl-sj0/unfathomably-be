#!/bin/sh

#
# Unfathomably ATProto PDS
# -----------------------
#
# File: certbot-atproto-dns-hook.sh
#
# Purpose:
#
#     Pause Certbot's manual DNS challenge while the administrator adds the
#     temporary GoDaddy TXT record required for the managed-handle wildcard.
#
# Responsibilities:
#
#     - Record the ACME validation value in a root-only state directory.
#     - Wait for an operator-created continuation marker.
#     - Remove transient coordination files after Certbot completes.
#
# This file intentionally does NOT contain:
#
#     - GoDaddy credentials or DNS API access.
#     - Certificate installation or Nginx configuration.
#     - A long-running certificate renewal service.
#

set -eu

STATE_DIRECTORY="${ATPROTO_CERTBOT_STATE_DIRECTORY:-/var/lib/unfathomably-atproto-certbot}"
EXPECTED_DOMAIN="social.fbxl.net"

# A full day leaves room for the GoDaddy UI and authoritative DNS publication.
MAXIMUM_WAIT_SECONDS=86400
POLL_INTERVAL_SECONDS=5

write_challenge()
{
    if [ "${CERTBOT_DOMAIN:-}" != "$EXPECTED_DOMAIN" ]; then
        printf 'Refusing unexpected Certbot domain: %s\n' "${CERTBOT_DOMAIN:-<unset>}" >&2
        return 1
    fi

    if [ -z "${CERTBOT_VALIDATION:-}" ]; then
        printf 'Certbot did not provide a DNS validation value.\n' >&2
        return 1
    fi

    install -d -m 0700 "$STATE_DIRECTORY"
    umask 077

    printf '%s\n' "$CERTBOT_DOMAIN" > "$STATE_DIRECTORY/domain"
    printf '%s\n' "$CERTBOT_VALIDATION" > "$STATE_DIRECTORY/validation"
    rm -f "$STATE_DIRECTORY/continue"
    : > "$STATE_DIRECTORY/waiting"

    elapsed_seconds=0

    while [ "$elapsed_seconds" -lt "$MAXIMUM_WAIT_SECONDS" ]; do
        if [ -f "$STATE_DIRECTORY/continue" ]; then
            return 0
        fi

        sleep "$POLL_INTERVAL_SECONDS"
        elapsed_seconds=$((elapsed_seconds + POLL_INTERVAL_SECONDS))
    done

    printf 'Timed out waiting for the DNS continuation marker.\n' >&2
    return 1
}

clean_challenge()
{
    rm -f "$STATE_DIRECTORY/continue" "$STATE_DIRECTORY/waiting"
}

action="${1:-}"

if [ -z "$action" ]; then
    case "$0" in
        *-auth)
            action="auth"
            ;;

        *-cleanup)
            action="cleanup"
            ;;
    esac
fi

case "$action" in
    auth)
        write_challenge
        ;;

    cleanup)
        clean_challenge
        ;;

    *)
        printf 'Usage: %s auth|cleanup\n' "$0" >&2
        exit 2
        ;;
esac

# end of certbot-atproto-dns-hook.sh
