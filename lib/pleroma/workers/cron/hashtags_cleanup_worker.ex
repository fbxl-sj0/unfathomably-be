# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.Cron.HashtagsCleanupWorker do
  @moduledoc """
  Removes stale hashtag join rows and old unused hashtags.

  Hashtag rows are deliberately kept when a local user follows the tag. An empty
  followed tag is still useful user state and should survive object pruning.
  """

  use Oban.Worker, queue: "background", max_attempts: 1

  alias Pleroma.Repo

  @unused_hashtag_age_seconds 24 * 60 * 60

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    hashtags_objects = delete_stale_hashtag_object_links()
    hashtags = delete_old_unused_hashtags()

    {:ok, %{hashtags_objects: hashtags_objects, hashtags: hashtags}}
  end

  defp delete_stale_hashtag_object_links do
    %{num_rows: count} =
      Repo.query!("""
      DELETE FROM hashtags_objects AS link
      USING hashtags AS hashtag, objects AS object
      WHERE link.hashtag_id = hashtag.id
        AND link.object_id = object.id
        AND NOT EXISTS (
          SELECT 1
          FROM jsonb_array_elements(COALESCE(object.data->'tag', '[]'::jsonb)) AS tag
          WHERE lower(COALESCE(tag->>'name', '')) IN (
            lower(hashtag.name),
            lower('#' || hashtag.name)
          )
        )
      """)

    count
  end

  defp delete_old_unused_hashtags do
    stale_before =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-@unused_hashtag_age_seconds, :second)
      |> NaiveDateTime.truncate(:second)

    %{num_rows: count} =
      Repo.query!(
        """
        DELETE FROM hashtags AS hashtag
        WHERE hashtag.updated_at < $1
          AND NOT EXISTS (
            SELECT 1 FROM hashtags_objects AS link WHERE link.hashtag_id = hashtag.id
          )
          AND NOT EXISTS (
            SELECT 1 FROM user_follows_hashtag AS follow WHERE follow.hashtag_id = hashtag.id
          )
        """,
        [stale_before]
      )

    count
  end
end
