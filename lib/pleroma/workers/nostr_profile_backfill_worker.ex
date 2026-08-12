# Unfathomably BE
# ----------------
#
# File: workers/nostr_profile_backfill_worker.ex
#
# Purpose:
#   Hydrate a followed native Nostr profile without depending on Mostr.
#
# Responsibilities:
#   - query administrator-approved native relays for profile metadata
#   - retrieve a bounded recent content history for newly followed identities
#   - ingest every result through normal signature and policy validation
#
# This file intentionally does NOT crawl contact graphs, trust arbitrary relay
# hints, contact ActivityPub-to-Nostr bridges, or maintain permanent WebSocket
# subscriptions.

defmodule Pleroma.Workers.NostrProfileBackfillWorker do
  use Pleroma.Workers.WorkerHelper,
    queue: "slow",
    max_attempts: 1,
    unique: [period: 3_600, states: Oban.Job.states(), keys: [:pubkey]]

  import Ecto.Query

  require Logger

  alias Pleroma.Config
  alias Pleroma.FollowingRelationship
  alias Pleroma.Nostr
  alias Pleroma.Nostr.Bridge
  alias Pleroma.Nostr.Entity
  alias Pleroma.Nostr.Identity
  alias Pleroma.Nostr.Protocol
  alias Pleroma.Nostr.RelayConnection
  alias Pleroma.Nostr.RelayManager
  alias Pleroma.Repo
  alias Pleroma.User

  @metadata_kinds [0, 10_002]
  @content_kinds [1, 6, 9, 11, 1_111, 30_023]
  @default_config [
    max_relays: 6,
    max_content_events: 40,
    request_timeout_ms: 2_500
  ]

  def enqueue(%User{} = user) do
    case Identity.get_by_user(user) do
      %Entity{kind: "mirror_profile", pubkey: pubkey} -> enqueue_pubkey(pubkey)
      _ -> :ok
    end
  end

  def enqueue(_user), do: :ok

  def enqueue_followed_profiles do
    pubkeys =
      Entity
      |> join(:inner, [entity], relationship in FollowingRelationship,
        on: relationship.following_id == entity.user_id
      )
      |> join(:inner, [_entity, relationship], follower in User,
        on: follower.id == relationship.follower_id
      )
      |> join(:left, [_entity, _relationship, follower], follower_entity in Entity,
        on:
          follower_entity.user_id == follower.id and
            follower_entity.kind in ["mirror_profile", "mirror_group"]
      )
      |> where(
        [entity, relationship, follower, follower_entity],
        entity.kind == "mirror_profile" and
          relationship.state == ^:follow_accept and
          follower.local and
          is_nil(follower_entity.id)
      )
      |> select([entity], entity.pubkey)
      |> distinct(true)
      |> Repo.all()

    Enum.each(pubkeys, &enqueue_pubkey/1)
    {:ok, length(pubkeys)}
  end

  @impl Oban.Worker
  def perform(%Job{args: %{"pubkey" => pubkey}}) do
    case Identity.get_profile(pubkey) do
      %Entity{kind: "mirror_profile"} = entity ->
        backfill(entity)
        :ok

      _ ->
        {:cancel, :profile_not_found}
    end
  end

  def perform(%Job{}), do: {:cancel, :bad_request}

  defp enqueue_pubkey(pubkey) when is_binary(pubkey) do
    %{"pubkey" => pubkey}
    |> new()
    |> Oban.insert()

    :ok
  end

  defp enqueue_pubkey(_pubkey), do: :ok

  defp backfill(%Entity{} = entity) do
    include_content? = followed_by_local_account?(entity.user_id)
    initial_relays = native_relays(entity)

    initial_relays
    |> fetch_events(entity.pubkey, include_content?)
    |> ingest_events(entity.pubkey)

    refreshed_relays =
      case Identity.get_profile(entity.pubkey) do
        %Entity{} = refreshed -> native_relays(refreshed)
        _ -> []
      end

    refreshed_relays
    |> Enum.reject(&(&1 in initial_relays))
    |> fetch_events(entity.pubkey, include_content?)
    |> ingest_events(entity.pubkey)
  end

  defp ingest_events(events, pubkey) do
    {_accepted, rejected} =
      events
      |> Map.values()
      |> Enum.sort_by(&event_order/1)
      |> Enum.reduce({0, []}, fn {event, relay_url}, {accepted, rejected} ->
        case Bridge.ingest_event(event, relay_url, {:profile_backfill, pubkey}) do
          {:ok, _event} ->
            {accepted + 1, rejected}

          {:error, prefix, reason} ->
            {accepted, [{prefix, reason} | rejected]}
        end
      end)

    if rejected != [] do
      Logger.warning("Nostr profile backfill rejected signed relay events",
        pubkey: pubkey,
        rejected: length(rejected),
        reasons: rejected |> Enum.uniq() |> Enum.take(3) |> inspect()
      )
    end

    :ok
  end

  defp fetch_events([], _pubkey, _include_content?), do: %{}

  defp fetch_events(relays, pubkey, include_content?) do
    filters =
      Enum.map(@metadata_kinds, fn kind ->
        %{"authors" => [pubkey], "kinds" => [kind], "limit" => 1}
      end) ++ content_filters(pubkey, include_content?)

    pending =
      Enum.reduce(relays, MapSet.new(), fn relay_url, pending ->
        subscription_id = subscription_id()

        case RelayConnection.request(
               relay_url,
               subscription_id,
               filters,
               self(),
               config_integer(:request_timeout_ms)
             ) do
          :ok -> MapSet.put(pending, {relay_url, subscription_id})
          _ -> pending
        end
      end)

    deadline =
      System.monotonic_time(:millisecond) + config_integer(:request_timeout_ms) + 250

    collect_events(pending, deadline, %{})
  end

  defp content_filters(pubkey, true) do
    [
      %{
        "authors" => [pubkey],
        "kinds" => @content_kinds,
        "limit" => config_integer(:max_content_events)
      }
    ]
  end

  defp content_filters(_pubkey, false), do: []

  defp followed_by_local_account?(user_id) do
    FollowingRelationship
    |> join(:inner, [relationship], follower in User, on: follower.id == relationship.follower_id)
    |> join(:left, [_relationship, follower], follower_entity in Entity,
      on:
        follower_entity.user_id == follower.id and
          follower_entity.kind in ["mirror_profile", "mirror_group"]
    )
    |> where(
      [relationship, follower, follower_entity],
      relationship.following_id == ^user_id and
        relationship.state == ^:follow_accept and
        follower.local and
        is_nil(follower_entity.id)
    )
    |> Repo.exists?()
  end

  defp collect_events(pending, deadline, events) do
    cond do
      MapSet.size(pending) == 0 ->
        events

      true ->
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        if remaining == 0 do
          events
        else
          receive do
            {:nostr_relay_event, relay_url, subscription_id, %{"id" => event_id} = event}
            when is_binary(event_id) ->
              key = {relay_url, subscription_id}

              events =
                if MapSet.member?(pending, key) do
                  Map.put_new(events, event_id, {event, relay_url})
                else
                  events
                end

              collect_events(pending, deadline, events)

            {:nostr_relay_eose, relay_url, subscription_id, _reason} ->
              pending = MapSet.delete(pending, {relay_url, subscription_id})
              collect_events(pending, deadline, events)

            _other ->
              collect_events(pending, deadline, events)
          after
            remaining -> events
          end
        end
    end
  end

  defp native_relays(%Entity{} = entity) do
    (Identity.relay_urls(entity, :read) ++ Nostr.profile_discovery_relays())
    |> normalize_relays()
    |> Enum.reject(&Nostr.compatibility_relay?/1)
    |> Enum.take(config_integer(:max_relays))
    |> connected_relays()
  end

  defp normalize_relays(relays) do
    relays
    |> Enum.map(&Protocol.normalize_relay_url/1)
    |> Enum.filter(&Nostr.allowed_relay?/1)
    |> Enum.reject(&(&1 == Nostr.relay_url()))
    |> Enum.uniq()
  end

  defp connected_relays(relays) do
    Enum.filter(relays, fn relay_url ->
      RelayManager.ensure_connection(relay_url)

      Registry.lookup(Pleroma.Nostr.ProcessRegistry, {:relay, relay_url}) != []
    end)
  end

  defp event_order({event, _relay_url}) do
    priority =
      case event["kind"] do
        0 -> 0
        10_002 -> 1
        _kind -> 2
      end

    {priority, event["created_at"] || 0}
  end

  defp subscription_id do
    unique = System.unique_integer([:positive, :monotonic])
    "unfathomably-profile-#{unique}"
  end

  defp config_integer(key) do
    default = Keyword.fetch!(@default_config, key)

    case Config.get([Nostr, :profile_backfill, key], default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end
end

# end of workers/nostr_profile_backfill_worker.ex
