# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.RemoteFetcherWorker do
  require Logger

  alias Pleroma.ATProto.BridgyCompat
  alias Pleroma.AutomatedSourcePacer
  alias Pleroma.Config
  alias Pleroma.Nostr.MostrCompat
  alias Pleroma.Object
  alias Pleroma.Object.Fetcher
  alias Pleroma.QuoteHydration
  alias Pleroma.Web.ActivityPub.RemoteReplies
  alias Pleroma.Web.Federation.Churn

  use Pleroma.Workers.WorkerHelper,
    queue: "remote_fetcher",
    max_attempts: 3,
    unique: [
      period: :infinity,
      states: [
        :available,
        :scheduled,
        :executing,
        :retryable,
        :suspended,
        :completed,
        :cancelled,
        :discarded
      ],
      keys: [:op, :id, :thread]
    ]

  @default_timeout_ms 30_000
  @terminal_http_statuses [400, 401, 403, 404, 405, 406, 410, 501]
  @retry_limited_transport_errors [
    :closed,
    :connect_timeout,
    :econnrefused,
    :ehostunreach,
    :enetunreach,
    :nxdomain,
    :recv_response_timeout,
    :timeout
  ]

  @impl Oban.Worker
  def perform(%Job{} = job) do
    if Pleroma.Federation.enabled?(),
      do: perform_enabled(job),
      else: {:cancel, :federation_disabled}
  end

  defp perform_enabled(%Job{args: %{"op" => "fetch_remote", "id" => id}})
       when not is_binary(id) or byte_size(id) == 0 do
    {:cancel, :bad_request}
  end

  defp perform_enabled(
         %Job{args: %{"op" => "fetch_remote", "id" => id, "source" => "fedibuzz"} = args} =
           job
       ) do
    case AutomatedSourcePacer.reserve({:fedibuzz, remote_host(id)}, fedibuzz_interval_ms()) do
      :ok -> perform_enabled(%{job | args: Map.delete(args, "source")})
      {:wait, wait_ms} -> {:snooze, max(div(wait_ms + 999, 1_000), 1)}
    end
  end

  defp perform_enabled(%Job{args: %{"op" => "fetch_quote", "id" => id}})
       when not is_binary(id) or byte_size(id) == 0 do
    {:cancel, :bad_request}
  end

  defp perform_enabled(%Job{args: %{"op" => "fetch_quote", "id" => id} = args} = job) do
    result = fetch_object(id, args)

    case process_fetch_result(result, job) do
      :ok -> QuoteHydration.reconcile(id)
      other -> other
    end
  end

  defp perform_enabled(%Job{args: %{"op" => "fetch_remote", "id" => id} = args} = job) do
    result = fetch_object(id, args)

    case Churn.mark_deactivated_actor(result) do
      {:ok, actor_id} ->
        {:cancel, {:remote_actor_deactivated, actor_id}}

      :noop ->
        process_fetch_result(result, job)
    end
  end

  defp perform_enabled(%Job{args: %{"op" => "fetch_remote"}}), do: {:cancel, :bad_request}

  defp perform_enabled(%Job{}), do: {:cancel, :bad_request}

  defp process_fetch_result(result, job) do
    case result do
      {:ok, _object} ->
        :ok

      %Object{} ->
        :ok

      {:reject, reason} ->
        {:cancel, reason}

      {:error, :unreachable_host} ->
        {:cancel, :unreachable_host}

      {:error, reason}
      when reason in @retry_limited_transport_errors and job.attempt >= job.max_attempts ->
        {:cancel, {:transport_retries_exhausted, reason}}

      {:error, {:http, code}} when code in @terminal_http_statuses ->
        {:cancel, http_cancel_reason(code)}

      {:error, {:content_type, _content_type} = reason} ->
        {:cancel, reason}

      {:error, %Jason.DecodeError{} = reason} ->
        {:cancel, reason}

      {:error, reason}
      when reason in [
             :allowed_depth,
             :collection_origin_mismatch,
             :final_response_origin_mismatch,
             :forbidden,
             :native_atproto_disabled,
             :native_atproto_lookup_failed,
             :native_atproto_not_found,
             :native_atproto_projection_failed,
             :native_nostr_disabled,
             :native_nostr_lookup_failed,
             :native_nostr_not_found,
             :not_found,
             :object_identifier_mismatch,
             :object_origin_mismatch,
             :private_network_address,
             "Object has been deleted"
           ] ->
        {:cancel, reason}

      {:error, {:transmogrifier, {:error, reason}}}
      when reason in [:actor_not_found, :object_not_found] ->
        {:cancel, reason}

      {:error, {:transmogrifier, {:error, {:validate, {:error, %Ecto.Changeset{} = changeset}}}}} ->
        Logger.warning(
          "Remote ActivityPub object validation failed for #{get_in(job.args, ["id"])}: " <>
            inspect(changeset.errors)
        )

        {:cancel, :remote_object_validation_failed}

      {:error, reason} ->
        {:error, reason}

      result ->
        {:error, result}
    end
  end

  @impl Oban.Worker
  def backoff(%Job{attempt: attempt}), do: min(300, 60 * max(attempt, 1))

  @impl Oban.Worker
  def timeout(_job), do: timeout_ms()

  defp fetch_object(id, %{"thread" => true} = args) do
    case fetch_native_bridge_object(id) do
      {:ok, %Object{} = object} ->
        {:ok, object}

      result when result in [:miss, :not_applicable] ->
        RemoteReplies.fetch_thread_from_reply(id, depth: args["depth"])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_object(id, args) do
    case fetch_native_bridge_object(id) do
      {:ok, %Object{} = object} ->
        {:ok, object}

      result when result in [:miss, :not_applicable] ->
        Fetcher.fetch_object_from_id(id, fetch_options(args))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_options(%{"op" => "fetch_quote", "depth" => depth}) do
    [depth: depth, allow_orphaned_public_reply: true]
  end

  defp fetch_options(%{"depth" => depth}), do: [depth: depth]
  defp fetch_options(_args), do: []

  defp fetch_native_bridge_object(id) do
    case BridgyCompat.fetch_native_object(id) do
      result when result in [:miss, :not_applicable] -> MostrCompat.fetch_native_object(id)
      result -> result
    end
  end

  defp remote_host(id) do
    case URI.parse(id) do
      %URI{host: host} when is_binary(host) -> String.downcase(host)
      _invalid -> id
    end
  end

  defp fedibuzz_interval_ms do
    case Config.get([Pleroma.Web.ActivityPub.FediBuzzConnector, :min_host_interval_ms], 1_000) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> 1_000
    end
  end

  defp timeout_ms do
    case Config.get([__MODULE__, :timeout_ms], @default_timeout_ms) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_timeout_ms(value)
      _ -> @default_timeout_ms
    end
    |> max(1_000)
  end

  defp parse_timeout_ms(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> @default_timeout_ms
    end
  end

  defp http_cancel_reason(400), do: :bad_request
  defp http_cancel_reason(code) when code in [401, 403], do: :forbidden
  defp http_cancel_reason(code) when code in [404, 410], do: :not_found
  defp http_cancel_reason(405), do: :method_not_allowed
  defp http_cancel_reason(406), do: :not_acceptable
  defp http_cancel_reason(501), do: :not_implemented
end
