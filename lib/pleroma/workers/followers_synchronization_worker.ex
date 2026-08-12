# Unfathomably follower synchronization worker
#
# File: followers_synchronization_worker.ex
#
# Purpose:
#   Fetch and reconcile a verified FEP-8fcf partial follower collection.
#
# This file intentionally does not create relationships absent from local
# state or trust an unsigned collection snapshot.

defmodule Pleroma.Workers.FollowersSynchronizationWorker do
  use Oban.Worker,
    queue: :federator_incoming,
    max_attempts: 3,
    unique: [period: 300, states: :incomplete, keys: [:actor, :url, :digest]]

  import Ecto.Query

  require Logger
  require Pleroma.Constants

  alias Pleroma.FollowingRelationship
  alias Pleroma.HTTP
  alias Pleroma.Repo
  alias Pleroma.Signature
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.FollowersSynchronization
  alias Pleroma.Web.ActivityPub.InternalFetchActor

  @maximum_body_bytes 2_000_000
  @maximum_items 10_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"actor" => actor_id, "url" => url, "digest" => digest}}) do
    with true <- FollowersSynchronization.enabled?(),
         %User{local: false} = actor <- User.get_cached_by_ap_id(actor_id),
         true <- FollowersSynchronization.same_origin?(actor.follower_address, url),
         {:ok, body} <- signed_fetch(url),
         {:ok, ids} <- decode_items(body),
         true <- FollowersSynchronization.digest(ids) == digest do
      reconcile(actor, MapSet.new(ids))
    else
      false -> {:cancel, :invalid_follower_synchronization}
      nil -> {:cancel, :unknown_actor}
      {:error, :temporary_fetch_failure} -> {:snooze, 60}
      {:error, reason} -> {:cancel, reason}
      _ -> {:cancel, :invalid_follower_synchronization}
    end
  end

  defp reconcile(actor, listed_ids) do
    relationships =
      FollowingRelationship
      |> where([relationship], relationship.following_id == ^actor.id)
      |> join(:inner, [relationship], follower in User,
        on: follower.id == relationship.follower_id
      )
      |> where([_relationship, follower], follower.local == true)
      |> select([relationship, follower], {relationship, follower})
      |> Repo.all()

    Enum.each(relationships, fn {relationship, follower} ->
      case {relationship.state, MapSet.member?(listed_ids, follower.ap_id)} do
        {:follow_pending, true} ->
          FollowingRelationship.update(follower, actor, :follow_accept)

        {:follow_accept, false} ->
          FollowingRelationship.unfollow(follower, actor)

        _ ->
          :ok
      end
    end)

    known_ids =
      relationships
      |> Enum.map(fn {_relationship, follower} -> follower.ap_id end)
      |> MapSet.new()

    unexpected_count = listed_ids |> MapSet.difference(known_ids) |> MapSet.size()

    if unexpected_count > 0 do
      Logger.debug(
        "Follower synchronization ignored #{unexpected_count} entries without local relationship state"
      )
    end

    :ok
  end

  defp signed_fetch(url) do
    date = Signature.signed_date()
    uri = URI.parse(url)
    request_target = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")

    host =
      if uri.port in [nil, URI.default_port(uri.scheme)] do
        uri.host
      else
        "#{uri.host}:#{uri.port}"
      end

    signature =
      Signature.sign(InternalFetchActor.get_actor(), %{
        "(request-target)" => "get #{request_target}",
        "host" => host,
        "date" => date
      })

    headers = [
      {"accept", Pleroma.Constants.activity_json_accept_header()},
      {"date", date},
      {"signature", signature}
    ]

    case HTTP.get(url, headers, pool: :federation, recv_timeout: 15_000) do
      {:ok, %{status: status, body: body}}
      when status in 200..299 and is_binary(body) and byte_size(body) <= @maximum_body_bytes ->
        {:ok, body}

      {:ok, %{status: status}} when status in [408, 425, 429, 500, 502, 503, 504] ->
        {:error, :temporary_fetch_failure}

      {:error, _reason} ->
        {:error, :temporary_fetch_failure}

      _ ->
        {:error, :invalid_fetch_response}
    end
  end

  defp decode_items(body) do
    with {:ok, data} when is_map(data) <- Jason.decode(body),
         type when type in ["Collection", "OrderedCollection"] <- data["type"],
         items when is_list(items) <- data["orderedItems"] || data["items"],
         true <- length(items) <= @maximum_items,
         true <- Enum.all?(items, &valid_local_actor_id?/1) do
      {:ok, Enum.uniq(items)}
    else
      _ -> {:error, :invalid_collection}
    end
  end

  defp valid_local_actor_id?(id) when is_binary(id) do
    FollowersSynchronization.same_origin?(id, Pleroma.Web.Endpoint.url())
  end

  defp valid_local_actor_id?(_id), do: false
end

# end of followers_synchronization_worker.ex
