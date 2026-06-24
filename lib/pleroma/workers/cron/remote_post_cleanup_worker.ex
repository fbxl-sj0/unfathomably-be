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
  alias Pleroma.Object
  alias Pleroma.Repo

  require Logger
  require Pleroma.Constants

  @default_max_age_days 365
  @default_batch_size 200
  @default_candidate_scan_limit 20_000
  @default_query_timeout_ms 60_000
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
  def timeout(_job), do: :timer.minutes(5)

  defp prune_candidates do
    cutoff = cutoff()
    batch_size = batch_size()
    keep_threads? = keep_threads_with_local_activity?()
    keep_direct? = keep_direct_or_mentioned?()

    case candidate_objects(cutoff, batch_size, keep_threads?, keep_direct?) do
      {:ok, objects} ->
        count = Enum.reduce(objects, 0, &prune_object/2)

        if count > 0 do
          prune_unused_hashtags()
        end

        count

      {:error, reason} ->
        Logger.warning("Remote post cleanup skipped after query failure: #{inspect(reason)}")
        0
    end
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
  end

  defp candidate_objects(cutoff, batch_size, keep_threads?, keep_direct?) do
    case candidate_object_ids(cutoff) do
      {:ok, []} ->
        {:ok, []}

      {:ok, object_ids} ->
        object_ids
        |> candidates_query(cutoff, batch_size, keep_threads?, keep_direct?)
        |> safe_repo_all()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp candidate_object_ids(cutoff) do
    Object
    |> where([object], object.inserted_at < ^cutoff)
    |> where([object], fragment("?->>'type' = ANY (?)", object.data, ^@prunable_object_types))
    |> order_by([object], asc: object.id)
    |> limit(^candidate_scan_limit())
    |> select([object], object.id)
    |> safe_repo_all()
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
    |> select([object, _activity], object)
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

  defp query_timeout_ms do
    config_integer(:query_timeout_ms, @default_query_timeout_ms)
    |> max(1_000)
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
