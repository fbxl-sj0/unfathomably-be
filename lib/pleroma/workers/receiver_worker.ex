# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.ReceiverWorker do
  alias Pleroma.Web.Federator
  alias Pleroma.Workers.SignatureRetryWorker

  use Pleroma.Workers.WorkerHelper, queue: "federator_incoming"

  @impl Oban.Worker
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
  def timeout(%_{args: %{"timeout" => timeout}}), do: timeout

  def timeout(_job), do: :timer.seconds(5)

  defp process_errors({:error, {:error, _} = error}), do: process_errors(error)

  defp process_errors(errors) do
    case errors do
      {:error, :not_found} = reason -> {:cancel, reason}
      {:error, :forbidden} = reason -> {:cancel, reason}
      {:error, {:user_active, false} = reason} -> {:cancel, reason}
      {:error, {:validate, {:error, _changeset} = reason}} -> {:cancel, reason}
      {:error, :origin_containment_failed} -> {:cancel, :origin_containment_failed}
      {:error, :already_present} -> {:cancel, :already_present}
      {:error, {:validate_object, reason}} -> {:cancel, reason}
      {:error, {:validate, reason}} -> {:cancel, reason}
      {:error, {:reject, reason}} -> {:cancel, reason}
      {:signature, false} -> {:cancel, :invalid_signature}
      {:same_actor, false} -> {:cancel, :actor_signature_mismatch}
      {:error, reason = "Object has been deleted"} -> {:cancel, reason}
      {:error, {:side_effects, {:error, :no_object_actor}} = reason} -> {:cancel, reason}
      :missing_incoming_ap_doc_params -> {:cancel, :missing_incoming_ap_doc_params}
      {:error, _} = e -> e
      e -> e
    end
  end
end
