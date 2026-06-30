# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.WebPusherWorker do
  alias Pleroma.Notification
  alias Pleroma.Repo

  use Pleroma.Workers.WorkerHelper, queue: "web_push"

  defguardp valid_job_id(id) when (is_binary(id) and byte_size(id) > 0) or is_integer(id)

  @impl Oban.Worker
  def perform(%Job{args: %{"op" => "web_push", "notification_id" => notification_id}})
      when valid_job_id(notification_id) do
    with %Notification{} = notification <- get_notification(notification_id) do
      notification =
        notification
        |> Repo.preload([:activity, :user])

      Pleroma.Web.Push.Impl.perform(notification)
    else
      nil -> {:cancel, :notification_not_found}
    end
  end

  def perform(%Job{}), do: :discard

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(5)

  defp get_notification(notification_id) do
    Repo.get(Notification, notification_id)
  rescue
    _ -> nil
  end
end
