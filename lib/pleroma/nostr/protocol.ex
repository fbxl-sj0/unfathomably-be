# Unfathomably BE
# ----------------
#
# File: nostr/protocol.ex
#
# Purpose:
#   Validate and serialize untrusted Nostr protocol data without atom creation.
#
# Responsibilities:
#   - enforce event, tag, timestamp, and filter bounds before cryptography
#   - verify NIP-01 event IDs and BIP-340 Schnorr signatures
#   - sign bridge-generated events using canonical NIP-01 serialization
#   - decode NIP-19 account and NIP-29 group identifiers
#   - match bounded relay filters without converting tag names to atoms
#
# This file intentionally does NOT authorize writers, perform database work,
# or translate events into ActivityPub.

defmodule Pleroma.Nostr.Protocol do
  alias Pleroma.Config

  @hex32 ~r/^[0-9a-f]{64}$/
  @hex64 ~r/^[0-9a-f]{128}$/
  @known_filter_keys ~w(ids authors kinds since until limit search)

  def validate_event(event) when is_map(event) do
    event = stringify_keys(event)

    with :ok <- event_shape(event),
         :ok <- event_bounds(event),
         :ok <- verify_event_id(event),
         :ok <- verify_signature(event) do
      {:ok, Map.take(event, ~w(id pubkey created_at kind tags content sig))}
    end
  rescue
    _ -> {:error, :invalid_event}
  end

  def validate_event(_event), do: {:error, :invalid_event}

  def sign_event(kind, tags, content, private_key, opts \\ [])

  def sign_event(kind, tags, content, private_key, opts)
      when is_integer(kind) and is_list(tags) and is_binary(content) and is_binary(private_key) do
    created_at = Keyword.get(opts, :created_at, System.system_time(:second))
    pubkey = Nostr.Crypto.pubkey(private_key)

    event = %{
      "pubkey" => pubkey,
      "created_at" => created_at,
      "kind" => kind,
      "tags" => tags,
      "content" => content
    }

    id = compute_id(event)
    signed = event |> Map.put("id", id) |> Map.put("sig", Nostr.Crypto.sign(id, private_key))

    case validate_event(signed) do
      {:ok, event} -> {:ok, event}
      error -> error
    end
  rescue
    _ -> {:error, :could_not_sign}
  end

  def sign_event(_kind, _tags, _content, _private_key, _opts), do: {:error, :invalid_event}

  def compute_id(event) do
    serialized =
      Jason.encode!([
        0,
        event["pubkey"],
        event["created_at"],
        event["kind"],
        event["tags"],
        event["content"]
      ])

    :crypto.hash(:sha256, serialized)
    |> Base.encode16(case: :lower)
  end

  def validate_filters(filters) when is_list(filters) do
    max_filters = config_integer(:max_filters, 10)

    if filters != [] and length(filters) <= max_filters do
      filters
      |> Enum.reduce_while({:ok, []}, fn filter, {:ok, acc} ->
        case validate_filter(filter) do
          {:ok, filter} -> {:cont, {:ok, [filter | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, valid} -> {:ok, Enum.reverse(valid)}
        error -> error
      end
    else
      {:error, :invalid_filter}
    end
  end

  def validate_filters(_filters), do: {:error, :invalid_filter}

  def validate_filter(filter) when is_map(filter) do
    filter = stringify_keys(filter)
    allowed? = Enum.all?(Map.keys(filter), &valid_filter_key?/1)

    with true <- allowed?,
         :ok <- validate_filter_values(filter, "ids", &hex_prefix?/1),
         :ok <- validate_filter_values(filter, "authors", &hex_prefix?/1),
         :ok <- validate_filter_values(filter, "kinds", &valid_kind?/1),
         :ok <- validate_dynamic_filter_values(filter),
         :ok <- validate_filter_integer(filter, "since", 0, 9_999_999_999),
         :ok <- validate_filter_integer(filter, "until", 0, 9_999_999_999),
         :ok <-
           validate_filter_integer(filter, "limit", 1, config_integer(:max_filter_limit, 500)),
         :ok <- validate_filter_search(filter) do
      {:ok, filter}
    else
      _ -> {:error, :invalid_filter}
    end
  end

  def validate_filter(_filter), do: {:error, :invalid_filter}

  def matches?(event, filter) do
    prefix_match?(event["id"], filter["ids"]) and
      prefix_match?(event["pubkey"], filter["authors"]) and
      list_match?(event["kind"], filter["kinds"]) and
      since_match?(event["created_at"], filter["since"]) and
      until_match?(event["created_at"], filter["until"]) and
      tags_match?(event["tags"], filter) and
      search_match?(event["content"], filter["search"])
  end

  def search_score(%{"content" => content}, search)
      when is_binary(content) and is_binary(search) do
    terms = search_terms(search)
    content = String.downcase(content)

    if terms != [] and Enum.all?(terms, &String.contains?(content, &1)) do
      phrase = Enum.join(terms, " ")
      phrase_score = if String.contains?(content, phrase), do: 1_000, else: 0
      occurrence_score = Enum.sum(Enum.map(terms, &term_occurrences(content, &1)))
      phrase_score + length(terms) * 100 + occurrence_score
    else
      0
    end
  end

  def search_score(_event, _search), do: 0

  def search_terms(search) when is_binary(search) do
    search
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&String.contains?(&1, ":"))
    |> Enum.uniq()
  end

  def search_terms(_search), do: []

  def tag_values(event, name) when is_map(event) and is_binary(name) do
    event
    |> Map.get("tags", [])
    |> Enum.flat_map(fn
      [^name, value | _rest] when is_binary(value) -> [value]
      _tag -> []
    end)
  end

  def tag_value(event, name), do: event |> tag_values(name) |> List.first()

  def proxy_activitypub?(event) do
    Enum.any?(Map.get(event, "tags", []), fn
      ["proxy", _identifier, "activitypub" | _rest] -> true
      _tag -> false
    end)
  end

  def replace_key(%{"kind" => kind, "pubkey" => pubkey})
      when kind in [0, 3] or kind in 10_000..19_999 do
    "#{kind}:#{pubkey}"
  end

  def replace_key(%{"kind" => kind, "pubkey" => pubkey} = event)
      when kind in 30_000..39_999 do
    "#{kind}:#{pubkey}:#{tag_value(event, "d") || ""}"
  end

  def replace_key(_event), do: nil

  def ephemeral?(%{"kind" => kind}), do: kind in 20_000..29_999
  def ephemeral?(_event), do: false

  def normalize_relay_url(value) when is_binary(value) do
    value = String.trim(value)

    case URI.parse(value) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["ws", "wss"] and is_binary(host) and host != "" ->
        uri
        |> Map.put(:fragment, nil)
        |> Map.put(:query, nil)
        |> URI.to_string()
        |> String.trim_trailing("/")

      _ ->
        nil
    end
  rescue
    URI.Error -> nil
  end

  def normalize_relay_url(_value), do: nil

  def decode_identifier(value) when is_binary(value) do
    value =
      value
      |> String.trim()
      |> String.trim_leading("nostr:")
      |> String.split("?", parts: 2)
      |> List.first()

    cond do
      String.starts_with?(value, "nostr+group://") ->
        decode_group_uri(value)

      Regex.match?(@hex32, value) ->
        {:ok, %{kind: :any, type: :profile, pubkey: value, relays: []}}

      true ->
        decode_nip19(value)
    end
  rescue
    _ -> {:error, :invalid_identifier}
  end

  def decode_identifier(_value), do: {:error, :invalid_identifier}

  defp decode_nip19(value) do
    case Nostr.NIP19.decode(value) do
      {:ok, :npub, pubkey} ->
        {:ok, %{kind: :any, type: :profile, pubkey: pubkey, relays: []}}

      {:ok, :nprofile, profile} ->
        {:ok,
         %{
           kind: :any,
           type: :profile,
           pubkey: Map.get(profile, :pubkey),
           relays: Map.get(profile, :relays, [])
         }}

      {:ok, :naddr, address} ->
        decode_naddr(address)

      _ ->
        {:error, :invalid_identifier}
    end
  end

  defp decode_naddr(address) do
    kind = Map.get(address, :kind)
    relays = Map.get(address, :relays, [])

    if kind == 39_000 and relays != [] do
      {:ok,
       %{
         kind: :group,
         type: :group,
         group_id: Map.get(address, :identifier),
         pubkey: Map.get(address, :pubkey),
         relays: relays
       }}
    else
      {:error, :unsupported_identifier}
    end
  end

  defp decode_group_uri(value) do
    uri = URI.parse(value)
    relay = "wss://" <> uri.host <> if(is_integer(uri.port), do: ":#{uri.port}", else: "")
    group_id = uri.path |> to_string() |> String.trim("/")

    if group_id != "" do
      {:ok, %{kind: :group, type: :group, group_id: group_id, pubkey: nil, relays: [relay]}}
    else
      {:error, :invalid_identifier}
    end
  end

  defp event_shape(event) do
    cond do
      not Regex.match?(@hex32, event["id"] || "") -> {:error, :invalid_id}
      not Regex.match?(@hex32, event["pubkey"] || "") -> {:error, :invalid_pubkey}
      not Regex.match?(@hex64, event["sig"] || "") -> {:error, :invalid_signature}
      not valid_kind?(event["kind"]) -> {:error, :invalid_kind}
      not is_integer(event["created_at"]) -> {:error, :invalid_timestamp}
      not is_binary(event["content"]) -> {:error, :invalid_content}
      not is_list(event["tags"]) -> {:error, :invalid_tags}
      true -> :ok
    end
  end

  defp event_bounds(event) do
    now = System.system_time(:second)
    future = config_integer(:future_tolerance_seconds, 900)
    oldest = config_integer(:oldest_event_unix, 1_230_768_000)

    cond do
      event["created_at"] < oldest ->
        {:error, :event_too_old}

      event["created_at"] > now + future ->
        {:error, :event_from_future}

      byte_size(event["content"]) > config_integer(:max_content_bytes, 50_000) ->
        {:error, :content_too_large}

      length(event["tags"]) > max_tags(event) ->
        {:error, :too_many_tags}

      not Enum.all?(event["tags"], &valid_tag?/1) ->
        {:error, :invalid_tags}

      true ->
        :ok
    end
  end

  defp valid_tag?(tag) when is_list(tag) do
    tag != [] and
      length(tag) <= config_integer(:max_tag_values, 16) and
      Enum.all?(tag, fn
        value when is_binary(value) ->
          byte_size(value) <= config_integer(:max_tag_value_bytes, 2_048)

        _ ->
          false
      end)
  end

  defp valid_tag?(_tag), do: false

  # NIP-02 contact lists, NIP-65 relay lists, and NIP-29 group role lists contain
  # one tag per identity or advertised relay. They remain bounded by the relay
  # frame-size limit, but established accounts and communities routinely exceed
  # the smaller limit appropriate for ordinary notes.
  defp max_tags(%{"kind" => 3}), do: config_integer(:max_contact_tags, 1_024)
  defp max_tags(%{"kind" => 10_002}), do: config_integer(:max_relay_tags, 1_024)

  defp max_tags(%{"kind" => kind}) when kind in [39_001, 39_002],
    do: config_integer(:max_group_list_tags, 1_024)

  defp max_tags(_event), do: config_integer(:max_tags, 128)

  defp verify_event_id(event) do
    if compute_id(event) == event["id"], do: :ok, else: {:error, :invalid_id}
  end

  defp verify_signature(event) do
    with {:ok, signature} <- Base.decode16(event["sig"], case: :lower),
         {:ok, id} <- Base.decode16(event["id"], case: :lower),
         {:ok, pubkey} <- Base.decode16(event["pubkey"], case: :lower),
         true <- Secp256k1.schnorr_valid?(signature, id, pubkey) do
      :ok
    else
      _ -> {:error, :invalid_signature}
    end
  end

  defp valid_kind?(kind), do: is_integer(kind) and kind >= 0 and kind <= 65_535

  defp valid_filter_key?(key) do
    key in @known_filter_keys or Regex.match?(~r/^#[A-Za-z]$/, key)
  end

  defp validate_filter_values(filter, key, validator) do
    case Map.fetch(filter, key) do
      :error ->
        :ok

      {:ok, values} when is_list(values) ->
        if length(values) <= config_integer(:max_filter_values, 500) and
             Enum.all?(values, validator),
           do: :ok,
           else: {:error, :invalid_filter}

      _ ->
        {:error, :invalid_filter}
    end
  end

  defp validate_dynamic_filter_values(filter) do
    filter
    |> Enum.filter(fn {key, _value} -> String.starts_with?(key, "#") end)
    |> Enum.reduce_while(:ok, fn {key, _values}, :ok ->
      case validate_filter_values(filter, key, &bounded_filter_string?/1) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_filter_integer(filter, key, minimum, maximum) do
    case Map.fetch(filter, key) do
      :error -> :ok
      {:ok, value} when is_integer(value) and value >= minimum and value <= maximum -> :ok
      _ -> {:error, :invalid_filter}
    end
  end

  defp validate_filter_search(filter) do
    case Map.fetch(filter, "search") do
      :error -> :ok
      {:ok, value} when is_binary(value) and byte_size(value) <= 256 -> :ok
      _ -> {:error, :invalid_filter}
    end
  end

  defp hex_prefix?(value) when is_binary(value) and byte_size(value) in 1..64,
    do: Regex.match?(~r/^[0-9a-f]+$/, value)

  defp hex_prefix?(_value), do: false

  defp bounded_filter_string?(value) when is_binary(value), do: byte_size(value) <= 512
  defp bounded_filter_string?(_value), do: false

  defp prefix_match?(_value, nil), do: true
  defp prefix_match?(value, prefixes), do: Enum.any?(prefixes, &String.starts_with?(value, &1))
  defp list_match?(_value, nil), do: true
  defp list_match?(value, values), do: value in values
  defp since_match?(_value, nil), do: true
  defp since_match?(value, since), do: value >= since
  defp until_match?(_value, nil), do: true
  defp until_match?(value, until), do: value <= until

  defp tags_match?(tags, filter) do
    filter
    |> Enum.filter(fn {key, _value} -> String.starts_with?(key, "#") end)
    |> Enum.all?(fn {"#" <> name, values} ->
      Enum.any?(tags, fn
        [^name, value | _rest] -> value in values
        _tag -> false
      end)
    end)
  end

  defp search_match?(_content, nil), do: true
  defp search_match?(_content, ""), do: true

  defp search_match?(content, search) do
    content = String.downcase(content)

    search
    |> search_terms()
    |> Enum.all?(&String.contains?(content, &1))
  end

  defp term_occurrences(content, term) do
    content
    |> String.split(term)
    |> length()
    |> Kernel.-(1)
    |> min(100)
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp config_integer(key, default) do
    case Config.get([Pleroma.Nostr, key], default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end
end

# end of nostr/protocol.ex
