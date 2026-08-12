# Unfathomably BE
# ----------------
#
# File: nostr/community_discovery.ex
#
# Purpose:
#   Discover active Nostr communities without trusting member totals or
#   importing unmoderated community submissions.
#
# Responsibilities:
#   - query approved relays through the existing bounded relay connection
#   - rank NIP-29 groups by recent messages and distinct authors
#   - validate NIP-72 definitions, moderators, approvals, and embedded posts
#   - update the existing Nostr group projection with activity metadata
#   - provide active group projections to the Mastodon-compatible group API
#
# This file intentionally does NOT publish group events, follow communities,
# accept unsigned data, or contact relays outside administrator policy.

defmodule Pleroma.Nostr.CommunityDiscovery do
  import Ecto.Query

  require Logger

  alias Pleroma.Nostr
  alias Pleroma.Nostr.Bridge
  alias Pleroma.Nostr.Entity
  alias Pleroma.Nostr.Identity
  alias Pleroma.Nostr.Protocol
  alias Pleroma.Nostr.RelayConnection
  alias Pleroma.Nostr.Semantics
  alias Pleroma.Repo

  @nip29_definition_kind 39_000
  @nip72_definition_kind 34_550
  @nip72_approval_kind 4_550
  @community_post_kinds [1, 9, 11, 20, 21, 22, 1_111]
  @activity_window_seconds 30 * 24 * 60 * 60
  @max_relays 8
  @max_events 2_500
  @max_definitions 2_000
  @max_discovered_per_relay 50
  @request_timeout_ms 10_000

  def refresh do
    Nostr.configured_relays()
    |> Enum.reject(&(&1 == Nostr.relay_url()))
    |> Enum.take(@max_relays)
    |> Task.async_stream(&refresh_relay/1,
      max_concurrency: 3,
      ordered: false,
      timeout: 60_000,
      on_timeout: :kill_task
    )
    |> Enum.each(fn
      {:ok, :ok} -> :ok
      {:ok, {:error, relay, reason}} -> log_refresh_failure(relay, reason)
      {:exit, reason} -> log_refresh_failure("unknown", reason)
    end)

    :ok
  end

  def discover_groups(params) when is_map(params) do
    limit = discovery_limit(params)

    Entity
    |> join(:inner, [entity], user in assoc(entity, :user))
    |> where([entity, user], entity.kind == "mirror_group" and user.is_active == true)
    |> where(
      [entity],
      fragment("coalesce((?->>'activity_30d')::integer, 0) > 0", entity.metadata)
    )
    |> where(
      [_entity, user],
      fragment(
        "EXISTS (SELECT 1 FROM activities AS activity WHERE activity.recipients @> ARRAY[?] AND activity.data->>'type' IN ('Create', 'Announce'))",
        user.ap_id
      )
    )
    |> order_by([entity],
      desc: fragment("coalesce((?->>'active_authors_30d')::integer, 0)", entity.metadata),
      desc: fragment("coalesce(?->>'last_activity_at', '')", entity.metadata),
      desc: fragment("coalesce((?->>'activity_30d')::integer, 0)", entity.metadata)
    )
    |> limit(^limit)
    |> select([_entity, user], user)
    |> Repo.all()
  end

  def discover_groups(_params), do: []

  def authorize_approved_submission(event, approval, definition) do
    coordinate = definition_coordinate(definition)
    moderator_pubkeys = moderator_pubkeys(definition)

    with {:ok, event} <- Protocol.validate_event(event),
         {:ok, approval} <- Protocol.validate_event(approval),
         {:ok, definition} <- Protocol.validate_event(definition),
         true <- definition["kind"] == @nip72_definition_kind,
         true <- approval["kind"] == @nip72_approval_kind,
         true <- is_binary(coordinate),
         true <- approval["pubkey"] in moderator_pubkeys,
         true <- coordinate in approval_coordinates(approval),
         true <- event["kind"] in @community_post_kinds,
         true <- approved_event_id?(approval, event["id"]),
         true <- event["pubkey"] in Protocol.tag_values(approval, "p"),
         true <- approved_community_reference?(event, coordinate),
         :ok <- Semantics.bridgeable?(event) do
      :ok
    else
      _ -> {:error, "restricted", "NIP-72 submission is not approved by this community"}
    end
  end

  defp refresh_relay(relay_url) do
    with :ok <- refresh_nip29(relay_url),
         :ok <- refresh_nip72(relay_url) do
      :ok
    else
      {:error, reason} -> {:error, relay_url, reason}
    end
  rescue
    error -> {:error, relay_url, Exception.message(error)}
  end

  defp refresh_nip29(relay_url) do
    with {:ok, raw_definitions} <-
           relay_request(relay_url, [
             %{"kinds" => [@nip29_definition_kind], "limit" => @max_definitions}
           ]) do
      definitions =
        raw_definitions
        |> valid_events(@nip29_definition_kind)
        |> latest_nip29_definitions()

      activity =
        definitions
        |> Map.keys()
        |> Enum.chunk_every(250)
        |> Enum.flat_map(fn group_ids ->
          case relay_request(relay_url, [
                 %{
                   "#h" => group_ids,
                   "kinds" => @community_post_kinds,
                   "limit" => @max_events,
                   "since" => activity_window_start()
                 }
               ]) do
            {:ok, events} -> valid_community_posts(events)
            {:error, _reason} -> []
          end
        end)
        |> Enum.uniq_by(& &1["id"])

      activity
      |> Enum.group_by(&Protocol.tag_value(&1, "h"))
      |> Enum.reject(fn {group_id, _events} -> not is_binary(group_id) end)
      |> Enum.map(fn {group_id, events} ->
        {group_id, events, activity_metadata(events, "nip29")}
      end)
      |> Enum.filter(fn {_group_id, _events, metadata} ->
        metadata["activity_30d"] >= 3 and metadata["active_authors_30d"] >= 2
      end)
      |> Enum.sort_by(
        fn {_group_id, _events, metadata} ->
          {metadata["active_authors_30d"], metadata["activity_30d"]}
        end,
        :desc
      )
      |> Enum.take(@max_discovered_per_relay)
      |> Enum.each(fn {group_id, events, metadata} ->
        case Map.get(definitions, group_id) do
          %{} = definition ->
            with {:ok, _group} <-
                   Identity.upsert_discovered_group(
                     definition,
                     relay_url,
                     "nip29",
                     metadata
                   ) do
              events
              |> Enum.sort_by(& &1["created_at"], :desc)
              |> Enum.take(50)
              |> Enum.each(&Bridge.ingest_event(&1, relay_url, :relay))
            end

          _ ->
            :ok
        end
      end)

      :ok
    end
  end

  defp refresh_nip72(relay_url) do
    with {:ok, raw_approvals} <-
           relay_request(relay_url, [
             %{
               "kinds" => [@nip72_approval_kind],
               "limit" => @max_events,
               "since" => activity_window_start()
             }
           ]) do
      approvals = valid_events(raw_approvals, @nip72_approval_kind)

      communities =
        approvals
        |> Enum.flat_map(fn approval ->
          Enum.map(approval_coordinates(approval), &{&1, approval})
        end)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Enum.sort_by(fn {_coordinate, events} -> length(events) end, :desc)
        |> Enum.take(@max_discovered_per_relay)

      definitions = fetch_nip72_definitions(relay_url, Enum.map(communities, &elem(&1, 0)))

      Enum.each(communities, fn {coordinate, community_approvals} ->
        case Map.get(definitions, coordinate) do
          %{} = definition ->
            approved =
              Enum.filter(community_approvals, fn approval ->
                approval["pubkey"] in moderator_pubkeys(definition)
              end)

            metadata = activity_metadata(approved, "nip72")

            if metadata["activity_30d"] >= 2 do
              with {:ok, _group} <-
                     Identity.upsert_discovered_group(
                       definition,
                       relay_url,
                       "nip72",
                       metadata
                     ) do
                approved
                |> Enum.sort_by(& &1["created_at"], :desc)
                |> Enum.take(50)
                |> Enum.each(&import_approved_submission(&1, definition, relay_url))
              end
            end

          _ ->
            :ok
        end
      end)

      :ok
    end
  end

  defp fetch_nip72_definitions(_relay_url, []), do: %{}

  defp fetch_nip72_definitions(relay_url, coordinates) do
    filters =
      Enum.flat_map(coordinates, fn coordinate ->
        case parse_coordinate(coordinate) do
          {:ok, pubkey, identifier} ->
            [
              %{
                "authors" => [pubkey],
                "#d" => [identifier],
                "kinds" => [@nip72_definition_kind],
                "limit" => 1
              }
            ]

          :error ->
            []
        end
      end)

    case relay_request(relay_url, filters) do
      {:ok, events} ->
        events
        |> valid_events(@nip72_definition_kind)
        |> Enum.reduce(%{}, fn definition, definitions ->
          case definition_coordinate(definition) do
            coordinate when is_binary(coordinate) ->
              Map.update(definitions, coordinate, definition, fn current ->
                if definition["created_at"] > current["created_at"],
                  do: definition,
                  else: current
              end)

            _ ->
              definitions
          end
        end)

      {:error, _reason} ->
        %{}
    end
  end

  defp import_approved_submission(approval, definition, relay_url) do
    with content when is_binary(content) and content != "" <- approval["content"],
         {:ok, event} when is_map(event) <- Jason.decode(content),
         {:ok, _event} <-
           Bridge.ingest_approved_community_event(event, approval, definition, relay_url) do
      :ok
    else
      _ -> :ok
    end
  end

  defp relay_request(_relay_url, []), do: {:ok, []}

  defp relay_request(relay_url, filters) do
    subscription_id =
      "community-discovery-" <>
        Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    case RelayConnection.request(
           relay_url,
           subscription_id,
           filters,
           self(),
           @request_timeout_ms
         ) do
      :ok -> collect_relay_events(relay_url, subscription_id, [])
      error -> {:error, error}
    end
  end

  defp collect_relay_events(_relay_url, _subscription_id, events)
       when length(events) >= @max_events,
       do: {:ok, Enum.reverse(events)}

  defp collect_relay_events(relay_url, subscription_id, events) do
    receive do
      {:nostr_relay_event, ^relay_url, ^subscription_id, event} when is_map(event) ->
        collect_relay_events(relay_url, subscription_id, [event | events])

      {:nostr_relay_eose, ^relay_url, ^subscription_id, _reason} ->
        {:ok, Enum.reverse(events)}
    after
      @request_timeout_ms + 1_000 -> {:ok, Enum.reverse(events)}
    end
  end

  defp valid_events(events, kind) do
    Enum.flat_map(events, fn event ->
      case Protocol.validate_event(event) do
        {:ok, %{"kind" => ^kind} = valid} -> [valid]
        _ -> []
      end
    end)
  end

  defp valid_community_posts(events) do
    Enum.flat_map(events, fn event ->
      case Protocol.validate_event(event) do
        {:ok, %{"kind" => kind} = valid} when kind in @community_post_kinds ->
          if Semantics.protected?(valid) or Semantics.expired?(valid), do: [], else: [valid]

        _ ->
          []
      end
    end)
  end

  defp latest_nip29_definitions(definitions) do
    Enum.reduce(definitions, %{}, fn definition, result ->
      case Protocol.tag_value(definition, "d") do
        group_id when is_binary(group_id) and group_id != "" ->
          Map.update(result, group_id, definition, fn current ->
            if definition["created_at"] > current["created_at"],
              do: definition,
              else: current
          end)

        _ ->
          result
      end
    end)
  end

  defp activity_metadata(events, standard) do
    unique_events = Enum.uniq_by(events, &activity_identity/1)
    authors = unique_events |> Enum.flat_map(&activity_authors/1) |> Enum.uniq()

    latest =
      unique_events
      |> Enum.map(& &1["created_at"])
      |> Enum.filter(&is_integer/1)
      |> Enum.max(fn -> 0 end)

    %{
      "community_standard" => standard,
      "activity_30d" => length(unique_events),
      "active_authors_30d" => length(authors),
      "last_activity_at" => unix_iso8601(latest)
    }
  end

  defp activity_identity(%{"kind" => @nip72_approval_kind} = approval) do
    Protocol.tag_value(approval, "e") || Protocol.tag_value(approval, "a") || approval["id"]
  end

  defp activity_identity(event), do: event["id"]

  defp activity_authors(%{"kind" => @nip72_approval_kind} = approval),
    do: Protocol.tag_values(approval, "p")

  defp activity_authors(event), do: List.wrap(event["pubkey"])

  defp definition_coordinate(%{"kind" => @nip72_definition_kind} = definition) do
    case Protocol.tag_value(definition, "d") do
      identifier when is_binary(identifier) and identifier != "" ->
        "34550:#{definition["pubkey"]}:#{identifier}"

      _ ->
        nil
    end
  end

  defp definition_coordinate(_definition), do: nil

  defp approval_coordinates(approval) do
    approval
    |> Protocol.tag_values("a")
    |> Enum.filter(&match?({:ok, _pubkey, _identifier}, parse_coordinate(&1)))
    |> Enum.uniq()
  end

  defp community_references(event) do
    (Protocol.tag_values(event, "A") ++ Protocol.tag_values(event, "a"))
    |> Enum.filter(&String.starts_with?(&1, "34550:"))
    |> Enum.uniq()
  end

  # Some NIP-72 clients put the community coordinate only on the moderator's
  # approval. That signature is authoritative, but an embedded submission that
  # does name communities must include the exact community being approved.
  defp approved_community_reference?(event, coordinate) do
    case community_references(event) do
      [] -> true
      references -> coordinate in references
    end
  end

  defp moderator_pubkeys(definition) do
    declared =
      definition["tags"]
      |> List.wrap()
      |> Enum.flat_map(fn
        ["p", pubkey, _relay, "moderator" | _rest] -> [pubkey]
        _tag -> []
      end)

    [definition["pubkey"] | declared]
    |> Enum.filter(&valid_pubkey?/1)
    |> Enum.uniq()
  end

  defp approved_event_id?(approval, event_id) when is_binary(event_id) do
    event_id in Protocol.tag_values(approval, "e")
  end

  defp approved_event_id?(_approval, _event_id), do: false

  defp parse_coordinate("34550:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [pubkey, identifier] when identifier != "" ->
        if valid_pubkey?(pubkey), do: {:ok, pubkey, identifier}, else: :error

      _ ->
        :error
    end
  end

  defp parse_coordinate(_coordinate), do: :error

  defp valid_pubkey?(pubkey),
    do: is_binary(pubkey) and Regex.match?(~r/\A[0-9a-f]{64}\z/, pubkey)

  defp unix_iso8601(timestamp) when is_integer(timestamp) and timestamp > 0 do
    timestamp
    |> DateTime.from_unix!()
    |> DateTime.to_iso8601()
  end

  defp unix_iso8601(_timestamp), do: nil

  defp activity_window_start, do: System.system_time(:second) - @activity_window_seconds

  defp discovery_limit(params) do
    value = Map.get(params, "limit", Map.get(params, :limit, 20))

    case value do
      limit when is_integer(limit) ->
        limit |> max(1) |> min(50)

      limit when is_binary(limit) ->
        case Integer.parse(limit) do
          {parsed, ""} -> parsed |> max(1) |> min(50)
          _ -> 20
        end

      _ ->
        20
    end
  end

  defp log_refresh_failure(relay, reason) do
    Logger.debug("Nostr community discovery skipped relay",
      relay: relay,
      reason: inspect(reason)
    )
  end
end

# end of nostr/community_discovery.ex
