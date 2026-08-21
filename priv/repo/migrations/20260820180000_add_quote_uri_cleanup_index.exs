# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.AddQuoteUriCleanupIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # Remote orphan cleanup protects local quote targets. Older data may use
    # either quoteUrl or quoteUri, so both spellings need an indexed lookup.
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS objects_quote_uri
    ON objects ((data->'quoteUri'))
    WHERE data->'quoteUri' IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS objects_quote_uri")
  end
end

# end of 20260820180000_add_quote_uri_cleanup_index.exs
