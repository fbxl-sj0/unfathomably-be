# Unfathomably BE
# ----------------
#
# File: workers/nostr_thread_fetch_worker.ex
#
# Purpose:
#   Hydrate a Nostr conversation only when a user opens its status context.
#
# Responsibilities:
#   - request a bounded ancestor and reply neighborhood from approved relays
#   - follow NIP-10, NIP-22, and NIP-C7 parent references to a configured depth
#   - ingest fetched events through the normal signature and policy checks
#   - close transient relay subscriptions after end-of-stream or timeout
#
# This file intentionally does NOT crawl author history, keep permanent thread
# subscriptions, trust arbitrary relay hints, or bypass bridge validation.

defmodule Pleroma.Workers.NostrThreadFetchWorker do
  use Pleroma.Workers.WorkerHelper,
    queue: "remote_fetcher",
    max_attempts: 3,
    unique: [period: 300, states: Oban.Job.states(), keys: [:event_id]]

  require Logger

  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.Nostr
  alias Pleroma.Nostr.Bridge
  alias Pleroma.Nostr.Event
  alias Pleroma.Nostr.Identity
  alias Pleroma.Nostr.Protocol
  alias Pleroma.Nostr.RelayConnection
  alias Pleroma.Nostr.RelayManager
  alias Pleroma.Nostr.Store
  alias Pleroma.Nostr.Thread
  alias Pleroma.Workers.NostrThreadRepairWorker

  @content_kinds [1, 9, 11, 1_111, 30_023]
  @default_config [
    enabled: true,
    max_relays: 4,
    max_events: 80,
    max_ancestor_depth: 12,
    max_request_rounds: 3,
    request_timeout_ms: 1_800
  ]

  def enqueue_for_activity(%Activity{id: activity_id}) do
    if enabled?() do
      case Store.get_by_ap_activity_id(activity_id) do
        %Event{id: event_id} ->
          case %{"event_id" => event_id} |> new() |> Oban.insert() do
            {:ok, %Job{conflict?: true, state: state}} -> hydration_state(state)
            {:ok, %Job{}} -> :scheduled
            _error -> :ignored
          end

        nil ->
          :ignored
      end
    else
      :ignored
    end
  end

  def enqueue_for_activity(_activity), do: :ignored

  @impl Oban.Worker
  def perform(%Job{args: %{"event_id" => event_id}}) when is_binary(event_id) do
    case Store.get(event_id) do
      %Event{} = event ->
        case hydrate(event) do
          {:ok, _outcome} -> :ok
          {:error, reason} -> {:error, reason}
        end

      nil ->
        {:cancel, :event_not_found}
    end
  end

  def perform(%Job{}), do: {:cancel, :bad_request}

  defp hydrate(%Event{} = event) do
    relays = destination_relays(event)
    max_events = config_integer(:max_events)
    max_depth = config_integer(:max_ancestor_depth)
    max_rounds = config_integer(:max_request_rounds)

    references =
      event.data
      |> Thread.reference_ids()
      |> Enum.reject(&(&1 == event.id))
      |> Enum.take(max_depth)

    # Exact ancestors are requested before the broader reply neighborhood.
    # This reserves the event budget for the objects required to construct the
    # context instead of allowing a busy relay's descendants to crowd them out.
    {ancestor_candidates, _rounds_left, ancestor_ids} =
      walk_ancestors(
        references,
        MapSet.new([event.id]),
        %{},
        relays,
        max_rounds,
        max_events,
        max_depth,
        MapSet.new()
      )

    ancestor_candidates =
      merge_candidate_maps(ancestor_candidates, stored_candidates(ancestor_ids))

    reply_targets =
      ancestor_ids
      |> MapSet.put(event.id)
      |> MapSet.to_list()

    remaining_events = max(max_events - map_size(ancestor_candidates), 0)

    {reply_candidates, _reply_rounds_left} =
      if remaining_events > 0 do
        fetch_round(relays, reply_filters(reply_targets, remaining_events), remaining_events, 1)
      else
        {%{}, 0}
      end

    candidates =
      ancestor_candidates
      |> merge_candidate_maps(reply_candidates)

    authorized_ids = Map.keys(candidates)
    outcome = ingest_candidates(candidates, authorized_ids, relays)

    missing_ancestors =
      ancestor_ids
      |> Enum.reject(&projected_event?/1)
      |> Enum.sort()

    log_outcome(event.id, ancestor_ids, candidates, outcome, missing_ancestors)

    case missing_ancestors do
      [] -> {:ok, outcome}
      ids -> {:error, {:parents_unavailable, Enum.map(ids, &String.slice(&1, 0, 16))}}
    end
  end

  defp walk_ancestors(
         _frontier,
         _seen,
         events,
         _relays,
         _rounds_left,
         _max_events,
         depth_left,
         target_ids
       )
       when depth_left <= 0,
       do: {events, 0, target_ids}

  defp walk_ancestors(
         frontier,
         seen,
         events,
         relays,
         rounds_left,
         max_events,
         depth_left,
         target_ids
       ) do
    frontier =
      frontier
      |> Enum.reject(&MapSet.member?(seen, &1))
      |> Enum.uniq()
      |> Enum.take(depth_left)

    if frontier == [] do
      {events, rounds_left, target_ids}
    else
      seen = Enum.reduce(frontier, seen, &MapSet.put(&2, &1))
      target_ids = Enum.reduce(frontier, target_ids, &MapSet.put(&2, &1))

      missing =
        Enum.reject(frontier, fn event_id ->
          Map.has_key?(events, event_id) or match?(%Event{}, Store.get(event_id))
        end)

      remaining_events = max(max_events - map_size(events), 0)

      {fetched, rounds_left} =
        if missing != [] and rounds_left > 0 and remaining_events > 0 do
          fetch_round(
            relays,
            [%{"ids" => missing, "limit" => remaining_events}],
            remaining_events,
            rounds_left
          )
        else
          {%{}, rounds_left}
        end

      events = Map.merge(events, fetched)

      next_frontier =
        frontier
        |> Enum.flat_map(fn event_id ->
          case Map.get(events, event_id) || Store.get(event_id) do
            [_candidate | _rest] = candidates ->
              candidates
              |> representative_event()
              |> Thread.reference_ids()

            %Event{data: data} ->
              Thread.reference_ids(data)

            _ ->
              []
          end
        end)

      walk_ancestors(
        next_frontier,
        seen,
        events,
        relays,
        rounds_left,
        max_events,
        depth_left - length(frontier),
        target_ids
      )
    end
  end

  defp fetch_round(_relays, [], _max_events, rounds_left), do: {%{}, rounds_left}

  defp fetch_round(_relays, _filters, _max_events, rounds_left) when rounds_left <= 0,
    do: {%{}, 0}

  defp fetch_round(relays, filters, max_events, rounds_left) do
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

    {collect_events(pending, deadline, %{}, max_events, filters), rounds_left - 1}
  end

  defp collect_events(pending, deadline, events, max_events, filters) do
    cond do
      MapSet.size(pending) == 0 ->
        events

      map_size(events) >= max_events ->
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
                if MapSet.member?(pending, key) and matches_filters?(event, filters) do
                  put_candidate(events, event_id, event, relay_url, max_events)
                else
                  events
                end

              collect_events(pending, deadline, events, max_events, filters)

            {:nostr_relay_eose, relay_url, subscription_id, _reason} ->
              pending = MapSet.delete(pending, {relay_url, subscription_id})
              collect_events(pending, deadline, events, max_events, filters)

            _other ->
              collect_events(pending, deadline, events, max_events, filters)
          after
            remaining -> events
          end
        end
    end
  end

  @doc """
  Ingest each relay candidate until one copy passes validation and projection.

  A Nostr event may be returned by several relays. Authorization and group
  policy can depend on the relay, so rejecting the first copy must not discard
  a later copy from the event's canonical or hinted relay.
  """
  def ingest_candidates(
        events,
        authorized_ids,
        relay_priority,
        ingester \\ &Bridge.ingest_event/3
      )
      when is_map(events) and is_list(authorized_ids) and is_list(relay_priority) and
             is_function(ingester, 3) do
    source = {:thread_hydration, authorized_ids}
    relay_ranks = relay_priority |> Enum.with_index() |> Map.new()

    events
    |> Map.to_list()
    |> order_events()
    |> Enum.reduce(%{accepted: [], rejected: %{}}, fn {event_id, candidates}, outcome ->
      candidates =
        Enum.sort_by(candidates, fn {_event, relay_url} ->
          Map.get(relay_ranks, relay_url, map_size(relay_ranks))
        end)

      case ingest_candidate_copies(candidates, source, ingester) do
        {:ok, relay_url} ->
          notify_thread_repair(event_id)
          %{outcome | accepted: [{event_id, relay_url} | outcome.accepted]}

        {:error, errors} ->
          %{outcome | rejected: Map.put(outcome.rejected, event_id, errors)}
      end
    end)
  end

  defp order_events(events), do: order_events(events, [])

  defp order_events([], ordered), do: Enum.reverse(ordered)

  defp order_events(events, ordered) do
    pending_ids = MapSet.new(events, fn {event_id, _candidates} -> event_id end)

    {ready, waiting} =
      Enum.split_with(events, fn {_event_id, candidates} ->
        case candidates |> representative_event() |> parent_id() do
          nil -> true
          parent_id -> not MapSet.member?(pending_ids, parent_id)
        end
      end)

    if ready == [] do
      Enum.reverse(ordered) ++ Enum.sort_by(waiting, &event_created_at/1)
    else
      ready = Enum.sort_by(ready, &event_created_at/1)
      order_events(waiting, Enum.reverse(ready) ++ ordered)
    end
  end

  defp parent_id(event) do
    Thread.reply_id(event)
  end

  defp event_created_at({_event_id, candidates}) do
    event = representative_event(candidates)

    case event["created_at"] do
      created_at when is_integer(created_at) -> created_at
      _ -> 0
    end
  end

  defp reply_filters([], _limit), do: []

  defp reply_filters(event_ids, limit) do
    [
      %{"#e" => event_ids, "kinds" => @content_kinds, "limit" => limit},
      %{"#E" => event_ids, "kinds" => @content_kinds, "limit" => limit},
      %{"#q" => event_ids, "kinds" => [9], "limit" => limit}
    ]
  end

  defp put_candidate(events, event_id, event, relay_url, max_events) do
    if Map.has_key?(events, event_id) or map_size(events) < max_events do
      Map.update(events, event_id, [{event, relay_url}], fn candidates ->
        if Enum.any?(candidates, fn {_event, candidate_relay} -> candidate_relay == relay_url end) do
          candidates
        else
          candidates ++ [{event, relay_url}]
        end
      end)
    else
      events
    end
  end

  defp merge_candidate_maps(left, right) do
    Map.merge(left, right, fn _event_id, left_candidates, right_candidates ->
      Enum.reduce(right_candidates, left_candidates, fn {event, relay_url}, candidates ->
        if Enum.any?(candidates, fn {_event, candidate_relay} -> candidate_relay == relay_url end) do
          candidates
        else
          candidates ++ [{event, relay_url}]
        end
      end)
    end)
  end

  defp stored_candidates(event_ids) do
    Enum.reduce(event_ids, %{}, fn event_id, candidates ->
      case Store.get(event_id) do
        %Event{data: event, relay_url: relay_url} when is_binary(relay_url) ->
          Map.put(candidates, event_id, [{event, relay_url}])

        _event ->
          candidates
      end
    end)
  end

  defp projected_event?(event_id) do
    match?(%Event{ap_activity_id: activity_id} when is_binary(activity_id), Store.get(event_id))
  end

  defp representative_event([{event, _relay_url} | _candidates]), do: event
  defp representative_event(_candidates), do: %{}

  defp matches_filters?(event, filters) do
    Enum.any?(filters, &Protocol.matches?(event, &1))
  rescue
    _error -> false
  end

  defp ingest_candidate_copies(candidates, source, ingester) do
    candidates
    |> Enum.reduce_while([], fn {event, relay_url}, errors ->
      case ingester.(event, relay_url, source) do
        {:ok, _event} -> {:halt, {:ok, relay_url}}
        error -> {:cont, [{relay_url, error} | errors]}
      end
    end)
    |> case do
      {:ok, relay_url} -> {:ok, relay_url}
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  defp log_outcome(event_id, ancestor_ids, candidates, outcome, missing_ancestors) do
    metadata = [
      event_id: event_id,
      requested_ancestors: MapSet.size(ancestor_ids),
      fetched_events: map_size(candidates),
      accepted_events: length(outcome.accepted),
      rejected_events: map_size(outcome.rejected),
      missing_ancestors: Enum.map(missing_ancestors, &String.slice(&1, 0, 16))
    ]

    if missing_ancestors == [] do
      Logger.info("Nostr thread hydration completed", metadata)
    else
      Logger.warning("Nostr thread hydration did not resolve every ancestor", metadata)
    end
  end

  defp hydration_state("completed"), do: :complete
  defp hydration_state(state) when state in ["cancelled", "discarded"], do: :unavailable
  defp hydration_state(_state), do: :pending

  defp notify_thread_repair(event_id) do
    case Store.get(event_id) do
      %Event{} = event ->
        NostrThreadRepairWorker.enqueue_for_event(event)
        NostrThreadRepairWorker.enqueue_waiting_children(event)

      _event ->
        :ok
    end
  end

  defp destination_relays(%Event{} = event) do
    relay_hints =
      event.data
      |> Thread.tags()
      |> Enum.flat_map(fn
        [_tag, _event_id, relay_url | _rest] when is_binary(relay_url) -> [relay_url]
        _tag -> []
      end)

    author_relays =
      event
      |> Thread.parent_author_pubkeys()
      |> Enum.flat_map(&author_write_relays/1)

    ([event.relay_url] ++
       relay_hints ++
       author_relays ++
       Nostr.search_relays() ++
       Nostr.profile_discovery_relays() ++ Nostr.configured_relays())
    |> Enum.map(&Protocol.normalize_relay_url/1)
    |> Enum.filter(&Nostr.allowed_relay?/1)
    |> Enum.reject(&(&1 == Nostr.relay_url()))
    |> Enum.uniq()
    |> Enum.take(config_integer(:max_relays))
    |> Enum.filter(fn relay_url ->
      RelayManager.ensure_connection(relay_url)

      Registry.lookup(Pleroma.Nostr.ProcessRegistry, {:relay, relay_url}) != []
    end)
  end

  defp author_write_relays(pubkey) do
    case Identity.get_profile(pubkey) do
      nil -> stored_write_relays(pubkey)
      entity -> Identity.relay_urls(entity, :write) |> fallback_relays(pubkey)
    end
  end

  defp fallback_relays([], pubkey), do: stored_write_relays(pubkey)
  defp fallback_relays(relays, _pubkey), do: relays

  defp stored_write_relays(pubkey) do
    case Store.query([%{"authors" => [pubkey], "kinds" => [10_002], "limit" => 1}]) do
      [%Event{data: %{"tags" => tags}} | _events] when is_list(tags) ->
        Enum.flat_map(tags, fn
          ["r", relay_url] when is_binary(relay_url) -> [relay_url]
          ["r", relay_url, "write"] when is_binary(relay_url) -> [relay_url]
          _tag -> []
        end)

      _events ->
        []
    end
  end

  defp subscription_id do
    unique = System.unique_integer([:positive, :monotonic])
    "unfathomably-thread-#{unique}"
  end

  defp enabled? do
    Config.get([Nostr, :thread_hydration, :enabled], Keyword.fetch!(@default_config, :enabled)) !=
      false
  end

  defp config_integer(key) do
    default = Keyword.fetch!(@default_config, key)

    case Config.get([Nostr, :thread_hydration, key], default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end
end

# end of workers/nostr_thread_fetch_worker.ex
