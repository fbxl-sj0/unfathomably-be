# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.RemoteFetcherWorker do
  alias Pleroma.Config
  alias Pleroma.Object.Fetcher
  alias Pleroma.Web.ActivityPub.RemoteReplies

  use Pleroma.Workers.WorkerHelper, queue: "remote_fetcher"

  @default_timeout_ms 30_000

  @impl Oban.Worker
  def perform(%Job{args: %{"op" => "fetch_remote", "id" => id} = args}) do
    case fetch_object(id, args) do
      {:ok, _object} ->
        :ok

      {:reject, reason} ->
        {:cancel, reason}

      {:error, {:http, code}} when code in [401, 403] ->
        {:cancel, :forbidden}

      {:error, {:http, code}} when code in [404, 410] ->
        {:cancel, :not_found}

      {:error, {:transmogrifier, {:error, reason}}}
      when reason in [:actor_not_found, :object_not_found] ->
        {:cancel, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

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
end
