# Unfathomably BE
# ----------------
#
# File: nostr/semantics.ex
#
# Purpose:
#   Preserve bounded Nostr event semantics while projecting events into
#   ActivityPub and while publishing local ActivityPub objects to Nostr.
#
# Responsibilities:
#   - enforce NIP-40 expiration and NIP-70 protected-event boundaries
#   - map NIP-36 content warnings into normal post parameters
#   - preserve and emit NIP-73 external content identifiers
#
# This file intentionally does NOT verify signatures, fetch identifier hints,
# resolve profiles, or choose external relays.

defmodule Pleroma.Nostr.Semantics do
  @max_external_ids 32
  @max_identifier_bytes 1_024
  @max_hint_bytes 2_048

  def bridgeable?(event) do
    if protected?(event) do
      {:error, "restricted", "protected events cannot be redistributed by the bridge"}
    else
      case event["kind"] do
        1_311 ->
          Pleroma.Nostr.Events.validate_chat(event)

        1_018 ->
          Pleroma.Nostr.Poll.validate_response(event)

        1_068 ->
          Pleroma.Nostr.Poll.validate(event)

        1_984 ->
          Pleroma.Nostr.Moderation.validate(event)

        kind when kind in [8, 10_008, 30_008, 30_009, 30_315] ->
          Pleroma.Nostr.ProfileExtensions.validate(event)

        kind when kind in [1_059, 10_050] ->
          Pleroma.Nostr.PrivateMessages.validate(event)

        30_311 ->
          Pleroma.Nostr.Events.validate(event)

        31_922 ->
          Pleroma.Nostr.Events.validate(event)

        31_923 ->
          Pleroma.Nostr.Events.validate(event)

        31_925 ->
          Pleroma.Nostr.Events.validate_rsvp(event)

        _kind ->
          :ok
      end
    end
  end

  def protected?(%{"tags" => tags}) when is_list(tags) do
    Enum.any?(tags, fn
      ["-"] -> true
      _tag -> false
    end)
  end

  def protected?(_event), do: false

  def expiration(%{"tags" => tags}) when is_list(tags) do
    tags
    |> Enum.flat_map(fn
      ["expiration", value | _rest] -> valid_timestamp(value)
      _tag -> []
    end)
    |> Enum.min(fn -> nil end)
  end

  def expiration(_event), do: nil

  def expired?(event, now \\ System.system_time(:second)) when is_integer(now) do
    case expiration(event) do
      timestamp when is_integer(timestamp) -> timestamp <= now
      nil -> false
    end
  end

  def put_inbound_params(params, event) when is_map(params) do
    params
    |> put_content_warning_params(event)
    |> put_expiration_params(event)
  end

  def put_object_metadata(object, event) when is_map(object) do
    case external_content_ids(event) do
      [] ->
        object

      identifiers ->
        Map.update(object, "unfathomably:nostr", %{"external_ids" => identifiers}, fn
          metadata when is_map(metadata) -> Map.put(metadata, "external_ids", identifiers)
          _metadata -> %{"external_ids" => identifiers}
        end)
    end
  end

  def outbound_tags(object) when is_map(object) do
    warning_tags(object) ++ external_identifier_tags(object)
  end

  def outbound_tags(_object), do: []

  def external_content_ids(%{"tags" => tags}) when is_list(tags) do
    tags
    |> Enum.flat_map(fn
      ["i", identifier, hint | _rest] -> external_identifier(identifier, hint)
      ["i", identifier] -> external_identifier(identifier, nil)
      _tag -> []
    end)
    |> Enum.uniq_by(& &1["id"])
    |> Enum.take(@max_external_ids)
  end

  def external_content_ids(_event), do: []

  defp put_content_warning_params(params, event) do
    case content_warning(event) do
      nil -> params
      warning -> params |> Map.put(:sensitive, true) |> Map.put(:spoiler_text, warning)
    end
  end

  defp put_expiration_params(params, event) do
    case expiration(event) do
      timestamp when is_integer(timestamp) ->
        Map.put(params, :expires_in, max(timestamp - System.system_time(:second), 0))

      nil ->
        params
    end
  end

  defp content_warning(%{"tags" => tags}) when is_list(tags) do
    Enum.find_value(tags, fn
      ["content-warning", reason | _rest] when is_binary(reason) ->
        bounded_text(reason, 1_500) || "Sensitive content"

      ["content-warning"] ->
        "Sensitive content"

      _tag ->
        nil
    end)
  end

  defp content_warning(_event), do: nil

  defp warning_tags(object) do
    if object["sensitive"] == true do
      reason = bounded_text(object["summary"], 1_500) || ""
      [["content-warning", reason]]
    else
      []
    end
  end

  defp external_identifier_tags(object) do
    inherited =
      object
      |> Map.get("unfathomably:nostr", %{})
      |> case do
        %{"external_ids" => identifiers} when is_list(identifiers) -> identifiers
        _metadata -> []
      end

    canonical =
      case external_identifier(object["id"], nil) do
        [identifier] -> [identifier]
        [] -> []
      end

    (canonical ++ inherited)
    |> Enum.flat_map(&normalize_stored_identifier/1)
    |> Enum.uniq_by(& &1["id"])
    |> Enum.take(@max_external_ids)
    |> Enum.flat_map(fn identifier ->
      i_tag =
        case identifier["url"] do
          url when is_binary(url) -> ["i", identifier["id"], url]
          _url -> ["i", identifier["id"]]
        end

      [i_tag, ["k", identifier["kind"]]]
    end)
    |> Enum.uniq()
  end

  defp normalize_stored_identifier(%{"id" => identifier} = stored) do
    external_identifier(identifier, stored["url"])
  end

  defp normalize_stored_identifier(_stored), do: []

  defp external_identifier(identifier, hint)
       when is_binary(identifier) and byte_size(identifier) in 1..@max_identifier_bytes do
    with true <- String.valid?(identifier),
         kind when is_binary(kind) <- identifier_kind(identifier),
         {:ok, hint} <- optional_https_hint(hint) do
      [
        %{"id" => identifier, "kind" => kind}
        |> maybe_put("url", hint)
      ]
    else
      _invalid -> []
    end
  end

  defp external_identifier(_identifier, _hint), do: []

  defp identifier_kind(identifier) do
    cond do
      valid_https_url?(identifier) ->
        "web"

      Regex.match?(~r/\Aisbn:(?:[0-9]{13}|[0-9Xx]{10})\z/, identifier) ->
        "isbn"

      Regex.match?(~r/\Ageo:[0-9bcdefghjkmnpqrstuvwxyz]{1,32}\z/, identifier) ->
        "geo"

      Regex.match?(~r/\Aiso3166:[A-Z]{2}(?:-[A-Z0-9]{1,3})?\z/, identifier) ->
        "iso3166"

      String.starts_with?(identifier, "isan:") ->
        "isan"

      String.starts_with?(identifier, "doi:") ->
        "doi"

      String.starts_with?(identifier, "podcast:guid:") ->
        "podcast:guid"

      String.starts_with?(identifier, "podcast:item:guid:") ->
        "podcast:item:guid"

      String.starts_with?(identifier, "podcast:publisher:guid:") ->
        "podcast:publisher:guid"

      Regex.match?(~r/\A[a-z0-9]+(?::[0-9]+)?:tx:[0-9a-f]+\z/, identifier) ->
        transaction_kind(identifier)

      Regex.match?(~r/\A[a-z0-9]+(?::[0-9]+)?:address:[A-Za-z0-9]+\z/, identifier) ->
        address_kind(identifier)

      true ->
        nil
    end
  end

  defp transaction_kind(identifier),
    do: identifier |> String.split(":") |> List.first() |> Kernel.<>(":tx")

  defp address_kind(identifier),
    do: identifier |> String.split(":") |> List.first() |> Kernel.<>(":address")

  defp optional_https_hint(nil), do: {:ok, nil}
  defp optional_https_hint(""), do: {:ok, nil}

  defp optional_https_hint(hint)
       when is_binary(hint) and byte_size(hint) <= @max_hint_bytes do
    if valid_https_url?(hint), do: {:ok, hint}, else: :error
  end

  defp optional_https_hint(_hint), do: :error

  defp valid_https_url?(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil, fragment: nil}
      when is_binary(host) and host != "" and host != "localhost" ->
        true

      _uri ->
        false
    end
  end

  defp valid_timestamp(value) when is_integer(value) and value >= 0, do: [value]

  defp valid_timestamp(value) when is_binary(value) do
    case Integer.parse(value) do
      {timestamp, ""} when timestamp >= 0 -> [timestamp]
      _invalid -> []
    end
  end

  defp valid_timestamp(_value), do: []

  defp bounded_text(value, max_bytes)
       when is_binary(value) and byte_size(value) <= max_bytes do
    if String.valid?(value) and not String.contains?(value, ["\0", "\r", "\n"]), do: value
  end

  defp bounded_text(_value, _max_bytes), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

# end of nostr/semantics.ex
