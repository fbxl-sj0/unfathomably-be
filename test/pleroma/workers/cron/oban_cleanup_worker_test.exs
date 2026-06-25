# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.Cron.ObanCleanupWorkerTest do
  use Pleroma.DataCase, async: false

  alias Pleroma.Repo
  alias Pleroma.Workers.Cron.ObanCleanupWorker
  alias Pleroma.Workers.EventReminderWorker
  alias Pleroma.Workers.PollWorker
  alias Pleroma.Workers.PublisherWorker
  alias Pleroma.Workers.ReceiverWorker

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

    assert 1 = ObanCleanupWorker.discard_stale_federator_retries(now)

    assert %Oban.Job{state: "discarded"} = Repo.get(Oban.Job, old_outgoing.id)
    assert %Oban.Job{state: "retryable"} = Repo.get(Oban.Job, recent_incoming.id)
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

    {:ok, job} =
      changeset
      |> Ecto.Changeset.put_change(:scheduled_at, scheduled_at)
      |> Ecto.Changeset.put_change(:inserted_at, scheduled_at)
      |> Ecto.Changeset.put_change(:state, state)
      |> Oban.insert()

    job
  end
end
