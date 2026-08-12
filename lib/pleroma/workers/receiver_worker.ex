# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.ReceiverWorker do
  import Ecto.Query, only: [from: 2]

  alias Pleroma.Config
  alias Pleroma.Repo
  alias Pleroma.Web.ActivityPub.BatchedAnnounce
  alias Pleroma.Web.Federation.Churn
  alias Pleroma.Web.Federator
  alias Pleroma.Workers.SignatureRetryWorker
  alias Pleroma.Workers.WorkerHelper

  @transport_retry_limit 3
  @remote_object_retry_limit 3
  @native_nostr_retry_limit 3
  @queued_create_retry_seconds 5
  @incomplete_job_states ~w(available scheduled executing retryable suspended)
  @terminal_certificate_errors [:bad_certificate, :certificate_expired, :unknown_ca]
  @terminal_side_effect_errors [
    :no_object_actor,
    :pinned_statuses_limit_reached
  ]
  @retry_limited_transport_errors [
    :closed,
    :connect_timeout,
    :econnrefused,
    :ehostunreach,
    :handshake_failure,
    :enetunreach,
    :nxdomain,
    :recv_response_timeout,
    :timeout,
    :unreachable_host
  ]

  use Pleroma.Workers.WorkerHelper,
    queue: "federator_incoming",
    unique: [
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable, :suspended],
      keys: [:op, :activity_key]
    ]

  @impl Oban.Worker
  def perform(%Job{} = job) do
    if Pleroma.Federation.enabled?(),
      do: perform_enabled(job),
      else: {:cancel, :federation_disabled}
  end

  defp perform_enabled(%Job{args: %{"op" => "incoming_ap_doc", "params" => params} = args} = job)
       when not is_map(params) do
    if signature_retry_job?(args) do
      perform_signature_retry(job)
    else
      process_errors(:missing_incoming_ap_doc_params, job)
    end
  end

  defp perform_enabled(%Job{args: %{"op" => "incoming_ap_doc", "params" => params} = args} = job) do
    if signature_retry_job?(args) do
      perform_signature_retry(job)
    else
      perform_incoming(job, params)
    end
  end

  defp perform_enabled(%Job{args: %{"op" => "incoming_ap_doc"} = args} = job) do
    if signature_retry_job?(args) do
      perform_signature_retry(job)
    else
      process_errors(:missing_incoming_ap_doc_params, job)
    end
  end

  defp perform_enabled(%Job{} = job), do: process_errors(:missing_incoming_ap_doc_params, job)

  defp perform_signature_retry(%Job{args: args} = job) do
    SignatureRetryWorker.perform(%Job{
      job
      | args: Map.put(args, "op", "incoming_failed_signature_ap_doc")
    })
  end

  defp perform_incoming(
         %Job{} = job,
         %{"type" => "Announce", "object" => objects} = params
       )
       when is_list(objects) do
    with {:ok, activities} <- BatchedAnnounce.expand(params),
         {:ok, results} <- perform_incoming_batch(activities) do
      {:ok, results}
    else
      error -> process_errors(error, job)
    end
  end

  defp perform_incoming(%Job{} = job, params) do
    with {:ok, res} <- Federator.perform(:incoming_ap_doc, params) do
      {:ok, res}
    else
      e -> process_errors(e, job)
    end
  end

  defp perform_incoming_batch(activities) do
    {results, errors} =
      Enum.reduce(activities, {[], []}, fn activity, {results, errors} ->
        case Federator.perform(:incoming_ap_doc, activity) do
          {:ok, result} -> {[result | results], errors}
          error -> {results, [error | errors]}
        end
      end)

    case errors do
      [] -> {:ok, Enum.reverse(results)}
      [error | _rest] -> error
    end
  end

  defp signature_retry_job?(args) do
    # Older failed-signature jobs used ReceiverWorker and can still exist in
    # long-lived Oban tables after an upgrade. A complete request envelope
    # identifies those jobs. Normal verified deliveries may also preserve
    # selected transport metadata, so one header-related key is not enough to
    # safely redirect an otherwise valid activity into signature recovery.
    Enum.all?(~w(method req_headers request_path query_string), &Map.has_key?(args, &1))
  end

  @impl Oban.Worker
  def timeout(%_{args: %{"timeout" => timeout}}) when is_integer(timeout) and timeout > 0,
    do: timeout

  def timeout(_job), do: configured_timeout()

  @impl Oban.Worker
  def backoff(%Job{
        attempt: attempt,
        args: %{
          "params" => %{"type" => "Announce", "object" => object_id}
        }
      })
      when is_binary(object_id) do
    if pending_incoming_create?(object_id) do
      min(@queued_create_retry_seconds * max(attempt, 1), 30)
    else
      default_backoff(attempt)
    end
  end

  def backoff(%Job{attempt: attempt}) do
    default_backoff(attempt)
  end

  defp default_backoff(attempt) do
    attempt
    |> WorkerHelper.sidekiq_backoff()
    |> max(5 * 60)
    |> min(6 * 60 * 60)
  end

  defp pending_incoming_create?(object_id) do
    worker = inspect(__MODULE__)

    query =
      from(job in Oban.Job,
        where: job.worker == ^worker,
        where: job.state in ^@incomplete_job_states,
        where: fragment("?->>'op' = 'incoming_ap_doc'", job.args),
        where: fragment("?->'params'->>'type' = 'Create'", job.args),
        where:
          fragment(
            "(?->'params'->'object'->>'id' = ? OR ?->'params'->>'object' = ?)",
            job.args,
            ^object_id,
            job.args,
            ^object_id
          )
      )

    Repo.exists?(query)
  end

  defp configured_timeout do
    case Config.get([__MODULE__, :timeout_ms], :timer.seconds(90)) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> :timer.seconds(90)
    end
  end

  defp process_errors({:error, {:transmogrifier, {:error, reason}}}, job),
    do: process_errors({:error, reason}, job)

  defp process_errors({:error, {:transmogrifier, reason}}, job),
    do: process_errors({:error, reason}, job)

  defp process_errors({:error, {:error, _} = error}, job), do: process_errors(error, job)

  defp process_errors(errors, job) do
    case Churn.mark_deactivated_actor(errors) do
      {:ok, actor_id} ->
        {:cancel, {:remote_actor_deactivated, actor_id}}

      :noop ->
        process_unclassified_errors(errors, job)
    end
  end

  defp process_unclassified_errors(errors, job) do
    cond do
      terminal_certificate_error?(errors) ->
        {:cancel, {:terminal_transport_error, errors}}

      retry_limited_transport_error?(errors) and transport_retries_exhausted?(job) ->
        {:cancel, {:transport_retries_exhausted, errors}}

      terminal_native_nostr_error?(errors) ->
        {:cancel, {:terminal_native_nostr_error, errors}}

      native_nostr_retries_exhausted?(errors, job) ->
        {:cancel, {:native_nostr_retries_exhausted, errors}}

      remote_object_retries_exhausted?(errors, job) ->
        {:cancel, {:remote_object_retries_exhausted, errors}}

      true ->
        classify_processing_error(errors)
    end
  end

  defp classify_processing_error(errors) do
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

      {:error, :invalid_batched_announce} ->
        {:cancel, :invalid_batched_announce}

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

      {:error, {:side_effects, {:error, side_effect_error}} = reason}
      when side_effect_error in @terminal_side_effect_errors ->
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

  defp transport_retries_exhausted?(%Job{attempt: attempt}),
    do: attempt >= @transport_retry_limit

  defp transport_retries_exhausted?(_), do: false

  defp remote_object_retries_exhausted?(
         {:error, :remote_object_unavailable},
         %Job{attempt: attempt}
       ),
       do: attempt >= @remote_object_retry_limit

  defp remote_object_retries_exhausted?(_, _), do: false

  defp native_nostr_retries_exhausted?(errors, %Job{attempt: attempt}),
    do: attempt >= @native_nostr_retry_limit and native_nostr_retry_error?(errors)

  defp native_nostr_retries_exhausted?(_, _), do: false

  defp native_nostr_retry_error?(reason)
       when reason in [:native_nostr_not_found, :native_nostr_lookup_failed],
       do: true

  defp native_nostr_retry_error?(reason) when is_tuple(reason),
    do: reason |> Tuple.to_list() |> Enum.any?(&native_nostr_retry_error?/1)

  defp native_nostr_retry_error?(reason) when is_list(reason),
    do: Enum.any?(reason, &native_nostr_retry_error?/1)

  defp native_nostr_retry_error?(_), do: false

  defp terminal_native_nostr_error?(reason)
       when reason in [:native_nostr_disabled, :native_nostr_required],
       do: true

  defp terminal_native_nostr_error?(reason) when is_tuple(reason),
    do: reason |> Tuple.to_list() |> Enum.any?(&terminal_native_nostr_error?/1)

  defp terminal_native_nostr_error?(reason) when is_list(reason),
    do: Enum.any?(reason, &terminal_native_nostr_error?/1)

  defp terminal_native_nostr_error?(_), do: false

  defp retry_limited_transport_error?({:error, reason}),
    do: retry_limited_transport_error?(reason)

  defp retry_limited_transport_error?({:tls_alert, {reason, _}})
       when reason in @retry_limited_transport_errors,
       do: true

  defp retry_limited_transport_error?({_, reason}),
    do: retry_limited_transport_error?(reason)

  defp retry_limited_transport_error?(reason),
    do: reason in @retry_limited_transport_errors

  defp terminal_certificate_error?({:error, reason}), do: terminal_certificate_error?(reason)

  defp terminal_certificate_error?({:tls_alert, {reason, _}})
       when reason in @terminal_certificate_errors,
       do: true

  defp terminal_certificate_error?({reason, _}) when reason in @terminal_certificate_errors,
    do: true

  defp terminal_certificate_error?({_, reason}), do: terminal_certificate_error?(reason)
  defp terminal_certificate_error?(_), do: false

  defp process_validation_changeset(%Ecto.Changeset{} = changeset) do
    if duplicate_like_changeset?(changeset) do
      {:ok, :already_present}
    else
      {:cancel, {:error, changeset}}
    end
  end

  defp duplicate_like_changeset?(%Ecto.Changeset{errors: errors}) do
    MapSet.new(errors) ==
      MapSet.new(
        actor: {"already liked this object", []},
        object: {"already liked by this actor", []}
      )
  end
end
