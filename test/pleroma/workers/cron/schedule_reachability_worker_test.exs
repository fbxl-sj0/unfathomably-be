# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.Cron.ScheduleReachabilityWorkerTest do
  use Pleroma.DataCase, async: false
  use Oban.Testing, repo: Pleroma.Repo

  import Ecto.Query

  alias Pleroma.Instances
  alias Pleroma.Repo
  alias Pleroma.Workers.BackgroundWorker
  alias Pleroma.Workers.Cron.ScheduleReachabilityWorker
  alias Pleroma.Workers.PublisherWorker

  setup do
    clear_config([:instance, :federation_reachability_timeout_days], 1)
    clear_config([:instance, :dormant_instance_timeout_days], 183)
  end

  test "schedules reachability checks and discards outgoing deliveries to dormant hosts" do
    Instances.set_unreachable("maybe-back.example", Instances.reachability_datetime_threshold())
    Instances.set_unreachable("dead.example", Instances.dormant_datetime_threshold())

    dormant_job = insert_delivery_job("https://dead.example/inbox", state: "retryable")

    legacy_dormant_job =
      insert_legacy_delivery_job("https://dead.example/legacy-inbox", state: "retryable")

    active_job = insert_delivery_job("https://active.example/inbox", state: "retryable")
    wakeup_job = insert_delivery_job("https://maybe-back.example/inbox", state: "retryable")

    unrelated_job =
      BackgroundWorker.new(%{"op" => "noop"})
      |> insert_job(state: "retryable")

    assert {:ok,
            %{
              scheduled_reachability_checks: 2,
              discarded_dormant_deliveries: 2
            }} = ScheduleReachabilityWorker.perform(%Oban.Job{})

    assert %Oban.Job{state: "discarded", discarded_at: %DateTime{}} =
             Repo.get(Oban.Job, dormant_job.id)

    assert %Oban.Job{state: "discarded", discarded_at: %DateTime{}} =
             Repo.get(Oban.Job, legacy_dormant_job.id)

    assert %Oban.Job{state: "retryable", discarded_at: nil} = Repo.get(Oban.Job, active_job.id)
    assert %Oban.Job{state: "retryable", discarded_at: nil} = Repo.get(Oban.Job, wakeup_job.id)
    assert %Oban.Job{state: "retryable", discarded_at: nil} = Repo.get(Oban.Job, unrelated_job.id)

    assert reachability_job_exists?("dead.example")
    assert reachability_job_exists?("maybe-back.example")
  end

  test "does not schedule reachability checks while a host is still backed off" do
    Instances.set_unreachable("backed-off.example", Instances.reachability_datetime_threshold())
    Instances.record_failure("backed-off.example", :timeout, source: "test")

    assert 0 = ScheduleReachabilityWorker.schedule_reachability_checks()
    refute reachability_job_exists?("backed-off.example")
  end

  test "only discards incomplete publish_one jobs" do
    Instances.set_unreachable("dead.example", Instances.dormant_datetime_threshold())

    available_job = insert_delivery_job("https://dead.example/inbox", state: "available")
    scheduled_job = insert_delivery_job("https://dead.example/inbox", state: "scheduled")
    completed_job = insert_delivery_job("https://dead.example/inbox", state: "completed")

    publish_job =
      PublisherWorker.new(%{"op" => "publish", "activity_id" => "123"})
      |> insert_job(state: "retryable")

    assert 2 = ScheduleReachabilityWorker.discard_dormant_delivery_jobs()

    assert %Oban.Job{state: "discarded"} = Repo.get(Oban.Job, available_job.id)
    assert %Oban.Job{state: "discarded"} = Repo.get(Oban.Job, scheduled_job.id)
    assert %Oban.Job{state: "completed"} = Repo.get(Oban.Job, completed_job.id)
    assert %Oban.Job{state: "retryable"} = Repo.get(Oban.Job, publish_job.id)
  end

  test "does nothing when no dormant hosts have queued deliveries" do
    Instances.set_unreachable(
      "recently-down.example",
      Instances.reachability_datetime_threshold()
    )

    delivery_job = insert_delivery_job("https://recently-down.example/inbox", state: "retryable")

    assert 0 = ScheduleReachabilityWorker.discard_dormant_delivery_jobs()
    assert %Oban.Job{state: "retryable", discarded_at: nil} = Repo.get(Oban.Job, delivery_job.id)
  end

  defp insert_delivery_job(inbox, opts) do
    state = Keyword.fetch!(opts, :state)

    PublisherWorker.new(%{
      "op" => "publish_one",
      "module" => "Elixir.Pleroma.Web.ActivityPub.Publisher",
      "params" => %{
        "inbox" => inbox,
        "json" => "{}",
        "id" => "https://local.example/activity"
      }
    })
    |> insert_job(state: state)
  end

  defp insert_legacy_delivery_job(inbox, opts) do
    state = Keyword.fetch!(opts, :state)

    PublisherWorker.new(%{
      "op" => "publish_one",
      "module" => "Elixir.Pleroma.Web.ActivityPub.Publisher",
      "inbox" => inbox,
      "json" => "{}",
      "id" => "https://local.example/activity"
    })
    |> insert_job(state: state)
  end

  defp insert_job(changeset, opts) do
    state = Keyword.fetch!(opts, :state)

    {:ok, job} =
      changeset
      |> Ecto.Changeset.put_change(:state, state)
      |> Oban.insert()

    job
  end

  defp reachability_job_exists?(domain) do
    Repo.exists?(
      from(job in Oban.Job,
        where: job.worker == "Pleroma.Workers.ReachabilityWorker",
        where: fragment("?->>'domain' = ?", job.args, ^domain)
      )
    )
  end
end
