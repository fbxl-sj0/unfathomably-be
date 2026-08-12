# Unfathomably Nostr bridge
#
# File: references.ex
# Purpose: Translate portable NIP-21 and NIP-27 references at the protocol edge.
# Responsibilities: Safe profile/event resolution and outbound reference tags.
# This file intentionally does not fetch relays or own post/thread semantics.

defmodule Pleroma.Nostr.References do
  @moduledoc """
  Translates portable NIP-21 and NIP-27 references at the protocol boundary.

  Incoming references are resolved only against identities and events already
  known to this instance. Formatting a post must not trigger relay traffic.
  Unknown references remain intact so another Nostr-aware client can resolve
  them, and private-key identifiers are never accepted.
  """

  import Ecto.Query

  alias Pleroma.Nostr.Entity
  alias Pleroma.Nostr.Event
  alias Pleroma.Nostr.Identity
  alias Pleroma.Nostr.Protocol
  alias Pleroma.Nostr.Store
  alias Pleroma.Formatter
  alias Pleroma.Repo
  alias Pleroma.User

  @max_content_bytes 100_000
  @max_references 32
  @nostr_uri_regex ~r/(?<![[:alnum:]_])nostr:(?:npub|nprofile|note|nevent|naddr)1[023456789acdefghjklmnpqrstuvwxyz]+/i
  @web_url_regex ~r/https?:\/\/[^\s<>"']*[[:alnum:]\/#=_~-]/u
  @hex_32_regex ~r/\A[0-9a-f]{64}\z/

  @doc """
  Rewrites known Nostr references for ActivityPub presentation.

  A profile URI becomes a local mention only when the Nostr event also carries
  the matching `p` tag. Without that tag it becomes an ordinary profile link,
  preserving NIP-27's distinction between a reference and a notification.
  """
  def inbound(content, event)
      when is_binary(content) and byte_size(content) <= @max_content_bytes do
    tagged_pubkeys = event |> Protocol.tag_values("p") |> MapSet.new()

    content =
      @nostr_uri_regex
      |> Regex.scan(content)
      |> Enum.map(&hd/1)
      |> Enum.uniq()
      |> Enum.take(@max_references)
      |> Enum.reduce(content, fn uri, text ->
        case inbound_target(uri, tagged_pubkeys) do
          target when is_binary(target) -> String.replace(text, uri, target)
          _ -> text
        end
      end)

    append_tagged_mentions(content, event)
  end

  def inbound(content, _event) when is_binary(content), do: content
  def inbound(_content, _event), do: ""

  @doc """
  Converts explicit ActivityPub mentions and known post links to NIP-21 URIs.

  Only ActivityPub `Mention` tags produce Nostr `p` tags. Ordinary links are
  portable references but do not create `q` tags or notifications implicitly.
  """
  def outbound(content, object_data)
      when is_binary(content) and is_map(object_data) and
             byte_size(content) <= @max_content_bytes do
    {content, tags} = rewrite_mentions(content, object_data)
    {rewrite_event_links(content), Enum.uniq(tags)}
  end

  def outbound(content, _object_data) when is_binary(content), do: {content, []}
  def outbound(_content, _object_data), do: {"", []}

  @doc "Returns bounded, locally known profile actors named by signed Nostr p tags."
  def tagged_mentions(%{} = event) do
    author = value(event, :pubkey)

    event
    |> Protocol.tag_values("p")
    |> Enum.filter(&(is_binary(&1) and &1 != author))
    |> Enum.uniq()
    |> Enum.take(@max_references)
    |> Enum.flat_map(fn pubkey ->
      case Identity.get_profile(pubkey) do
        %Entity{user: %User{} = user} -> [%{pubkey: pubkey, user: user}]
        _entity -> []
      end
    end)
  end

  def tagged_mentions(_event), do: []

  @doc "Adds canonical ActivityPub presentation and addressing for signed p tags."
  def put_inbound_mentions(%{} = object, event) do
    event
    |> tagged_mentions()
    |> Enum.reduce(object, &put_inbound_mention/2)
  end

  def put_inbound_mentions(object, _event), do: object

  defp inbound_target(uri, tagged_pubkeys) do
    case Nostr.NIP21.parse(uri) do
      {:ok, :npub, pubkey} ->
        profile_target(pubkey, tagged_pubkeys)

      {:ok, :nprofile, profile} ->
        profile_target(value(profile, :pubkey), tagged_pubkeys)

      {:ok, :note, event_id} ->
        event_target(Store.get(event_id))

      {:ok, :nevent, event} ->
        event_target(Store.get(value(event, :event_id) || value(event, :id)))

      {:ok, :naddr, address} ->
        address_target(address)

      _ ->
        nil
    end
  end

  defp profile_target(pubkey, tagged_pubkeys) when is_binary(pubkey) do
    with true <- Regex.match?(@hex_32_regex, pubkey),
         %Entity{user: %User{} = user} <- Identity.get_profile(pubkey) do
      if MapSet.member?(tagged_pubkeys, pubkey) do
        "@#{user.nickname}"
      else
        user.ap_id
      end
    else
      _ -> nil
    end
  end

  defp profile_target(_pubkey, _tagged_pubkeys), do: nil

  defp append_tagged_mentions(content, event) do
    missing =
      event
      |> tagged_mentions()
      |> Enum.map(&"@#{&1.user.nickname}")
      |> Enum.reject(&String.contains?(content, &1))

    case missing do
      [] -> content
      mentions -> content <> "\n\n" <> Enum.join(mentions, " ")
    end
  end

  defp put_inbound_mention(mention, object) do
    ap_id = mention.user.ap_id
    link = Formatter.mention_from_user(mention.user, %{mentions_format: :compact})
    content = object["content"] || ""

    content =
      if String.contains?(content, ~s(href="#{ap_id}")) do
        content
      else
        source = "@#{mention.user.nickname}"

        if String.contains?(content, source) do
          String.replace(content, source, link)
        else
          content <> "<br/><br/>" <> link
        end
      end

    tag = %{"type" => "Mention", "href" => ap_id, "name" => "@#{mention.user.nickname}"}

    object
    |> Map.put("content", content)
    |> Map.update("to", [ap_id], fn value -> Enum.uniq(list_values(value) ++ [ap_id]) end)
    |> Map.update("tag", [tag], fn value ->
      Enum.uniq_by(list_values(value) ++ [tag], &tag_identity/1)
    end)
  end

  defp list_values(value) when is_list(value), do: value
  defp list_values(value) when is_binary(value) or is_map(value), do: [value]
  defp list_values(_value), do: []

  defp tag_identity(%{"href" => href}) when is_binary(href), do: {:href, href}
  defp tag_identity(tag), do: {:tag, tag}

  defp address_target(address) do
    kind = value(address, :kind)
    pubkey = value(address, :author) || value(address, :pubkey)
    identifier = value(address, :identifier)

    with true <- is_integer(kind),
         true <- is_binary(pubkey) and Regex.match?(@hex_32_regex, pubkey),
         true <- is_binary(identifier),
         %Event{} = event <- find_addressable_event(kind, pubkey, identifier) do
      event_target(event)
    else
      _ -> nil
    end
  end

  defp find_addressable_event(kind, pubkey, identifier) do
    Event
    |> where([event], event.kind == ^kind and event.pubkey == ^pubkey)
    |> order_by([event], desc: event.created_at)
    |> limit(50)
    |> Repo.all()
    |> Enum.find(&has_identifier?(&1, identifier))
  end

  defp has_identifier?(%Event{data: data}, identifier) when is_map(data) do
    tags = Map.get(data, "tags") || Map.get(data, :tags) || []

    Enum.any?(tags, fn
      ["d", ^identifier | _rest] -> true
      _ -> false
    end)
  end

  defp has_identifier?(_event, _identifier), do: false

  defp event_target(%Event{} = event) do
    first_http_uri([event.ap_activity_uri, event.ap_object_id])
  end

  defp event_target(_event), do: nil

  defp rewrite_mentions(content, object_data) do
    object_data
    |> Map.get("tag", [])
    |> List.wrap()
    |> Enum.filter(&mention_tag?/1)
    |> Enum.take(@max_references)
    |> Enum.reduce({content, []}, fn mention, {text, tags} ->
      case outgoing_profile_reference(mention) do
        {:ok, uri, p_tag} -> {replace_mention(text, mention, uri), [p_tag | tags]}
        _ -> {text, tags}
      end
    end)
  end

  defp mention_tag?(%{"type" => "Mention", "href" => href}) when is_binary(href), do: true
  defp mention_tag?(_tag), do: false

  defp outgoing_profile_reference(%{"href" => href}) do
    with %User{} = user <- User.get_cached_by_ap_id(href),
         presentation when is_map(presentation) <- Identity.presentation(user),
         pubkey when is_binary(pubkey) <- value(presentation, :pubkey),
         true <- Regex.match?(@hex_32_regex, pubkey),
         relays <- safe_relays(value(presentation, :relays)),
         {:ok, uri} <- Nostr.NIP21.encode_nprofile(pubkey, relays) do
      {:ok, uri, p_tag(pubkey, relays)}
    else
      _ -> :error
    end
  end

  defp replace_mention(text, mention, uri) do
    [Map.get(mention, "name"), Map.get(mention, "href")]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.reduce(text, fn source, current -> String.replace(current, source, uri) end)
  end

  defp rewrite_event_links(content) do
    @web_url_regex
    |> Regex.scan(content)
    |> Enum.map(&hd/1)
    |> Enum.uniq()
    |> Enum.take(@max_references)
    |> Enum.reduce(content, fn url, text ->
      case stored_event_for_url(url) |> outgoing_event_reference() do
        uri when is_binary(uri) -> String.replace(text, url, uri)
        _ -> text
      end
    end)
  end

  defp stored_event_for_url(url) do
    Store.get_by_ap_activity_uri(url) || Store.get_by_ap_object_id(url)
  end

  defp outgoing_event_reference(%Event{id: id, pubkey: pubkey, kind: kind})
       when is_binary(id) and is_binary(pubkey) and is_integer(kind) do
    case Nostr.NIP21.encode_nevent(id, author: pubkey, kind: kind) do
      {:ok, uri} -> uri
      _ -> nil
    end
  end

  defp outgoing_event_reference(_event), do: nil

  defp p_tag(pubkey, [relay | _rest]), do: ["p", pubkey, relay]
  defp p_tag(pubkey, _relays), do: ["p", pubkey]

  defp safe_relays(relays) do
    relays
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, ["wss://", "ws://"])))
    |> Enum.uniq()
    |> Enum.take(4)
  end

  defp first_http_uri(values) do
    Enum.find(values, &(is_binary(&1) and String.starts_with?(&1, ["https://", "http://"])))
  end

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp value(_map, _key), do: nil
end

# end of references.ex
