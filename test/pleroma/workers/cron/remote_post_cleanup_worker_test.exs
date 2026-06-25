# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.Cron.RemotePostCleanupWorkerTest do
  use Pleroma.DataCase

  alias Pleroma.Activity
  alias Pleroma.Bookmark
  alias Pleroma.FollowingRelationship
  alias Pleroma.Notification
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Workers.Cron.RemotePostCleanupWorker

  import Pleroma.Factory

  require Pleroma.Constants

  setup do
    clear_config([RemotePostCleanupWorker, :enabled], true)
    clear_config([RemotePostCleanupWorker, :max_age_days], 365)
    clear_config([RemotePostCleanupWorker, :batch_size], 50)
    clear_config([RemotePostCleanupWorker, :candidate_scan_limit], 100)
    clear_config([RemotePostCleanupWorker, :max_scan_pages], 4)
    clear_config([RemotePostCleanupWorker, :query_timeout_ms], 60_000)
    clear_config([RemotePostCleanupWorker, :keep_threads_with_local_activity], true)
    clear_config([RemotePostCleanupWorker, :keep_direct_or_mentioned], true)
    clear_config([RemotePostCleanupWorker, :remote_actor_cleanup_enabled], true)
    clear_config([RemotePostCleanupWorker, :remote_actor_max_age_days], 730)
    clear_config([RemotePostCleanupWorker, :remote_actor_batch_size], 50)
  end

  test "prunes old untouched remote public post objects without deleting their create activities" do
    %{activity: activity, object: object} = remote_public_post()

    assert {:ok, 1} = RemotePostCleanupWorker.perform(%Oban.Job{})

    refute Object.get_by_ap_id(object.data["id"])
    assert Repo.get(Activity, activity.id)
  end

  test "keeps recent remote public post objects" do
    %{activity: activity, object: object} = remote_public_post(old_days: 30)

    assert {:ok, 0} = RemotePostCleanupWorker.perform(%Oban.Job{})

    assert %Object{data: %{"type" => "Note"}} = Object.get_by_ap_id(object.data["id"])
    assert Repo.get(Activity, activity.id)
  end

  test "keeps old remote public posts favourited by a local user" do
    %{activity: activity, object: object} = remote_public_post()
    user = insert(:user)

    assert {:ok, _favorite} = CommonAPI.favorite(user, activity.id)

    assert {:ok, 0} = RemotePostCleanupWorker.perform(%Oban.Job{})

    assert %Object{data: %{"type" => "Note"}} = Object.get_by_ap_id(object.data["id"])
    assert Repo.get(Activity, activity.id)
  end

  test "keeps old remote public posts repeated by a local user" do
    %{activity: activity, object: object} = remote_public_post()
    user = insert(:user)

    assert {:ok, _repeat} = CommonAPI.repeat(activity.id, user)

    assert {:ok, 0} = RemotePostCleanupWorker.perform(%Oban.Job{})

    assert %Object{data: %{"type" => "Note"}} = Object.get_by_ap_id(object.data["id"])
    assert Repo.get(Activity, activity.id)
  end

  test "keeps old remote public posts replied to by a local user" do
    %{activity: activity, object: object} = remote_public_post()
    user = insert(:user)

    assert {:ok, _reply} =
             CommonAPI.post(user, %{
               status: "I want to keep this thread",
               in_reply_to_status_id: activity.id,
               visibility: "public"
             })

    assert {:ok, 0} = RemotePostCleanupWorker.perform(%Oban.Job{})

    assert %Object{data: %{"type" => "Note"}} = Object.get_by_ap_id(object.data["id"])
    assert Repo.get(Activity, activity.id)
  end

  test "keeps old remote public posts when local users touched the same thread" do
    context = "https://remote.example/threads/kept"
    %{activity: first_activity, object: first_object} = remote_public_post(context: context)
    %{object: second_object} = remote_public_post(context: context)
    user = insert(:user)

    assert {:ok, _reply} =
             CommonAPI.post(user, %{
               status: "This should keep the surrounding thread",
               in_reply_to_status_id: first_activity.id,
               visibility: "public"
             })

    assert {:ok, 0} = RemotePostCleanupWorker.perform(%Oban.Job{})

    assert %Object{data: %{"type" => "Note"}} = Object.get_by_ap_id(first_object.data["id"])
    assert %Object{data: %{"type" => "Note"}} = Object.get_by_ap_id(second_object.data["id"])
  end

  test "can prune other posts in a touched thread when thread preservation is disabled" do
    clear_config([RemotePostCleanupWorker, :keep_threads_with_local_activity], false)

    context = "https://remote.example/threads/not-kept"
    %{activity: first_activity, object: first_object} = remote_public_post(context: context)
    %{object: second_object} = remote_public_post(context: context)
    user = insert(:user)

    assert {:ok, _reply} =
             CommonAPI.post(user, %{
               status: "Keep the direct parent only",
               in_reply_to_status_id: first_activity.id,
               visibility: "public"
             })

    assert {:ok, 1} = RemotePostCleanupWorker.perform(%Oban.Job{})

    assert %Object{data: %{"type" => "Note"}} = Object.get_by_ap_id(first_object.data["id"])
    refute Object.get_by_ap_id(second_object.data["id"])
  end

  test "keeps old remote public posts bookmarked by a local user" do
    %{activity: activity, object: object} = remote_public_post()
    user = insert(:user)

    assert {:ok, _bookmark} = Bookmark.create(user.id, activity.id)

    assert {:ok, 0} = RemotePostCleanupWorker.perform(%Oban.Job{})

    assert %Object{data: %{"type" => "Note"}} = Object.get_by_ap_id(object.data["id"])
    assert Repo.get(Activity, activity.id)
  end

  test "keeps old remote public posts directly addressed to a local user" do
    user = insert(:user)

    %{activity: activity, object: object} =
      remote_public_post(to: [Pleroma.Constants.as_public(), user.ap_id])

    assert {:ok, 0} = RemotePostCleanupWorker.perform(%Oban.Job{})

    assert %Object{data: %{"type" => "Note"}} = Object.get_by_ap_id(object.data["id"])
    assert Repo.get(Activity, activity.id)
  end

  test "keeps old remote public posts with local notifications" do
    %{activity: activity, object: object} = remote_public_post()
    user = insert(:user)

    notification = insert(:notification, user: user, activity: activity)

    assert {:ok, 0} = RemotePostCleanupWorker.perform(%Oban.Job{})

    assert %Object{data: %{"type" => "Note"}} = Object.get_by_ap_id(object.data["id"])
    assert Repo.get(Notification, notification.id)
  end

  test "does nothing when disabled" do
    clear_config([RemotePostCleanupWorker, :enabled], false)
    %{object: object} = remote_public_post()

    assert {:ok, 0} = RemotePostCleanupWorker.perform(%Oban.Job{})

    assert %Object{data: %{"type" => "Note"}} = Object.get_by_ap_id(object.data["id"])
  end

  test "respects the configured batch size" do
    clear_config([RemotePostCleanupWorker, :batch_size], 1)
    first = remote_public_post()
    second = remote_public_post()

    assert {:ok, 1} = RemotePostCleanupWorker.perform(%Oban.Job{})

    pruned_count =
      [first.object, second.object]
      |> Enum.count(&(Object.get_by_ap_id(&1.data["id"]) == nil))

    assert pruned_count == 1
  end

  test "keeps scanning when the first old candidate window is protected" do
    clear_config([RemotePostCleanupWorker, :batch_size], 1)
    clear_config([RemotePostCleanupWorker, :candidate_scan_limit], 1)
    clear_config([RemotePostCleanupWorker, :max_scan_pages], 2)

    protected = remote_public_post()
    prunable = remote_public_post()
    user = insert(:user)

    assert {:ok, _favorite} = CommonAPI.favorite(user, protected.activity.id)

    assert {:ok, 1} = RemotePostCleanupWorker.perform(%Oban.Job{})

    assert %Object{data: %{"type" => "Note"}} = Object.get_by_ap_id(protected.object.data["id"])
    refute Object.get_by_ap_id(prunable.object.data["id"])
  end

  test "hides stale unused remote actors and clears cached presentation data" do
    actor = old_remote_actor()

    assert {:ok, 0} = RemotePostCleanupWorker.perform(%Oban.Job{})

    assert %User{
             invisible: true,
             is_discoverable: false,
             avatar: %{},
             banner: %{},
             tags: [],
             emoji: %{}
           } = Repo.reload(actor)
  end

  test "keeps stale remote actors followed by local users" do
    local_user = insert(:user)
    actor = old_remote_actor()

    assert {:ok, _, _} = FollowingRelationship.follow(local_user, actor, :follow_accept)

    assert {:ok, 0} = RemotePostCleanupWorker.perform(%Oban.Job{})

    assert %User{invisible: false, avatar: %{"url" => _}} = Repo.reload(actor)
  end

  defp remote_public_post(opts \\ []) do
    old_days = Keyword.get(opts, :old_days, 400)
    public = Pleroma.Constants.as_public()
    remote_id = System.unique_integer([:positive])
    remote_host = Keyword.get(opts, :remote_host, "remote.example")
    context = Keyword.get(opts, :context, "https://#{remote_host}/threads/#{remote_id}")
    to = Keyword.get(opts, :to, [public])
    cc = Keyword.get(opts, :cc, [])

    old_inserted_at =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-old_days * 86_400, :second)
      |> NaiveDateTime.truncate(:second)

    poster = insert(:user, local: false, domain: remote_host)

    object =
      insert(:note,
        user: poster,
        data: %{
          "id" => "https://#{remote_host}/objects/#{remote_id}",
          "to" => to,
          "cc" => cc,
          "context" => context,
          "published" =>
            DateTime.utc_now()
            |> DateTime.add(-old_days * 86_400, :second)
            |> DateTime.to_iso8601()
        }
      )

    Object
    |> Ecto.Query.where([object], object.id == ^object.id)
    |> Repo.update_all(set: [inserted_at: old_inserted_at, updated_at: old_inserted_at])

    object = Repo.get(Object, object.id)

    activity =
      insert(:note_activity,
        user: poster,
        note: object,
        local: false,
        inserted_at: old_inserted_at,
        updated_at: old_inserted_at,
        data_attrs: %{
          "to" => to,
          "cc" => cc,
          "context" => context
        }
      )

    %{activity: activity, object: object}
  end

  defp old_remote_actor do
    old_datetime =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-800 * 86_400, :second)
      |> NaiveDateTime.truncate(:second)

    insert(:user,
      local: false,
      domain: "unused.example",
      actor_type: "Person",
      updated_at: old_datetime,
      last_refreshed_at: old_datetime,
      last_status_at: old_datetime,
      invisible: false,
      is_discoverable: true,
      avatar: %{"url" => "https://unused.example/avatar.png"},
      banner: %{"url" => "https://unused.example/banner.png"},
      tags: ["stale"],
      emoji: %{"old" => "https://unused.example/old.png"}
    )
  end
end
