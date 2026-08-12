# Unfathomably BE
# ----------------
#
# File: workers/nostr_publish_worker.ex
#
# Purpose:
#   Export committed ActivityPub interactions to Nostr asynchronously.
#
# Responsibilities:
#   - load the final committed activity by database id
#   - republish local actor metadata to configured relay destinations
#   - invoke the bridge's idempotent event publisher
#   - discard stale or unsupported activity references
#
# This file intentionally does NOT perform translation itself or publish
# uncommitted transaction state.

defmodule Pleroma.Workers.NostrPublishWorker do
  use Pleroma.Workers.WorkerHelper,
    queue: "nostr",
    max_attempts: 3,
    unique: [period: 86_400, states: :incomplete]

  alias Pleroma.Activity
  alias Pleroma.Nostr.Bridge
  alias Pleroma.User

  def enqueue_activity(id) do
    __MODULE__.new(%{"op" => "activity", "id" => id})
    |> Oban.insert()

    :ok
  end

  def enqueue_profile(%User{ap_id: ap_id}) when is_binary(ap_id) do
    __MODULE__.new(%{"op" => "profile", "ap_id" => ap_id})
    |> Oban.insert()

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
  def perform(%Job{args: %{"op" => "activity", "id" => id}}) do
    case Activity.get_by_id(id) do
      %Activity{} = activity -> Bridge.publish_activity(activity)
      nil -> {:cancel, :not_found}
    end
  end

  def perform(%Job{args: %{"op" => "profile", "ap_id" => ap_id}}) do
    case User.get_cached_by_ap_id(ap_id) do
      %User{} = user -> Bridge.publish_profile(user)
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
         %User{} = follower <- User.get_by_id(follower_id),
         %User{} = unfollowed <- User.get_by_id(unfollowed_id) do
      Bridge.publish_unfollow(activity, follower, unfollowed)
    else
      _ -> {:cancel, :not_found}
    end
  end

  def perform(%Job{}), do: {:cancel, :bad_request}
end

# end of workers/nostr_publish_worker.ex
