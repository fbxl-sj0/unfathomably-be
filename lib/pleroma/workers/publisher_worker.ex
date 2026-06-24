# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.PublisherWorker do
  alias Pleroma.Activity
  alias Pleroma.Instances
  alias Pleroma.Web.Federator

  use Pleroma.Workers.WorkerHelper, queue: "federator_outgoing"

  def backoff(%Job{attempt: attempt}) when is_integer(attempt) do
    Pleroma.Workers.WorkerHelper.sidekiq_backoff(attempt, 5)
  end

  @impl Oban.Worker
  def perform(%Job{args: %{"op" => "publish", "activity_id" => activity_id} = args}) do
    case Activity.get_by_id(activity_id) do
      %Activity{} = activity ->
        activity = maybe_restore_activity_data(activity, args["activity_data"])
        Federator.perform(:publish, activity)

      nil ->
        {:cancel, :activity_not_found}
    end
  end

  def perform(%Job{args: %{"op" => "publish_one", "module" => module_name, "params" => params}}) do
    params = Map.new(params, fn {k, v} -> {String.to_atom(k), v} end)

    case validate_delivery_target(params) do
      {:ok, params} -> Federator.perform(:publish_one, String.to_atom(module_name), params)
      {:cancel, _} = result -> result
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(30)

  defp validate_delivery_target(%{inbox: inbox} = params) when is_binary(inbox) do
    if Instances.dormant?(inbox) do
      {:cancel, :dormant_instance}
    else
      {:ok, params}
    end
  end

  defp validate_delivery_target(params), do: {:ok, params}

  defp maybe_restore_activity_data(%Activity{} = activity, %{} = activity_data) do
    %{activity | data: activity_data}
  end

  defp maybe_restore_activity_data(activity, _), do: activity
end
