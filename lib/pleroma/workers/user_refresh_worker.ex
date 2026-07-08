# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.UserRefreshWorker do
  @moduledoc """
  Refreshes stale remote actors without blocking request or render paths.
  """

  use Pleroma.Workers.WorkerHelper, queue: "background"

  alias Pleroma.User

  @impl Oban.Worker
  def perform(%Job{args: %{"op" => "refresh", "ap_id" => ap_id}})
      when is_binary(ap_id) and byte_size(ap_id) > 0 do
    case User.fetch_by_ap_id(ap_id) do
      {:ok, %User{}} -> :ok
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  def perform(%Job{}), do: {:cancel, :bad_request}

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(15)
end
