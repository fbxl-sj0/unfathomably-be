# Unfathomably received video playlist discovery index
# -----------------------------------------------------
#
# File: 20260725223000_add_video_playlist_discovery_search_index.exs
#
# Purpose:
#   Index public-search metadata on structurally identified PeerTube playlists.
#
# Responsibilities:
#   - distinguish video playlists using PeerTube's channel position field
#   - index title, description, UUID, and channel attribution
#   - build and remove the index without a long table lock
#
# This file intentionally does not index playlist elements, infer software from
# hostnames, or include Funkwhale playlists that use the same object type.

defmodule Pleroma.Repo.Migrations.AddVideoPlaylistDiscoverySearchIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS objects_video_playlist_discovery_search_idx
    ON objects
    USING gin (
      to_tsvector(
        'simple',
        coalesce(data->>'name', '') || ' ' ||
        coalesce(data->>'content', '') || ' ' ||
        coalesce(data->>'summary', '') || ' ' ||
        coalesce(data->>'uuid', '') || ' ' ||
        coalesce(data->>'attributedTo', '')
      )
    )
    WHERE data->>'type' = 'Playlist'
      AND jsonb_typeof(data->'videoChannelPosition') = 'number'
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS objects_video_playlist_discovery_search_idx")
  end
end

# end of 20260725223000_add_video_playlist_discovery_search_index.exs
