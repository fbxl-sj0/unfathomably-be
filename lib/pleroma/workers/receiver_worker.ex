# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.ReceiverWorker do
  alias Pleroma.Config
  alias Pleroma.Web.Federation.Churn
  alias Pleroma.Web.Federator
  alias Pleroma.Workers.SignatureRetryWorker

  use Pleroma.Workers.WorkerHelper, queue: "federator_incoming"

  @impl Oban.Worker
  def perform(%Job{args: %{"op" => "incoming_ap_doc", "params" => params} = args} = job)
      when not is_map(params) do
    if signature_retry_job?(args) do
      perform_signature_retry(job)
    else
      process_errors(:missing_incoming_ap_doc_params)
    end
  end

  def perform(%Job{args: %{"op" => "incoming_ap_doc", "params" => params} = args} = job) do
    if signature_retry_job?(args) do
      perform_signature_retry(job)
    else
      perform_incoming(params)
    end
  end

  def perform(%Job{args: %{"op" => "incoming_ap_doc"} = args} = job) do
    if signature_retry_job?(args) do
      perform_signature_retry(job)
    else
      process_errors(:missing_incoming_ap_doc_params)
    end
  end

  def perform(%Job{}), do: process_errors(:missing_incoming_ap_doc_params)

  defp perform_signature_retry(%Job{args: args} = job) do
    SignatureRetryWorker.perform(%Job{
      job
      | args: Map.put(args, "op", "incoming_failed_signature_ap_doc")
    })
  end

  defp perform_incoming(params) do
    with {:ok, res} <- Federator.perform(:incoming_ap_doc, params) do
      {:ok, res}
    else
      e -> process_errors(e)
    end
  end

  defp signature_retry_job?(args) do
    Enum.any?(~w(method req_headers request_path query_string), &Map.has_key?(args, &1))
  end

  @impl Oban.Worker
  def timeout(%_{args: %{"timeout" => timeout}}) when is_integer(timeout) and timeout > 0,
    do: timeout

  def timeout(_job), do: configured_timeout()

  defp configured_timeout do
    case Config.get([__MODULE__, :timeout_ms], :timer.seconds(90)) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> :timer.seconds(90)
    end
  end

  defp process_errors({:error, {:transmogrifier, {:error, reason}}}),
    do: process_errors({:error, reason})

  defp process_errors({:error, {:transmogrifier, reason}}), do: process_errors({:error, reason})

  defp process_errors({:error, {:error, _} = error}), do: process_errors(error)

  defp process_errors(errors) do
    case Churn.mark_deactivated_actor(errors) do
      {:ok, actor_id} ->
        {:cancel, {:remote_actor_deactivated, actor_id}}

      :noop ->
        process_unclassified_errors(errors)
    end
  end

  defp process_unclassified_errors(errors) do
    case errors do
      {:error, :not_found} = reason ->
        {:cancel, reason}

      {:error, :forbidden} = reason ->
        {:cancel, reason}

      {:error, {:user_active, false} = reason} ->
        {:cancel, reason}

      {:error, {:validate, {:error, %Ecto.Changeset{} = changeset}}} ->
        process_validation_changeset(changeset)

      {:error, %Ecto.Changeset{} = changeset} ->
        process_validation_changeset(changeset)

      {:error, :origin_containment_failed} ->
        {:cancel, :origin_containment_failed}

      {:error, :already_present} ->
        {:ok, :already_present}

      {:error, {:http, status}} when status in [400, 401, 403, 404, 405, 406, 410, 501] ->
        {:cancel, {:http, status}}

      {:error, {:content_type, _} = reason} ->
        {:cancel, reason}

      {:error, {:unsupported_activity_type, _} = reason} ->
        {:cancel, reason}

      {:error, {:validate_object, reason}} ->
        {:cancel, reason}

      {:error, {:validate, reason}} ->
        {:cancel, reason}

      {:error, {:reject, reason}} ->
        {:cancel, reason}

      {:signature, false} ->
        {:cancel, :invalid_signature}

      {:same_actor, false} ->
        {:cancel, :actor_signature_mismatch}

      {:error, reason = "Object has been deleted"} ->
        {:cancel, reason}

      {:error, {:side_effects, {:error, :no_object_actor}} = reason} ->
        {:cancel, reason}

      {:error, {:side_effects, {:error, :pinned_statuses_limit_reached}} = reason} ->
        {:cancel, reason}

      :missing_incoming_ap_doc_params ->
        {:cancel, :missing_incoming_ap_doc_params}

      :error ->
        {:cancel, :error}

      {:error, :error} ->
        {:cancel, :error}

      {:error, _} = e ->
        e

      e ->
        {:error, e}
    end
  end

  defp process_validation_changeset(%Ecto.Changeset{} = changeset) do
    if duplicate_like_changeset?(changeset) do
      {:ok, :already_present}
    else
      {:cancel, {:error, changeset}}
    end
  end

  defp duplicate_like_changeset?(%Ecto.Changeset{errors: errors}) do
    MapSet.new(errors) ==
      MapSet.new([
        actor: {"already liked this object", []},
        object: {"already liked by this actor", []}
      ])
  end
end
