# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.PollWorker do
  @moduledoc """
  Generates notifications when a poll ends.
  """
  use Pleroma.Workers.WorkerHelper, queue: "poll_notifications"

  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.Notification
  alias Pleroma.Object

  defguardp valid_job_id(id) when (is_binary(id) and byte_size(id) > 0) or is_integer(id)

  @default_max_poll_schedule_seconds 365 * 24 * 60 * 60

  @impl Oban.Worker
  def perform(%Job{args: %{"op" => "poll_end", "activity_id" => activity_id}})
      when valid_job_id(activity_id) do
    with %Activity{} = activity <- find_poll_activity(activity_id),
         {:ok, notifications} <- Notification.create_poll_notifications(activity) do
      Notification.stream(notifications)
      :ok
    else
      {:error, :poll_activity_not_found} -> {:cancel, :poll_activity_not_found}
    end
  end

  def perform(%Job{}), do: :discard

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(5)

  defp find_poll_activity(activity_id) do
    with nil <- Activity.get_by_id(activity_id) do
      {:error, :poll_activity_not_found}
    end
  rescue
    _ -> {:error, :poll_activity_not_found}
  end

  def schedule_poll_end(%Activity{data: %{"type" => "Create"}, id: activity_id} = activity) do
    with %Object{data: %{"type" => "Question", "closed" => closed}} when is_binary(closed) <-
           Object.normalize(activity),
         {:ok, end_time} <- NaiveDateTime.from_iso8601(closed),
         now <- NaiveDateTime.utc_now(),
         :gt <- NaiveDateTime.compare(end_time, now),
         true <- poll_end_within_schedule_window?(end_time, now) do
      %{
        op: "poll_end",
        activity_id: activity_id
      }
      |> new(scheduled_at: end_time)
      |> Oban.insert()
    else
      _ -> {:error, activity}
    end
  end

  def schedule_poll_end(activity), do: {:error, activity}

  defp poll_end_within_schedule_window?(end_time, now) do
    max_end_time = NaiveDateTime.add(now, max_poll_schedule_seconds(), :second)

    NaiveDateTime.compare(end_time, max_end_time) in [:lt, :eq]
  end

  defp max_poll_schedule_seconds do
    case Config.get([:instance, :poll_limits, :max_expiration]) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _ -> @default_max_poll_schedule_seconds
    end
  end
end
