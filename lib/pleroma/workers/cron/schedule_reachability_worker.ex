# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.Cron.ScheduleReachabilityWorker do
  @moduledoc """
  Schedules reachability checks and trims stale delivery work.

  Publisher-side delivery avoids repeatedly hammering hosts that are known to
  be unreachable. This cron job gives those hosts a quiet path back into normal
  delivery once they start answering again.

  It also performs the janitor side of that policy. When an instance has been
  unreachable long enough to be considered dormant, outgoing federation jobs for
  that host are discarded in bulk instead of waiting for each job to wake up and
  cancel itself. This keeps routine dead-instance cleanup out of the admin's
  hands and prevents retry storms from occupying the outgoing federation queue.
  """

  import Ecto.Query

  alias Pleroma.Instances
  alias Pleroma.Instances.Instance
  alias Pleroma.Repo
  alias Pleroma.Workers.ReachabilityWorker

  use Oban.Worker, queue: "background"

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    scheduled_reachability_checks = schedule_reachability_checks()
    discarded_dormant_deliveries = discard_dormant_delivery_jobs()

    {:ok,
     %{
       scheduled_reachability_checks: scheduled_reachability_checks,
       discarded_dormant_deliveries: discarded_dormant_deliveries
     }}
  end

  def schedule_reachability_checks do
    hosts =
      Instances.get_consistently_unreachable()
      |> Enum.map(&elem(&1, 0))

    existing_hosts =
      Oban.Job
      |> where([job], job.worker == "Pleroma.Workers.ReachabilityWorker")
      |> where([job], job.state in ["available", "executing", "scheduled", "retryable"])
      |> where([job], job.args["domain"] in ^hosts)
      |> select([job], job.args["domain"])
      |> Repo.all()
      |> MapSet.new()

    jobs =
      hosts
      |> Enum.reject(&MapSet.member?(existing_hosts, &1))
      |> Enum.map(&ReachabilityWorker.new(%{"domain" => &1}))

    insert_all(jobs)
    length(jobs)
  end

  def discard_dormant_delivery_jobs do
    now = DateTime.utc_now()

    {count, _} =
      Oban.Job
      |> join(:inner, [job], instance in Instance,
        on:
          fragment(
            "lower(?) = ap_id_host(coalesce(? #>> '{params,inbox}', ?->>'inbox'))",
            instance.host,
            job.args,
            job.args
          )
      )
      |> where([job, instance], job.queue == "federator_outgoing")
      |> where([job, instance], job.worker == "Pleroma.Workers.PublisherWorker")
      |> where([job, instance], job.state in ["available", "scheduled", "retryable"])
      |> where([job, instance], job.args["op"] == "publish_one")
      |> where([job, instance], not is_nil(instance.unreachable_since))
      |> where(
        [job, instance],
        instance.unreachable_since <= ^Instances.dormant_datetime_threshold()
      )
      |> Repo.update_all(set: [state: "discarded", discarded_at: now])

    count
  end

  defp insert_all([]), do: :ok

  defp insert_all(jobs) do
    Oban.insert_all(jobs)
  end
end
