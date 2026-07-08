# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.Cron.HashtagsCleanupWorkerTest do
  use Pleroma.DataCase

  import Ecto.Query
  import Pleroma.Factory

  alias Pleroma.Hashtag
  alias Pleroma.Repo
  alias Pleroma.User.HashtagFollow
  alias Pleroma.Workers.Cron.HashtagsCleanupWorker

  test "removes orphaned hashtag links and old unused hashtags" do
    user = insert(:user)
    object = insert(:note)
    orphaned_hashtag = insert(:hashtag, name: "orphaned")
    old_unused_hashtag = insert(:hashtag, name: "old-unused")
    followed_hashtag = insert(:hashtag, name: "followed-empty")
    fresh_unused_hashtag = insert(:hashtag, name: "fresh-unused")

    Repo.insert_all("hashtags_objects", [
      %{hashtag_id: orphaned_hashtag.id, object_id: object.id}
    ])

    old_timestamp =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-2 * 24 * 60 * 60, :second)
      |> NaiveDateTime.truncate(:second)

    Hashtag
    |> where([hashtag], hashtag.id in ^[old_unused_hashtag.id, followed_hashtag.id])
    |> Repo.update_all(set: [inserted_at: old_timestamp, updated_at: old_timestamp])

    assert {:ok, _} = HashtagFollow.new(user, followed_hashtag)

    assert {:ok, %{hashtags_objects: 1, hashtags: 1}} =
             HashtagsCleanupWorker.perform(%Oban.Job{})

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT COUNT(*) FROM hashtags_objects WHERE hashtag_id = $1",
               [orphaned_hashtag.id]
             )

    refute Repo.get(Hashtag, old_unused_hashtag.id)
    assert Repo.get(Hashtag, followed_hashtag.id)
    assert Repo.get(Hashtag, fresh_unused_hashtag.id)
  end
end
