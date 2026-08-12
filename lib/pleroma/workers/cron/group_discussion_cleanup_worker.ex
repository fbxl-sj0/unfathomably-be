# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.Cron.GroupDiscussionCleanupWorker do
  @moduledoc """
  Purges old remote group discussion objects that nobody local has touched.

  Remote groups can pull in very large discussion trees. Keeping every untouched
  remote group post forever makes group support expensive for instances that
  follow busy communities, so this worker removes stale remote Create objects
  addressed to known group actors.

  A discussion is kept if a local non-group user has interacted with it. That
  includes local replies in the same context, local likes/reactions/repeats, and
  local bookmarks. Local Group actors are intentionally ignored here because
  group mirroring can create automatic local activities that should not pin the
  remote discussion forever. Untouched discussions from a group that a local
  user follows receive a longer, but still finite, retention horizon.
  """

  use Oban.Worker, queue: "background", max_attempts: 3

  import Ecto.Query

  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.FollowingRelationship
  alias Pleroma.Object
  alias Pleroma.Repo

  @default_max_age_days 183
  @default_followed_group_max_age_days 730
  @default_batch_size 50
  @default_candidate_scan_limit 250
  @default_candidate_query_chunk_size 10
  @default_max_scan_pages 10
  @default_query_timeout_ms 120_000
  @max_batch_size 500
  @max_candidate_scan_limit 500
  @max_candidate_query_chunk_size 100
  @seconds_per_day 86_400
  @group_service_actor_regex "fedigroups|gancio|gup\\.pe|buzzrelay|tootgroup"

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if enabled?() do
      {:ok, purge_candidates()}
    else
      {:ok, 0}
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  defp purge_candidates do
    cutoff = cutoff()
    batch_size = batch_size()

    case candidate_objects(cutoff, batch_size) do
      {:ok, objects, scanned_count} ->
        count = Enum.reduce(objects, 0, &safely_delete_object/2)

        Logger.info(
          "Group discussion cleanup deleted #{count} objects after scanning #{scanned_count} stale remote candidates"
        )

        count

      {:error, reason} ->
        Logger.warning("Group discussion cleanup skipped after query failure: #{inspect(reason)}")
        0
    end
  end

  defp safely_delete_object(object, count) do
    delete_object(object, count)
  rescue
    error ->
      Logger.warning(
        "Group discussion cleanup skipped object #{object.id}: #{Exception.message(error)}"
      )

      count
  catch
    kind, reason ->
      Logger.warning(
        "Group discussion cleanup skipped object #{object.id}: #{inspect({kind, reason})}"
      )

      count
  end

  defp candidate_objects(cutoff, batch_size) do
    collect_candidate_objects(cutoff, batch_size, nil, [], 0, max_scan_pages())
  end

  defp collect_candidate_objects(_, _, _, objects, scanned_count, 0) do
    {:ok, Enum.reverse(objects), scanned_count}
  end

  defp collect_candidate_objects(_, batch_size, _, objects, scanned_count, _)
       when length(objects) >= batch_size do
    {:ok, Enum.reverse(objects), scanned_count}
  end

  defp collect_candidate_objects(
         cutoff,
         batch_size,
         after_cursor,
         objects,
         scanned_count,
         pages_left
       ) do
    case candidate_object_rows(cutoff, after_cursor) do
      {:ok, []} ->
        {:ok, Enum.reverse(objects), scanned_count}

      {:ok, object_rows} ->
        object_ids = Enum.map(object_rows, &elem(&1, 0))
        remaining_count = batch_size - length(objects)

        case candidate_page_objects(object_ids, cutoff, remaining_count) do
          {:ok, page_objects} ->
            mark_retained_candidates(object_ids, Enum.map(page_objects, & &1.id))

            collect_candidate_objects(
              cutoff,
              batch_size,
              List.last(object_rows),
              Enum.reverse(page_objects) ++ objects,
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

  # Each candidate needs several safety checks before it may be removed. Keep
  # those checks in small slices so a single janitor query cannot monopolize a
  # database connection on a large federation cache.
  defp candidate_page_objects(object_ids, cutoff, remaining_count) do
    object_ids
    |> Enum.chunk_every(candidate_query_chunk_size())
    |> Enum.reduce_while({:ok, []}, fn object_id_chunk, {:ok, selected_objects} ->
      remaining_count = remaining_count - length(selected_objects)

      if remaining_count <= 0 do
        {:halt, {:ok, selected_objects}}
      else
        result =
          object_id_chunk
          |> candidates_query(cutoff, remaining_count)
          |> safe_repo_all()

        case result do
          {:ok, objects} -> {:cont, {:ok, selected_objects ++ objects}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    end)
  end

  defp delete_object(%Object{} = object, count) do
    case Object.delete(object) do
      {:ok, _object, _activity} -> count + 1
      _ -> count
    end
  end

  defp candidate_object_rows(cutoff, after_cursor) do
    Object
    |> maybe_after_object_cursor(after_cursor)
    |> where([object], object.inserted_at < ^cutoff)
    |> where([object], object.updated_at < ^cutoff)
    |> where(
      [object],
      fragment(
        "?->>'type' in ('Note', 'Article', 'Page', 'Question', 'Event', 'Audio', 'Video')",
        object.data
      )
    )
    |> order_by([object], asc: object.updated_at, asc: object.id)
    |> limit(^candidate_scan_limit())
    |> select([object], {object.id, object.updated_at})
    |> safe_repo_all()
  end

  defp maybe_after_object_cursor(query, nil), do: query

  defp maybe_after_object_cursor(query, {after_id, after_updated_at}) do
    where(
      query,
      [object],
      object.updated_at > ^after_updated_at or
        (object.updated_at == ^after_updated_at and object.id > ^after_id)
    )
  end

  defp mark_retained_candidates(scanned_ids, prunable_ids) do
    retained_ids = scanned_ids -- prunable_ids

    if retained_ids != [] do
      Object
      |> where([object], object.id in ^retained_ids)
      |> Repo.update_all(set: [updated_at: NaiveDateTime.utc_now()])
    end
  end

  defp candidates_query(object_ids, cutoff, batch_size) do
    from(activity in Activity,
      join: object in Object,
      on:
        fragment(
          "(?->>'id') = associated_object_id(?)",
          object.data,
          activity.data
        ),
      where: object.id in ^object_ids,
      where: activity.local == false,
      where: activity.inserted_at < ^cutoff,
      where: fragment("?->>'type' = 'Create'", activity.data),
      where:
        fragment(
          "?->>'type' in ('Note', 'Article', 'Page', 'Question', 'Event', 'Audio', 'Video')",
          object.data
        ),
      where: ^addressed_to_remote_group?(),
      where: ^followed_group_retention_elapsed?(followed_group_cutoff()),
      where: ^no_local_user_activity?(),
      where: ^no_local_bookmark?(),
      distinct: object.id,
      limit: ^batch_size,
      select: object
    )
  end

  defp addressed_to_remote_group? do
    group_service_actor_regex = @group_service_actor_regex

    dynamic(
      [activity, object],
      fragment(
        """
        EXISTS (
          SELECT 1
          FROM users AS group_actor
          WHERE group_actor.local = false
            AND group_actor.is_active = true
            AND group_actor.invisible = false
            AND (
              group_actor.actor_type = 'Group'
              OR (
                group_actor.actor_type IN ('Application', 'Service')
                AND group_actor.ap_id ~* ?
              )
            )
            AND (
              (?->'to') \\? group_actor.ap_id
              OR (?->'cc') \\? group_actor.ap_id
              OR (?->'bto') \\? group_actor.ap_id
              OR (?->'bcc') \\? group_actor.ap_id
              OR (?->'to') \\? group_actor.ap_id
              OR (?->'cc') \\? group_actor.ap_id
              OR (?->'bto') \\? group_actor.ap_id
              OR (?->'bcc') \\? group_actor.ap_id
              OR ?->>'target' = group_actor.ap_id
              OR ?->>'context' = group_actor.ap_id
            )
        )
        """,
        ^group_service_actor_regex,
        object.data,
        object.data,
        object.data,
        object.data,
        activity.data,
        activity.data,
        activity.data,
        activity.data,
        object.data,
        object.data
      )
    )
  end

  defp no_local_user_activity? do
    dynamic(
      [_activity, object],
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

  defp no_local_bookmark? do
    dynamic(
      [activity, _object],
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

  # A local follow is an explicit request to retain a community's useful
  # history. It extends, rather than disables, pruning so a followed high-volume
  # forum still has a finite storage horizon.
  defp followed_group_retention_elapsed?(followed_cutoff) do
    group_service_actor_regex = @group_service_actor_regex
    follow_accept = FollowingRelationship.accept_state_code()

    dynamic(
      [activity, object],
      object.inserted_at < ^followed_cutoff or
        fragment(
          """
          NOT EXISTS (
            SELECT 1
            FROM users AS group_actor
            JOIN following_relationships AS group_follow
              ON group_follow.following_id = group_actor.id
            JOIN users AS local_follower
              ON local_follower.id = group_follow.follower_id
            WHERE group_follow.state = ?
              AND local_follower.local = true
              AND local_follower.is_active = true
              AND group_actor.local = false
              AND group_actor.is_active = true
              AND group_actor.invisible = false
              AND (
                group_actor.actor_type = 'Group'
                OR (
                  group_actor.actor_type IN ('Application', 'Service')
                  AND group_actor.ap_id ~* ?
                )
              )
              AND (
                (?->'to') \\? group_actor.ap_id
                OR (?->'cc') \\? group_actor.ap_id
                OR (?->'bto') \\? group_actor.ap_id
                OR (?->'bcc') \\? group_actor.ap_id
                OR (?->'to') \\? group_actor.ap_id
                OR (?->'cc') \\? group_actor.ap_id
                OR (?->'bto') \\? group_actor.ap_id
                OR (?->'bcc') \\? group_actor.ap_id
                OR ?->>'target' = group_actor.ap_id
                OR ?->>'context' = group_actor.ap_id
              )
          )
          """,
          ^follow_accept,
          ^group_service_actor_regex,
          object.data,
          object.data,
          object.data,
          object.data,
          activity.data,
          activity.data,
          activity.data,
          activity.data,
          object.data,
          object.data
        )
    )
  end

  defp enabled? do
    Config.get([__MODULE__, :enabled], true)
  end

  defp cutoff do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.add(-max_age_days() * @seconds_per_day, :second)
  end

  defp max_age_days do
    __MODULE__
    |> config_integer(:max_age_days, @default_max_age_days)
    |> max(1)
  end

  defp followed_group_cutoff do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.add(-followed_group_max_age_days() * @seconds_per_day, :second)
  end

  defp followed_group_max_age_days do
    __MODULE__
    |> config_integer(:followed_group_max_age_days, @default_followed_group_max_age_days)
    |> max(max_age_days())
  end

  defp batch_size do
    __MODULE__
    |> config_integer(:batch_size, @default_batch_size)
    |> max(1)
    |> min(@max_batch_size)
  end

  defp candidate_scan_limit do
    __MODULE__
    |> config_integer(:candidate_scan_limit, @default_candidate_scan_limit)
    |> max(batch_size())
    |> min(@max_candidate_scan_limit)
  end

  defp candidate_query_chunk_size do
    __MODULE__
    |> config_integer(:candidate_query_chunk_size, @default_candidate_query_chunk_size)
    |> max(1)
    |> min(@max_candidate_query_chunk_size)
    |> min(candidate_scan_limit())
  end

  defp max_scan_pages do
    __MODULE__
    |> config_integer(:max_scan_pages, @default_max_scan_pages)
    |> max(1)
  end

  defp query_timeout_ms do
    __MODULE__
    |> config_integer(:query_timeout_ms, @default_query_timeout_ms)
    |> max(1_000)
  end

  defp safe_repo_all(query) do
    {:ok, Repo.all(query, timeout: query_timeout_ms())}
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, error}
  catch
    :exit, reason ->
      {:error, {:exit, reason}}
  end

  defp config_integer(module, key, default) do
    case Config.get([module, key], default) do
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
end
