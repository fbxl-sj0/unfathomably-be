# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.MuteExpireWorker do
  use Pleroma.Workers.WorkerHelper, queue: "mute_expire"

  defguardp valid_job_id(id) when (is_binary(id) and byte_size(id) > 0) or is_integer(id)

  @impl Oban.Worker
  def perform(%Job{
        args: %{"op" => "unmute_user", "muter_id" => muter_id, "mutee_id" => mutee_id}
      })
      when valid_job_id(muter_id) and valid_job_id(mutee_id) do
    Pleroma.User.unmute(muter_id, mutee_id)
    :ok
  end

  def perform(%Job{
        args: %{"op" => "unmute_conversation", "user_id" => user_id, "activity_id" => activity_id}
      })
      when valid_job_id(user_id) and valid_job_id(activity_id) do
    Pleroma.Web.CommonAPI.remove_mute(user_id, activity_id)
    :ok
  end

  def perform(%Job{}), do: :discard

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(5)
end
