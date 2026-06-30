#!/usr/bin/env bash

# Project: unfathomably-be deployment tooling
# -------------------------------------------
#
# File: build_scripts/promote-source-to-live.sh
#
# Purpose:
#
#   Promote a prepared source tree into a live source installation while
#   preserving server-local configuration, uploads, and build state.
#
# Responsibilities:
#
#   * copy source files with rsync
#   * preserve config/prod.secret.exs and other local secret files
#   * preserve live instance data and local uploads
#   * optionally run dependency, compile, migration, and restart steps
#
# This file intentionally does NOT contain:
#
#   * database backup logic
#   * frontend asset build logic
#   * host provisioning or package installation

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  promote-source-to-live.sh --source SRC --target DST [options]

Required:
  --source SRC          Prepared source tree to promote.
  --target DST          Live source tree, for example /opt/pleroma.

Options:
  --user USER           Service user. Default: pleroma.
  --backup-dir DIR      Backup directory. Default: /var/backups.
  --no-activate         Only rsync source. Do not deps.get, compile, migrate, or restart.
  --no-restart          Run deps.get, compile, and migrate, but do not restart service.
  --service NAME        systemd service name. Default: pleroma.
  -h, --help            Show this help.

The script excludes server-local state and secrets by default. In particular,
config/prod.secret.exs, config/*.secret.exs, instance/, uploads/, deps/, and
_build/ are never removed or replaced by source promotion.
EOF
}

SOURCE=""
TARGET=""
SERVICE_USER="${SERVICE_USER:-pleroma}"
SERVICE_NAME="${SERVICE_NAME:-pleroma}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups}"
ACTIVATE=1
RESTART=1

while [ "$#" -gt 0 ]; do
    case "$1" in
        --source)
            SOURCE="${2:-}"
            shift 2
            ;;
        --target)
            TARGET="${2:-}"
            shift 2
            ;;
        --user)
            SERVICE_USER="${2:-}"
            shift 2
            ;;
        --backup-dir)
            BACKUP_DIR="${2:-}"
            shift 2
            ;;
        --service)
            SERVICE_NAME="${2:-}"
            shift 2
            ;;
        --no-activate)
            ACTIVATE=0
            shift
            ;;
        --no-restart)
            RESTART=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

if [ -z "$SOURCE" ] || [ -z "$TARGET" ]; then
    usage >&2
    exit 64
fi

if [ ! -d "$SOURCE" ]; then
    echo "Source directory does not exist: $SOURCE" >&2
    exit 66
fi

if [ ! -d "$TARGET" ]; then
    echo "Target directory does not exist: $TARGET" >&2
    exit 66
fi

SOURCE="$(cd "$SOURCE" && pwd -P)"
TARGET="$(cd "$TARGET" && pwd -P)"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_PATH="$BACKUP_DIR/unfathomably-be-source-pre-$STAMP.tgz"

if [ "$SOURCE" = "$TARGET" ]; then
    echo "Source and target must be different directories." >&2
    exit 64
fi

if [ ! -f "$TARGET/config/prod.secret.exs" ]; then
    echo "Refusing promotion: $TARGET/config/prod.secret.exs is missing." >&2
    echo "That file is server-local state and should exist before promotion." >&2
    exit 78
fi

mkdir -p "$BACKUP_DIR"
tar -C "$TARGET" -czf "$BACKUP_PATH" .

rsync -a --delete \
    --exclude='.git/' \
    --exclude='_build/' \
    --exclude='deps/' \
    --exclude='instance/' \
    --exclude='uploads/' \
    --exclude='.elixir_ls/' \
    --exclude='erl_crash.dump' \
    --exclude='soapbox.zip' \
    --exclude='config/*.secret.exs' \
    --exclude='config/prod.secret.exs' \
    "$SOURCE/" "$TARGET/"

chown -R "$SERVICE_USER:$SERVICE_USER" "$TARGET"

if [ ! -f "$TARGET/config/prod.secret.exs" ]; then
    echo "Refusing to continue: config/prod.secret.exs disappeared during promotion." >&2
    echo "Restore from $BACKUP_PATH before restarting the service." >&2
    exit 70
fi

if [ "$ACTIVATE" -eq 0 ]; then
    echo "Source promoted. Activation skipped."
    echo "Backup: $BACKUP_PATH"
    exit 0
fi

sudo -u "$SERVICE_USER" -H env MIX_ENV=prod bash -lc "
    set -euo pipefail
    cd '$TARGET'
    mix deps.get
    mix compile
    mix ecto.migrate
"

if [ "$RESTART" -eq 1 ]; then
    systemctl restart "$SERVICE_NAME"
    systemctl is-active "$SERVICE_NAME"
fi

echo "Source promoted and activated."
echo "Backup: $BACKUP_PATH"

# end of build_scripts/promote-source-to-live.sh
