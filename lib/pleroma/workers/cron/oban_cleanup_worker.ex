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
  @incoming_workers [
    "Pleroma.Workers.ReceiverWorker",
    "Pleroma.Workers.SignatureRetryWorker"
  ]
  @stale_federator_workers @incoming_workers ++ ["Pleroma.Workers.PublisherWorker"]
  @terminal_publisher_status_pattern "status[^0-9]*(400|403|404|405|406|410|501)"
  @terminal_incoming_status_pattern "http[^0-9]*(400|401|403|404|405|406|410|501)"
  @terminal_remote_fetch_status_pattern "http[^0-9]*(400|403|404|405|406|410|501)"
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
    deleted_far_future_polls = delete_far_future_poll_notifications()
    discarded_stale_event_reminders = discard_stale_event_reminders()
    discarded_stale_cleanup_retries = discard_stale_cleanup_retries()
    discarded_stale_federator_retries = discard_stale_federator_retries()
    discarded_terminal_publisher_retries = discard_terminal_publisher_retries()
    discarded_unreachable_publisher_jobs = discard_unreachable_publisher_jobs()
    discarded_fixed_federation_exception_retries = discard_fixed_federation_exception_retries()

    {:ok,
     %{
       deleted_far_future_poll_notifications: deleted_far_future_polls,
       discarded_stale_event_reminders: discarded_stale_event_reminders,
       discarded_stale_cleanup_retries: discarded_stale_cleanup_retries,
       discarded_stale_federator_retries: discarded_stale_federator_retries,
       discarded_terminal_publisher_retries: discarded_terminal_publisher_retries,
       discarded_unreachable_publisher_jobs: discarded_unreachable_publisher_jobs,
       discarded_fixed_federation_exception_retries: discarded_fixed_federation_exception_retries
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
      |> where([job], fragment("?::text ~ ?", job.errors, ^@terminal_publisher_status_pattern))
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
      |> where([job], job.worker == "Pleroma.Workers.RemoteFetcherWorker")
      |> where([job], job.state == "retryable")
      |> where(
        [job],
        fragment("?::text ILIKE ANY(?)", job.errors, ^@fixed_remote_fetch_error_patterns) or
          fragment("?::text ~ ?", job.errors, ^@terminal_remote_fetch_status_pattern)
      )
    )
  end

  def discard_unreachable_publisher_jobs do
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
      |> where([_job, instance], not is_nil(instance.unreachable_since))
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
