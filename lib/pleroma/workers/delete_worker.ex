# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.DeleteWorker do
  @moduledoc """
  Runs slow user and instance deletion work away from the normal background queue.
  """

  alias Pleroma.Instances.Instance
  alias Pleroma.User

  use Pleroma.Workers.WorkerHelper, queue: "slow"

  defguardp valid_job_id(id) when (is_binary(id) and byte_size(id) > 0) or is_integer(id)

  @impl Oban.Worker
  def perform(%Job{args: %{"op" => "delete_user", "user_id" => user_id}})
      when valid_job_id(user_id) do
    with %User{} = user <- get_cached_user(user_id) do
      User.perform(:delete, user)
    else
      nil -> {:cancel, :user_not_found}
    end
  end

  def perform(%Job{args: %{"op" => "delete_instance", "host" => host}})
      when is_binary(host) and byte_size(host) > 0 do
    Instance.perform(:delete_instance, host)
  end

  def perform(%Job{}), do: {:cancel, :bad_request}

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(900)

  defp get_cached_user(user_id) do
    User.get_cached_by_id(user_id)
  rescue
    _ -> nil
  end
end
