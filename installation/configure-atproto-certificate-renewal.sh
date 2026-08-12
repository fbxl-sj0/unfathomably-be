#!/bin/sh

#
# Unfathomably ATProto PDS
# -----------------------
#
# File: configure-atproto-certificate-renewal.sh
#
# Purpose:
#
#     Configure safe renewal behavior for the manually validated wildcard
#     handle certificate.
#
# Responsibilities:
#
#     - back up the Certbot renewal configuration
#     - prevent unattended DNS challenges from waiting for an operator
#     - install the checked Nginx reload hook used after manual renewal
#
# This file intentionally does NOT alter certificates, DNS, or Nginx sites.
#

set -eu

if [ "$#" -ne 1 ]; then
    printf 'Usage: %s NGINX_RELOAD_HOOK\n' "$0" >&2
    exit 2
fi

reload_hook_source="$1"
renewal_config="/etc/letsencrypt/renewal/atproto-handles.social.fbxl.net.conf"
reload_hook_target="/etc/letsencrypt/renewal-hooks/deploy/reload-nginx"
backup_root="/var/backups/unfathomably"

if [ ! -f "$reload_hook_source" ]; then
    printf 'Nginx reload hook not found: %s\n' "$reload_hook_source" >&2
    exit 1
fi

if [ ! -f "$renewal_config" ]; then
    printf 'Wildcard renewal configuration not found: %s\n' "$renewal_config" >&2
    exit 1
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_directory="$backup_root/${timestamp}-atproto-certificate-renewal"

install -d -m 0700 "$backup_directory"
cp -a "$renewal_config" "$backup_directory/"

if grep -q '^autorenew[[:space:]]*=' "$renewal_config"; then
    sed -i 's/^autorenew[[:space:]]*=.*/autorenew = False/' "$renewal_config"
else
    sed -i '/^\[renewalparams\]$/a autorenew = False' "$renewal_config"
fi

install -o root -g root -m 0755 "$reload_hook_source" "$reload_hook_target"

certbot certificates >/dev/null
nginx -t

printf '%s\n' "$backup_directory"

# end of configure-atproto-certificate-renewal.sh
