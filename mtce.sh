#!/bin/sh

# Hard safety guard: require explicit local Postgres unless override is set.
if [ -z "$ALLOW_REMOTE_DB" ]; then
  : "${DB_HOST:=127.0.0.1}"
  if [ "$DB_HOST" != "127.0.0.1" ] && [ "$DB_HOST" != "localhost" ]; then
    echo "Refusing to run maintenance tasks: DB_HOST is '$DB_HOST', but this script requires local Postgres."
    echo "Set ALLOW_REMOTE_DB=1 to override, or set DB_HOST=127.0.0.1."
    exit 1
  fi
fi

export DB_HOST="${DB_HOST:-127.0.0.1}"
export MIX_ENV=prod

mix pleroma.database vacuum full
mix pleroma.database set_text_search_config english
