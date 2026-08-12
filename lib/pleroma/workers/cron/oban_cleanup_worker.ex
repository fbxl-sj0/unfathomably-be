# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.Cron.ObanCleanupWorker do
  @moduledoc """
  Cleans up stale one-shot Oban jobs that are no longer useful to run.

  Some federated data contains event and poll times that are technically valid
  timestamps but operationally useless, such as polls scheduled centuries in the
  future. Older deployments also lacked an `event_reminders` queue, leaving past
  reminder jobs available forever. This worker keeps those queues from becoming
  another manual janitor chore.
  """

  use Oban.Worker,
    queue: "background",
    max_attempts: 1,
    unique: [period: 3_300, states: :incomplete]

  import Ecto.Query

  alias Pleroma.Config
  alias Pleroma.Instances
  alias Pleroma.Repo

  require Logger

  @default_max_poll_schedule_seconds 365 * 24 * 60 * 60
  @default_cleanup_batch_size 5_000
  # Remote software sometimes represents "never expires" as a timestamp a
  # century in the future. Ten years remains far beyond normal local and MRF
  # expiration horizons while keeping those sentinel jobs out of Oban forever.
  @max_activity_expiration_schedule_seconds 10 * 365 * 24 * 60 * 60
  @stale_event_reminder_seconds 24 * 60 * 60
  @stale_cleanup_retry_seconds 24 * 60 * 60
  @stale_federator_retry_seconds 30 * 24 * 60 * 60
  @incoming_workers [
    "Pleroma.Workers.ReceiverWorker",
    "Pleroma.Workers.SignatureRetryWorker"
  ]
  @stale_federator_workers @incoming_workers ++ ["Pleroma.Workers.PublisherWorker"]
  @terminal_publisher_status_pattern "status[^0-9]*(301|308|400|403|404|405|406|410|501)"
  @persistent_publisher_server_error_pattern "status[^0-9]*5[0-9][0-9]"
  @persistent_publisher_server_error_attempts 12
  @terminal_incoming_status_pattern "http[^0-9]*(400|401|403|404|405|406|410|501)"
  @terminal_remote_fetch_status_pattern "http[^0-9]*(400|403|404|405|406|410|501)"
  @receiver_worker "Pleroma.Workers.ReceiverWorker"
  @receiver_transport_retry_limit 3
  @receiver_retry_limited_transport_pattern "(recv_response_timeout|connect_timeout|econnrefused|ehostunreach|handshake_failure|enetunreach|nxdomain|timeout|unreachable_host)"
  @receiver_terminal_certificate_pattern "(bad_certificate|certificate_expired|unknown_ca)"
  @receiver_native_nostr_retry_limit 3
  @receiver_native_nostr_retry_pattern "(native_nostr_not_found|native_nostr_lookup_failed)"
  @remote_fetch_worker "Pleroma.Workers.RemoteFetcherWorker"
  @remote_replies_fetch_worker "Pleroma.Workers.RemoteRepliesFetcherWorker"
  @user_refresh_worker "Pleroma.Workers.UserRefreshWorker"
  @oban_args_index_min_bytes 256 * 1024 * 1024
  @oban_args_index_max_heap_ratio 8
  @fixed_federation_error_patterns [
    "%activities_unique_apid_index%",
    "%objects_unique_apid_index%",
    "%users_ap_id_index%",
    "%side_effects.ex:325%",
    "%fix_activity_context/2%",
    "%pinned_statuses_limit_reached%",
    "%common_fixes.ex:89%",
    "%Object.Containment.get_actor%",
    "%don't know how to handle\", nil%",
    "%emoji_react_validator.ex:66%",
    "%utils.ex:476%",
    "%web/federator.ex:103%"
  ]
  @fixed_remote_fetch_error_patterns [
    "%objects_unique_apid_index%",
    "%Object has been deleted%",
    "%actor_not_found%",
    "%object_not_found%",
    "%errors: [likes:%",
    "%errors: [announcements:%",
    "%Unsupported URI scheme%",
    "%unsupported_uri_scheme%",
    "%id must be a string%",
    "%invalid_id%",
    "%terminal_status%",
    "%unreachable_host%"
  ]
  @cleanup_workers [
    "Pleroma.Workers.Cron.GroupDiscussionCleanupWorker",
    "Pleroma.Workers.Cron.RemotePostCleanupWorker"
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    steps = [
      {:collapsed_duplicate_remote_fetch_jobs, &collapse_duplicate_remote_fetch_jobs/0},
      {:collapsed_triggered_remote_reply_jobs, &collapse_triggered_remote_reply_jobs/0},
      {:collapsed_duplicate_incoming_jobs, &collapse_duplicate_incoming_jobs/0},
      {:discarded_exhausted_receiver_transport_retries,
       &discard_exhausted_receiver_transport_retries/0},
      {:discarded_exhausted_native_nostr_retries, &discard_exhausted_native_nostr_retries/0},
      {:discarded_terminal_user_refresh_retries, &discard_terminal_user_refresh_retries/0},
      {:deleted_far_future_poll_notifications, &delete_far_future_poll_notifications/0},
      {:deleted_far_future_activity_expirations, &delete_far_future_activity_expirations/0},
      {:discarded_stale_event_reminders, &discard_stale_event_reminders/0},
      {:discarded_stale_cleanup_retries, &discard_stale_cleanup_retries/0},
      {:discarded_stale_federator_retries, &discard_stale_federator_retries/0},
      {:discarded_terminal_publisher_retries, &discard_terminal_publisher_retries/0},
      {:discarded_unreachable_publisher_jobs, &discard_unreachable_publisher_jobs/0},
      {:discarded_fixed_federation_exception_retries,
       &discard_fixed_federation_exception_retries/0},
      {:reindexed_bloated_oban_args_index, &reindex_bloated_oban_args_index/0}
    ]

    {counts, failures} =
      Enum.reduce(steps, {%{}, []}, fn {name, operation}, {counts, failures} ->
        case safe_cleanup_step(name, operation) do
          {:ok, count} -> {Map.put(counts, name, count), failures}
          {:error, reason} -> {Map.put(counts, name, 0), [{name, reason} | failures]}
        end
      end)

    failures = Enum.reverse(failures)
    cleaned = counts |> Map.values() |> Enum.filter(&is_integer/1) |> Enum.sum()
    changed = Map.reject(counts, fn {_name, count} -> count == 0 end)

    if cleaned > 0 or failures != [] do
      Logger.info(
        "Oban cleanup cycle completed: cleaned=#{cleaned} failures=#{length(failures)} " <>
          "changes=#{inspect(changed)}"
      )
    end

    {:ok, Map.put(counts, :failed_steps, failures)}
  end

  defp safe_cleanup_step(name, operation) do
    {:ok, operation.()}
  rescue
    error ->
      Logger.warning("Oban cleanup step #{name} failed: #{Exception.message(error)}")
      {:error, Exception.message(error)}
  catch
    kind, reason ->
      Logger.warning("Oban cleanup step #{name} stopped: #{inspect({kind, reason})}")
      {:error, inspect({kind, reason})}
  end

  def collapse_duplicate_remote_fetch_jobs do
    # Oban uniqueness prevents new amplification, while this query repairs rows
    # created by older code. An executing job always wins so cleanup never
    # removes work that a live process currently owns.
    %{num_rows: count} =
      Repo.query!(
        """
        WITH ranked AS MATERIALIZED (
          SELECT
            id,
            state,
            row_number() OVER (
              PARTITION BY
                worker,
                args->>'op',
                args->>'id',
                coalesce(args->>'thread', 'false')
              ORDER BY
                CASE state
                  WHEN 'executing' THEN 0
                  WHEN 'available' THEN 1
                  WHEN 'scheduled' THEN 2
                  WHEN 'retryable' THEN 3
                  ELSE 4
                END,
                id
            ) AS duplicate_rank
          FROM oban_jobs
          WHERE queue = 'remote_fetcher'
            AND worker = $1
            AND state IN ('available', 'scheduled', 'retryable', 'executing')
        ), duplicates AS (
          SELECT id
          FROM ranked
          WHERE duplicate_rank > 1
            AND state <> 'executing'
          ORDER BY id
          LIMIT $2
        )
        DELETE FROM oban_jobs AS job
        USING duplicates
        WHERE job.id = duplicates.id
          AND job.state <> 'executing'
        """,
        [@remote_fetch_worker, cleanup_batch_size()]
      )

    count
  end

  def collapse_triggered_remote_reply_jobs do
    # Numeric refresh indexes are intentional stages and must all survive.
    # A triggered refresh is redundant when any stage for the same object is
    # already incomplete, so merge its earlier schedule into the first pending
    # stage and remove only the triggered row. Legacy duplicate triggered rows
    # are collapsed separately, with executing work always preserved.
    %{rows: [[count]]} =
      Repo.query!(
        """
        WITH triggered AS MATERIALIZED (
          SELECT id, state, args->>'object_id' AS object_id, scheduled_at
          FROM oban_jobs
          WHERE worker = $1
            AND state IN ('available', 'scheduled', 'retryable', 'executing')
            AND args->>'refresh_index' = 'triggered'
          ORDER BY id
          LIMIT $2
        ), numeric_refreshes AS MATERIALIZED (
          SELECT id, state, args->>'object_id' AS object_id, scheduled_at
          FROM oban_jobs
          WHERE worker = $1
            AND state IN ('available', 'scheduled', 'retryable', 'executing')
            AND coalesce(args->>'refresh_index', '') ~ '^[0-9]+$'
            AND args->>'object_id' IN (SELECT object_id FROM triggered)
        ), first_scheduled_numeric AS (
          SELECT DISTINCT ON (numeric_refreshes.object_id)
            numeric_refreshes.id,
            numeric_refreshes.object_id,
            triggered.scheduled_at AS triggered_at
          FROM numeric_refreshes
          INNER JOIN triggered USING (object_id)
          WHERE numeric_refreshes.state = 'scheduled'
            AND triggered.state <> 'executing'
          ORDER BY
            numeric_refreshes.object_id,
            numeric_refreshes.scheduled_at,
            numeric_refreshes.id,
            triggered.scheduled_at,
            triggered.id
        ), accelerated AS (
          UPDATE oban_jobs AS job
          SET scheduled_at = LEAST(job.scheduled_at, target.triggered_at)
          FROM first_scheduled_numeric AS target
          WHERE job.id = target.id
          RETURNING job.id
        ), merged_triggered AS (
          DELETE FROM oban_jobs AS job
          USING triggered
          WHERE job.id = triggered.id
            AND job.state <> 'executing'
            AND EXISTS (
              SELECT 1
              FROM numeric_refreshes
              WHERE numeric_refreshes.object_id = triggered.object_id
            )
          RETURNING job.id
        ), ranked_triggered AS MATERIALIZED (
          SELECT
            id,
            state,
            row_number() OVER (
              PARTITION BY object_id
              ORDER BY
                CASE state
                  WHEN 'executing' THEN 0
                  WHEN 'available' THEN 1
                  WHEN 'scheduled' THEN 2
                  WHEN 'retryable' THEN 3
                  ELSE 4
                END,
                scheduled_at,
                id
            ) AS duplicate_rank
          FROM triggered
          WHERE NOT EXISTS (
            SELECT 1
            FROM numeric_refreshes
            WHERE numeric_refreshes.object_id = triggered.object_id
          )
        ), deduplicated_triggered AS (
          DELETE FROM oban_jobs AS job
          USING ranked_triggered
          WHERE job.id = ranked_triggered.id
            AND ranked_triggered.duplicate_rank > 1
            AND job.state <> 'executing'
          RETURNING job.id
        )
        SELECT
          (SELECT count(*) FROM merged_triggered) +
          (SELECT count(*) FROM deduplicated_triggered)
        """,
        [@remote_replies_fetch_worker, cleanup_batch_size()]
      )

    count
  end

  def collapse_duplicate_incoming_jobs do
    # New jobs carry activity_key. The fallback keeps this cleanup useful for
    # legacy rows while preserving software that reuses an ID across activity
    # types. Idless documents are compared by their complete argument payload.
    %{num_rows: count} =
      Repo.query!(
        """
        WITH ranked AS MATERIALIZED (
          SELECT
            id,
            state,
            row_number() OVER (
              PARTITION BY
                worker,
                CASE
                  WHEN args->>'activity_key' IS NOT NULL THEN args->>'activity_key'
                  WHEN args #>> '{params,id}' IS NOT NULL THEN
                    concat(
                      coalesce(args #>> '{params,type}', ''),
                      ':',
                      args #>> '{params,id}'
                    )
                  ELSE md5(args::text)
                END
              ORDER BY
                CASE state
                  WHEN 'executing' THEN 0
                  WHEN 'available' THEN 1
                  WHEN 'scheduled' THEN 2
                  WHEN 'retryable' THEN 3
                  ELSE 4
                END,
                id
            ) AS duplicate_rank
          FROM oban_jobs
          WHERE queue = 'federator_incoming'
            AND worker = $1
            AND state IN ('available', 'scheduled', 'retryable', 'executing')
        ), duplicates AS (
          SELECT id
          FROM ranked
          WHERE duplicate_rank > 1
            AND state <> 'executing'
          ORDER BY id
          LIMIT $2
        )
        DELETE FROM oban_jobs AS job
        USING duplicates
        WHERE job.id = duplicates.id
          AND job.state <> 'executing'
        """,
        [@receiver_worker, cleanup_batch_size()]
      )

    count
  end

  def discard_exhausted_receiver_transport_retries do
    discard_jobs(
      Oban.Job
      |> where([job], job.queue == "federator_incoming")
      |> where([job], job.worker == ^@receiver_worker)
      |> where([job], job.state == "retryable")
      |> where(
        [job],
        (job.attempt >= ^@receiver_transport_retry_limit and
           fragment(
             "?::text ~* ?",
             job.errors,
             ^@receiver_retry_limited_transport_pattern
           )) or
          fragment(
            "?::text ~* ?",
            job.errors,
            ^@receiver_terminal_certificate_pattern
          )
      )
    )
  end

  def discard_exhausted_native_nostr_retries do
    discard_jobs(
      Oban.Job
      |> where([job], job.queue == "federator_incoming")
      |> where([job], job.worker == ^@receiver_worker)
      |> where([job], job.state == "retryable")
      |> where([job], job.attempt >= ^@receiver_native_nostr_retry_limit)
      |> where(
        [job],
        fragment("?::text ~* ?", job.errors, ^@receiver_native_nostr_retry_pattern)
      )
    )
  end

  def discard_terminal_user_refresh_retries do
    discard_jobs(
      Oban.Job
      |> where([job], job.queue == "background")
      |> where([job], job.worker == ^@user_refresh_worker)
      |> where([job], job.state == "retryable")
      |> where([job], fragment("?::text ILIKE ?", job.errors, "%content_type%"))
    )
  end

  def delete_far_future_poll_notifications(now \\ DateTime.utc_now()) do
    max_scheduled_at = DateTime.add(now, max_poll_schedule_seconds(), :second)

    Oban.Job
    |> where([job], job.queue == "poll_notifications")
    |> where([job], job.worker == "Pleroma.Workers.PollWorker")
    |> where([job], job.state in ["scheduled", "available", "retryable"])
    |> where([job], job.scheduled_at > ^max_scheduled_at)
    |> delete_jobs()
  end

  def delete_far_future_activity_expirations(now \\ DateTime.utc_now()) do
    max_scheduled_at =
      DateTime.add(now, @max_activity_expiration_schedule_seconds, :second)

    Oban.Job
    |> where([job], job.queue == "activity_expiration")
    |> where([job], job.worker == "Pleroma.Workers.PurgeExpiredActivity")
    |> where([job], job.state in ["scheduled", "available", "retryable"])
    |> where([job], job.scheduled_at > ^max_scheduled_at)
    |> delete_jobs()
  end

  def discard_stale_event_reminders(now \\ DateTime.utc_now()) do
    stale_before = DateTime.add(now, -@stale_event_reminder_seconds, :second)

    discard_jobs(
      Oban.Job
      |> where([job], job.queue == "event_reminders")
      |> where([job], job.worker == "Pleroma.Workers.EventReminderWorker")
      |> where([job], job.state in ["available", "scheduled", "retryable"])
      |> where([job], job.scheduled_at < ^stale_before)
    )
  end

  def discard_stale_cleanup_retries(now \\ DateTime.utc_now()) do
    stale_before = DateTime.add(now, -@stale_cleanup_retry_seconds, :second)

    discard_jobs(
      Oban.Job
      |> where([job], job.queue == "background")
      |> where([job], job.worker in ^@cleanup_workers)
      |> where([job], job.state == "retryable")
      |> where([job], job.inserted_at < ^stale_before)
    )
  end

  def discard_stale_federator_retries(now \\ DateTime.utc_now()) do
    stale_before = DateTime.add(now, -@stale_federator_retry_seconds, :second)

    discard_jobs(
      Oban.Job
      |> where([job], job.queue in ["federator_incoming", "federator_outgoing"])
      |> where([job], job.worker in ^@stale_federator_workers)
      |> where([job], job.state == "retryable")
      |> where([job], job.inserted_at < ^stale_before)
    )
  end

  def discard_terminal_publisher_retries do
    discard_jobs(
      Oban.Job
      |> where([job], job.queue == "federator_outgoing")
      |> where([job], job.worker == "Pleroma.Workers.PublisherWorker")
      |> where([job], job.state == "retryable")
      |> where(
        [job],
        fragment("?::text ~ ?", job.errors, ^@terminal_publisher_status_pattern) or
          (job.attempt >= ^@persistent_publisher_server_error_attempts and
             fragment(
               "?::text ~ ?",
               job.errors,
               ^@persistent_publisher_server_error_pattern
             ))
      )
    )
  end

  def discard_fixed_federation_exception_retries do
    discard_fixed_receiver_retries() + discard_fixed_remote_fetch_retries()
  end

  defp discard_fixed_receiver_retries do
    discard_jobs(
      Oban.Job
      |> where([job], job.queue == "federator_incoming")
      |> where([job], job.worker in ^@incoming_workers)
      |> where([job], job.state == "retryable")
      |> where(
        [job],
        fragment("?::text ILIKE ANY(?)", job.errors, ^@fixed_federation_error_patterns) or
          fragment("?::text ~ ?", job.errors, ^@terminal_incoming_status_pattern)
      )
    )
  end

  defp discard_fixed_remote_fetch_retries do
    discard_jobs(
      Oban.Job
      |> where([job], job.queue == "remote_fetcher")
      |> where([job], job.worker == ^@remote_fetch_worker)
      |> where([job], job.state == "retryable")
      |> where(
        [job],
        fragment("?::text ILIKE ANY(?)", job.errors, ^@fixed_remote_fetch_error_patterns) or
          fragment("?::text ~ ?", job.errors, ^@terminal_remote_fetch_status_pattern)
      )
    )
  end

  def discard_unreachable_publisher_jobs do
    consistently_unreachable_before = Instances.reachability_datetime_threshold()

    discard_jobs(
      Oban.Job
      |> join(:inner, [job], instance in Pleroma.Instances.Instance,
        on:
          fragment(
            "lower(?) = ap_id_host(coalesce(? #>> '{params,inbox}', ?->>'inbox'))",
            instance.host,
            job.args,
            job.args
          )
      )
      |> where([job, _instance], job.queue == "federator_outgoing")
      |> where([job, _instance], job.worker == "Pleroma.Workers.PublisherWorker")
      |> where([job, _instance], job.state in ["available", "scheduled", "retryable"])
      |> where([job, _instance], job.args["op"] == "publish_one")
      |> where(
        [_job, instance],
        not is_nil(instance.unreachable_since) and
          instance.unreachable_since <= ^consistently_unreachable_before
      )
    )
  end

  def reindex_bloated_oban_args_index do
    # Oban's JSONB argument index is read on every unique-job insertion. Heavy
    # job churn can leave the GIN index much larger than the live jobs heap
    # because ordinary vacuuming cannot return empty index pages. A concurrent
    # rebuild keeps workers available and is reserved for severe bloat so this
    # hourly janitor does not turn routine index growth into recurring DDL.
    %{rows: [[index_bytes, heap_bytes, reindex_in_progress]]} =
      Repo.query!("""
      SELECT
        pg_relation_size('oban_jobs_args_index'::regclass),
        greatest(pg_relation_size('oban_jobs'::regclass), 1),
        EXISTS (
          SELECT 1
          FROM pg_stat_progress_create_index
          WHERE relid = 'oban_jobs'::regclass
             OR index_relid = 'oban_jobs_args_index'::regclass
        )
      """)

    if not reindex_in_progress and
         index_bytes >= @oban_args_index_min_bytes and
         index_bytes >= heap_bytes * @oban_args_index_max_heap_ratio do
      Repo.query!(
        "REINDEX INDEX CONCURRENTLY oban_jobs_args_index",
        [],
        timeout: 60_000
      )

      1
    else
      0
    end
  end

  defp discard_jobs(query) do
    now = DateTime.utc_now()
    job_ids = bounded_job_ids(query)

    {count, _} =
      Oban.Job
      |> where([job], job.id in subquery(job_ids))
      |> where([job], job.state != "executing")
      |> Repo.update_all(set: [state: "discarded", discarded_at: now])

    count
  end

  defp delete_jobs(query) do
    job_ids = bounded_job_ids(query)

    {count, _} =
      Oban.Job
      |> where([job], job.id in subquery(job_ids))
      |> where([job], job.state != "executing")
      |> Repo.delete_all()

    count
  end

  defp bounded_job_ids(query) do
    query
    |> exclude(:select)
    |> exclude(:order_by)
    |> order_by([job, ...], asc: job.id)
    |> limit(^cleanup_batch_size())
    |> select([job, ...], job.id)
  end

  defp cleanup_batch_size do
    case Config.get([:oban_cleanup, :batch_size], @default_cleanup_batch_size) do
      size when is_integer(size) -> size |> max(100) |> min(25_000)
      _size -> @default_cleanup_batch_size
    end
  end

  defp max_poll_schedule_seconds do
    case Config.get([:instance, :poll_limits, :max_expiration]) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _ -> @default_max_poll_schedule_seconds
    end
  end
end
