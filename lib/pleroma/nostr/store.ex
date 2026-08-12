# Unfathomably BE
# ----------------
#
# File: nostr/store.ex
#
# Purpose:
#   Persist verified Nostr events and answer bounded relay subscriptions.
#
# Responsibilities:
#   - enforce normal, replaceable, and ephemeral event storage semantics
#   - serialize replacement races with PostgreSQL advisory transaction locks
#   - retain ActivityPub mapping identifiers
#   - execute bounded NIP-01 filter queries
#
# This file intentionally does NOT validate signatures, authorize writers, or
# translate events.

defmodule Pleroma.Nostr.Store do
  import Ecto.Query

  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.Nostr.Event
  alias Pleroma.Nostr.Protocol
  alias Pleroma.Nostr.Semantics
  alias Pleroma.Repo

  def put(event, opts \\ []) do
    attrs = %{
      id: event["id"],
      pubkey: event["pubkey"],
      kind: event["kind"],
      created_at: DateTime.from_unix!(event["created_at"]),
      relay_url: Keyword.get(opts, :relay_url),
      local: Keyword.get(opts, :local, false),
      replace_key: Protocol.replace_key(event),
      data: event,
      ap_activity_id: Keyword.get(opts, :ap_activity_id),
      ap_activity_uri: Keyword.get(opts, :ap_activity_uri) || activitypub_proxy_uri(event),
      ap_object_id: Keyword.get(opts, :ap_object_id)
    }

    cond do
      Semantics.expired?(event) ->
        {:error, :expired_event}

      Protocol.ephemeral?(event) ->
        {:ok, struct(Event, attrs), true}

      is_binary(attrs.replace_key) ->
        put_replaceable(attrs)

      true ->
        put_normal(attrs)
    end
  end

  def map_activity(event_id, activity_id, object_id) do
    activity_uri =
      case Activity.get_by_id(activity_id) do
        %Activity{data: %{"id" => uri}} when is_binary(uri) -> uri
        _ -> nil
      end

    Event
    |> where(id: ^event_id)
    |> Repo.update_all(
      set: [
        ap_activity_id: activity_id,
        ap_activity_uri: activity_uri,
        ap_object_id: object_id
      ]
    )

    :ok
  end

  def claim_activity(event_id, activity_id, object_id) do
    activity_uri =
      case Activity.get_by_id(activity_id) do
        %Activity{data: %{"id" => uri}} when is_binary(uri) -> uri
        _ -> nil
      end

    {claimed, _rows} =
      Event
      |> where(id: ^event_id)
      |> where([event], is_nil(event.ap_activity_id))
      |> Repo.update_all(
        set: [
          ap_activity_id: activity_id,
          ap_object_id: object_id
        ]
      )

    if claimed == 1 and is_binary(activity_uri) do
      Event
      |> where(id: ^event_id)
      |> where([event], is_nil(event.ap_activity_uri))
      |> Repo.update_all(set: [ap_activity_uri: activity_uri])
    end

    case Repo.get(Event, event_id) do
      %Event{ap_activity_id: ^activity_id} -> {:ok, :claimed}
      %Event{ap_activity_id: existing_id} when not is_nil(existing_id) -> {:ok, existing_id}
      _ -> {:error, :event_not_found}
    end
  end

  def get(id) when is_binary(id), do: Repo.get(Event, id)
  def get(_id), do: nil

  def get_by_ap_activity_id(activity_id) do
    Repo.get_by(Event, ap_activity_id: activity_id)
  end

  def get_by_ap_activity_uri(activity_uri) when is_binary(activity_uri) do
    Repo.get_by(Event, ap_activity_uri: activity_uri)
  end

  def get_by_ap_activity_uri(_activity_uri), do: nil

  def get_by_ap_object_id(object_id) when is_binary(object_id) do
    Event
    |> where(ap_object_id: ^object_id)
    |> order_by(desc: :created_at)
    |> limit(1)
    |> Repo.one()
  end

  def get_by_ap_object_id(_object_id), do: nil

  def query(filters) when is_list(filters) do
    events =
      filters
      |> Enum.flat_map(&query_filter/1)
      |> Enum.uniq_by(& &1.id)
      |> Enum.reject(&Semantics.expired?(&1.data))

    if Enum.any?(filters, &search_filter?/1) do
      Enum.sort_by(
        events,
        &{search_score(&1, filters), DateTime.to_unix(&1.created_at, :microsecond)},
        :desc
      )
    else
      Enum.sort_by(events, & &1.created_at, {:desc, DateTime})
    end
  end

  def query(_filters), do: []

  def delete_event(id, pubkey) do
    Event
    |> where(id: ^id, pubkey: ^pubkey)
    |> Repo.delete_all()

    :ok
  end

  defp put_normal(attrs) do
    changeset = Event.changeset(%Event{}, attrs)

    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:id]) do
      {:ok, %Event{} = stored} ->
        case Repo.get(Event, attrs.id) do
          %Event{inserted_at: inserted_at} = event when not is_nil(inserted_at) ->
            inserted? = stored.inserted_at == event.inserted_at
            {:ok, event, inserted?}

          _ ->
            {:error, :could_not_store}
        end

      error ->
        error
    end
  end

  defp put_replaceable(attrs) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [attrs.replace_key])

      current =
        Event
        |> where(replace_key: ^attrs.replace_key)
        |> order_by(desc: :created_at, asc: :id)
        |> limit(1)
        |> Repo.one()

      cond do
        current && preferred_replaceable?(current, attrs) ->
          {:ok, current, false}

        true ->
          Event
          |> where(replace_key: ^attrs.replace_key)
          |> Repo.delete_all()

          case Repo.insert(Event.changeset(%Event{}, attrs)) do
            {:ok, event} -> {:ok, event, true}
            {:error, changeset} -> Repo.rollback(changeset)
          end
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, error} -> {:error, error}
    end
  end

  defp query_filter(filter) do
    limit =
      filter
      |> Map.get("limit", config_integer(:max_filter_limit, 500))
      |> min(config_integer(:max_filter_limit, 500))

    candidate_limit =
      if search_filter?(filter),
        do: config_integer(:max_search_candidates, 10_000),
        else: config_integer(:max_query_candidates, 2_000)

    candidates =
      Event
      |> maybe_filter_ids(filter["ids"])
      |> maybe_filter_authors(filter["authors"])
      |> maybe_filter_kinds(filter["kinds"])
      |> maybe_filter_since(filter["since"])
      |> maybe_filter_until(filter["until"])
      |> order_by(desc: :created_at)
      |> limit(^candidate_limit)
      |> Repo.all()

    candidates
    |> Enum.filter(&Protocol.matches?(&1.data, filter))
    |> newest_replaceable()
    |> rank_search_results(filter)
    |> Enum.take(limit)
  end

  defp rank_search_results(events, %{"search" => search})
       when is_binary(search) and search != "" do
    Enum.sort_by(
      events,
      &{Protocol.search_score(&1.data, search), DateTime.to_unix(&1.created_at, :microsecond)},
      :desc
    )
  end

  defp rank_search_results(events, _filter), do: events

  defp search_score(event, filters) do
    filters
    |> Enum.map(&Protocol.search_score(event.data, &1["search"]))
    |> Enum.max(fn -> 0 end)
  end

  defp search_filter?(%{"search" => search}), do: is_binary(search) and search != ""
  defp search_filter?(_filter), do: false

  defp newest_replaceable(events) do
    events
    |> Enum.reduce(%{}, fn event, acc ->
      key = event.replace_key || event.id

      Map.update(acc, key, event, fn current ->
        if preferred_replaceable?(event, current), do: event, else: current
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
  end

  # NIP-01 resolves replaceable events with equal timestamps by retaining the
  # event with the lowest hexadecimal identifier. Applying the same comparison
  # in storage and query deduplication keeps relay arrival order from changing
  # the visible group, profile, or list state.
  defp preferred_replaceable?(candidate, current) do
    case DateTime.compare(candidate.created_at, current.created_at) do
      :gt -> true
      :lt -> false
      :eq -> candidate.id <= current.id
    end
  end

  defp maybe_filter_ids(query, nil), do: query

  defp maybe_filter_ids(query, ids) do
    where(query, [event], fragment("? LIKE ANY(?)", event.id, ^Enum.map(ids, &"#{&1}%")))
  end

  defp maybe_filter_authors(query, nil), do: query

  defp maybe_filter_authors(query, authors) do
    where(query, [event], fragment("? LIKE ANY(?)", event.pubkey, ^Enum.map(authors, &"#{&1}%")))
  end

  defp maybe_filter_kinds(query, nil), do: query
  defp maybe_filter_kinds(query, kinds), do: where(query, [event], event.kind in ^kinds)
  defp maybe_filter_since(query, nil), do: query

  defp maybe_filter_since(query, since) do
    where(query, [event], event.created_at >= ^DateTime.from_unix!(since))
  end

  defp maybe_filter_until(query, nil), do: query

  defp maybe_filter_until(query, until) do
    where(query, [event], event.created_at <= ^DateTime.from_unix!(until))
  end

  defp activitypub_proxy_uri(%{"tags" => tags}) when is_list(tags) do
    Enum.find_value(tags, fn
      ["proxy", uri, "activitypub" | _rest] when is_binary(uri) and byte_size(uri) <= 2_048 ->
        case URI.new(uri) do
          {:ok, %URI{scheme: "https", host: host, userinfo: nil}} when is_binary(host) -> uri
          _ -> nil
        end

      _tag ->
        nil
    end)
  end

  defp activitypub_proxy_uri(_event), do: nil

  defp config_integer(key, default) do
    case Config.get([Pleroma.Nostr, key], default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end
end

# end of nostr/store.ex
