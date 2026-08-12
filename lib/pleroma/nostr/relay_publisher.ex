# Unfathomably BE
# ----------------
#
# File: nostr/relay_publisher.ex
#
# Purpose:
#   Forward locally accepted user-signed events to approved external relays.
#
# Responsibilities:
#   - derive per-author write destinations from signed NIP-65 events
#   - start bounded server-side relay connections when needed
#   - keep external WebSocket traffic out of web browsers
#
# This file intentionally does NOT sign events, accept unverified events, or
# expose relay credentials to clients.

defmodule Pleroma.Nostr.RelayPublisher do
  require Logger

  alias Pleroma.Nostr
  alias Pleroma.Nostr.Event
  alias Pleroma.Nostr.Identity
  alias Pleroma.Nostr.Protocol
  alias Pleroma.Nostr.RelayConnection
  alias Pleroma.Nostr.Semantics
  alias Pleroma.Nostr.Store

  @relay_limit 8
  @relay_supervisor Pleroma.Nostr.RelayConnectionSupervisor

  def publish(%{"pubkey" => pubkey} = event) when is_binary(pubkey) do
    unless Semantics.protected?(event) do
      event
      |> relay_preferences()
      |> Enum.each(&publish_to_relay(&1, event))
    end

    :ok
  end

  def publish(_event), do: :ok

  defp relay_preferences(%{"kind" => 10_002} = event) do
    relay_preferences_from_tags(event["tags"], true)
  end

  defp relay_preferences(%{"pubkey" => pubkey} = event) do
    if is_binary(Protocol.tag_value(event, "h")) do
      normalize_relay_preferences(Nostr.group_relays() ++ recipient_read_relays(event))
    else
      author_relays = author_write_relays(pubkey)
      recipient_relays = recipient_read_relays(event)
      normalize_relay_preferences(author_relays ++ recipient_relays)
    end
  end

  defp author_write_relays(pubkey) do
    case Store.query([%{"authors" => [pubkey], "kinds" => [10_002], "limit" => 1}]) do
      [%Event{data: event} | _events] -> relay_preferences_from_tags(event["tags"], false)
      _events -> []
    end
  end

  defp recipient_read_relays(event) do
    event
    |> Protocol.tag_values("p")
    |> Enum.flat_map(fn pubkey ->
      case Identity.get_profile(pubkey) do
        %{user: user} when not is_nil(user) -> Identity.relays_for_user(user, :read)
        _ -> []
      end
    end)
  end

  defp relay_preferences_from_tags(tags, include_read_relays) do
    tags
    |> List.wrap()
    |> Enum.reduce([], fn
      ["r", relay_url, marker | _values], relays
      when is_binary(relay_url) and
             (include_read_relays or marker != "read") ->
        [relay_url | relays]

      ["r", relay_url], relays when is_binary(relay_url) ->
        [relay_url | relays]

      _tag, relays ->
        relays
    end)
    |> Enum.reverse()
    |> normalize_relay_preferences()
  end

  defp normalize_relay_preferences(relays) do
    relays
    |> Enum.map(&Protocol.normalize_relay_url/1)
    |> Enum.filter(&Nostr.allowed_relay?/1)
    |> Enum.reject(&(&1 == Nostr.relay_url()))
    |> Enum.uniq()
    |> Enum.take(@relay_limit)
  end

  defp publish_to_relay(relay_url, event) do
    case ensure_connection(relay_url) do
      :ok ->
        safe_publish(relay_url, event)

      {:error, reason} ->
        Logger.debug("Nostr event relay unavailable",
          relay: relay_url,
          reason: inspect(reason)
        )
    end
  end

  defp ensure_connection(relay_url) do
    case Process.whereis(@relay_supervisor) do
      pid when is_pid(pid) ->
        case DynamicSupervisor.start_child(pid, {RelayConnection, relay_url}) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end

      nil ->
        {:error, :relay_supervisor_not_running}
    end
  end

  defp safe_publish(relay_url, event) do
    case Pleroma.Workers.NostrRelayPublishWorker.enqueue_delivery(event, relay_url) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Nostr relay publication could not be queued",
          relay: relay_url,
          event_id: event["id"],
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end
end

# end of nostr/relay_publisher.ex
