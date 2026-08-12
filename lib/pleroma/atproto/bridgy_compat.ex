# Unfathomably BE
# ----------------
#
# File: atproto/bridgy_compat.ex
#
# Purpose:
#   Reconcile ActivityPub projections of Bluesky records with native AT
#   Protocol identities and records.
#
# Responsibilities:
#   - recognize configured Bluesky-to-ActivityPub bridge actors
#   - extract native DIDs and handles from bridge actor identifiers
#   - recognize FEP-fffd canonical at:// links on bridged posts
#   - prefer the native AT projection for posts, replies, likes, and reposts
#   - prevent retired bridge endpoints from remaining runtime dependencies
#
# This file intentionally does NOT trust an ActivityPub bridge to sign for an
# AT identity, consume an AT firehose, or accept arbitrary claimed DIDs from
# hosts outside the configured bridge list.

defmodule Pleroma.ATProto.BridgyCompat do
  alias Pleroma.Activity
  alias Pleroma.ATProto
  alias Pleroma.ATProto.Bridge
  alias Pleroma.ATProto.Identities
  alias Pleroma.ATProto.Record
  alias Pleroma.ATProto.Store
  alias Pleroma.Config
  alias Pleroma.Object
  alias Pleroma.User

  @post_collection "app.bsky.feed.post"
  @default_bridge_hosts ["bsky.brid.gy"]
  @did_pattern ~r/\Adid:(plc|web):[A-Za-z0-9._:%-]+\z/
  @handle_pattern ~r/\A(?=.{1,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,62}\z/
  @target_activity_types ~w[Add Announce Block Dislike EmojiReact Like Remove]

  @spec handle_incoming(map(), (map() -> term())) :: term()
  def handle_incoming(data, fallback) when is_map(data) and is_function(fallback, 1) do
    case direct_native_activity(data) do
      {:ok, %Activity{} = activity} ->
        {:ok, activity}

      {:error, reason} ->
        {:error, reason}

      :not_applicable ->
        if legacy_envelope?(data) do
          {:reject, :native_atproto_required}
        else
          with {:ok, rewritten} <- rewrite_references(data) do
            fallback.(rewritten)
          end
        end
    end
  end

  def handle_incoming(data, fallback) when is_function(fallback, 1), do: fallback.(data)

  @doc """
  Resolves a configured Bluesky bridge actor as its native AT identity.

  The bridge host is used only to locate a DID or handle. The resulting profile
  is fetched independently from the configured AppView before it is stored.
  """
  @spec resolve_native_actor(term()) ::
          {:ok, User.t()} | {:error, atom() | term()} | :not_applicable
  def resolve_native_actor(reference) do
    if legacy_actor?(reference) do
      with identifier when is_binary(identifier) <- native_identifier(reference),
           {:ok, %User{} = user} <- Identities.resolve(identifier) do
        {:ok, user}
      else
        nil -> {:error, :native_identifier_not_found}
        {:error, reason} -> {:error, reason}
        _ -> {:error, :native_atproto_lookup_failed}
      end
    else
      :not_applicable
    end
  rescue
    _ -> {:error, :native_atproto_lookup_failed}
  catch
    :exit, _reason -> {:error, :native_atproto_lookup_failed}
  end

  @doc "Returns the native DID or handle embedded in a bridge actor."
  @spec native_identifier(term()) :: String.t() | nil
  def native_identifier(%User{} = user) do
    [user.also_known_as, user.ap_id, user.nickname, user.actor_extensions, user.fields]
    |> collect_strings()
    |> identifier_from_strings()
  end

  def native_identifier(%{} = reference) do
    [
      reference[:also_known_as],
      reference["alsoKnownAs"],
      reference[:ap_id],
      reference["id"],
      reference[:nickname],
      reference["preferredUsername"],
      reference["url"],
      reference[:actor_extensions],
      reference[:fields]
    ]
    |> collect_strings()
    |> identifier_from_strings()
  end

  def native_identifier(reference) when is_binary(reference) do
    identifier_from_strings([reference])
  end

  def native_identifier(_reference), do: nil

  @doc "Returns whether a value identifies a configured Bluesky bridge actor."
  @spec legacy_actor?(term()) :: boolean()
  def legacy_actor?(%User{} = user) do
    legacy_reference?(user.ap_id) or legacy_handle?(user.nickname)
  end

  def legacy_actor?(%{} = reference) do
    legacy_reference?(reference["id"] || reference[:ap_id]) or
      legacy_handle?(reference["preferredUsername"] || reference[:nickname])
  end

  def legacy_actor?(reference), do: legacy_reference?(reference) or legacy_handle?(reference)

  @doc "Returns whether a URL belongs to a configured Bluesky bridge host."
  @spec legacy_reference?(term()) :: boolean()
  def legacy_reference?(reference) when is_binary(reference) do
    reference = String.trim(reference)

    case URI.parse(reference) do
      %URI{host: host} when is_binary(host) -> bridge_host?(host)
      _ -> legacy_handle?(reference)
    end
  rescue
    URI.Error -> false
  end

  def legacy_reference?(_reference), do: false

  @doc "Returns whether an ActivityPub envelope originated at a bridge host."
  @spec legacy_envelope?(term()) :: boolean()
  def legacy_envelope?(data) when is_map(data) do
    legacy_reference?(data["id"]) or
      legacy_reference?(actor_id(data["actor"])) or
      legacy_reference?(object_actor_id(data["object"]))
  end

  def legacy_envelope?(_data), do: false

  @doc "Extracts a validated native AT post URI from a proxy reference."
  @spec canonical_uri(term()) :: String.t() | nil
  def canonical_uri(%{} = reference) do
    direct_uri(reference) ||
      proxy_uri(reference["proxyOf"]) ||
      canonical_url(reference["url"]) ||
      canonical_url(reference["urls"]) ||
      canonical_uri(reference["id"])
  end

  def canonical_uri(reference) when is_binary(reference) do
    normalize_post_uri(reference) || bridgy_convert_uri(reference)
  end

  def canonical_uri(_reference), do: nil

  @doc "Returns the local native object identifier when a record is mapped."
  @spec canonical_object_id(term()) :: String.t() | nil
  def canonical_object_id(reference) do
    with uri when is_binary(uri) <- canonical_uri(reference),
         %Record{ap_object_id: object_id} <- Store.get(uri),
         true <- is_binary(object_id) do
      object_id
    else
      _ -> nil
    end
  end

  @doc "Fetches a canonical AT post without falling back to its AP proxy."
  @spec fetch_native_object(term()) ::
          {:ok, Object.t()} | {:error, atom()} | :miss | :not_applicable
  def fetch_native_object(reference) do
    with uri when is_binary(uri) <- canonical_uri(reference) do
      if ATProto.enabled?() do
        case native_object(uri) do
          %Object{} = object ->
            {:ok, object}

          nil ->
            case Bridge.resolve_uri(uri) do
              {:ok, %Activity{} = activity} ->
                case Object.normalize(activity, fetch: false) do
                  %Object{} = object -> {:ok, object}
                  nil -> {:error, :native_atproto_projection_failed}
                end

              _ ->
                {:error, :native_atproto_not_found}
            end
        end
      else
        {:error, :native_atproto_disabled}
      end
    else
      _ -> :not_applicable
    end
  rescue
    _ -> {:error, :native_atproto_lookup_failed}
  catch
    :exit, _reason -> {:error, :native_atproto_lookup_failed}
  end

  defp direct_native_activity(%{"type" => type, "object" => object})
       when type in ["Create", "Update"] do
    case canonical_uri(object) do
      uri when is_binary(uri) -> fetch_native_activity(uri)
      nil -> :not_applicable
    end
  end

  defp direct_native_activity(_data), do: :not_applicable

  defp fetch_native_activity(uri) do
    case native_activity(uri) do
      %Activity{} = activity ->
        {:ok, activity}

      nil ->
        if ATProto.enabled?() do
          case Bridge.resolve_uri(uri) do
            {:ok, %Activity{} = activity} -> {:ok, activity}
            _ -> {:error, :native_atproto_not_found}
          end
        else
          {:error, :native_atproto_disabled}
        end
    end
  end

  defp native_activity(uri) do
    with %Record{ap_activity_id: activity_id} <- Store.get(uri),
         true <- not is_nil(activity_id) do
      Activity.get_by_id(activity_id)
    else
      _ -> nil
    end
  end

  defp native_object(uri) do
    with %Record{ap_object_id: object_id} <- Store.get(uri),
         true <- is_binary(object_id) do
      Object.get_by_ap_id(object_id)
    else
      _ -> nil
    end
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
    case canonical_uri(reference) do
      uri when is_binary(uri) ->
        case canonical_object_id(uri) do
          object_id when is_binary(object_id) ->
            {:ok, object_id}

          nil ->
            case fetch_native_object(uri) do
              {:ok, %Object{data: %{"id" => object_id}}} when is_binary(object_id) ->
                {:ok, object_id}

              {:error, reason} ->
                {:error, reason}

              _ ->
                {:error, :native_atproto_not_found}
            end
        end

      nil ->
        {:ok, reference}
    end
  end

  defp direct_uri(reference) do
    uri =
      case reference["unfathomably:atproto"] do
        %{} = metadata -> metadata["uri"]
        _metadata -> nil
      end

    normalize_post_uri(uri || reference["atUri"] || reference["at_uri"])
  end

  defp proxy_uri(proxies) do
    proxies
    |> List.wrap()
    |> Enum.find_value(fn
      %{"authoritative" => true, "proxied" => identifier} = proxy
      when is_binary(identifier) ->
        protocol =
          case proxy["protocol"] do
            value when is_binary(value) -> String.downcase(value)
            _value -> ""
          end

        if String.contains?(protocol, "atproto") or String.contains?(protocol, "at protocol") do
          normalize_post_uri(identifier)
        end

      _proxy ->
        nil
    end)
  end

  defp canonical_url(urls) do
    urls
    |> List.wrap()
    |> Enum.find_value(fn
      %{"href" => href, "rel" => rel} when rel in ["alternate", "canonical"] ->
        normalize_post_uri(href)

      href when is_binary(href) ->
        canonical_uri(href)

      _url ->
        nil
    end)
  end

  defp bridgy_convert_uri(reference) do
    with %URI{host: host, path: path} <- URI.parse(reference),
         true <- bridge_host?(host),
         true <- is_binary(path),
         decoded <- URI.decode(path),
         "/convert/ap/" <> identifier <- decoded do
      normalize_post_uri(identifier)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp normalize_post_uri(uri) when is_binary(uri) do
    uri = String.trim(uri)

    case Store.split_uri(uri) do
      {:ok, _did, @post_collection, _rkey} -> uri
      _ -> nil
    end
  end

  defp normalize_post_uri(_uri), do: nil

  defp identifier_from_strings(strings) do
    strings = Enum.filter(strings, &is_binary/1)

    Enum.find_value(strings, &did_from_string/1) ||
      Enum.find_value(strings, &handle_from_string/1)
  end

  defp did_from_string(value) do
    value = String.trim(value)

    cond do
      valid_did?(value) ->
        String.downcase(value)

      true ->
        with %URI{host: host, path: path} <- URI.parse(value),
             true <- bridge_host?(host),
             ["ap", encoded_did] <- String.split(path || "", "/", trim: true),
             did <- encoded_did |> URI.decode() |> String.downcase(),
             true <- valid_did?(did) do
          did
        else
          _ -> nil
        end
    end
  rescue
    _ -> nil
  end

  defp handle_from_string(value) do
    value = value |> String.trim() |> String.trim_leading("@")

    case String.split(value, "@", parts: 2) do
      [handle, host] ->
        if bridge_host?(host), do: valid_handle(handle)

      _ ->
        bsky_profile_handle(value)
    end
  end

  defp bsky_profile_handle(value) do
    with %URI{scheme: "https", host: "bsky.app", path: path} <- URI.parse(value),
         ["profile", identifier | _rest] <- String.split(path || "", "/", trim: true),
         identifier <- URI.decode(identifier) do
      cond do
        valid_did?(identifier) -> String.downcase(identifier)
        true -> valid_handle(identifier)
      end
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp legacy_handle?(value) when is_binary(value) do
    value = value |> String.trim() |> String.trim_leading("@")

    case String.split(value, "@", parts: 2) do
      [_handle, host] -> bridge_host?(host)
      _ -> false
    end
  end

  defp legacy_handle?(_value), do: false

  defp bridge_host?(host) when is_binary(host) do
    normalized = host |> String.downcase() |> String.trim_trailing(".")

    Config.get([ATProto, :bridge_hosts], @default_bridge_hosts)
    |> List.wrap()
    |> Kernel.++(@default_bridge_hosts)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(String.downcase(&1) |> String.trim_trailing(".")))
    |> Enum.any?(&(normalized == &1))
  end

  defp bridge_host?(_host), do: false

  defp valid_did?(did) do
    is_binary(did) and byte_size(did) <= 2_048 and Regex.match?(@did_pattern, did)
  end

  defp valid_handle(handle) when is_binary(handle) do
    handle = handle |> String.trim() |> String.downcase()
    if Regex.match?(@handle_pattern, handle), do: handle
  end

  defp valid_handle(_handle), do: nil

  defp actor_id(%{"id" => id}) when is_binary(id), do: id
  defp actor_id(id) when is_binary(id), do: id
  defp actor_id(_actor), do: nil

  defp object_actor_id(%{"attributedTo" => actor}), do: actor_id(actor)
  defp object_actor_id(_object), do: nil

  defp collect_strings(value) when is_binary(value), do: [value]
  defp collect_strings(values) when is_list(values), do: Enum.flat_map(values, &collect_strings/1)

  defp collect_strings(%{} = value) do
    value
    |> Map.values()
    |> Enum.flat_map(&collect_strings/1)
  end

  defp collect_strings(_value), do: []
end

# end of atproto/bridgy_compat.ex
