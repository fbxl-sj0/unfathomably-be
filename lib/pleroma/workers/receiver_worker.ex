# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.ReceiverWorker do
  alias Pleroma.Object.Fetcher
  alias Pleroma.Web.Federation.Churn
  alias Pleroma.Web.Federator
  alias Pleroma.Workers.RemoteFetcherWorker
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
      e -> process_errors(e, params)
    end
  end

  defp signature_retry_job?(args) do
    Enum.any?(~w(method req_headers request_path query_string), &Map.has_key?(args, &1))
  end

  @impl Oban.Worker
  def timeout(%_{args: %{"timeout" => timeout}}), do: timeout

  def timeout(_job), do: :timer.seconds(30)

  defp process_errors(errors, params \\ nil)

  defp process_errors({:error, {:transmogrifier, {:error, reason}}}, params),
    do: process_errors({:error, reason}, params)

  defp process_errors({:error, {:transmogrifier, reason}}, params),
    do: process_errors({:error, reason}, params)

  defp process_errors({:error, {:error, _} = error}, params), do: process_errors(error, params)

  defp process_errors(errors, params) do
    case Churn.mark_deactivated_actor(errors) do
      {:ok, actor_id} ->
        {:cancel, {:remote_actor_deactivated, actor_id}}

      :noop ->
        process_unclassified_errors(errors, params)
    end
  end

  defp process_unclassified_errors(errors, params) do
    case errors do
      {:error, :not_found} = reason ->
        {:cancel, reason}

      {:error, :forbidden} = reason ->
        {:cancel, reason}

      {:error, {:user_active, false} = reason} ->
        {:cancel, reason}

      {:error, {:validate, {:error, %Ecto.Changeset{} = changeset} = reason}} ->
        recover_missing_reference(changeset, params) || {:cancel, reason}

      {:error, %Ecto.Changeset{} = changeset} ->
        recover_missing_reference(changeset, params) || {:cancel, {:error, changeset}}

      {:error, :origin_containment_failed} ->
        {:cancel, :origin_containment_failed}

      {:error, :already_present} ->
        {:cancel, :already_present}

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

  defp recover_missing_reference(%Ecto.Changeset{} = changeset, params) do
    if missing_object_reference?(changeset) do
      case missing_reference_id(params) do
        id when is_binary(id) -> recover_missing_reference_id(id, changeset)
        _ -> {:error, changeset}
      end
    end
  end

  defp recover_missing_reference_id(id, changeset) do
    case Fetcher.fetch_object_from_id(id, depth: 1) do
      {:ok, _object} ->
        {:error, changeset}

      {:error, reason} when reason in [:not_found, :forbidden, "Object has been deleted"] ->
        {:cancel, {:missing_reference, id, reason}}

      {:error, {:http, status}} when status in [400, 401, 403, 404, 405, 406, 410, 501] ->
        {:cancel, {:missing_reference, id, {:http, status}}}

      _ ->
        RemoteFetcherWorker.enqueue("fetch_remote", %{"id" => id, "depth" => 1})
        {:error, changeset}
    end
  end

  defp missing_object_reference?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {field, {"can't find object", _}} when field in [:object, :target] -> true
      {field, {"can't find activity", _}} when field in [:object, :target] -> true
      _ -> false
    end)
  end

  defp missing_reference_id(%{
         "type" => "Announce",
         "object" => %{"type" => type, "object" => object}
       })
       when type in ["Like", "EmojiReact", "Dislike", "Delete", "Undo"] do
    object_id(object)
  end

  defp missing_reference_id(%{"object" => object}), do: object_id(object)
  defp missing_reference_id(_), do: nil

  defp object_id(%{"id" => id}) when is_binary(id), do: id
  defp object_id(id) when is_binary(id), do: id
  defp object_id(_), do: nil
end
