# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.Cron.RemotePostCleanupWorker do
  @moduledoc """
  Prunes stale remote public posts that nobody local has kept alive.

  The instance keeps remote posts as a cache. For busy federated timelines this
  can grow without bound, while most old remote posts are never viewed again.
  This worker removes cached object rows and safely detachable remote activity
  envelopes. A persistent database cursor lets orphan cleanup make bounded
  progress across restarts without repeatedly scanning the beginning of the
  activities table.

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
  alias Pleroma.Workers.Cron.DatabaseCleanupLock
  alias Pleroma.User

  require Logger
  require Pleroma.Constants

  @default_max_age_days 365
  @default_batch_size 500
  @default_candidate_scan_limit 5_000
  @default_candidate_query_chunk_size 10
  @default_max_scan_pages 10
  @default_query_timeout_ms 30_000
  @default_orphan_activity_batch_size 500
  @default_orphan_activity_scan_limit 1_000
  @default_orphan_activity_full_sweep_days 30
  @default_orphan_activity_continuation_delay_seconds 5
  @orphan_activity_continuation_work_multiplier 4
  @max_orphan_activity_continuation_delay_seconds 300
  @default_remote_cache_continuation_delay_seconds 30
  @default_tombstone_max_age_days 730
  @default_tombstone_batch_size 500
  @default_remote_actor_max_age_days 730
  @default_remote_actor_batch_size 50
  @max_batch_size 2_000
  @max_candidate_scan_limit 20_000
  @max_candidate_query_chunk_size 100
  @max_orphan_activity_batch_size 10_000
  @max_orphan_activity_scan_limit 20_000
  @max_tombstone_batch_size 2_000
  @seconds_per_day 86_400
  @orphan_activity_state_name "remote_orphan_activities"
  @orphan_activity_lock_name "unfathomably_remote_orphan_activities"
  @prunable_object_types ~w(Note Article Page Question Event Audio Video)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"orphan_activity_continuation" => true}}) do
    if enabled?() and orphan_activity_cleanup_enabled?() do
      cond do
        group_discussion_cleanup_active?() ->
          Logger.debug("Remote activity cleanup is yielding to group discussion cleanup")
          maybe_schedule_orphan_activity_continuation(true, 60)
          {:ok, 0}

        retention_vacuum_active?() ->
          Logger.debug("Remote activity cleanup is yielding to PostgreSQL vacuum")
          maybe_schedule_orphan_activity_continuation(true, 60)
          {:ok, 0}

        true ->
          case DatabaseCleanupLock.run(&run_orphan_activity_cleanup/0) do
            {:acquired, result} ->
              result

            :busy ->
              Logger.debug("Remote activity cleanup is yielding to database cleanup")
              maybe_schedule_orphan_activity_continuation(true, 60)
              {:ok, 0}
          end
      end
    else
      {:ok, 0}
    end
  end

  def perform(%Oban.Job{args: %{"remote_cache_continuation" => true}}) do
    cond do
      not enabled?() or not remote_cache_continuation_enabled?() ->
        {:ok, 0}

      group_discussion_cleanup_active?() ->
        Logger.debug("Remote cache cleanup is yielding to group discussion cleanup")
        maybe_schedule_remote_cache_continuation(true, 60)
        {:ok, 0}

      orphan_activity_sweep_active?() ->
        {:ok, 0}

      retention_vacuum_active?() ->
        Logger.debug("Remote cache cleanup is yielding to PostgreSQL vacuum")
        maybe_schedule_remote_cache_continuation(true, 60)
        {:ok, 0}

      true ->
        case DatabaseCleanupLock.run(fn -> {:ok, prune_candidates()} end) do
          {:acquired, result} ->
            result

          :busy ->
            Logger.debug("Remote cache cleanup is yielding to database cleanup")
            maybe_schedule_remote_cache_continuation(true, 60)
            {:ok, 0}
        end
    end
  end

  def perform(%Oban.Job{}) do
    if enabled?() do
      cond do
        group_discussion_cleanup_active?() ->
          Logger.debug("Remote cleanup is yielding to group discussion cleanup")

          if orphan_activity_cleanup_enabled?() do
            maybe_schedule_orphan_activity_continuation(true, 60)
          end

          {:ok, 0}

        retention_vacuum_active?() ->
          Logger.debug("Remote cache cleanup is yielding to PostgreSQL vacuum")

          if orphan_activity_cleanup_enabled?() do
            maybe_schedule_orphan_activity_continuation(true, 60)
          end

          {:ok, 0}

        true ->
          case DatabaseCleanupLock.run(fn ->
                 if orphan_activity_cleanup_enabled?() do
                   run_orphan_activity_cleanup()
                 end

                 pruned_object_count =
                   if orphan_activity_sweep_active?() do
                     0
                   else
                     prune_candidates()
                   end

                 {:ok, pruned_object_count}
               end) do
            {:acquired, result} ->
              result

            :busy ->
              Logger.debug("Remote cleanup is yielding to database cleanup")

              if orphan_activity_cleanup_enabled?() do
                maybe_schedule_orphan_activity_continuation(true, 60)
              end

              maybe_schedule_remote_cache_continuation(true, 60)
              {:ok, 0}
          end
      end
    else
      {:ok, 0}
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  # Autovacuum makes deleted pages reusable and must be allowed to complete.
  # Running another cold historical page at the same time can turn background
  # maintenance into user-visible pool timeouts on very large installations.
  defp retention_vacuum_active? do
    case Repo.query(
           """
           SELECT EXISTS (
             SELECT 1
             FROM pg_locks
             WHERE relation IN ('activities'::regclass, 'objects'::regclass)
               AND mode = 'ShareUpdateExclusiveLock'
               AND granted
           )
           """,
           [],
           timeout: 5_000
         ) do
      {:ok, %{rows: [[active?]]}} -> active?
      _ -> true
    end
  rescue
    _ -> true
  catch
    :exit, _reason -> true
  end

  defp group_discussion_cleanup_active? do
    Oban.Job
    |> where(
      [job],
      job.worker == "Pleroma.Workers.Cron.GroupDiscussionCleanupWorker" and
        job.state == "executing"
    )
    |> Repo.exists?()
  rescue
    _ -> true
  catch
    :exit, _reason -> true
  end

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
            |> Enum.reduce(0, &safely_prune_object/2)

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

    tombstone_count = prune_stale_remote_tombstones()

    if tombstone_count > 0 do
      Logger.info("Remote post cleanup pruned #{tombstone_count} old remote Tombstones")
    end

    stale_actor_count = prune_stale_remote_actors()

    if stale_actor_count > 0 do
      Logger.info("Remote post cleanup hid #{stale_actor_count} stale remote actors")
    end

    maybe_schedule_remote_cache_continuation(
      count >= batch_size or
        tombstone_count >= tombstone_batch_size() or
        stale_actor_count >= remote_actor_batch_size()
    )

    count
  end

  defp safely_prune_object(object, count) do
    prune_object(object, count)
  rescue
    error ->
      Logger.warning(
        "Remote post cleanup skipped object #{object.id}: #{Exception.message(error)}"
      )

      count
  catch
    kind, reason ->
      Logger.warning(
        "Remote post cleanup skipped object #{object.id}: #{inspect({kind, reason})}"
      )

      count
  end

  defp prune_object(%Object{} = object, count) do
    object_ap_id = object.data["id"]

    case Object.prune(object) do
      {:ok, _object} ->
        prune_remote_activities_for_object(object_ap_id)
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

  # Object.prune/1 intentionally operates only on the cached object row. Once
  # the janitor has proved that a remote object is safe to discard, retaining
  # old remote envelopes for that missing object provides no refetch value and
  # multiplies storage through every activities index. Dependencies are checked
  # again here so a bookmark, notification, report, or local interaction wins a
  # race with cleanup.
  defp prune_remote_activities_for_object(object_ap_id) when is_binary(object_ap_id) do
    sql = """
    WITH candidates AS MATERIALIZED (
      SELECT orphan_activity.id
      FROM activities AS orphan_activity
      WHERE orphan_activity.local = false
        AND jsonb_typeof(orphan_activity.data->'object') = 'string'
        AND associated_object_id(orphan_activity.data) = $1
        AND #{orphan_activity_prunable_sql()}
      ORDER BY orphan_activity.id
      LIMIT $2
    )
    DELETE FROM activities AS orphan_activity
    USING candidates
    WHERE orphan_activity.id = candidates.id
    """

    case safe_repo_query(sql, [object_ap_id, orphan_activity_batch_size()]) do
      {:ok, %{num_rows: count}} when count > 0 ->
        Logger.debug(
          "Remote post cleanup removed #{count} remote activities for pruned object #{inspect(object_ap_id)}"
        )

        count

      {:ok, _result} ->
        0

      {:error, reason} ->
        Logger.warning(
          "Remote post cleanup could not remove activities for #{inspect(object_ap_id)}: #{inspect(reason)}"
        )

        0
    end
  end

  defp prune_remote_activities_for_object(_), do: 0

  defp run_orphan_activity_cleanup do
    started_at = System.monotonic_time()

    case prune_orphaned_activity_page() do
      {:ok, deleted_count, scanned_count, continue?} ->
        if deleted_count > 0 do
          Logger.info(
            "Remote activity cleanup removed #{deleted_count} orphaned activities after checking #{scanned_count} candidates"
          )
        end

        maybe_schedule_orphan_activity_continuation(
          continue?,
          measured_orphan_activity_continuation_delay_seconds(started_at)
        )

        {:ok, deleted_count}

      {:locked} ->
        maybe_schedule_orphan_activity_continuation(true)
        {:ok, 0}

      {:error, reason} ->
        Logger.warning("Remote activity cleanup skipped after query failure: #{inspect(reason)}")
        maybe_schedule_orphan_activity_continuation(true, 60)
        {:ok, 0}
    end
  end

  defp prune_orphaned_activity_page do
    transaction_result =
      Repo.transaction(
        fn ->
          case Repo.query!(
                 "SELECT pg_try_advisory_xact_lock(hashtext($1))",
                 [@orphan_activity_lock_name]
               ).rows do
            [[true]] -> prune_locked_orphaned_activity_page()
            _ -> {:locked}
          end
        end,
        timeout: query_timeout_ms()
      )

    case transaction_result do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp prune_locked_orphaned_activity_page do
    ensure_orphan_activity_state()
    maybe_start_periodic_orphan_activity_sweep()

    [cursor, full_sweep, _cycle_scanned, cycle_deleted] =
      Repo.query!(
        """
        SELECT cursor, full_sweep, cycle_scanned, cycle_deleted
        FROM janitor_states
        WHERE name = $1
        FOR UPDATE
        """,
        [@orphan_activity_state_name]
      ).rows
      |> List.first()

    candidates = orphan_activity_candidates(cursor)

    case candidates do
      [] ->
        finish_orphan_activity_cycle(full_sweep, cycle_deleted)

      candidates ->
        {processed_candidates, orphan_ids} =
          take_orphan_activity_batch(candidates, orphan_activity_batch_size())

        deleted_count = delete_orphan_activity_ids(orphan_ids)
        processed_count = length(processed_candidates)

        [last_processed_id, _activity_ap_id, _object_ap_id, _prunable] =
          List.last(processed_candidates)

        Repo.query!(
          """
          UPDATE janitor_states
          SET cursor = $2,
              cycle_scanned = cycle_scanned + $3,
              cycle_deleted = cycle_deleted + $4,
              updated_at = NOW()
          WHERE name = $1
          """,
          [
            @orphan_activity_state_name,
            last_processed_id,
            processed_count,
            deleted_count
          ]
        )

        {:ok, deleted_count, processed_count, true}
    end
  end

  defp ensure_orphan_activity_state do
    Repo.query!(
      """
      INSERT INTO janitor_states (
        name,
        cursor,
        full_sweep,
        cycle_scanned,
        cycle_deleted,
        cycle_started_at,
        inserted_at,
        updated_at
      )
      VALUES ($1, NULL, true, 0, 0, NOW(), NOW(), NOW())
      ON CONFLICT (name) DO NOTHING
      """,
      [@orphan_activity_state_name]
    )
  end

  defp maybe_start_periodic_orphan_activity_sweep do
    Repo.query!(
      """
      UPDATE janitor_states
      SET cursor = NULL,
          full_sweep = true,
          cycle_scanned = 0,
          cycle_deleted = 0,
          cycle_started_at = NOW(),
          updated_at = NOW()
      WHERE name = $1
        AND full_sweep = false
        AND (
          last_full_sweep_at IS NULL
          OR last_full_sweep_at < NOW() - make_interval(days => $2::integer)
        )
      """,
      [@orphan_activity_state_name, orphan_activity_full_sweep_days()]
    )
  end

  defp orphan_activity_candidates(cursor) do
    sql = """
    SELECT orphan_activity.id::text,
           orphan_activity.data->>'id',
           orphan_activity.data->>'object',
           (#{orphan_activity_prunable_sql()}) AS prunable
    FROM activities AS orphan_activity
    WHERE orphan_activity.local = false
      AND jsonb_typeof(orphan_activity.data->'object') = 'string'
      AND orphan_activity.inserted_at < $1
      AND ($2::text IS NULL OR orphan_activity.id > $2::uuid)
    ORDER BY orphan_activity.id
    LIMIT $3
    """

    Repo.query!(sql, [cutoff(), cursor, orphan_activity_scan_limit()]).rows
  end

  defp orphan_activity_prunable_sql do
    """
    NOT EXISTS (
      SELECT 1
      FROM objects AS target_object
      WHERE target_object.data->>'id' = orphan_activity.data->>'object'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM activities AS target_activity
      WHERE target_activity.data->>'id' = orphan_activity.data->>'object'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM users AS target_actor
      WHERE target_actor.ap_id = orphan_activity.data->>'object'
    )
    AND NOT EXISTS (
      SELECT 1 FROM bookmarks
      WHERE bookmarks.activity_id = orphan_activity.id
    )
    AND NOT EXISTS (
      SELECT 1 FROM notifications
      WHERE notifications.activity_id = orphan_activity.id
    )
    AND NOT EXISTS (
      SELECT 1 FROM report_notes
      WHERE report_notes.activity_id = orphan_activity.id
    )
    AND NOT EXISTS (
      SELECT 1
      FROM janitor_local_references AS local_reference
      WHERE local_reference.reference = orphan_activity.data->>'id'
         OR local_reference.reference = orphan_activity.data->>'object'
    )
    """
  end

  defp take_orphan_activity_batch(candidates, batch_size) do
    candidates
    |> Enum.reduce_while({[], [], 0}, fn [id, _activity_ap_id, _object_ap_id, prunable] =
                                           candidate,
                                         {processed, orphan_ids, orphan_count} ->
      processed = [candidate | processed]

      if prunable do
        orphan_ids = [id | orphan_ids]
        orphan_count = orphan_count + 1

        if orphan_count >= batch_size do
          {:halt, {processed, orphan_ids, orphan_count}}
        else
          {:cont, {processed, orphan_ids, orphan_count}}
        end
      else
        {:cont, {processed, orphan_ids, orphan_count}}
      end
    end)
    |> then(fn {processed, orphan_ids, _count} ->
      {Enum.reverse(processed), Enum.reverse(orphan_ids)}
    end)
  end

  defp delete_orphan_activity_ids([]), do: 0

  defp delete_orphan_activity_ids(orphan_ids) do
    sql = """
    DELETE FROM activities AS orphan_activity
    WHERE orphan_activity.id IN (
      SELECT orphan_id::uuid
      FROM unnest($1::text[]) AS orphan_id
    )
      AND orphan_activity.local = false
      AND jsonb_typeof(orphan_activity.data->'object') = 'string'
      AND #{orphan_activity_prunable_sql()}
    """

    Repo.query!(sql, [orphan_ids]).num_rows
  end

  defp finish_orphan_activity_cycle(_full_sweep, cycle_deleted) when cycle_deleted > 0 do
    Repo.query!(
      """
      UPDATE janitor_states
      SET cursor = NULL,
          full_sweep = true,
          cycle_scanned = 0,
          cycle_deleted = 0,
          cycle_started_at = NOW(),
          completed_at = NOW(),
          updated_at = NOW()
      WHERE name = $1
      """,
      [@orphan_activity_state_name]
    )

    {:ok, 0, 0, true}
  end

  defp finish_orphan_activity_cycle(full_sweep, _cycle_deleted) do
    Repo.query!(
      """
      UPDATE janitor_states
      SET full_sweep = false,
          last_full_sweep_at = CASE WHEN $2 THEN NOW() ELSE last_full_sweep_at END,
          completed_at = NOW(),
          updated_at = NOW()
      WHERE name = $1
      """,
      [@orphan_activity_state_name, full_sweep]
    )

    {:ok, 0, 0, false}
  end

  defp maybe_schedule_orphan_activity_continuation(continue?, delay_seconds \\ nil)

  defp maybe_schedule_orphan_activity_continuation(false, _delay_seconds), do: :ok

  defp maybe_schedule_orphan_activity_continuation(true, delay_seconds) do
    if orphan_activity_continuation_enabled?() do
      delay_seconds = delay_seconds || configured_orphan_activity_continuation_delay_seconds()

      job =
        __MODULE__.new(
          %{"orphan_activity_continuation" => true},
          schedule_in: delay_seconds,
          unique: [
            period: max(60, delay_seconds * 4),
            states: [:available, :scheduled, :retryable]
          ]
        )

      case Oban.insert(job) do
        {:ok, _job} ->
          :ok

        {:error, reason} ->
          Logger.warning("Could not continue remote activity cleanup: #{inspect(reason)}")
      end
    end
  end

  @doc false
  def orphan_activity_continuation_delay_seconds(elapsed_ms, configured_delay_seconds)
      when is_integer(elapsed_ms) and elapsed_ms >= 0 and is_integer(configured_delay_seconds) and
             configured_delay_seconds >= 1 do
    # Backlog cleanup must remain subordinate to live API and federation work.
    # Waiting four times as long as the preceding database page caps sustained
    # janitor activity at roughly one fifth of wall-clock time without requiring
    # installation-specific guesses about table size or storage performance.
    measured_delay_seconds =
      div(elapsed_ms * @orphan_activity_continuation_work_multiplier + 999, 1_000)

    configured_delay_seconds
    |> max(measured_delay_seconds)
    |> min(@max_orphan_activity_continuation_delay_seconds)
  end

  defp measured_orphan_activity_continuation_delay_seconds(started_at) do
    elapsed_ms =
      System.monotonic_time()
      |> Kernel.-(started_at)
      |> System.convert_time_unit(:native, :millisecond)

    orphan_activity_continuation_delay_seconds(
      elapsed_ms,
      configured_orphan_activity_continuation_delay_seconds()
    )
  end

  defp maybe_schedule_remote_cache_continuation(continue?, delay_seconds \\ nil)

  defp maybe_schedule_remote_cache_continuation(false, _delay_seconds), do: :ok

  defp maybe_schedule_remote_cache_continuation(true, delay_seconds) do
    if remote_cache_continuation_enabled?() and not orphan_activity_sweep_active?() do
      delay_seconds = delay_seconds || remote_cache_continuation_delay_seconds()

      job =
        __MODULE__.new(
          %{"remote_cache_continuation" => true},
          schedule_in: delay_seconds,
          unique: [
            period: max(120, delay_seconds * 4),
            states: [:available, :scheduled, :retryable]
          ]
        )

      case Oban.insert(job) do
        {:ok, _job} ->
          :ok

        {:error, reason} ->
          Logger.warning("Could not continue remote cache cleanup: #{inspect(reason)}")
      end
    end
  end

  # The old object, Tombstone, and actor lanes wait until the historical
  # activity sweep is idle. Both the hourly root and continuation jobs use
  # this guard so retries cannot make the two historical scans compete for
  # the same database connections, large tables, and storage bandwidth.
  defp orphan_activity_sweep_active? do
    if orphan_activity_cleanup_enabled?() do
      case Repo.query(
             "SELECT full_sweep FROM janitor_states WHERE name = $1",
             [@orphan_activity_state_name],
             timeout: 5_000
           ) do
        {:ok, %{rows: [[active?]]}} -> active?
        {:ok, %{rows: []}} -> false
        _ -> true
      end
    else
      false
    end
  rescue
    _ -> true
  catch
    :exit, _reason -> true
  end

  defp prune_stale_remote_tombstones do
    if tombstone_cleanup_enabled?() do
      sql = """
      SELECT tombstone.id
      FROM objects AS tombstone
      WHERE tombstone.data->>'type' = 'Tombstone'
        AND tombstone.updated_at < $1
        AND ap_id_host(tombstone.data->>'id') IS NOT NULL
        AND ap_id_host(tombstone.data->>'id') <> $2
        AND NOT EXISTS (
          SELECT 1 FROM deliveries
          WHERE deliveries.object_id = tombstone.id
        )
        AND NOT EXISTS (
          SELECT 1
          FROM activities AS local_activity
          WHERE local_activity.local = true
            AND associated_object_id(local_activity.data) = tombstone.data->>'id'
        )
        AND NOT EXISTS (
          SELECT 1
          FROM objects AS local_object
          JOIN users AS local_actor
            ON local_actor.local = true
           AND local_actor.ap_id = local_object.data->>'actor'
          WHERE local_object.data->>'inReplyTo' = tombstone.data->>'id'
             OR local_object.data->>'quoteUrl' = tombstone.data->>'id'
             OR local_object.data->>'quoteUri' = tombstone.data->>'id'
        )
      ORDER BY tombstone.updated_at, tombstone.id
      LIMIT $3
      """

      case safe_repo_query(sql, [
             tombstone_cleanup_cutoff(),
             Pleroma.Web.Endpoint.host(),
             tombstone_batch_size()
           ]) do
        {:ok, %{rows: rows}} ->
          rows
          |> Enum.map(fn [id] -> id end)
          |> objects_by_ids()
          |> Enum.reduce(0, &safely_prune_object/2)

        {:error, reason} ->
          Logger.warning(
            "Remote Tombstone cleanup skipped after query failure: #{inspect(reason)}"
          )

          0
      end
    else
      0
    end
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

        page_result =
          candidate_page_object_ids(
            object_ids,
            cutoff,
            remaining_count,
            keep_threads?,
            keep_direct?
          )

        case page_result do
          {:ok, page_object_ids} ->
            mark_retained_candidates(object_ids, page_object_ids)

            collect_candidate_objects(
              cutoff,
              batch_size,
              keep_threads?,
              keep_direct?,
              List.last(object_rows),
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

  # The protection query is deliberately rich because it must not prune posts
  # retained by any local interaction. Run bounded slices of a candidate page
  # so a cold scan cannot hold one database connection for the full timeout.
  defp candidate_page_object_ids(
         object_ids,
         cutoff,
         remaining_count,
         keep_threads?,
         keep_direct?
       ) do
    object_ids
    |> Enum.chunk_every(candidate_query_chunk_size())
    |> Enum.reduce_while({:ok, []}, fn object_id_chunk, {:ok, selected_ids} ->
      remaining_count = remaining_count - length(selected_ids)

      if remaining_count <= 0 do
        {:halt, {:ok, selected_ids}}
      else
        result =
          candidate_chunk_object_ids(
            object_id_chunk,
            cutoff,
            remaining_count,
            keep_threads?,
            keep_direct?
          )

        case result do
          {:ok, chunk_ids} -> {:cont, {:ok, selected_ids ++ chunk_ids}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    end)
  end

  defp candidate_chunk_object_ids(
         _object_ids,
         _cutoff,
         remaining_count,
         _keep_threads?,
         _keep_direct?
       )
       when remaining_count <= 0,
       do: {:ok, []}

  defp candidate_chunk_object_ids([], _cutoff, _remaining_count, _keep_threads?, _keep_direct?),
    do: {:ok, []}

  defp candidate_chunk_object_ids(
         object_ids,
         cutoff,
         remaining_count,
         keep_threads?,
         keep_direct?
       ) do
    result =
      object_ids
      |> candidates_query(cutoff, remaining_count, keep_threads?, keep_direct?)
      |> safe_repo_all()

    case result do
      {:error, _reason} when length(object_ids) > 1 ->
        {left_ids, right_ids} = Enum.split(object_ids, div(length(object_ids), 2))

        Logger.debug(
          "Remote post cleanup is splitting a slow candidate query of #{length(object_ids)} objects"
        )

        with {:ok, left_candidates} <-
               candidate_chunk_object_ids(
                 left_ids,
                 cutoff,
                 remaining_count,
                 keep_threads?,
                 keep_direct?
               ),
             right_remaining = remaining_count - length(left_candidates),
             {:ok, right_candidates} <-
               candidate_chunk_object_ids(
                 right_ids,
                 cutoff,
                 right_remaining,
                 keep_threads?,
                 keep_direct?
               ) do
          {:ok, left_candidates ++ right_candidates}
        end

      result ->
        result
    end
  end

  defp candidate_object_rows(cutoff, after_cursor) do
    query =
      Object
      |> maybe_after_object_cursor(after_cursor)

    query
    |> where([object], object.inserted_at < ^cutoff)
    |> where([object], object.updated_at < ^cutoff)
    |> where(
      [object],
      fragment("?->>'type' = ANY (?::text[])", object.data, ^@prunable_object_types)
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

  defp orphan_activity_cleanup_enabled? do
    config_boolean(:orphan_activity_cleanup_enabled, true)
  end

  defp orphan_activity_continuation_enabled? do
    config_boolean(:orphan_activity_continuation_enabled, true)
  end

  defp remote_cache_continuation_enabled? do
    config_boolean(:remote_cache_continuation_enabled, true)
  end

  defp tombstone_cleanup_enabled? do
    config_boolean(:tombstone_cleanup_enabled, true)
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
    |> min(@max_batch_size)
  end

  defp candidate_scan_limit do
    config_integer(:candidate_scan_limit, @default_candidate_scan_limit)
    |> max(batch_size())
    |> min(@max_candidate_scan_limit)
  end

  defp candidate_query_chunk_size do
    config_integer(:candidate_query_chunk_size, @default_candidate_query_chunk_size)
    |> max(1)
    |> min(@max_candidate_query_chunk_size)
    |> min(candidate_scan_limit())
  end

  defp max_scan_pages do
    config_integer(:max_scan_pages, @default_max_scan_pages)
    |> max(1)
  end

  defp query_timeout_ms do
    config_integer(:query_timeout_ms, @default_query_timeout_ms)
    |> max(1_000)
  end

  defp orphan_activity_batch_size do
    config_integer(:orphan_activity_batch_size, @default_orphan_activity_batch_size)
    |> max(1)
    |> min(@max_orphan_activity_batch_size)
  end

  defp orphan_activity_scan_limit do
    config_integer(:orphan_activity_scan_limit, @default_orphan_activity_scan_limit)
    |> max(orphan_activity_batch_size())
    |> min(@max_orphan_activity_scan_limit)
  end

  defp orphan_activity_full_sweep_days do
    config_integer(:orphan_activity_full_sweep_days, @default_orphan_activity_full_sweep_days)
    |> max(1)
  end

  defp configured_orphan_activity_continuation_delay_seconds do
    config_integer(
      :orphan_activity_continuation_delay_seconds,
      @default_orphan_activity_continuation_delay_seconds
    )
    |> max(1)
  end

  defp remote_cache_continuation_delay_seconds do
    config_integer(
      :remote_cache_continuation_delay_seconds,
      @default_remote_cache_continuation_delay_seconds
    )
    |> max(5)
    |> min(3_600)
  end

  defp tombstone_cleanup_cutoff do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.add(-tombstone_max_age_days() * @seconds_per_day, :second)
  end

  defp tombstone_max_age_days do
    config_integer(:tombstone_max_age_days, @default_tombstone_max_age_days)
    |> max(max_age_days())
  end

  defp tombstone_batch_size do
    config_integer(:tombstone_batch_size, @default_tombstone_batch_size)
    |> max(1)
    |> min(@max_tombstone_batch_size)
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
