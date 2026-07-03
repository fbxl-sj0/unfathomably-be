# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.RemoteFetcherWorker do
  alias Pleroma.Config
  alias Pleroma.Object.Fetcher
  alias Pleroma.Web.ActivityPub.RemoteReplies

  use Pleroma.Workers.WorkerHelper, queue: "remote_fetcher"

  @default_timeout_ms 30_000
  @terminal_http_statuses [400, 401, 403, 404, 405, 406, 410, 501]

  @impl Oban.Worker
  def perform(%Job{args: %{"op" => "fetch_remote", "id" => id}})
      when not is_binary(id) or byte_size(id) == 0 do
    {:cancel, :bad_request}
  end

  def perform(%Job{args: %{"op" => "fetch_remote", "id" => id} = args}) do
    case fetch_object(id, args) do
      {:ok, _object} ->
        :ok

      {:reject, reason} ->
        {:cancel, reason}

      {:error, :unreachable_host} ->
        {:cancel, :unreachable_host}

      {:error, {:http, code}} when code in @terminal_http_statuses ->
        {:cancel, http_cancel_reason(code)}

      {:error, {:content_type, _} = reason} ->
        {:cancel, reason}

      {:error, {:transmogrifier, {:error, reason}}}
      when reason in [:actor_not_found, :object_not_found] ->
        {:cancel, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def perform(%Job{args: %{"op" => "fetch_remote"}}), do: {:cancel, :bad_request}

  def perform(%Job{}), do: {:cancel, :bad_request}

  @impl Oban.Worker
  def timeout(_job), do: timeout_ms()

  defp fetch_object(id, %{"thread" => true} = args) do
    RemoteReplies.fetch_thread_from_reply(id, depth: args["depth"])
  end

  defp fetch_object(id, args) do
    Fetcher.fetch_object_from_id(id, depth: args["depth"])
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
