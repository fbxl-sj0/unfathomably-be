# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.Cron.RemotePostCleanupWorker do
  @moduledoc """
  Prunes stale remote public posts that nobody local has kept alive.

  The instance keeps remote posts as a cache. For busy federated timelines this
  can grow without bound, while most old remote posts are never viewed again.
  This worker removes only the cached object row, leaving the remote Create
  activity in place so the object can be fetched again if a user follows a link
  to it later.

  Posts are preserved when a local non-group user has interacted with them. That
  includes favourites, reactions, repeats, replies, bookmarks, notifications,
  direct addressing, and, by default, any local activity in the same thread.
  """

  use Oban.Worker, queue: "background", max_attempts: 3

  import Ecto.Query

  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.FollowingRelationship
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User

  require Logger
  require Pleroma.Constants

  @default_max_age_days 365
  @default_batch_size 50
  @default_candidate_scan_limit 1_000
  @default_max_scan_pages 10
  @default_query_timeout_ms 60_000
  @default_remote_actor_max_age_days 730
  @default_remote_actor_batch_size 50
  @seconds_per_day 86_400
  @prunable_object_types ~w(Note Article Page Question Event Audio Video)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if enabled?() do
      {:ok, prune_candidates()}
    else
      {:ok, 0}
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  defp prune_candidates do
    cutoff = cutoff()
    batch_size = batch_size()
    keep_threads? = keep_threads_with_local_activity?()
    keep_direct? = keep_direct_or_mentioned?()

    count =
      case candidate_objects(cutoff, batch_size, keep_threads?, keep_direct?) do
        {:ok, object_ids, scanned_count} ->
          count =
            object_ids
            |> objects_by_ids()
            |> Enum.reduce(0, &prune_object/2)

          if count > 0 do
            prune_unused_hashtags()
          end

          Logger.info(
            "Remote post cleanup pruned #{count} objects after scanning #{scanned_count} old remote candidates"
          )

          count

        {:error, reason} ->
          Logger.warning("Remote post cleanup skipped after query failure: #{inspect(reason)}")
          0
      end

    stale_actor_count = prune_stale_remote_actors()

    if stale_actor_count > 0 do
      Logger.info("Remote post cleanup hid #{stale_actor_count} stale remote actors")
    end

    count
  end

  defp prune_object(%Object{} = object, count) do
    case Object.prune(object) do
      {:ok, _object} ->
        count + 1

      error ->
        Logger.warning(
          "Could not prune stale remote object #{inspect(object.data["id"])}: #{inspect(error)}"
        )

        count
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning(
        "Could not prune stale remote object #{inspect(object.data["id"])}: #{inspect(error)}"
      )

      count
  catch
    :exit, reason ->
      Logger.warning(
        "Could not prune stale remote object #{inspect(object.data["id"])}: #{inspect({:exit, reason})}"
      )

      count
  end

  defp candidate_objects(cutoff, batch_size, keep_threads?, keep_direct?) do
    collect_candidate_objects(
      cutoff,
      batch_size,
      keep_threads?,
      keep_direct?,
      nil,
      [],
      0,
      max_scan_pages()
    )
  end

  defp collect_candidate_objects(_, _, _, _, _, objects, scanned_count, 0) do
    {:ok, Enum.reverse(objects), scanned_count}
  end

  defp collect_candidate_objects(_, batch_size, _, _, _, objects, scanned_count, _)
       when length(objects) >= batch_size do
    {:ok, Enum.reverse(objects), scanned_count}
  end

  defp collect_candidate_objects(
         cutoff,
         batch_size,
         keep_threads?,
         keep_direct?,
         after_id,
         objects,
         scanned_count,
         pages_left
       ) do
    case candidate_object_ids(cutoff, after_id) do
      {:ok, []} ->
        {:ok, Enum.reverse(objects), scanned_count}

      {:ok, object_ids} ->
        remaining_count = batch_size - length(objects)

        page_result =
          object_ids
          |> candidates_query(cutoff, remaining_count, keep_threads?, keep_direct?)
          |> safe_repo_all()

        case page_result do
          {:ok, page_object_ids} ->
            mark_retained_candidates(object_ids, page_object_ids)

            collect_candidate_objects(
              cutoff,
              batch_size,
              keep_threads?,
              keep_direct?,
              List.last(object_ids),
              Enum.reverse(page_object_ids) ++ objects,
              scanned_count + length(object_ids),
              pages_left - 1
            )

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp candidate_object_ids(cutoff, after_id) do
    query =
      Object
      |> maybe_after_object_id(after_id)

    query
    |> where([object], object.inserted_at < ^cutoff)
    |> where([object], object.updated_at < ^cutoff)
    |> where(
      [object],
      fragment("?->>'type' = ANY (?::text[])", object.data, ^@prunable_object_types)
    )
    |> order_by([object], asc: object.id)
    |> limit(^candidate_scan_limit())
    |> select([object], object.id)
    |> safe_repo_all()
  end

  defp maybe_after_object_id(query, nil), do: query

  defp maybe_after_object_id(query, after_id) do
    where(query, [object], object.id > ^after_id)
  end

  defp candidates_query(object_ids, cutoff, batch_size, keep_threads?, keep_direct?) do
    Object
    |> where([object], object.id in ^object_ids)
    |> join(:inner, [object], activity in Activity,
      on:
        fragment(
          "associated_object_id(?) = ?->>'id'",
          activity.data,
          object.data
        )
    )
    |> where([_object, activity], activity.local == false)
    |> where([_object, activity], activity.inserted_at < ^cutoff)
    |> where([_object, activity], fragment("?->>'type' = 'Create'", activity.data))
    |> where(^public_remote_post?())
    |> where(^not_authored_by_local_user?())
    |> where(^no_local_user_activity?(keep_threads?))
    |> where(^no_local_bookmark?(keep_threads?))
    |> maybe_keep_direct_or_mentioned(keep_direct?)
    |> distinct([object, _activity], object.id)
    |> order_by([object, _activity], asc: object.id)
    |> limit(^batch_size)
    |> select([object, _activity], object.id)
  end

  defp objects_by_ids([]), do: []

  defp objects_by_ids(object_ids) do
    Object
    |> where([object], object.id in ^object_ids)
    |> Repo.all(timeout: query_timeout_ms())
  end

  defp mark_retained_candidates(scanned_ids, prunable_ids) do
    retained_ids = scanned_ids -- prunable_ids

    if retained_ids != [] do
      # Old protected rows can otherwise pin every future cleanup run to the
      # same small ID range. Touching only the retained rows lets the janitor
      # continue walking the remote cache while still revisiting retained rows
      # after the configured age window.
      Object
      |> where([object], object.id in ^retained_ids)
      |> Repo.update_all(set: [updated_at: NaiveDateTime.utc_now()])
    end
  end

  defp maybe_keep_direct_or_mentioned(query, true) do
    query
    |> where(^not_addressed_to_local_user?())
    |> where(^no_local_notification?())
  end

  defp maybe_keep_direct_or_mentioned(query, _), do: query

  defp public_remote_post? do
    public = Pleroma.Constants.as_public()

    dynamic(
      [object, activity],
      fragment(
        """
        (?->'to') \\? ?
        OR (?->'cc') \\? ?
        OR (?->'to') \\? ?
        OR (?->'cc') \\? ?
        """,
        object.data,
        ^public,
        object.data,
        ^public,
        activity.data,
        ^public,
        activity.data,
        ^public
      )
    )
  end

  defp not_authored_by_local_user? do
    dynamic(
      [object, _activity],
      fragment(
        """
        NOT EXISTS (
          SELECT 1
          FROM users AS object_actor
          WHERE object_actor.local = true
            AND object_actor.ap_id = ?->>'actor'
        )
        """,
        object.data
      )
    )
  end

  defp no_local_user_activity?(true) do
    dynamic(
      [object, _activity],
      fragment(
        """
        NOT EXISTS (
          SELECT 1
          FROM activities AS local_activity
          JOIN users AS local_user ON local_user.ap_id = local_activity.actor
          LEFT JOIN objects AS local_object
            ON local_object.data->>'id' = associated_object_id(local_activity.data)
          WHERE local_activity.local = true
            AND local_user.local = true
            AND COALESCE(local_user.actor_type, 'Person') <> 'Group'
            AND (
              local_activity.data->>'object' = ?->>'id'
              OR associated_object_id(local_activity.data) = ?->>'id'
              OR local_object.data->>'inReplyTo' = ?->>'id'
              OR (
                ?->>'context' IS NOT NULL
                AND local_activity.data->>'context' = ?->>'context'
              )
            )
        )
        """,
        object.data,
        object.data,
        object.data,
        object.data,
        object.data
      )
    )
  end

  defp no_local_user_activity?(_) do
    dynamic(
      [object, _activity],
      fragment(
        """
        NOT EXISTS (
          SELECT 1
          FROM activities AS local_activity
          JOIN users AS local_user ON local_user.ap_id = local_activity.actor
          LEFT JOIN objects AS local_object
            ON local_object.data->>'id' = associated_object_id(local_activity.data)
          WHERE local_activity.local = true
            AND local_user.local = true
            AND COALESCE(local_user.actor_type, 'Person') <> 'Group'
            AND (
              local_activity.data->>'object' = ?->>'id'
              OR associated_object_id(local_activity.data) = ?->>'id'
              OR local_object.data->>'inReplyTo' = ?->>'id'
            )
        )
        """,
        object.data,
        object.data,
        object.data
      )
    )
  end

  defp no_local_bookmark?(true) do
    dynamic(
      [object, activity],
      fragment(
        """
        NOT EXISTS (
          SELECT 1
          FROM bookmarks AS bookmark
          JOIN users AS bookmark_user ON bookmark_user.id = bookmark.user_id
          JOIN activities AS bookmarked_activity ON bookmarked_activity.id = bookmark.activity_id
          WHERE bookmark_user.local = true
            AND (
              bookmark.activity_id = ?
              OR (
                ?->>'context' IS NOT NULL
                AND bookmarked_activity.data->>'context' = ?->>'context'
              )
            )
        )
        """,
        activity.id,
        object.data,
        object.data
      )
    )
  end

  defp no_local_bookmark?(_) do
    dynamic(
      [_object, activity],
      fragment(
        """
        NOT EXISTS (
          SELECT 1
          FROM bookmarks AS bookmark
          JOIN users AS bookmark_user ON bookmark_user.id = bookmark.user_id
          WHERE bookmark.activity_id = ?
            AND bookmark_user.local = true
        )
        """,
        activity.id
      )
    )
  end

  defp not_addressed_to_local_user? do
    dynamic(
      [object, activity],
      fragment(
        """
        NOT EXISTS (
          SELECT 1
          FROM users AS local_user
          WHERE local_user.local = true
            AND COALESCE(local_user.actor_type, 'Person') <> 'Group'
            AND (
              (?->'to') \\? local_user.ap_id
              OR (?->'cc') \\? local_user.ap_id
              OR (?->'bto') \\? local_user.ap_id
              OR (?->'bcc') \\? local_user.ap_id
              OR (?->'to') \\? local_user.ap_id
              OR (?->'cc') \\? local_user.ap_id
              OR (?->'bto') \\? local_user.ap_id
              OR (?->'bcc') \\? local_user.ap_id
            )
        )
        """,
        object.data,
        object.data,
        object.data,
        object.data,
        activity.data,
        activity.data,
        activity.data,
        activity.data
      )
    )
  end

  defp no_local_notification? do
    dynamic(
      [_object, activity],
      fragment(
        """
        NOT EXISTS (
          SELECT 1
          FROM notifications AS notification
          JOIN users AS notification_user ON notification_user.id = notification.user_id
          WHERE notification.activity_id = ?
            AND notification_user.local = true
        )
        """,
        activity.id
      )
    )
  end

  defp prune_unused_hashtags do
    case safe_repo_query(
           """
           DELETE FROM hashtags AS hashtag
           WHERE NOT EXISTS (
             SELECT 1
             FROM hashtags_objects AS hashtag_object
             WHERE hashtag.id = hashtag_object.hashtag_id
           )
           """,
           []
         ) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning("Could not prune unused hashtags: #{inspect(reason)}")
    end
  end

  defp prune_stale_remote_actors do
    if remote_actor_cleanup_enabled?() do
      remote_actor_cleanup_cutoff()
      |> stale_remote_actor_ids()
      |> case do
        {:ok, user_ids} ->
          hide_stale_remote_actors(user_ids)

        {:error, reason} ->
          Logger.warning("Remote actor cleanup skipped after query failure: #{inspect(reason)}")
          0
      end
    else
      0
    end
  end

  defp stale_remote_actor_ids(cutoff) do
    sql = """
    SELECT remote_user.id
    FROM users AS remote_user
    WHERE remote_user.local = false
      AND remote_user.is_active = true
      AND COALESCE(remote_user.invisible, false) = false
      AND remote_user.updated_at < $1
      AND (
        remote_user.last_refreshed_at IS NULL
        OR remote_user.last_refreshed_at < $1
      )
      AND (
        remote_user.last_status_at IS NULL
        OR remote_user.last_status_at < $1
      )
      AND NOT EXISTS (
        SELECT 1
        FROM following_relationships AS relationship
        JOIN users AS local_user
          ON local_user.local = true
         AND (
           local_user.id = relationship.follower_id
           OR local_user.id = relationship.following_id
         )
        WHERE relationship.state = $2
          AND (
            relationship.follower_id = remote_user.id
            OR relationship.following_id = remote_user.id
          )
      )
      AND NOT EXISTS (
        SELECT 1
        FROM activities AS local_activity
        JOIN users AS local_actor ON local_actor.ap_id = local_activity.actor
        WHERE local_activity.local = true
          AND local_actor.local = true
          AND (
            local_activity.data->>'object' = remote_user.ap_id
            OR local_activity.data->'to' ? remote_user.ap_id
            OR local_activity.data->'cc' ? remote_user.ap_id
          )
      )
      AND NOT EXISTS (
        SELECT 1
        FROM notifications AS notification
        JOIN users AS notification_user ON notification_user.id = notification.user_id
        JOIN activities AS notification_activity ON notification_activity.id = notification.activity_id
        WHERE notification_user.local = true
          AND notification_activity.actor = remote_user.ap_id
      )
      AND NOT EXISTS (
        SELECT 1
        FROM bookmarks AS bookmark
        JOIN users AS bookmark_user ON bookmark_user.id = bookmark.user_id
        JOIN activities AS bookmarked_activity ON bookmarked_activity.id = bookmark.activity_id
        WHERE bookmark_user.local = true
          AND bookmarked_activity.actor = remote_user.ap_id
      )
    ORDER BY remote_user.updated_at ASC
    LIMIT $3
    """

    case safe_repo_query(sql, [
           cutoff,
           FollowingRelationship.accept_state_code(),
           remote_actor_batch_size()
         ]) do
      {:ok, %{rows: rows}} ->
        {:ok, Enum.map(rows, fn [id] -> id end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp hide_stale_remote_actors([]), do: 0

  defp hide_stale_remote_actors(user_ids) do
    User
    |> where([user], user.id in ^user_ids)
    |> Repo.all(timeout: query_timeout_ms())
    |> Enum.reduce(0, fn user, count ->
      case hide_stale_remote_actor(user) do
        {:ok, _user} -> count + 1
        _ -> count
      end
    end)
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning("Remote actor cleanup could not load stale actors: #{inspect(error)}")
      0
  catch
    :exit, reason ->
      Logger.warning(
        "Remote actor cleanup could not load stale actors: #{inspect({:exit, reason})}"
      )

      0
  end

  defp hide_stale_remote_actor(%User{} = user) do
    user
    |> Ecto.Changeset.change(%{
      invisible: true,
      is_discoverable: false,
      avatar: %{},
      banner: %{},
      tags: [],
      emoji: %{}
    })
    |> User.update_and_set_cache()
  end

  defp safe_repo_all(query) do
    {:ok, Repo.all(query, timeout: query_timeout_ms())}
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp safe_repo_query(sql, params) do
    Repo.query(sql, params, timeout: query_timeout_ms())
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp enabled? do
    config_boolean(:enabled, true)
  end

  defp keep_threads_with_local_activity? do
    config_boolean(:keep_threads_with_local_activity, true)
  end

  defp keep_direct_or_mentioned? do
    config_boolean(:keep_direct_or_mentioned, true)
  end

  defp remote_actor_cleanup_enabled? do
    config_boolean(:remote_actor_cleanup_enabled, true)
  end

  defp cutoff do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.add(-max_age_days() * @seconds_per_day, :second)
  end

  defp max_age_days do
    config_integer(:max_age_days, @default_max_age_days)
    |> max(1)
  end

  defp batch_size do
    config_integer(:batch_size, @default_batch_size)
    |> max(1)
  end

  defp candidate_scan_limit do
    config_integer(:candidate_scan_limit, @default_candidate_scan_limit)
    |> max(batch_size())
  end

  defp max_scan_pages do
    config_integer(:max_scan_pages, @default_max_scan_pages)
    |> max(1)
  end

  defp query_timeout_ms do
    config_integer(:query_timeout_ms, @default_query_timeout_ms)
    |> max(1_000)
  end

  defp remote_actor_cleanup_cutoff do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.add(-remote_actor_max_age_days() * @seconds_per_day, :second)
  end

  defp remote_actor_max_age_days do
    config_integer(:remote_actor_max_age_days, @default_remote_actor_max_age_days)
    |> max(1)
  end

  defp remote_actor_batch_size do
    config_integer(:remote_actor_batch_size, @default_remote_actor_batch_size)
    |> max(1)
  end

  defp config_integer(key, default) do
    case Config.get([__MODULE__, key], default) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_integer(value, default)
      _ -> default
    end
  end

  defp parse_integer(value, default) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> default
    end
  end

  defp config_boolean(key, default) do
    case Config.get([__MODULE__, key], default) do
      value when is_boolean(value) -> value
      value when is_binary(value) -> String.downcase(value) in ~w(true 1 yes on)
      _ -> default
    end
  end
end
