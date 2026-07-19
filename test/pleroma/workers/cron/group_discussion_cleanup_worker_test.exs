# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.Cron.GroupDiscussionCleanupWorkerTest do
  use Pleroma.DataCase

  alias Pleroma.Activity
  alias Pleroma.Bookmark
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Workers.Cron.GroupDiscussionCleanupWorker

  import Pleroma.Factory

  require Pleroma.Constants

  setup do
    clear_config([GroupDiscussionCleanupWorker, :enabled], true)
    clear_config([GroupDiscussionCleanupWorker, :max_age_days], 183)
    clear_config([GroupDiscussionCleanupWorker, :batch_size], 50)
  end

  test "purges old remote group discussions without local user interaction" do
    %{activity: activity, object: object} = remote_group_discussion()

    assert {:ok, 1} = GroupDiscussionCleanupWorker.perform(%Oban.Job{})

    assert %Object{data: %{"type" => "Tombstone"}} = Object.get_by_ap_id(object.data["id"])
    refute Repo.get(Activity, activity.id)
  end

  test "keeps old remote group discussions favourited by a local user" do
    %{activity: activity, object: object} = remote_group_discussion()
    user = insert(:user)

    assert {:ok, _favorite} = CommonAPI.favorite(user, activity.id)

    assert {:ok, 0} = GroupDiscussionCleanupWorker.perform(%Oban.Job{})

    assert %Object{data: %{"type" => "Note"}} = Object.get_by_ap_id(object.data["id"])
    assert Repo.get(Activity, activity.id)
  end

  test "keeps old remote group discussions replied to by a local user" do
    %{activity: activity, object: object} = remote_group_discussion()
    user = insert(:user)

    assert {:ok, _reply} =
             CommonAPI.post(user, %{
               status: "I want to keep this",
               in_reply_to_status_id: activity.id
             })

    assert {:ok, 0} = GroupDiscussionCleanupWorker.perform(%Oban.Job{})

    assert %Object{data: %{"type" => "Note"}} = Object.get_by_ap_id(object.data["id"])
    assert Repo.get(Activity, activity.id)
  end

  test "keeps old remote group discussions bookmarked by a local user" do
    %{activity: activity, object: object} = remote_group_discussion()
    user = insert(:user)

    assert {:ok, _bookmark} = Bookmark.create(user.id, activity.id)

    assert {:ok, 0} = GroupDiscussionCleanupWorker.perform(%Oban.Job{})

    assert %Object{data: %{"type" => "Note"}} = Object.get_by_ap_id(object.data["id"])
    assert Repo.get(Activity, activity.id)
  end

  defp remote_group_discussion do
    old_inserted_at =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-200 * 86_400, :second)
      |> NaiveDateTime.truncate(:second)

    group =
      insert(:user,
        local: false,
        actor_type: "Group",
        ap_id: "https://lemmy.example/c/3dprinting",
        follower_address: "https://lemmy.example/c/3dprinting/followers"
      )

    poster = insert(:user, local: false, domain: "lemmy.example")
    context = "https://lemmy.example/post/abc"

    object =
      insert(:note,
        user: poster,
        data: %{
          "to" => [group.ap_id, Pleroma.Constants.as_public()],
          "cc" => [group.follower_address],
          "context" => context,
          "published" =>
            DateTime.utc_now() |> DateTime.add(-200 * 86_400, :second) |> DateTime.to_iso8601()
        }
      )
      |> Ecto.Changeset.change(inserted_at: old_inserted_at, updated_at: old_inserted_at)
      |> Repo.update!()

    activity =
      insert(:note_activity,
        user: poster,
        note: object,
        local: false,
        inserted_at: old_inserted_at,
        updated_at: old_inserted_at,
        data_attrs: %{
          "to" => object.data["to"],
          "cc" => object.data["cc"],
          "context" => context
        }
      )

    %{activity: activity, object: object, group: group}
  end
end
