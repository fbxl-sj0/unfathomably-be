# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.Cron.ObanCleanupWorkerTest do
  use Pleroma.DataCase, async: false

  alias Pleroma.Instances
  alias Pleroma.Repo
  alias Pleroma.Workers.Cron.ObanCleanupWorker
  alias Pleroma.Workers.EventReminderWorker
  alias Pleroma.Workers.PollWorker
  alias Pleroma.Workers.PublisherWorker
  alias Pleroma.Workers.ReceiverWorker
  alias Pleroma.Workers.RemoteFetcherWorker
  alias Pleroma.Workers.RichMediaWorker
  alias Pleroma.Workers.SignatureRetryWorker

  setup do
    clear_config([:instance, :poll_limits], %{max_expiration: 365 * 24 * 60 * 60})
  end

  test "deletes poll notification jobs scheduled beyond the configured poll window" do
    now = DateTime.utc_now()
    far_future = DateTime.add(now, 370 * 24 * 60 * 60, :second)
    near_future = DateTime.add(now, 5 * 60, :second)

    far_job =
      insert_job(PollWorker.new(%{"op" => "poll_end", "activity_id" => "far"}), far_future)

    near_job =
      insert_job(PollWorker.new(%{"op" => "poll_end", "activity_id" => "near"}), near_future)

    assert 1 = ObanCleanupWorker.delete_far_future_poll_notifications(now)

    refute Repo.get(Oban.Job, far_job.id)
    assert Repo.get(Oban.Job, near_job.id)
  end

  test "discards event reminders that are already stale" do
    now = DateTime.utc_now()
    old_time = DateTime.add(now, -2 * 24 * 60 * 60, :second)
    soon_time = DateTime.add(now, 60 * 60, :second)

    old_job =
      insert_job(
        EventReminderWorker.new(%{"op" => "event_reminder", "activity_id" => "old"}),
        old_time,
        state: "available"
      )

    soon_job =
      insert_job(
        EventReminderWorker.new(%{"op" => "event_reminder", "activity_id" => "soon"}),
        soon_time,
        state: "available"
      )

    assert 1 = ObanCleanupWorker.discard_stale_event_reminders(now)

    assert %Oban.Job{state: "discarded"} = Repo.get(Oban.Job, old_job.id)
    assert %Oban.Job{state: "available"} = Repo.get(Oban.Job, soon_job.id)
  end

  test "discards very old federator retry jobs" do
    now = DateTime.utc_now()

    old_outgoing =
      PublisherWorker.new(%{"op" => "publish_one"})
      |> insert_job(DateTime.add(now, -31 * 24 * 60 * 60, :second), state: "retryable")

    recent_incoming =
      ReceiverWorker.new(%{"op" => "incoming_ap_doc"})
      |> insert_job(DateTime.add(now, -2 * 24 * 60 * 60, :second), state: "retryable")

    old_signature_retry =
      SignatureRetryWorker.new(%{"op" => "incoming_failed_signature_ap_doc"})
      |> insert_job(DateTime.add(now, -31 * 24 * 60 * 60, :second), state: "retryable")

    assert 2 = ObanCleanupWorker.discard_stale_federator_retries(now)

    assert %Oban.Job{state: "discarded"} = Repo.get(Oban.Job, old_outgoing.id)
    assert %Oban.Job{state: "discarded"} = Repo.get(Oban.Job, old_signature_retry.id)
    assert %Oban.Job{state: "retryable"} = Repo.get(Oban.Job, recent_incoming.id)
  end

  test "discards fixed incoming federation exception retries" do
    now = DateTime.utc_now()

    duplicate_activity =
      ReceiverWorker.new(%{"op" => "incoming_ap_doc"})
      |> insert_job(now,
        state: "retryable",
        errors: [%{"error" => "constraint error: activities_unique_apid_index"}]
      )

    terminal_signature_retry =
      SignatureRetryWorker.new(%{"op" => "incoming_failed_signature_ap_doc"})
      |> insert_job(now,
        state: "retryable",
        errors: [%{"error" => "{:error, {:http, 405}}"}]
      )

    tombstone_reaction =
      ReceiverWorker.new(%{"op" => "incoming_ap_doc"})
      |> insert_job(now,
        state: "retryable",
        errors: [%{"error" => "do_fix_object_action_recipients tombstoned Page"}]
      )

    pinned_limit =
      ReceiverWorker.new(%{"op" => "incoming_ap_doc"})
      |> insert_job(now,
        state: "retryable",
        errors: [%{"error" => "side_effects {:error, :pinned_statuses_limit_reached}"}]
      )

    duplicate_object =
      ReceiverWorker.new(%{"op" => "incoming_ap_doc"})
      |> insert_job(now,
        state: "retryable",
        errors: [%{"error" => "The object to create already exists"}]
      )

    unknown_error =
      ReceiverWorker.new(%{"op" => "incoming_ap_doc"})
      |> insert_job(now,
        state: "retryable",
        errors: [%{"error" => "fresh unclassified receiver error"}]
      )

    assert 5 = ObanCleanupWorker.discard_fixed_federation_exception_retries()

    assert %Oban.Job{state: "discarded"} = Repo.get(Oban.Job, duplicate_activity.id)
    assert %Oban.Job{state: "discarded"} = Repo.get(Oban.Job, terminal_signature_retry.id)
    assert %Oban.Job{state: "discarded"} = Repo.get(Oban.Job, tombstone_reaction.id)
    assert %Oban.Job{state: "discarded"} = Repo.get(Oban.Job, pinned_limit.id)
    assert %Oban.Job{state: "discarded"} = Repo.get(Oban.Job, duplicate_object.id)
    assert %Oban.Job{state: "retryable"} = Repo.get(Oban.Job, unknown_error.id)
  end

  test "discards fixed remote fetch retry errors" do
    now = DateTime.utc_now()

    fixed_collection_error =
      RemoteFetcherWorker.new(%{"op" => "fetch_remote", "id" => "https://remote.example/o/1"})
      |> insert_job(now,
        state: "retryable",
        errors: [%{"error" => "errors: [likes: {\"is invalid\", []}]"}]
      )

    terminal_status_error =
      RemoteFetcherWorker.new(%{"op" => "fetch_remote", "id" => "https://remote.example/o/3"})
      |> insert_job(now,
        state: "retryable",
        errors: [%{"error" => "{:error, {:http, 405}}"}]
      )

    unknown_error =
      RemoteFetcherWorker.new(%{"op" => "fetch_remote", "id" => "https://remote.example/o/2"})
      |> insert_job(now,
        state: "retryable",
        errors: [%{"error" => "fresh remote fetch parser error"}]
      )

    assert 2 = ObanCleanupWorker.discard_fixed_federation_exception_retries()

    assert %Oban.Job{state: "discarded"} = Repo.get(Oban.Job, fixed_collection_error.id)
    assert %Oban.Job{state: "discarded"} = Repo.get(Oban.Job, terminal_status_error.id)
    assert %Oban.Job{state: "retryable"} = Repo.get(Oban.Job, unknown_error.id)
  end

  test "deletes duplicate pending remote fetch jobs while keeping one copy" do
    now = DateTime.utc_now()
    duplicate_args = %{"op" => "fetch_remote", "id" => "https://remote.example/o/dupe"}
    other_args = %{"op" => "fetch_remote", "id" => "https://remote.example/o/other"}

    [first_id, second_id, other_id] =
      insert_remote_fetch_rows!(now, [duplicate_args, duplicate_args, other_args])

    assert 1 = ObanCleanupWorker.delete_duplicate_remote_fetch_jobs()

    remaining_ids =
      Oban.Job
      |> where([job], job.worker == "Pleroma.Workers.RemoteFetcherWorker")
      |> select([job], job.id)
      |> Repo.all()

    assert first_id in remaining_ids
    refute second_id in remaining_ids
    assert other_id in remaining_ids
  end

  test "discards terminal publisher retries" do
    now = DateTime.utc_now()

    terminal_job =
      PublisherWorker.new(%{"op" => "publish_one"})
      |> insert_job(now, state: "retryable", errors: [%{"error" => "status: 405"}])

    minds_html_500 =
      PublisherWorker.new(%{"op" => "publish_one"})
      |> insert_job(now,
        state: "retryable",
        errors: [
          %{
            "error" =>
              "url: \"https://www.minds.com/api/activitypub/inbox\", headers: [{\"x-minds\", \"Something is wrong\"}], status: 500"
          }
        ]
      )

    temporary_job =
      PublisherWorker.new(%{"op" => "publish_one"})
      |> insert_job(now, state: "retryable", errors: [%{"error" => "status: 502"}])

    assert 2 = ObanCleanupWorker.discard_terminal_publisher_retries()

    assert %Oban.Job{state: "discarded"} = Repo.get(Oban.Job, terminal_job.id)
    assert %Oban.Job{state: "discarded"} = Repo.get(Oban.Job, minds_html_500.id)
    assert %Oban.Job{state: "retryable"} = Repo.get(Oban.Job, temporary_job.id)
  end

  test "discards terminal background retries" do
    now = DateTime.utc_now()

    oversized_rich_media =
      RichMediaWorker.new(%{"op" => "backfill", "url" => "https://remote.example/big"})
      |> insert_job(now, state: "retryable", errors: [%{"error" => "{:error, :body_too_large}"}])

    invalid_content_type =
      RichMediaWorker.new(%{"op" => "backfill", "url" => "https://remote.example/not-html"})
      |> insert_job(now, state: "retryable", errors: [%{"error" => "{:error, :content_type}"}])

    temporary_job =
      RichMediaWorker.new(%{"op" => "backfill", "url" => "https://remote.example/slow"})
      |> insert_job(now, state: "retryable", errors: [%{"error" => "{:error, :timeout}"}])

    assert 2 = ObanCleanupWorker.discard_terminal_background_retries()

    assert %Oban.Job{state: "discarded"} = Repo.get(Oban.Job, oversized_rich_media.id)
    assert %Oban.Job{state: "discarded"} = Repo.get(Oban.Job, invalid_content_type.id)
    assert %Oban.Job{state: "retryable"} = Repo.get(Oban.Job, temporary_job.id)
  end

  test "discards exhausted incoming transaction retries" do
    now = DateTime.utc_now()

    exhausted_job =
      SignatureRetryWorker.new(%{
        "op" => "incoming_failed_signature_ap_doc",
        "id" => "exhausted-transaction"
      })
      |> insert_job(now,
        state: "retryable",
        attempt: :last_retryable,
        errors: [
          %{"error" => "ERROR 25P02 (in_failed_sql_transaction) current transaction is aborted"}
        ]
      )

    recent_job =
      SignatureRetryWorker.new(%{
        "op" => "incoming_failed_signature_ap_doc",
        "id" => "recent-transaction"
      })
      |> insert_job(now,
        state: "retryable",
        attempt: 2,
        errors: [
          %{"error" => "ERROR 25P02 (in_failed_sql_transaction) current transaction is aborted"}
        ]
      )

    assert 1 = ObanCleanupWorker.discard_exhausted_incoming_transaction_retries()

    assert %Oban.Job{state: "discarded"} = Repo.get(Oban.Job, exhausted_job.id)
    assert %Oban.Job{state: "retryable"} = Repo.get(Oban.Job, recent_job.id)
  end

  test "discards publisher jobs aimed at unreachable hosts" do
    now = DateTime.utc_now()
    Instances.set_unreachable("dead.example", Instances.reachability_datetime_threshold())

    dead_job =
      PublisherWorker.new(%{
        "op" => "publish_one",
        "module" => "Elixir.Pleroma.Web.ActivityPub.Publisher",
        "params" => %{"inbox" => "https://dead.example/inbox"}
      })
      |> insert_job(now, state: "retryable")

    live_job =
      PublisherWorker.new(%{
        "op" => "publish_one",
        "module" => "Elixir.Pleroma.Web.ActivityPub.Publisher",
        "params" => %{"inbox" => "https://live.example/inbox"}
      })
      |> insert_job(now, state: "retryable")

    assert 1 = ObanCleanupWorker.discard_unreachable_publisher_jobs()

    assert %Oban.Job{state: "discarded"} = Repo.get(Oban.Job, dead_job.id)
    assert %Oban.Job{state: "retryable"} = Repo.get(Oban.Job, live_job.id)
  end

  test "discards stale cleanup retries" do
    now = DateTime.utc_now()

    old_cleanup =
      %{"op" => "cleanup"}
      |> Pleroma.Workers.Cron.RemotePostCleanupWorker.new()
      |> insert_job(DateTime.add(now, -2 * 24 * 60 * 60, :second), state: "retryable")

    recent_cleanup =
      %{"op" => "cleanup"}
      |> Pleroma.Workers.Cron.GroupDiscussionCleanupWorker.new()
      |> insert_job(DateTime.add(now, -60 * 60, :second), state: "retryable")

    assert 1 = ObanCleanupWorker.discard_stale_cleanup_retries(now)

    assert %Oban.Job{state: "discarded"} = Repo.get(Oban.Job, old_cleanup.id)
    assert %Oban.Job{state: "retryable"} = Repo.get(Oban.Job, recent_cleanup.id)
  end

  defp insert_job(changeset, scheduled_at, opts \\ []) do
    state = Keyword.get(opts, :state, "scheduled")
    errors = Keyword.get(opts, :errors, [])
    attempt = Keyword.get(opts, :attempt, 0)

    {:ok, job} =
      changeset
      |> Ecto.Changeset.put_change(:scheduled_at, scheduled_at)
      |> Ecto.Changeset.put_change(:inserted_at, scheduled_at)
      |> Ecto.Changeset.put_change(:state, state)
      |> Ecto.Changeset.put_change(:errors, errors)
      |> Oban.insert()

    attempt =
      case attempt do
        :max -> job.max_attempts
        :last_retryable -> max(job.max_attempts - 1, 1)
        attempt -> attempt
      end

    if attempt > 0 do
      job
      |> Ecto.Changeset.change(attempt: attempt)
      |> Repo.update!()
    else
      job
    end
  end

  defp insert_remote_fetch_rows!(scheduled_at, args_list) do
    values =
      Enum.map(args_list, fn args ->
        [
          "available",
          "remote_fetcher",
          "Pleroma.Workers.RemoteFetcherWorker",
          Jason.encode!(args),
          scheduled_at,
          scheduled_at
        ]
      end)

    %{rows: rows} =
      Repo.query!(
        """
        INSERT INTO oban_jobs (
          state,
          queue,
          worker,
          args,
          meta,
          tags,
          errors,
          attempt,
          max_attempts,
          priority,
          scheduled_at,
          inserted_at
        )
        SELECT
          row_data.state::oban_job_state,
          row_data.queue,
          row_data.worker,
          row_data.args::jsonb,
          '{}'::jsonb,
          ARRAY[]::varchar[],
          ARRAY[]::jsonb[],
          0,
          1,
          0,
          row_data.scheduled_at,
          row_data.inserted_at
        FROM unnest(
          $1::varchar[],
          $2::varchar[],
          $3::varchar[],
          $4::varchar[],
          $5::timestamp[],
          $6::timestamp[]
        ) AS row_data(
          state,
          queue,
          worker,
          args,
          scheduled_at,
          inserted_at
        )
        RETURNING id
        """,
        Enum.zip_with(values, & &1)
      )

    Enum.map(rows, fn [id] -> id end)
  end
end
