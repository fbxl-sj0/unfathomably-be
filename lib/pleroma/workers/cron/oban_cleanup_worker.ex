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

  use Oban.Worker, queue: "background", max_attempts: 1

  import Ecto.Query

  alias Pleroma.Config
  alias Pleroma.Repo

  @default_max_poll_schedule_seconds 365 * 24 * 60 * 60
  @stale_event_reminder_seconds 24 * 60 * 60
  @stale_cleanup_retry_seconds 24 * 60 * 60
  @stale_federator_retry_seconds 30 * 24 * 60 * 60
  @terminal_publisher_status_re ~r/status: (400|401|403|404|405|406|410|422|451|501)(,|})/
  @duplicate_receiver_error_re ~r/activities_unique_apid_index/
  @cleanup_workers [
    "Pleroma.Workers.Cron.GroupDiscussionCleanupWorker",
    "Pleroma.Workers.Cron.RemotePostCleanupWorker"
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    deleted_far_future_polls = delete_far_future_poll_notifications()
    discarded_stale_event_reminders = discard_stale_event_reminders()
    discarded_stale_cleanup_retries = discard_stale_cleanup_retries()
    discarded_stale_federator_retries = discard_stale_federator_retries()
    discarded_terminal_publisher_retries = discard_terminal_publisher_retries()
    discarded_duplicate_receiver_retries = discard_duplicate_receiver_retries()

    {:ok,
     %{
       deleted_far_future_poll_notifications: deleted_far_future_polls,
       discarded_stale_event_reminders: discarded_stale_event_reminders,
       discarded_stale_cleanup_retries: discarded_stale_cleanup_retries,
       discarded_stale_federator_retries: discarded_stale_federator_retries,
       discarded_terminal_publisher_retries: discarded_terminal_publisher_retries,
       discarded_duplicate_receiver_retries: discarded_duplicate_receiver_retries
     }}
  end

  def delete_far_future_poll_notifications(now \\ DateTime.utc_now()) do
    max_scheduled_at = DateTime.add(now, max_poll_schedule_seconds(), :second)

    {count, _} =
      Oban.Job
      |> where([job], job.queue == "poll_notifications")
      |> where([job], job.worker == "Pleroma.Workers.PollWorker")
      |> where([job], job.state in ["scheduled", "available", "retryable"])
      |> where([job], job.scheduled_at > ^max_scheduled_at)
      |> Repo.delete_all()

    count
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
      |> where(
        [job],
        job.worker in ["Pleroma.Workers.ReceiverWorker", "Pleroma.Workers.PublisherWorker"]
      )
      |> where([job], job.state == "retryable")
      |> where([job], job.inserted_at < ^stale_before)
    )
  end

  def discard_terminal_publisher_retries do
    terminal_status_re = Regex.source(@terminal_publisher_status_re)

    discard_jobs(
      Oban.Job
      |> where([job], job.queue == "federator_outgoing")
      |> where([job], job.worker == "Pleroma.Workers.PublisherWorker")
      |> where([job], job.state == "retryable")
      |> where(
        [job],
        fragment(
          "exists (select 1 from unnest(?) as error where error->>'error' ~ ?)",
          job.errors,
          ^terminal_status_re
        )
      )
    )
  end

  def discard_duplicate_receiver_retries do
    duplicate_error_re = Regex.source(@duplicate_receiver_error_re)

    discard_jobs(
      Oban.Job
      |> where([job], job.queue == "federator_incoming")
      |> where([job], job.worker == "Pleroma.Workers.ReceiverWorker")
      |> where([job], job.state == "retryable")
      |> where(
        [job],
        fragment(
          "exists (select 1 from unnest(?) as error where error->>'error' ~ ?)",
          job.errors,
          ^duplicate_error_re
        )
      )
    )
  end

  defp discard_jobs(query) do
    now = DateTime.utc_now()

    {count, _} =
      query
      |> Repo.update_all(set: [state: "discarded", discarded_at: now])

    count
  end

  defp max_poll_schedule_seconds do
    case Config.get([:instance, :poll_limits, :max_expiration]) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _ -> @default_max_poll_schedule_seconds
    end
  end
end
