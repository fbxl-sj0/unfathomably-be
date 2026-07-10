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

    unknown_error =
      ReceiverWorker.new(%{"op" => "incoming_ap_doc"})
      |> insert_job(now,
        state: "retryable",
        errors: [%{"error" => "fresh unclassified receiver error"}]
      )

    assert 2 = ObanCleanupWorker.discard_fixed_federation_exception_retries()

    assert %Oban.Job{state: "discarded"} = Repo.get(Oban.Job, duplicate_activity.id)
    assert %Oban.Job{state: "discarded"} = Repo.get(Oban.Job, terminal_signature_retry.id)
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

  test "deletes redundant incomplete remote fetch jobs" do
    now = DateTime.utc_now()

    first_job =
      RemoteFetcherWorker.new(%{
        "op" => "fetch_remote",
        "id" => "https://remote.example/o/duplicate",
        "depth" => 1
      })
      |> insert_job(now, state: "available")

    duplicate_job =
      RemoteFetcherWorker.new(%{
        "op" => "fetch_remote",
        "id" => "https://remote.example/o/temporary",
        "depth" => 2
      })
      |> insert_job(now, state: "available")

    thread_job =
      RemoteFetcherWorker.new(%{
        "op" => "fetch_remote",
        "id" => "https://remote.example/o/duplicate",
        "depth" => 1,
        "thread" => true
      })
      |> insert_job(now, state: "available")

    duplicate_args = Map.put(duplicate_job.args, "id", first_job.args["id"])

    duplicate_job
    |> Ecto.Changeset.change(args: duplicate_args)
    |> Repo.update!()

    assert 1 = ObanCleanupWorker.collapse_duplicate_remote_fetch_jobs()

    assert Repo.get(Oban.Job, first_job.id)
    refute Repo.get(Oban.Job, duplicate_job.id)
    assert Repo.get(Oban.Job, thread_job.id)
  end

  test "discards terminal publisher retries" do
    now = DateTime.utc_now()

    terminal_job =
      PublisherWorker.new(%{"op" => "publish_one"})
      |> insert_job(now, state: "retryable", errors: [%{"error" => "status: 405"}])

    temporary_job =
      PublisherWorker.new(%{"op" => "publish_one"})
      |> insert_job(now, state: "retryable", errors: [%{"error" => "status: 502"}])

    assert 1 = ObanCleanupWorker.discard_terminal_publisher_retries()

    assert %Oban.Job{state: "discarded"} = Repo.get(Oban.Job, terminal_job.id)
    assert %Oban.Job{state: "retryable"} = Repo.get(Oban.Job, temporary_job.id)
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

    {:ok, job} =
      changeset
      |> Ecto.Changeset.put_change(:scheduled_at, scheduled_at)
      |> Ecto.Changeset.put_change(:inserted_at, scheduled_at)
      |> Ecto.Changeset.put_change(:state, state)
      |> Ecto.Changeset.put_change(:errors, errors)
      |> Oban.insert()

    job
  end
end
