# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.PublisherWorker do
  alias Pleroma.Activity
  alias Pleroma.ATProto.BridgyCompat
  alias Pleroma.Instances
  alias Pleroma.Nostr.MostrCompat
  alias Pleroma.Web.Federator

  use Pleroma.Workers.WorkerHelper, queue: "federator_outgoing"

  @max_backoff_seconds 24 * 60 * 60
  @delivery_backoff_jitter_seconds 5 * 60

  def backoff(%Job{attempt: attempt}) when is_integer(attempt) do
    attempt
    |> Pleroma.Workers.WorkerHelper.sidekiq_backoff(5)
    |> min(@max_backoff_seconds)
  end

  @impl Oban.Worker
  def perform(%Job{} = job) do
    if Pleroma.Federation.enabled?(),
      do: perform_enabled(job),
      else: {:cancel, :federation_disabled}
  end

  defp perform_enabled(%Job{args: %{"op" => "publish", "activity_id" => activity_id} = args}) do
    case fetch_activity(activity_id) do
      {:ok, activity} ->
        activity = maybe_restore_activity_data(activity, args["activity_data"])

        Federator.perform(:publish, activity)

      {:cancel, _} = result ->
        result
    end
  end

  defp perform_enabled(
         %Job{args: %{"op" => "publish_one", "module" => module_name, "params" => params}} =
           job
       ) do
    with {:ok, module} <- existing_atom(module_name),
         {:ok, params} <- atomize_params(params),
         {:ok, params} <- validate_source_activity(params) do
      case validate_delivery_target(job, params) do
        {:ok, params} -> perform_publish_one(module, params)
        {:cancel, _} = result -> result
        {:snooze, _} = result -> result
      end
    else
      {:cancel, _} = result -> result
    end
  end

  defp perform_enabled(%Job{}), do: {:cancel, :bad_request}

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(10)

  defp validate_delivery_target(%Job{} = job, %{inbox: inbox} = params)
       when is_binary(inbox) do
    cond do
      MostrCompat.legacy_reference?(inbox) ->
        {:cancel, :native_nostr_required}

      BridgyCompat.legacy_reference?(inbox) and not bridge_retirement_delivery?(params) ->
        {:cancel, :native_atproto_required}

      Instances.dormant?(inbox) ->
        {:cancel, :dormant_instance}

      true ->
        case Instances.filter_reachable([inbox]) do
          %{^inbox => nil} ->
            {:ok, params}

          %{^inbox => _unreachable_since} ->
            snooze_for_delivery_backoff(job, inbox, params)

          %{} ->
            {:cancel, :unreachable_instance}
        end
    end
  end

  defp validate_delivery_target(_job, params), do: {:ok, params}

  # The migration sends one final Undo(Follow) so the bridge can stop fanout to
  # this instance. All ordinary traffic uses the native AT publisher instead.
  defp bridge_retirement_delivery?(%{json: json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"type" => "Undo", "object" => %{"type" => "Follow"}}} -> true
      _ -> false
    end
  end

  defp bridge_retirement_delivery?(_params), do: false

  defp validate_source_activity(%{id: id, json: json} = params)
       when is_binary(id) and is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"type" => "Create"}} ->
        # Recipient fanout inserts one job per inbox. A user can delete the
        # activity while that fanout is still running, after CommonAPI has
        # cancelled the jobs that already existed. Late jobs must therefore
        # verify the persisted source again immediately before delivery.
        case Activity.get_by_ap_id(id) do
          %Activity{} -> {:ok, params}
          nil -> {:cancel, :activity_not_found}
        end

      _ ->
        {:ok, params}
    end
  end

  defp validate_source_activity(params), do: {:ok, params}

  defp perform_publish_one(module, params) do
    case Federator.perform(:publish_one, module, params) do
      {:ok, _response} = result ->
        mark_successful_delivery(params)
        result

      result ->
        result
    end
  end

  defp mark_successful_delivery(%{id: id, json: json})
       when is_binary(id) and is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"type" => "Create"}} ->
        Activity.mark_federated(id)

      {:ok, %{"type" => "Update", "object" => %{"id" => object_id}}}
      when is_binary(object_id) ->
        Activity.mark_object_federated(object_id)

      {:ok, %{"type" => "Update", "object" => object_id}} when is_binary(object_id) ->
        Activity.mark_object_federated(object_id)

      _ ->
        :ok
    end
  end

  defp mark_successful_delivery(_params), do: :ok

  defp snooze_for_delivery_backoff(%Job{} = job, inbox, params) do
    case Instances.delivery_backoff_seconds(inbox) do
      seconds when seconds > 0 ->
        jitter = delivery_backoff_jitter(job)
        {:snooze, min(seconds + jitter, @max_backoff_seconds + @delivery_backoff_jitter_seconds)}

      _ ->
        {:ok, params}
    end
  end

  defp delivery_backoff_jitter(%Job{id: id}) when is_integer(id) do
    rem(id, @delivery_backoff_jitter_seconds)
  end

  defp delivery_backoff_jitter(_job), do: 0

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
