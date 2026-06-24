# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.RemoteFetcherWorker do
  alias Pleroma.Object.Fetcher

  use Pleroma.Workers.WorkerHelper, queue: "remote_fetcher"

  @impl Oban.Worker
  def perform(%Job{args: %{"op" => "fetch_remote", "id" => id} = args}) do
    case Fetcher.fetch_object_from_id(id, depth: args["depth"]) do
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
  def timeout(_job), do: :timer.seconds(10)
end
