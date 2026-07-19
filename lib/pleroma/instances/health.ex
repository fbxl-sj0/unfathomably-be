# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Instances.Health do
  @moduledoc """
  Read-only federation delivery and remote instance health summaries.

  The admin UI uses this module to show the current delivery queues and
  unreachable remote hosts without giving the UI direct knowledge of Oban's
  internal tables. All values returned here are summaries or short samples so
  this endpoint remains cheap even on a busy instance.
  """

  import Ecto.Query

  alias Pleroma.Instances
  alias Pleroma.Instances.Instance
  alias Pleroma.Repo

  @pending_delivery_states ["available", "scheduled", "retryable"]
  @publisher_worker "Pleroma.Workers.PublisherWorker"

  def snapshot(opts \\ []) do
    limit = Keyword.get(opts, :limit, 25)

    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      instances: instance_summary(),
      queues: queue_summary(),
      outgoing: outgoing_summary(),
      unreachable_instances: unreachable_instances(limit)
    }
  end

  defp instance_summary do
    total = Repo.aggregate(Instance, :count, :id)
    unreachable = instance_count(where_unreachable())
    consistently_unreachable = instance_count(where_consistently_unreachable())
    dormant = instance_count(where_dormant())

    %{
      total: total,
      reachable: max(total - consistently_unreachable, 0),
      unreachable: unreachable,
      consistently_unreachable: consistently_unreachable,
      dormant: dormant
    }
  end

  defp queue_summary do
    rows =
      Oban.Job
      |> group_by([job], [job.queue, job.state])
      |> select([job], %{
        queue: job.queue,
        state: job.state,
        count: count(job.id),
        oldest_scheduled_at: min(job.scheduled_at)
      })
      |> Repo.all()

    rows
    |> Enum.group_by(& &1.queue)
    |> Enum.map(fn {queue, rows} ->
      states =
        rows
        |> Enum.map(fn row ->
          %{
            state: row.state,
            count: row.count,
            oldest_scheduled_at: iso8601(row.oldest_scheduled_at)
          }
        end)
        |> Enum.sort_by(& &1.state)

      %{
        name: queue,
        total: Enum.sum(Enum.map(states, & &1.count)),
        states: states
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp outgoing_summary do
    pending_query = pending_delivery_query()
    blocked_query = blocked_delivery_query()
    dormant_query = blocked_delivery_query(where_dormant: true)

    %{
      pending: count_jobs(pending_query),
      blocked_by_unreachable: count_jobs(blocked_query),
      blocked_by_dormant: count_jobs(dormant_query),
      oldest_pending_scheduled_at: oldest_scheduled_at(pending_query)
    }
  end

  defp unreachable_instances(limit) do
    Instance
    |> where_unreachable()
    |> order_by([instance], asc: instance.unreachable_since)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&instance_entry/1)
  end

  defp instance_entry(%Instance{} = instance) do
    %{
      host: instance.host,
      unreachable_since: iso8601(instance.unreachable_since),
      dormant: dormant_instance?(instance),
      software_name: metadata_value(instance, :software_name),
      software_version: metadata_value(instance, :software_version),
      last_status: metadata_value(instance, :last_status),
      failure_count: metadata_value(instance, :failure_count) || 0,
      last_failure_at: iso8601(metadata_value(instance, :last_failure_at)),
      last_failure_reason: metadata_value(instance, :last_failure_reason),
      last_success_at: iso8601(metadata_value(instance, :last_success_at)),
      backoff_until: iso8601(metadata_value(instance, :backoff_until)),
      probe_due: Instance.backoff_due?(instance),
      redirect_target: metadata_value(instance, :redirect_target),
      gone_at: iso8601(metadata_value(instance, :gone_at)),
      delivery_endpoints: metadata_value(instance, :delivery_endpoints) || []
    }
  end

  defp metadata_value(%Instance{metadata: nil}, _key), do: nil
  defp metadata_value(%Instance{metadata: metadata}, key), do: Map.get(metadata, key)

  defp dormant_instance?(%Instance{unreachable_since: nil}), do: false

  defp dormant_instance?(%Instance{unreachable_since: unreachable_since}) do
    NaiveDateTime.compare(unreachable_since, Instances.dormant_datetime_threshold()) != :gt
  end

  defp pending_delivery_query do
    Oban.Job
    |> where([job], job.queue == "federator_outgoing")
    |> where([job], job.worker == @publisher_worker)
    |> where([job], job.state in ^@pending_delivery_states)
    |> where([job], job.args["op"] == "publish_one")
  end

  defp blocked_delivery_query(opts \\ []) do
    where_dormant? = Keyword.get(opts, :where_dormant, false)

    query =
      pending_delivery_query()
      |> join(:inner, [job], instance in Instance,
        on:
          fragment(
            "lower(?) = ap_id_host(? #>> '{params,inbox}')",
            instance.host,
            job.args
          )
      )
      |> where([job, instance], not is_nil(instance.unreachable_since))

    if where_dormant? do
      where(
        query,
        [job, instance],
        instance.unreachable_since <= ^Instances.dormant_datetime_threshold()
      )
    else
      query
    end
  end

  defp count_jobs(query) do
    Repo.aggregate(query, :count, :id)
  end

  defp oldest_scheduled_at(query) do
    query
    |> select([job], min(job.scheduled_at))
    |> Repo.one()
    |> iso8601()
  end

  defp instance_count(query) do
    Repo.aggregate(query, :count, :id)
  end

  defp where_unreachable(query \\ Instance) do
    where(query, [instance], not is_nil(instance.unreachable_since))
  end

  defp where_consistently_unreachable(query \\ Instance) do
    where(
      query,
      [instance],
      not is_nil(instance.unreachable_since) and
        instance.unreachable_since <= ^Instances.reachability_datetime_threshold()
    )
  end

  defp where_dormant(query \\ Instance) do
    where(
      query,
      [instance],
      not is_nil(instance.unreachable_since) and
        instance.unreachable_since <= ^Instances.dormant_datetime_threshold()
    )
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)
end
