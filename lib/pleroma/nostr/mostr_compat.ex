# Unfathomably BE
# ----------------
#
# File: nostr/mostr_compat.ex
#
# Purpose:
#   Reconcile Mostr ActivityPub projections with validated native Nostr events.
#
# Responsibilities:
#   - recognize Mostr object URLs and authoritative FEP-fffd Nostr proxies
#   - prefer an existing native ActivityPub projection of a signed Nostr event
#   - retarget replies, quotes, reposts, reactions, and deletes to native objects
#   - resolve legacy Mostr actor identifiers through native Nostr identities
#   - prevent legacy bridge URLs from becoming live network dependencies
#
# This file intentionally does NOT trust Mostr to sign for a Nostr author,
# connect to Mostr, or delete historical Mostr records.

defmodule Pleroma.Nostr.MostrCompat do
  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.Nostr, as: NativeNostr
  alias Pleroma.Nostr.Bridge
  alias Pleroma.Nostr.Event
  alias Pleroma.Nostr.Identity
  alias Pleroma.Nostr.Protocol
  alias Pleroma.Nostr.RelayConnection
  alias Pleroma.Nostr.RelayManager
  alias Pleroma.Nostr.Store
  alias Pleroma.Object
  alias Pleroma.User
  alias Pleroma.Workers.NostrProfileBackfillWorker

  @nostr_protocol "https://github.com/nostr-protocol/nostr"
  @default_mostr_hosts ["mostr.pub", "momostr.pink"]
  @default_native_lookup_max_relays 3
  @default_native_lookup_timeout_ms 1_200
  @hex_event ~r/\A[0-9a-f]{64}\z/
  @hex_pubkey ~r/\A[0-9a-f]{64}\z/
  @target_activity_types ~w[Add Announce Block Delete Dislike EmojiReact Like Remove]
  @content_kinds [1, 9, 11, 1_111, 30_023]

  @spec handle_incoming(map(), (map() -> term())) :: term()
  def handle_incoming(data, fallback) when is_map(data) and is_function(fallback, 1) do
    case existing_projection(data) do
      {:activity, %Activity{} = activity} ->
        {:ok, activity}

      :verified_without_projection ->
        {:error, :already_present}

      nil ->
        if legacy_envelope?(data) do
          {:reject, :native_nostr_required}
        else
          case rewrite_references(data) do
            {:ok, rewritten} -> fallback.(rewritten)
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  def handle_incoming(data, fallback) when is_function(fallback, 1), do: fallback.(data)

  @doc """
  Resolves a recognized Mostr object through approved native Nostr relays.

  Relay responses still pass the normal cryptographic and bridge authorization
  pipeline. A recognized Mostr URL never falls back to ActivityPub because that
  would restore the bridge as a runtime dependency.
  """
  @spec fetch_native_object(term()) ::
          {:ok, Object.t()} | {:error, atom()} | :miss | :not_applicable
  def fetch_native_object(reference) do
    legacy_reference? = legacy_event_reference?(reference)

    with event_id when is_binary(event_id) <- reference_event_id(reference) do
      if NativeNostr.enabled?() do
        case native_object(event_id) do
          %Object{} = object ->
            {:ok, object}

          nil ->
            case fetch_native_object_from_relays(event_id) do
              :miss when legacy_reference? -> {:error, :native_nostr_not_found}
              result -> result
            end
        end
      else
        if legacy_reference?,
          do: {:error, :native_nostr_disabled},
          else: :not_applicable
      end
    else
      _ -> :not_applicable
    end
  rescue
    _ ->
      if legacy_event_reference?(reference),
        do: {:error, :native_nostr_lookup_failed},
        else: :miss
  catch
    :exit, _reason ->
      if legacy_event_reference?(reference),
        do: {:error, :native_nostr_lookup_failed},
        else: :miss
  end

  @doc """
  Resolves a legacy Mostr actor URL or handle as a native Nostr profile.

  The public key is identity material, not profile metadata. The resulting
  placeholder is hydrated only from administrator-approved Nostr relays, where
  every accepted profile event must carry a valid signature from that key.
  """
  @spec resolve_native_actor(term()) ::
          {:ok, User.t()} | {:error, atom() | term()} | :not_applicable
  def resolve_native_actor(reference) do
    with pubkey when is_binary(pubkey) <- reference_pubkey(reference) do
      if NativeNostr.enabled?() do
        with {:ok, identity} <- Protocol.decode_identifier(pubkey),
             {:ok, %User{} = user} <- Identity.resolve(identity) do
          NostrProfileBackfillWorker.enqueue(user)
          {:ok, user}
        end
      else
        {:error, :native_nostr_disabled}
      end
    else
      _ -> :not_applicable
    end
  rescue
    _ -> {:error, :native_nostr_lookup_failed}
  catch
    :exit, _reason -> {:error, :native_nostr_lookup_failed}
  end

  @doc """
  Returns whether a URL or handle belongs to a configured legacy Mostr host.
  """
  @spec legacy_reference?(term()) :: boolean()
  def legacy_reference?(%{"id" => reference}), do: legacy_reference?(reference)

  def legacy_reference?(reference) when is_binary(reference) do
    reference = reference |> String.trim() |> String.trim_leading("@")

    case URI.parse(reference) do
      %URI{host: host} when is_binary(host) ->
        allowed_mostr_host?(host)

      _ ->
        legacy_handle_host?(reference)
    end
  rescue
    URI.Error -> false
  end

  def legacy_reference?(_reference), do: false

  @doc """
  Returns whether an ActivityPub envelope originates from a legacy Mostr
  projection.

  This check intentionally uses only the envelope identifiers. Mostr traffic
  is discarded before actor hydration or worker insertion; native relay
  ingestion remains the sole source of Nostr events and profiles.
  """
  @spec legacy_envelope?(term()) :: boolean()
  def legacy_envelope?(data) when is_map(data) do
    legacy_reference?(data["id"]) or legacy_reference?(data["actor"])
  end

  def legacy_envelope?(_data), do: false

  @spec canonical_object_id(term()) :: String.t() | nil
  def canonical_object_id(reference) do
    with event_id when is_binary(event_id) <- reference_event_id(reference),
         %Event{ap_object_id: object_id, data: event} <- Store.get(event_id),
         false <- Protocol.proxy_activitypub?(event),
         true <- is_binary(object_id) do
      object_id
    else
      _ -> nil
    end
  end

  defp existing_projection(data) do
    data
    |> direct_event_ids()
    |> Enum.find_value(fn event_id ->
      case Store.get(event_id) do
        %Event{data: event} = stored ->
          projection_for(data["type"], stored, event)

        nil ->
          nil
      end
    end)
  end

  defp projection_for(incoming_type, %Event{} = stored, event) do
    cond do
      Protocol.proxy_activitypub?(event) ->
        nil

      not event_kind_matches_activity?(stored.kind, incoming_type) ->
        nil

      is_nil(stored.ap_activity_id) ->
        :verified_without_projection

      true ->
        case Activity.get_by_id(stored.ap_activity_id) do
          %Activity{data: %{"type" => ^incoming_type}} = activity -> {:activity, activity}
          _ -> nil
        end
    end
  end

  defp event_kind_matches_activity?(kind, "Create"), do: kind in @content_kinds
  defp event_kind_matches_activity?(6, "Announce"), do: true
  defp event_kind_matches_activity?(7, type) when type in ["Like", "EmojiReact"], do: true
  defp event_kind_matches_activity?(5, "Delete"), do: true
  defp event_kind_matches_activity?(_kind, _type), do: false

  defp direct_event_ids(%{"type" => "Create", "object" => %{} = object} = data) do
    [
      proxy_event_id(data),
      mostr_event_id(data["id"]),
      proxy_event_id(object),
      mostr_event_id(object["id"])
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp direct_event_ids(data) do
    [proxy_event_id(data), mostr_event_id(data["id"])]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp rewrite_references(%{"type" => "Create", "object" => %{} = object} = data) do
    with {:ok, object} <-
           rewrite_object_fields(object, [
             "inReplyTo",
             "quoteUrl",
             "quoteUri",
             "_misskey_quote"
           ]) do
      {:ok, Map.put(data, "object", object)}
    end
  end

  defp rewrite_references(%{"type" => "Undo", "object" => %{} = object} = data) do
    with {:ok, object} <- rewrite_references(object) do
      {:ok, Map.put(data, "object", object)}
    end
  end

  defp rewrite_references(%{"type" => type, "object" => object} = data)
       when type in @target_activity_types do
    with {:ok, object} <- rewrite_reference(object) do
      {:ok, Map.put(data, "object", object)}
    end
  end

  defp rewrite_references(data), do: {:ok, data}

  defp rewrite_object_fields(object, fields) do
    Enum.reduce_while(fields, {:ok, object}, fn field, {:ok, acc} ->
      case Map.fetch(acc, field) do
        {:ok, value} ->
          case rewrite_reference(value) do
            {:ok, rewritten} -> {:cont, {:ok, Map.put(acc, field, rewritten)}}
            {:error, _reason} = error -> {:halt, error}
          end

        :error ->
          {:cont, {:ok, acc}}
      end
    end)
  end

  defp rewrite_reference(references) when is_list(references) do
    Enum.reduce_while(references, {:ok, []}, fn reference, {:ok, acc} ->
      case rewrite_reference(reference) do
        {:ok, rewritten} -> {:cont, {:ok, [rewritten | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rewritten} -> {:ok, Enum.reverse(rewritten)}
      error -> error
    end
  end

  defp rewrite_reference(reference) do
    case canonical_object_id(reference) do
      object_id when is_binary(object_id) ->
        {:ok, object_id}

      nil ->
        case fetch_native_object(reference) do
          {:ok, %Object{data: %{"id" => object_id}}} when is_binary(object_id) ->
            {:ok, object_id}

          result when result in [:miss, :not_applicable] ->
            {:ok, reference}

          {:error, reason} ->
            {:error, reason}

          _ ->
            {:error, :native_nostr_lookup_failed}
        end
    end
  end

  defp fetch_native_object_from_relays(event_id) do
    relays =
      NativeNostr.profile_discovery_relays()
      |> Enum.take(native_lookup_max_relays())

    pending =
      Enum.reduce(relays, MapSet.new(), fn relay_url, pending ->
        RelayManager.ensure_connection(relay_url)
        subscription_id = native_lookup_subscription_id(event_id)

        case RelayConnection.request(
               relay_url,
               subscription_id,
               [%{"ids" => [event_id], "limit" => 1}],
               self(),
               native_lookup_timeout_ms()
             ) do
          :ok -> MapSet.put(pending, {relay_url, subscription_id})
          _ -> pending
        end
      end)

    deadline =
      System.monotonic_time(:millisecond) + native_lookup_timeout_ms() + 250

    collect_native_object(pending, event_id, deadline)
  end

  defp collect_native_object(pending, event_id, deadline) do
    if MapSet.size(pending) == 0 do
      :miss
    else
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      if remaining == 0 do
        :miss
      else
        receive do
          {:nostr_relay_event, relay_url, subscription_id, %{"id" => ^event_id} = event} ->
            key = {relay_url, subscription_id}

            if MapSet.member?(pending, key) do
              case Bridge.ingest_event(event, relay_url, :relay) do
                {:ok, _event} ->
                  case native_object(event_id) do
                    %Object{} = object -> {:ok, object}
                    nil -> collect_native_object(pending, event_id, deadline)
                  end

                _rejected ->
                  collect_native_object(pending, event_id, deadline)
              end
            else
              collect_native_object(pending, event_id, deadline)
            end

          {:nostr_relay_eose, relay_url, subscription_id, _reason} ->
            pending = MapSet.delete(pending, {relay_url, subscription_id})
            collect_native_object(pending, event_id, deadline)

          _other ->
            collect_native_object(pending, event_id, deadline)
        after
          remaining -> :miss
        end
      end
    end
  end

  defp native_object(event_id) do
    with %Event{data: event, ap_object_id: object_id} <- Store.get(event_id),
         false <- Protocol.proxy_activitypub?(event),
         true <- is_binary(object_id),
         %Object{} = object <- Object.get_by_ap_id(object_id) do
      object
    else
      _ -> nil
    end
  end

  defp native_lookup_subscription_id(event_id) do
    unique = System.unique_integer([:positive, :monotonic])
    "unfathomably-mostr-#{String.slice(event_id, 0, 12)}-#{unique}"
  end

  defp native_lookup_max_relays do
    case Config.get(
           [NativeNostr, :mostr_native_lookup_max_relays],
           @default_native_lookup_max_relays
         ) do
      value when is_integer(value) and value >= 1 and value <= 6 -> value
      _ -> @default_native_lookup_max_relays
    end
  end

  defp native_lookup_timeout_ms do
    case Config.get(
           [NativeNostr, :mostr_native_lookup_timeout_ms],
           @default_native_lookup_timeout_ms
         ) do
      value when is_integer(value) and value >= 250 and value <= 3_000 -> value
      _ -> @default_native_lookup_timeout_ms
    end
  end

  defp reference_event_id(%{} = reference) do
    proxy_event_id(reference) || mostr_event_id(reference["id"])
  end

  defp reference_event_id(reference) when is_binary(reference), do: mostr_event_id(reference)
  defp reference_event_id(_reference), do: nil

  defp legacy_event_reference?(%{} = reference) do
    is_binary(mostr_event_id(reference["id"]))
  end

  defp legacy_event_reference?(reference) when is_binary(reference) do
    is_binary(mostr_event_id(reference))
  end

  defp legacy_event_reference?(_reference), do: false

  defp reference_pubkey(%{"id" => reference}), do: reference_pubkey(reference)

  defp reference_pubkey(reference) when is_binary(reference) do
    reference = reference |> String.trim() |> String.trim_leading("@")

    case legacy_handle_pubkey(reference) do
      pubkey when is_binary(pubkey) ->
        pubkey

      nil ->
        with %URI{host: host, path: path} <- URI.parse(reference),
             true <- allowed_mostr_host?(host),
             [pubkey] <-
               Regex.run(
                 ~r|/users/([0-9a-fA-F]{64})(?:/)?\z|,
                 path,
                 capture: :all_but_first
               ) do
          valid_pubkey(pubkey)
        else
          _ -> nil
        end
    end
  rescue
    URI.Error -> nil
  end

  defp reference_pubkey(_reference), do: nil

  defp legacy_handle_pubkey(reference) do
    case String.split(reference, "@", parts: 2) do
      [pubkey, host] ->
        if allowed_mostr_host?(host), do: valid_pubkey(pubkey)

      _ ->
        nil
    end
  end

  defp legacy_handle_host?(reference) do
    case String.split(reference, "@", parts: 2) do
      [_name, host] -> allowed_mostr_host?(host)
      _ -> false
    end
  end

  defp proxy_event_id(%{"proxyOf" => proxies}) do
    proxies
    |> List.wrap()
    |> Enum.find_value(fn
      %{
        "authoritative" => true,
        "protocol" => @nostr_protocol,
        "proxied" => identifier
      }
      when is_binary(identifier) ->
        decode_event_identifier(identifier)

      _proxy ->
        nil
    end)
  end

  defp proxy_event_id(_data), do: nil

  defp decode_event_identifier(identifier) do
    identifier =
      identifier
      |> String.trim()
      |> String.trim_leading("nostr:")

    case Nostr.NIP19.decode(identifier) do
      {:ok, :note, event_id} -> valid_event_id(event_id)
      {:ok, :nevent, %{event_id: event_id}} -> valid_event_id(event_id)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp mostr_event_id(url) when is_binary(url) do
    with %URI{scheme: scheme, host: host, path: path} <-
           URI.parse(url),
         true <- scheme in ["http", "https"],
         true <- allowed_mostr_host?(host) do
      mostr_event_id_from_path(path)
    else
      _ -> nil
    end
  rescue
    URI.Error -> nil
  end

  defp mostr_event_id(_url), do: nil

  defp mostr_event_id_from_path(path) when is_binary(path) do
    case Regex.run(
           ~r"/(?:objects|activities)/([0-9a-fA-F]{64})(?:/)?\z",
           path,
           capture: :all_but_first
         ) do
      [event_id] ->
        valid_event_id(event_id)

      _ ->
        case Regex.run(~r|/notes/([^/]+)(?:/)?\z|, path, capture: :all_but_first) do
          [identifier] -> decode_event_identifier(identifier)
          _ -> nil
        end
    end
  end

  defp mostr_event_id_from_path(_path), do: nil

  defp allowed_mostr_host?(host) when is_binary(host) do
    normalized_host = String.downcase(host)

    Config.get([Pleroma.Nostr, :mostr_hosts], @default_mostr_hosts)
    |> List.wrap()
    |> Kernel.++(@default_mostr_hosts)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.any?(fn allowed ->
      normalized_host == allowed or String.ends_with?(normalized_host, "." <> allowed)
    end)
  end

  defp allowed_mostr_host?(_host), do: false

  defp valid_event_id(event_id) when is_binary(event_id) do
    event_id = String.downcase(event_id)
    if Regex.match?(@hex_event, event_id), do: event_id
  end

  defp valid_event_id(_event_id), do: nil

  defp valid_pubkey(pubkey) when is_binary(pubkey) do
    pubkey = String.downcase(pubkey)
    if Regex.match?(@hex_pubkey, pubkey), do: pubkey
  end

  defp valid_pubkey(_pubkey), do: nil
end

# end of nostr/mostr_compat.ex
