#!/bin/sh

#
# Unfathomably ATProto PDS
# -----------------------
#
# File: install-atproto-pds-config.sh
#
# Purpose:
#
#     Install the production PDS settings and import them from Pleroma's
#     protected production configuration.
#
# Responsibilities:
#
#     - validate the supplied settings file and production paths
#     - back up every configuration file that may be replaced
#     - install the settings with the Pleroma service account's ownership
#     - add the import exactly once
#
# This file intentionally does NOT contain:
#
#     - PDS credentials
#     - compilation, migration, or restart commands
#     - reverse-proxy configuration
#

set -eu

if [ "$#" -ne 1 ]; then
    printf 'Usage: %s SETTINGS_FILE\n' "$0" >&2
    exit 2
fi

SOURCE_SETTINGS="$1"
CONFIG_DIRECTORY="/opt/pleroma/config"
PRODUCTION_CONFIG="$CONFIG_DIRECTORY/prod.secret.exs"
INSTALLED_SETTINGS="$CONFIG_DIRECTORY/atproto-pds.secret.exs"
IMPORT_LINE='import_config "atproto-pds.secret.exs"'
BACKUP_ROOT="/var/backups/unfathomably"

if [ ! -f "$SOURCE_SETTINGS" ]; then
    printf 'Settings file not found: %s\n' "$SOURCE_SETTINGS" >&2
    exit 1
fi

if [ ! -f "$PRODUCTION_CONFIG" ]; then
    printf 'Production configuration not found: %s\n' "$PRODUCTION_CONFIG" >&2
    exit 1
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_directory="$BACKUP_ROOT/${timestamp}-atproto-pds-enable"

install -d -m 0700 "$backup_directory"
cp -a "$PRODUCTION_CONFIG" "$backup_directory/prod.secret.exs"

if [ -e "$INSTALLED_SETTINGS" ]; then
    cp -a "$INSTALLED_SETTINGS" "$backup_directory/atproto-pds.secret.exs"
fi

install -o pleroma -g pleroma -m 0640 "$SOURCE_SETTINGS" "$INSTALLED_SETTINGS"

if ! grep -Fxq "$IMPORT_LINE" "$PRODUCTION_CONFIG"; then
    printf '\n%s\n' "$IMPORT_LINE" >> "$PRODUCTION_CONFIG"
fi

chown pleroma:pleroma "$PRODUCTION_CONFIG"
chmod 0640 "$PRODUCTION_CONFIG"

printf '%s\n' "$backup_directory"

# end of install-atproto-pds-config.sh
