# Unfathomably BE
# ----------------
#
# File: workers/diaspora_publish_worker.ex
#
# Purpose:
#   Deliver committed local activities to relevant diaspora* pods.
#
# Responsibilities:
#   - load the final committed activity
#   - invoke deterministic translation and signed delivery with bounded retries
#
# This file intentionally does NOT parse or translate protocol entities.

defmodule Pleroma.Workers.DiasporaPublishWorker do
  use Pleroma.Workers.WorkerHelper,
    queue: "diaspora",
    max_attempts: 4,
    unique: [period: 86_400, states: :incomplete]

  alias Pleroma.Activity
  alias Pleroma.Diaspora.Publisher

  def enqueue_activity(id) do
    __MODULE__.new(%{"id" => id}) |> Oban.insert()
    :ok
  end

  def enqueue_unfollow(activity_id, follower_id, unfollowed_id) do
    __MODULE__.new(%{
      "op" => "unfollow",
      "activity_id" => activity_id,
      "follower_id" => follower_id,
      "unfollowed_id" => unfollowed_id
    })
    |> Oban.insert()

    :ok
  end

  @impl Oban.Worker
  def perform(%Job{args: %{"id" => id}}) do
    case Activity.get_by_id(id) do
      %Activity{} = activity -> Publisher.publish(activity)
      nil -> {:cancel, :not_found}
    end
  end

  def perform(%Job{
        args: %{
          "op" => "unfollow",
          "activity_id" => activity_id,
          "follower_id" => follower_id,
          "unfollowed_id" => unfollowed_id
        }
      }) do
    with %Activity{} = activity <- Activity.get_by_id(activity_id),
         %Pleroma.User{} = follower <- Pleroma.User.get_by_id(follower_id),
         %Pleroma.User{} = unfollowed <- Pleroma.User.get_by_id(unfollowed_id) do
      Publisher.publish_unfollow(activity, follower, unfollowed)
    else
      _ -> {:cancel, :not_found}
    end
  end

  def perform(%Job{}), do: {:cancel, :bad_request}
end

# end of workers/diaspora_publish_worker.ex
