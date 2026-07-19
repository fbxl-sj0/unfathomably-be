# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.UserRefreshWorker do
  @moduledoc """
  Refreshes stale remote actors without blocking request or render paths.
  """

  use Pleroma.Workers.WorkerHelper,
    queue: "background",
    max_attempts: 3,
    unique: [
      period: 300,
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
      keys: [:op, :ap_id]
    ]

  alias Pleroma.User

  @terminal_http_statuses [400, 401, 403, 404, 405, 406, 410, 501]
  @terminal_refresh_errors [:forbidden, :not_found, :unreachable_host, "Object has been deleted"]

  @impl Oban.Worker
  def perform(%Job{args: %{"op" => "refresh", "ap_id" => ap_id}})
      when is_binary(ap_id) and byte_size(ap_id) > 0 do
    case User.fetch_by_ap_id(ap_id) do
      {:ok, %User{}} -> :ok
      {:error, reason} when reason in @terminal_refresh_errors -> {:cancel, reason}
      {:error, {:http, status} = reason} when status in @terminal_http_statuses ->
        {:cancel, reason}

      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  def perform(%Job{}), do: {:cancel, :bad_request}

  @impl Oban.Worker
  def backoff(%Job{attempt: attempt}), do: min(300, 60 * max(attempt, 1))

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(15)
end
