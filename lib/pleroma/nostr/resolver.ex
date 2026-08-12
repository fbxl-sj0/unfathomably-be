# Unfathomably BE
# ----------------
#
# File: nostr/resolver.ex
#
# Purpose:
#   Resolve an explicit NIP-19 event reference into an ordinary local status.
#
# Responsibilities:
#   - accept only note and nevent identifiers selected by a user
#   - query a bounded set of operator-approved or identity-owned relays
#   - verify the requested event id, optional author, and event signature
#   - ingest the event through the normal Nostr bridge policy
#
# This file intentionally does NOT perform text search, crawl event links, or
# treat relay data as trusted before normal bridge validation.

defmodule Pleroma.Nostr.Resolver do
  require Logger

  alias Pleroma.Activity
  alias Pleroma.Nostr.Bridge
  alias Pleroma.Nostr.Entity
  alias Pleroma.Nostr.Identity
  alias Pleroma.Nostr.Protocol
  alias Pleroma.Nostr.RelayConnection
  alias Pleroma.Nostr.RelayManager
  alias Pleroma.Nostr.Store

  @event_id_regex ~r/\A[0-9a-f]{64}\z/
  @maximum_relays 6
  @preferred_relays_per_source 2
  @request_timeout_ms 2_000

  def resolve_activity(identifier)
      when is_binary(identifier) and byte_size(identifier) <= 2_048 do
    with {:ok, target} <- parse_target(identifier) do
      stored_activity(target.event_id) || fetch_activity(target)
    else
      reason ->
        Logger.debug("Explicit Nostr event reference was rejected: #{inspect(reason)}")
        nil
    end
  rescue
    error ->
      Logger.debug("Explicit Nostr event resolution raised: #{Exception.message(error)}")
      nil
  catch
    kind, reason ->
      Logger.debug("Explicit Nostr event resolution caught #{kind}: #{inspect(reason)}")
      nil
  end

  def resolve_activity(_identifier), do: nil

  defp parse_target(identifier) do
    uri =
      identifier
      |> String.trim()
      |> then(fn value ->
        if String.starts_with?(value, "nostr:"), do: value, else: "nostr:" <> value
      end)

    case Nostr.NIP21.parse(uri) do
      {:ok, :note, event_id} when is_binary(event_id) ->
        target(event_id, nil, [])

      {:ok, :nevent, event} when is_map(event) ->
        target(
          value(event, :event_id) || value(event, :id),
          value(event, :author) || value(event, :pubkey),
          value(event, :relays) || []
        )

      _ ->
        {:error, :unsupported_identifier}
    end
  end

  defp target(event_id, author, relays) do
    cond do
      not valid_event_id?(event_id) ->
        {:error, :invalid_event_id}

      not is_nil(author) and not valid_event_id?(author) ->
        {:error, :invalid_author}

      true ->
        {:ok, %{event_id: event_id, author: author, relays: List.wrap(relays)}}
    end
  end

  defp fetch_activity(target) do
    with :ok <- ensure_target_author(target),
         relays when relays != [] <- destination_relays(target),
         {:ok, event, relay_url} <- fetch_event(target, relays),
         :ok <- ensure_event_author(target, event, relay_url),
         {:ok, _stored_event} <-
           Bridge.ingest_event(event, relay_url, {:profile_backfill, event["pubkey"]}) do
      stored_activity(target.event_id)
    else
      reason ->
        Logger.debug(
          "Explicit Nostr event resolution failed event_id=#{String.slice(target.event_id, 0, 12)} reason=#{inspect(reason)}"
        )

        nil
    end
  end

  defp stored_activity(event_id) do
    case Store.get(event_id) do
      %{ap_activity_id: activity_id} when not is_nil(activity_id) ->
        Activity.get_by_id_with_object(activity_id)

      _ ->
        nil
    end
  end

  defp ensure_target_author(%{author: nil}), do: :ok

  defp ensure_target_author(%{author: author} = target) do
    case Identity.get_profile(author) do
      %Entity{} ->
        :ok

      nil ->
        case Identity.resolve(%{
               type: :profile,
               pubkey: author,
               relays: approved_relays(target.relays ++ configured_relays())
             }) do
          {:ok, _user} -> :ok
          _ -> {:error, :unknown_author}
        end
    end
  end

  defp ensure_event_author(%{author: author}, %{"pubkey" => author}, _relay_url)
       when is_binary(author),
       do: :ok

  defp ensure_event_author(%{author: author}, _event, _relay_url) when is_binary(author),
    do: {:error, :author_mismatch}

  defp ensure_event_author(%{author: nil}, %{"pubkey" => pubkey}, relay_url) do
    case Identity.get_profile(pubkey) do
      %Entity{} ->
        :ok

      nil ->
        case Identity.resolve(%{type: :profile, pubkey: pubkey, relays: [relay_url]}) do
          {:ok, _user} -> :ok
          _ -> {:error, :unknown_author}
        end
    end
  end

  defp destination_relays(target) do
    target_relays = approved_relays(target.relays)

    identity_relays =
      case target.author && Identity.get_profile(target.author) do
        %Entity{} = entity -> Identity.relay_urls(entity, :read)
        _ -> []
      end
      |> approved_relays()

    operator_relays = approved_relays(configured_relays())

    preferred_relays =
      Enum.take(target_relays, @preferred_relays_per_source) ++
        Enum.take(identity_relays, @preferred_relays_per_source) ++
        Enum.take(operator_relays, @preferred_relays_per_source)

    (preferred_relays ++ target_relays ++ identity_relays ++ operator_relays)
    |> Enum.uniq()
    |> Enum.take(@maximum_relays)
  end

  defp configured_relays do
    Pleroma.Nostr.configured_relays() ++ Pleroma.Nostr.search_relays()
  end

  defp approved_relays(relays) do
    relays
    |> Enum.map(&Protocol.normalize_relay_url/1)
    |> Enum.filter(&Pleroma.Nostr.allowed_relay?/1)
    |> Enum.reject(&(&1 == Pleroma.Nostr.relay_url()))
    |> Enum.reject(&Pleroma.Nostr.compatibility_relay?/1)
    |> Enum.uniq()
  end

  defp fetch_event(target, relays) do
    pending =
      Enum.reduce(relays, MapSet.new(), fn relay_url, pending ->
        subscription_id = subscription_id()
        RelayManager.ensure_connection(relay_url)

        case RelayConnection.request(
               relay_url,
               subscription_id,
               [%{"ids" => [target.event_id], "limit" => 1}],
               self(),
               @request_timeout_ms
             ) do
          :ok -> MapSet.put(pending, {relay_url, subscription_id})
          _ -> pending
        end
      end)

    collect_event(
      pending,
      target,
      System.monotonic_time(:millisecond) + @request_timeout_ms
    )
  end

  defp collect_event(pending, target, deadline) do
    if MapSet.size(pending) == 0 do
      {:error, :not_found}
    else
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      if remaining == 0 do
        {:error, :timeout}
      else
        receive do
          {:nostr_relay_event, relay_url, subscription_id, raw_event} ->
            key = {relay_url, subscription_id}

            if MapSet.member?(pending, key) do
              case Protocol.validate_event(raw_event) do
                {:ok, %{"id" => event_id} = event} when event_id == target.event_id ->
                  {:ok, event, relay_url}

                _ ->
                  collect_event(pending, target, deadline)
              end
            else
              collect_event(pending, target, deadline)
            end

          {:nostr_relay_eose, relay_url, subscription_id, _reason} ->
            pending = MapSet.delete(pending, {relay_url, subscription_id})
            collect_event(pending, target, deadline)

          _other ->
            collect_event(pending, target, deadline)
        after
          remaining -> {:error, :timeout}
        end
      end
    end
  end

  defp valid_event_id?(value),
    do: is_binary(value) and Regex.match?(@event_id_regex, value)

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp subscription_id do
    "unfathomably-resolve-#{System.unique_integer([:positive, :monotonic])}"
  end
end

# end of nostr/resolver.ex
