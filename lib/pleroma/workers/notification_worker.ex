# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.NotificationWorker do
  @moduledoc """
  Creates notifications for an Activity.
  """
  use Pleroma.Workers.WorkerHelper, queue: "notifications"

  alias Pleroma.Activity
  alias Pleroma.Notification

  defguardp valid_job_id(id) when (is_binary(id) and byte_size(id) > 0) or is_integer(id)

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) ::
          :discard | {:cancel, :activity_not_found} | {:ok, [Pleroma.Notification.t()]}
  def perform(%Job{args: %{"op" => "create", "activity_id" => activity_id}})
      when valid_job_id(activity_id) do
    with %Activity{} = activity <- find_activity(activity_id) do
      Notification.create_notifications(activity)
    else
      {:error, :activity_not_found} -> {:cancel, :activity_not_found}
    end
  end

  def perform(%Job{}), do: :discard

  defp find_activity(activity_id) do
    with nil <- Activity.get_by_id(activity_id) do
      {:error, :activity_not_found}
    end
  rescue
    _ -> {:error, :activity_not_found}
  end
end
