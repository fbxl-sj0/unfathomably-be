# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.PublisherWorker do
  alias Pleroma.Activity
  alias Pleroma.Instances
  alias Pleroma.Web.Federator

  use Pleroma.Workers.WorkerHelper, queue: "federator_outgoing"

  @max_backoff_seconds 24 * 60 * 60

  def backoff(%Job{attempt: attempt}) when is_integer(attempt) do
    attempt
    |> Pleroma.Workers.WorkerHelper.sidekiq_backoff(5)
    |> min(@max_backoff_seconds)
  end

  @impl Oban.Worker
  def perform(%Job{args: %{"op" => "publish", "activity_id" => activity_id} = args}) do
    case fetch_activity(activity_id) do
      {:ok, activity} ->
        activity = maybe_restore_activity_data(activity, args["activity_data"])

        Federator.perform(:publish, activity)

      {:cancel, _} = result ->
        result
    end
  end

  def perform(%Job{args: %{"op" => "publish_one", "module" => module_name, "params" => params}}) do
    with {:ok, module} <- existing_atom(module_name),
         {:ok, params} <- atomize_params(params) do
      case validate_delivery_target(params) do
        {:ok, params} -> Federator.perform(:publish_one, module, params)
        {:cancel, _} = result -> result
      end
    else
      {:cancel, _} = result -> result
    end
  end

  def perform(%Job{}), do: {:cancel, :invalid_params}

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(10)

  defp validate_delivery_target(%{inbox: inbox} = params) when is_binary(inbox) do
    if Instances.dormant?(inbox) do
      {:cancel, :dormant_instance}
    else
      {:ok, params}
    end
  end

  defp validate_delivery_target(params), do: {:ok, params}

  defp fetch_activity(activity_id) do
    case Activity.get_by_id(activity_id) do
      %Activity{} = activity -> {:ok, activity}
      nil -> {:cancel, :activity_not_found}
    end
  rescue
    Ecto.Query.CastError -> {:cancel, :invalid_activity_id}
    Ecto.CastError -> {:cancel, :invalid_activity_id}
  end

  defp existing_atom(value) when is_atom(value), do: {:ok, value}

  defp existing_atom(value) when is_binary(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> {:cancel, :unknown_atom}
  end

  defp existing_atom(_), do: {:cancel, :unknown_atom}

  defp atomize_params(params) when is_map(params) do
    {:ok, Map.new(params, fn {key, value} -> {existing_atom!(key), value} end)}
  rescue
    ArgumentError -> {:cancel, :unknown_param}
  end

  defp atomize_params(_), do: {:cancel, :invalid_params}

  defp existing_atom!(key) when is_atom(key), do: key
  defp existing_atom!(key) when is_binary(key), do: String.to_existing_atom(key)
  defp existing_atom!(_), do: raise(ArgumentError, "unknown parameter key")

  defp maybe_restore_activity_data(%Activity{} = activity, %{} = activity_data) do
    %{activity | data: activity_data}
  end

  defp maybe_restore_activity_data(activity, _), do: activity
end
