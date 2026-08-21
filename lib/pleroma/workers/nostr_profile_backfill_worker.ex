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
  alias Pleroma.Nostr.Event
  alias Pleroma.Nostr.Identity
  alias Pleroma.Nostr.Protocol
  alias Pleroma.Nostr.RelayConnection
  alias Pleroma.Nostr.RelayManager
  alias Pleroma.Repo
  alias Pleroma.User

  @metadata_kinds [0, 10_002]
  @content_kinds [1, 6, 9, 11, 1_111, 30_023]
  @default_config [
    max_relays: 8,
    max_content_events: 40,
    request_timeout_ms: 2_500,
    max_unhydrated_profiles: 200,
    unhydrated_candidate_multiplier: 4,
    metadata_batch_size: 40,
    max_batch_origin_relays: 8,
    first_retry_seconds: 600,
    second_retry_seconds: 3_600,
    third_retry_seconds: 21_600,
    unhydrated_retry_seconds: 86_400
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

  def enqueue_unhydrated_profiles do
    if Nostr.enabled?() do
      max_profiles = config_integer(:max_unhydrated_profiles)
      candidate_limit = max_profiles * config_integer(:unhydrated_candidate_multiplier)
      now = System.system_time(:second)

      entities =
        Entity
        |> where([entity], entity.kind == "mirror_profile")
        |> where(
          [entity],
          fragment("COALESCE(?->>'profile_event_id', '') = ''", entity.metadata)
        )
        |> order_by(
          [entity],
          desc:
            fragment(
              "EXISTS (SELECT 1 FROM nostr_events AS stored_event WHERE stored_event.pubkey = ? AND stored_event.kind = 0)",
              entity.pubkey
            ),
          asc:
            fragment(
              "COALESCE(NULLIF(?->>'profile_backfill_attempted_at', '')::bigint, 0)",
              entity.metadata
            ),
          desc: entity.inserted_at,
          desc: entity.id
        )
        |> limit(^candidate_limit)
        |> Repo.all()
        |> Enum.filter(&retry_due?(&1, now))
        |> Enum.take(max_profiles)

      backfill_metadata_batch(entities)
      {:ok, length(entities)}
    else
      {:ok, 0}
    end
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

  def perform(%Job{args: args}) when map_size(args) == 0 do
    enqueue_unhydrated_profiles()
    :ok
  end

  def perform(%Job{}), do: {:cancel, :bad_request}

  def enqueue_pubkey(pubkey) when is_binary(pubkey) do
    %{"pubkey" => pubkey}
    |> new()
    |> Oban.insert()

    :ok
  end

  def enqueue_pubkey(_pubkey), do: :ok

  defp backfill(%Entity{} = entity) do
    include_content? = followed_by_local_account?(entity.user_id)
    project_stored_metadata([entity.pubkey])
    refreshed = Identity.get_profile(entity.pubkey) || entity

    if include_content? or not profile_hydrated?(refreshed) do
      initial_relays = native_relays(refreshed)

      initial_relays
      |> fetch_events(entity.pubkey, include_content?)
      |> ingest_events([entity.pubkey])

      refreshed_relays =
        case Identity.get_profile(entity.pubkey) do
          %Entity{} = updated -> native_relays(updated)
          _ -> []
        end

      refreshed_relays
      |> Enum.reject(&(&1 in initial_relays))
      |> fetch_events(entity.pubkey, include_content?)
      |> ingest_events([entity.pubkey])
    end

    touch_backfill_attempts([entity.id])
  end

  defp backfill_metadata_batch([]), do: :ok

  defp backfill_metadata_batch(entities) do
    pubkeys = Enum.map(entities, & &1.pubkey)
    project_stored_metadata(pubkeys)

    remaining =
      Entity
      |> where([entity], entity.id in ^Enum.map(entities, & &1.id))
      |> where(
        [entity],
        fragment("COALESCE(?->>'profile_event_id', '') = ''", entity.metadata)
      )
      |> Repo.all()

    remaining
    |> fetch_metadata_batch()
    |> ingest_events(Enum.map(remaining, & &1.pubkey))

    touch_backfill_attempts(Enum.map(entities, & &1.id))
  end

  # Metadata can arrive shortly after a contact-list event. The attempt count
  # provides quick early retries followed by a daily steady-state retry without
  # relying on updated_at, which unrelated relay-list updates also change.
  defp touch_backfill_attempts([]), do: :ok

  defp touch_backfill_attempts(entity_ids) do
    attempted_at = System.system_time(:second)
    updated_at = DateTime.utc_now()

    Entity
    |> where([entity], entity.id in ^entity_ids)
    |> update([entity],
      set: [
        metadata:
          fragment(
            "jsonb_set(jsonb_set(COALESCE(?, '{}'::jsonb), '{profile_backfill_attempts}', to_jsonb(COALESCE(NULLIF(?->>'profile_backfill_attempts', '')::integer, 0) + 1), true), '{profile_backfill_attempted_at}', to_jsonb(?::bigint), true)",
            entity.metadata,
            entity.metadata,
            ^attempted_at
          ),
        updated_at: ^updated_at
      ]
    )
    |> Repo.update_all([])

    :ok
  end

  defp ingest_events(events, pubkeys) do
    requested = MapSet.new(pubkeys)

    {_accepted, rejected} =
      events
      |> Map.values()
      |> Enum.sort_by(&event_order/1)
      |> Enum.reduce({0, []}, fn {event, relay_url}, {accepted, rejected} ->
        pubkey = event["pubkey"]

        if MapSet.member?(requested, pubkey) do
          case Bridge.ingest_event(event, relay_url, {:profile_backfill, pubkey}) do
            {:ok, _event} ->
              {accepted + 1, rejected}

            {:error, prefix, reason} ->
              {accepted, [{prefix, reason} | rejected]}
          end
        else
          {accepted, [{"restricted", "event author was not requested"} | rejected]}
        end
      end)

    project_stored_metadata(pubkeys)

    if rejected != [] do
      Logger.warning("Nostr profile backfill rejected signed relay events",
        pubkeys: length(pubkeys),
        rejected: length(rejected),
        reasons: rejected |> Enum.uniq() |> Enum.take(3) |> inspect()
      )
    end

    :ok
  end

  # Replaceable events may have been validated and stored before a referenced
  # contact caused its mirror User to be created. Reprojecting the stored winner
  # repairs that ordering without accepting unverified wire data or allowing an
  # older relay response to overwrite newer metadata.
  defp project_stored_metadata([]), do: :ok

  defp project_stored_metadata(pubkeys) do
    rejected =
      Event
      |> where([event], event.pubkey in ^pubkeys and event.kind in ^@metadata_kinds)
      |> order_by([event], asc: event.created_at, asc: event.id)
      |> Repo.all()
      |> Enum.reduce([], fn event, rejected ->
        case project_stored_metadata_event(event) do
          :ok -> rejected
          {:error, reason} -> [reason | rejected]
        end
      end)

    if rejected != [] do
      Logger.warning("Nostr stored profile metadata could not be projected",
        pubkeys: length(pubkeys),
        rejected: length(rejected),
        reasons: rejected |> Enum.uniq() |> Enum.take(3) |> inspect()
      )
    end

    :ok
  end

  defp project_stored_metadata_event(%Event{
         id: event_id,
         kind: 0,
         pubkey: pubkey,
         relay_url: relay_url,
         data: event
       }) do
    case Identity.get_profile(pubkey) do
      %Entity{metadata: %{"profile_event_id" => ^event_id}} ->
        :ok

      %Entity{} ->
        normalize_projection_result(Identity.update_profile(event, relay_url))

      _ ->
        {:error, :profile_not_found}
    end
  end

  defp project_stored_metadata_event(%Event{
         id: event_id,
         kind: 10_002,
         pubkey: pubkey,
         relay_url: relay_url,
         data: event
       }) do
    case Identity.get_profile(pubkey) do
      %Entity{metadata: %{"relay_list_event_id" => ^event_id}} ->
        :ok

      %Entity{} ->
        normalize_projection_result(Identity.update_relay_list(event, relay_url))

      _ ->
        {:error, :profile_not_found}
    end
  end

  defp project_stored_metadata_event(_event), do: :ok

  defp normalize_projection_result({:ok, _value}), do: :ok
  defp normalize_projection_result(:ok), do: :ok
  defp normalize_projection_result({:error, reason}), do: {:error, reason}
  defp normalize_projection_result(result), do: {:error, result}

  defp profile_hydrated?(%Entity{metadata: metadata}) when is_map(metadata) do
    is_binary(metadata["profile_event_id"]) and metadata["profile_event_id"] != ""
  end

  defp profile_hydrated?(_entity), do: false

  defp retry_due?(%Entity{metadata: metadata}, now) do
    attempts = metadata_integer(metadata, "profile_backfill_attempts")
    attempted_at = metadata_integer(metadata, "profile_backfill_attempted_at")
    attempted_at == 0 or now - attempted_at >= retry_delay(attempts)
  end

  defp retry_delay(0), do: 0
  defp retry_delay(1), do: config_integer(:first_retry_seconds)
  defp retry_delay(2), do: config_integer(:second_retry_seconds)
  defp retry_delay(3), do: config_integer(:third_retry_seconds)
  defp retry_delay(_attempts), do: config_integer(:unhydrated_retry_seconds)

  defp metadata_integer(metadata, key) when is_map(metadata) do
    case metadata[key] do
      value when is_integer(value) and value >= 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed >= 0 -> parsed
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp metadata_integer(_metadata, _key), do: 0

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

  defp fetch_metadata_batch([]), do: %{}

  defp fetch_metadata_batch(entities) do
    pubkeys = Enum.map(entities, & &1.pubkey)

    shared_relays =
      (Nostr.response_relays() ++ Nostr.profile_discovery_relays())
      |> normalize_relays()

    origin_groups =
      entities
      |> Enum.group_by(&Protocol.normalize_relay_url(&1.relay_url), & &1.pubkey)
      |> Enum.reject(fn {relay_url, _pubkeys} ->
        not is_binary(relay_url) or relay_url in shared_relays or
          normalize_relays([relay_url]) == []
      end)
      |> Enum.sort_by(fn {relay_url, relay_pubkeys} -> {-length(relay_pubkeys), relay_url} end)
      |> Enum.take(config_integer(:max_batch_origin_relays))

    requests =
      Enum.flat_map(shared_relays, &metadata_requests(&1, pubkeys)) ++
        Enum.flat_map(origin_groups, fn {relay_url, relay_pubkeys} ->
          metadata_requests(relay_url, relay_pubkeys)
        end)

    connected =
      requests
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
      |> connected_relays()
      |> MapSet.new()

    requests
    |> Enum.filter(fn {relay_url, _pubkeys} -> MapSet.member?(connected, relay_url) end)
    |> fetch_metadata_requests()
  end

  defp metadata_requests(relay_url, pubkeys) do
    pubkeys
    |> Enum.uniq()
    |> Enum.chunk_every(config_integer(:metadata_batch_size))
    |> Enum.map(&{relay_url, &1})
  end

  defp fetch_metadata_requests([]), do: %{}

  defp fetch_metadata_requests(requests) do
    pending =
      Enum.reduce(requests, MapSet.new(), fn {relay_url, pubkeys}, pending ->
        subscription_id = subscription_id()

        filters =
          Enum.map(@metadata_kinds, fn kind ->
            %{"authors" => pubkeys, "kinds" => [kind], "limit" => length(pubkeys)}
          end)

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
    (Identity.relay_urls(entity, :read) ++
       Nostr.response_relays() ++ Nostr.profile_discovery_relays())
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
