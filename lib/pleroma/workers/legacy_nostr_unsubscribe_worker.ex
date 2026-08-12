# Unfathomably BE
# ----------------
#
# File: workers/legacy_nostr_unsubscribe_worker.ex
#
# Purpose:
#   Ask a retired Mostr projection to stop delivering activities for local
#   accounts that historically followed it.
#
# Responsibilities:
#   - find historical local Follow activities for a Mostr actor
#   - construct a deterministic signed ActivityPub Undo(Follow)
#   - deliver only to a validated inbox on the same configured Mostr host
#   - deduplicate unsubscribe work by remote actor
#
# This file intentionally does NOT reactivate Mostr actors, recreate follow
# relationships, ingest bridge content, or provide general Mostr publishing.

defmodule Pleroma.Workers.LegacyNostrUnsubscribeWorker do
  import Ecto.Query

  require Logger

  alias Pleroma.Activity
  alias Pleroma.Nostr.MostrCompat
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Publisher

  @maximum_local_followers 16

  use Pleroma.Workers.WorkerHelper,
    queue: "federator_outgoing",
    max_attempts: 5,
    unique: [
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable, :suspended, :completed],
      keys: [:target_ap_id]
    ]

  def enqueue(target_ap_id) when is_binary(target_ap_id) do
    if MostrCompat.legacy_reference?(target_ap_id) do
      %{"target_ap_id" => target_ap_id}
      |> new()
      |> Oban.insert()
    else
      {:error, :not_legacy_nostr_actor}
    end
  end

  def enqueue(_target_ap_id), do: {:error, :invalid_target}

  @impl Oban.Worker
  def perform(%Job{args: %{"target_ap_id" => target_ap_id}}) do
    with true <- MostrCompat.legacy_reference?(target_ap_id),
         %User{} = target <- Repo.get_by(User, ap_id: target_ap_id),
         {:ok, inbox} <- validated_inbox(target),
         follows <- historical_local_follows(target_ap_id) do
      deliver_unsubscribes(follows, target_ap_id, inbox)
    else
      false -> {:cancel, :not_legacy_nostr_actor}
      nil -> {:cancel, :legacy_actor_not_cached}
      {:error, reason} -> {:cancel, reason}
    end
  end

  def perform(%Job{}), do: {:cancel, :invalid_params}

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(60)

  defp historical_local_follows(target_ap_id) do
    Activity
    |> join(:inner, [activity], follower in User, on: follower.ap_id == activity.actor)
    |> where([activity, follower], follower.local and follower.is_active)
    |> where([activity], fragment("?->>'type'", activity.data) == "Follow")
    |> where([activity], fragment("?->>'object'", activity.data) == ^target_ap_id)
    |> where([activity], fragment("coalesce(?->>'state', '') <> 'cancelled'", activity.data))
    |> order_by([activity], desc: activity.id)
    |> limit(64)
    |> select([activity, follower], {activity, follower})
    |> Repo.all()
    |> Enum.uniq_by(fn {_activity, follower} -> follower.id end)
    |> Enum.take(@maximum_local_followers)
  end

  defp deliver_unsubscribes([], target_ap_id, _inbox) do
    Logger.info("No historical local Mostr follow requires an unsubscribe",
      target: target_ap_id
    )

    :ok
  end

  defp deliver_unsubscribes(follows, target_ap_id, inbox) do
    Enum.reduce_while(follows, :ok, fn {follow, follower}, :ok ->
      case deliver_unsubscribe(follow, follower, target_ap_id, inbox) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp deliver_unsubscribe(
         %Activity{} = follow,
         %User{} = follower,
         target_ap_id,
         inbox
       ) do
    activity_id = unsubscribe_activity_id(follower, target_ap_id)

    undo = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => activity_id,
      "type" => "Undo",
      "actor" => follower.ap_id,
      "object" => follow.data["id"],
      "to" => follow.data["to"] || [target_ap_id],
      "cc" => follow.data["cc"] || []
    }

    case Publisher.publish_one(%{
           inbox: inbox,
           json: Jason.encode!(undo),
           actor: follower,
           id: activity_id
         }) do
      {:ok, %{status: status}} when status in 200..299 ->
        mark_unsubscribe_handled(follow)

        Logger.info("Sent legacy Mostr unsubscribe",
          actor: follower.ap_id,
          target: target_ap_id,
          status: status
        )

        :ok

      {:cancel, :bad_request} ->
        mark_unsubscribe_handled(follow)

        Logger.warning(
          "Mostr rejected standards-compliant Undo(Follow); its ActivityPub inbox does not support Undo",
          actor: follower.ap_id,
          target: target_ap_id
        )

        :ok

      {:cancel, reason} ->
        mark_unsubscribe_handled(follow)

        Logger.info("Legacy Mostr unsubscribe reached a terminal destination",
          actor: follower.ap_id,
          target: target_ap_id,
          reason: inspect(reason)
        )

        :ok

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  defp mark_unsubscribe_handled(%Activity{} = follow) do
    data = Map.put(follow.data, "state", "cancelled")

    Activity
    |> where([activity], activity.id == ^follow.id)
    |> Repo.update_all(set: [data: data])

    :ok
  end

  defp validated_inbox(%User{} = target) do
    [target.shared_inbox, target.inbox]
    |> Enum.find_value(fn inbox ->
      if valid_inbox_for_target?(inbox, target.ap_id), do: {:ok, inbox}
    end)
    |> case do
      {:ok, inbox} -> {:ok, inbox}
      nil -> {:error, :invalid_legacy_actor_inbox}
    end
  end

  defp valid_inbox_for_target?(inbox, target_ap_id)
       when is_binary(inbox) and is_binary(target_ap_id) do
    with %URI{scheme: "https", host: inbox_host} when is_binary(inbox_host) <- URI.parse(inbox),
         %URI{scheme: "https", host: target_host} when is_binary(target_host) <-
           URI.parse(target_ap_id) do
      String.downcase(inbox_host) == String.downcase(target_host) and
        MostrCompat.legacy_reference?(inbox)
    else
      _ -> false
    end
  rescue
    URI.Error -> false
  end

  defp valid_inbox_for_target?(_inbox, _target_ap_id), do: false

  defp unsubscribe_activity_id(%User{} = follower, target_ap_id) do
    digest =
      :crypto.hash(:sha256, follower.ap_id <> <<0>> <> target_ap_id)
      |> Base.url_encode64(padding: false)

    "#{Pleroma.Web.Endpoint.url()}/activities/mostr-unsubscribe-#{digest}"
  end
end

# end of workers/legacy_nostr_unsubscribe_worker.ex
