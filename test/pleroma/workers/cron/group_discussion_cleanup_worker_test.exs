# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.Cron.GroupDiscussionCleanupWorkerTest do
  use Pleroma.DataCase
  use Oban.Testing, repo: Pleroma.Repo

  alias Pleroma.Activity
  alias Pleroma.Bookmark
  alias Pleroma.FollowingRelationship
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Workers.Cron.GroupDiscussionCleanupWorker

  import Pleroma.Factory

  require Pleroma.Constants

  setup do
    clear_config([GroupDiscussionCleanupWorker, :enabled], true)
    clear_config([GroupDiscussionCleanupWorker, :max_age_days], 183)
    clear_config([GroupDiscussionCleanupWorker, :followed_group_max_age_days], 730)
    clear_config([GroupDiscussionCleanupWorker, :batch_size], 50)
    clear_config([GroupDiscussionCleanupWorker, :candidate_scan_limit], 100)
    clear_config([GroupDiscussionCleanupWorker, :candidate_query_chunk_size], 50)
    clear_config([GroupDiscussionCleanupWorker, :max_scan_pages], 4)
    clear_config([GroupDiscussionCleanupWorker, :query_timeout_ms], 60_000)
    clear_config([GroupDiscussionCleanupWorker, :work_budget_ms], 60_000)
    clear_config([GroupDiscussionCleanupWorker, :continuation_enabled], false)
    clear_config([GroupDiscussionCleanupWorker, :continuation_delay_seconds], 60)
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

  test "keeps recent history from a remote group followed by a local user" do
    %{activity: activity, object: object, group: group} = remote_group_discussion()
    user = insert(:user)

    assert {:ok, _follower, _following} = FollowingRelationship.follow(user, group)
    assert {:ok, 0} = GroupDiscussionCleanupWorker.perform(%Oban.Job{})

    assert %Object{data: %{"type" => "Note"}} = Object.get_by_ap_id(object.data["id"])
    assert Repo.get(Activity, activity.id)
  end

  test "eventually prunes untouched history from a followed remote group" do
    # The janitor advances retained rows by touching updated_at. The immutable
    # insertion age must therefore control the longer follow-aware horizon.
    %{object: object, group: group} = remote_group_discussion(800, 200)
    user = insert(:user)

    assert {:ok, _follower, _following} = FollowingRelationship.follow(user, group)
    assert {:ok, 1} = GroupDiscussionCleanupWorker.perform(%Oban.Job{})

    assert %Object{data: %{"type" => "Tombstone"}} = Object.get_by_ap_id(object.data["id"])
  end

  test "checks stale candidates in bounded query chunks" do
    clear_config([GroupDiscussionCleanupWorker, :batch_size], 2)
    clear_config([GroupDiscussionCleanupWorker, :candidate_scan_limit], 2)
    clear_config([GroupDiscussionCleanupWorker, :candidate_query_chunk_size], 1)
    clear_config([GroupDiscussionCleanupWorker, :max_scan_pages], 1)

    first = remote_group_discussion()
    second = remote_group_discussion()

    assert {:ok, 2} = GroupDiscussionCleanupWorker.perform(%Oban.Job{})

    assert %Object{data: %{"type" => "Tombstone"}} =
             Object.get_by_ap_id(first.object.data["id"])

    assert %Object{data: %{"type" => "Tombstone"}} =
             Object.get_by_ap_id(second.object.data["id"])
  end

  test "schedules another bounded slice when a candidate page remains" do
    clear_config([GroupDiscussionCleanupWorker, :batch_size], 2)
    clear_config([GroupDiscussionCleanupWorker, :candidate_scan_limit], 1)
    clear_config([GroupDiscussionCleanupWorker, :candidate_query_chunk_size], 1)
    clear_config([GroupDiscussionCleanupWorker, :max_scan_pages], 1)
    clear_config([GroupDiscussionCleanupWorker, :continuation_enabled], true)

    remote_group_discussion()

    assert {:ok, 1} = GroupDiscussionCleanupWorker.perform(%Oban.Job{})

    assert_enqueued(
      worker: GroupDiscussionCleanupWorker,
      args: %{"continuation" => true}
    )
  end

  test "paces continuation slices from measured work time" do
    assert GroupDiscussionCleanupWorker.continuation_delay_seconds(1_000, 60) == 60
    assert GroupDiscussionCleanupWorker.continuation_delay_seconds(20_000, 60) == 80
    assert GroupDiscussionCleanupWorker.continuation_delay_seconds(2_000_000, 60) == 3_600
  end

  defp remote_group_discussion(age_days \\ 200, updated_age_days \\ nil) do
    remote_id = System.unique_integer([:positive])
    updated_age_days = updated_age_days || age_days

    old_inserted_at =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-age_days * 86_400, :second)
      |> NaiveDateTime.truncate(:second)

    old_updated_at =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-updated_age_days * 86_400, :second)
      |> NaiveDateTime.truncate(:second)

    group =
      insert(:user,
        local: false,
        actor_type: "Group",
        ap_id: "https://lemmy.example/c/3dprinting-#{remote_id}",
        follower_address: "https://lemmy.example/c/3dprinting-#{remote_id}/followers"
      )

    poster = insert(:user, local: false, domain: "lemmy.example")
    context = "https://lemmy.example/post/#{remote_id}"

    object =
      insert(:note,
        user: poster,
        data: %{
          "to" => [group.ap_id, Pleroma.Constants.as_public()],
          "cc" => [group.follower_address],
          "context" => context,
          "published" =>
            DateTime.utc_now()
            |> DateTime.add(-age_days * 86_400, :second)
            |> DateTime.to_iso8601()
        }
      )
      |> Ecto.Changeset.change(inserted_at: old_inserted_at, updated_at: old_updated_at)
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
