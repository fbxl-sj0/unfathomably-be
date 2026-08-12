# Unfathomably BE
# ----------------
#
# File: atproto/rich_text.ex
#
# Purpose:
#   Translate AT Protocol rich-text mentions at the ActivityPub boundary.
#
# Responsibilities:
#   - validate UTF-8 byte ranges supplied by Bluesky facets
#   - resolve mention DIDs to local projection actors
#   - rewrite imported mentions through the normal ActivityPub formatter
#   - emit AT Protocol mention facets for linked local accounts
#
# This file intentionally does NOT render arbitrary HTML, fetch post threads,
# or handle non-mention rich-text features.

defmodule Pleroma.ATProto.RichText do
  alias Pleroma.ATProto.Identities
  alias Pleroma.ATProto.Identity
  alias Pleroma.Formatter
  alias Pleroma.User

  @mention_type "app.bsky.richtext.facet#mention"
  @link_type "app.bsky.richtext.facet#link"
  @tag_type "app.bsky.richtext.facet#tag"
  @maximum_facets 64

  @doc "Rewrites valid Bluesky mention facets to local ActivityPub nicknames."
  def inbound(record, resolver \\ &resolve_did/1)

  def inbound(%{"text" => text, "facets" => facets}, resolver)
      when is_binary(text) and is_list(facets) do
    mentions = inbound_mentions(text, facets, resolver)

    Enum.reduce(Enum.reverse(mentions), text, fn mention, current ->
      replacement = inbound_replacement(text, mention.stop, mention.user)
      replace_byte_range(current, mention.start, mention.stop, replacement)
    end)
  end

  def inbound(%{"text" => text}, _resolver) when is_binary(text), do: text
  def inbound(_record, _resolver), do: ""

  @doc "Adds canonical ActivityPub presentation and addressing for Bluesky mentions."
  def put_inbound_mentions(object, record, resolver \\ &resolve_did/1)

  def put_inbound_mentions(
        %{} = object,
        %{"text" => text, "facets" => facets},
        resolver
      )
      when is_binary(text) and is_list(facets) do
    text
    |> inbound_mentions(facets, resolver)
    |> Enum.reduce(object, &put_inbound_mention/2)
  end

  def put_inbound_mentions(object, _record, _resolver), do: object

  @doc "Adds native mention facets for ActivityPub mentions of AT Protocol identities."
  def outbound(text, tags, resolver \\ &resolve_ap_actor/1)

  def outbound(text, tags, resolver)
      when is_binary(text) and is_list(tags) do
    mentions =
      tags
      |> Enum.filter(&mention_tag?/1)
      |> Enum.take(@maximum_facets)
      |> Enum.flat_map(&outbound_mention(&1, resolver))

    rewritten = Enum.reduce(mentions, text, &rewrite_outbound_mention/2)

    mention_facets =
      mentions
      |> Enum.flat_map(&outbound_facets(rewritten, &1))
      |> Enum.uniq_by(fn facet ->
        {get_in(facet, ["index", "byteStart"]), get_in(facet, ["index", "byteEnd"])}
      end)

    facets =
      (mention_facets ++ plain_facets(rewritten))
      |> non_overlapping_facets()
      |> Enum.take(@maximum_facets)

    {rewritten, facets}
  end

  def outbound(text, _tags, _resolver) when is_binary(text), do: {text, []}
  def outbound(_text, _tags, _resolver), do: {"", []}

  defp inbound_mention(text, %{"index" => index, "features" => features}, resolver)
       when is_map(index) and is_list(features) do
    start = index["byteStart"]
    stop = index["byteEnd"]
    did = mention_did(features)

    with true <- valid_range?(text, start, stop),
         true <- is_binary(did),
         label when is_binary(label) <- binary_part(text, start, stop - start),
         true <- String.valid?(label),
         {:ok, %User{} = user} <- safe_resolve(resolver, did) do
      [%{start: start, stop: stop, label: label, did: did, user: user}]
    else
      _ -> []
    end
  end

  defp inbound_mention(_text, _facet, _resolver), do: []

  defp inbound_mentions(text, facets, resolver) do
    facets
    |> Enum.take(@maximum_facets)
    |> Enum.flat_map(&inbound_mention(text, &1, resolver))
    |> non_overlapping_mentions()
  end

  defp mention_did(features) do
    Enum.find_value(features, fn
      %{"$type" => @mention_type, "did" => did} when is_binary(did) -> did
      _feature -> nil
    end)
  end

  defp valid_range?(text, start, stop)
       when is_integer(start) and is_integer(stop) and start >= 0 and start < stop and
              stop <= byte_size(text) do
    prefix = binary_part(text, 0, start)
    value = binary_part(text, start, stop - start)
    suffix = binary_part(text, stop, byte_size(text) - stop)
    String.valid?(prefix) and String.valid?(value) and String.valid?(suffix)
  end

  defp valid_range?(_text, _start, _stop), do: false

  defp non_overlapping_mentions(mentions) do
    mentions
    |> Enum.sort_by(&{&1.start, &1.stop})
    |> Enum.reduce({[], 0}, fn mention, {accepted, previous_stop} ->
      if mention.start >= previous_stop do
        {[mention | accepted], mention.stop}
      else
        {accepted, previous_stop}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp replace_byte_range(text, start, stop, replacement) do
    prefix = binary_part(text, 0, start)
    suffix = binary_part(text, stop, byte_size(text) - stop)
    prefix <> replacement <> suffix
  end

  # Linkify treats a possessive apostrophe as part of a fediverse nickname.
  # A zero-width boundary keeps the visible Bluesky text unchanged while the
  # normal mention formatter sees the account token as complete.
  defp inbound_replacement(text, stop, user) do
    suffix = binary_part(text, stop, byte_size(text) - stop)
    boundary = if String.starts_with?(suffix, ["'", "\u2019"]), do: "\u200B", else: ""
    "@#{user.nickname}#{boundary}"
  end

  defp put_inbound_mention(mention, object) do
    ap_id = mention.user.ap_id
    link = Formatter.mention_from_user(mention.user, %{mentions_format: :compact})
    content = object["content"] || ""

    content =
      if String.contains?(content, ~s(href="#{ap_id}")) do
        content
      else
        [mention.label, "@#{mention.user.nickname}"]
        |> Enum.find(&String.contains?(content, &1))
        |> case do
          source when is_binary(source) -> String.replace(content, source, link)
          _source -> content <> "<br/><br/>" <> link
        end
      end

    tag = %{"type" => "Mention", "href" => ap_id, "name" => mention.label}

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

  defp mention_tag?(%{"type" => "Mention", "href" => href}) when is_binary(href), do: true
  defp mention_tag?(_tag), do: false

  defp outbound_mention(%{"href" => href} = tag, resolver) do
    with {:ok, %{did: did, handle: handle, user: %User{} = user}} <-
           safe_resolve(resolver, href),
         true <- is_binary(did) and is_binary(handle) and handle != "" do
      [%{did: did, handle: handle, user: user, name: tag["name"]}]
    else
      _ -> []
    end
  end

  defp rewrite_outbound_mention(mention, text) do
    replacement = "@#{mention.handle}"

    [mention.name, "@#{mention.user.nickname}", "@#{User.full_nickname(mention.user)}"]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.reduce(text, fn source, current ->
      pattern =
        Regex.compile!(
          "(?<![\\p{L}\\p{N}_@])#{Regex.escape(source)}(?![\\p{L}\\p{N}_.-])",
          "u"
        )

      Regex.replace(pattern, current, replacement)
    end)
  end

  defp outbound_facets(text, mention) do
    token = "@#{mention.handle}"

    text
    |> :binary.matches(token)
    |> Enum.map(fn {start, length} ->
      %{
        "index" => %{"byteStart" => start, "byteEnd" => start + length},
        "features" => [%{"$type" => @mention_type, "did" => mention.did}]
      }
    end)
  end

  defp plain_facets(text) do
    link_facets(text) ++ tag_facets(text)
  end

  defp link_facets(text) do
    ~r{https?://[^\s<>"']+}u
    |> Regex.scan(text, return: :index)
    |> Enum.flat_map(fn
      [{start, length}] ->
        value = binary_part(text, start, length)
        uri = Regex.replace(~r/[.,;:!?]+$/u, value, "")
        adjusted_length = byte_size(uri)

        case URI.new(uri) do
          {:ok, %URI{scheme: scheme, host: host}}
          when scheme in ["http", "https"] and is_binary(host) and host != "" and
                 adjusted_length > 0 ->
            [
              %{
                "index" => %{
                  "byteStart" => start,
                  "byteEnd" => start + adjusted_length
                },
                "features" => [%{"$type" => @link_type, "uri" => uri}]
              }
            ]

          _uri ->
            []
        end

      _match ->
        []
    end)
  end

  defp tag_facets(text) do
    ~r/(?:^|[\s(])(#[^\d\s#][\p{L}\p{M}\p{N}_-]*)/u
    |> Regex.scan(text, return: :index)
    |> Enum.flat_map(fn
      [_full, {start, length}] ->
        value = binary_part(text, start, length)
        tag = String.trim_leading(value, "#")

        if String.length(tag) in 1..64 do
          [
            %{
              "index" => %{"byteStart" => start, "byteEnd" => start + length},
              "features" => [%{"$type" => @tag_type, "tag" => tag}]
            }
          ]
        else
          []
        end

      _match ->
        []
    end)
  end

  defp non_overlapping_facets(facets) do
    facets
    |> Enum.sort_by(fn facet ->
      {get_in(facet, ["index", "byteStart"]), get_in(facet, ["index", "byteEnd"])}
    end)
    |> Enum.reduce({[], 0}, fn facet, {accepted, previous_stop} ->
      start = get_in(facet, ["index", "byteStart"])
      stop = get_in(facet, ["index", "byteEnd"])

      if is_integer(start) and is_integer(stop) and start >= previous_stop and start < stop do
        {[facet | accepted], stop}
      else
        {accepted, previous_stop}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp resolve_did(did) do
    case Identities.get_by_did(did) do
      %Identity{user: %User{} = user} -> {:ok, user}
      _identity -> Identities.resolve(did)
    end
  end

  defp resolve_ap_actor(ap_id) do
    with %User{} = user <- User.get_cached_by_ap_id(ap_id),
         %Identity{did: did, handle: handle} <- Identities.get_by_user(user),
         true <- is_binary(handle) and handle != "" do
      {:ok, %{did: did, handle: handle, user: user}}
    else
      _ -> :error
    end
  end

  defp safe_resolve(resolver, value) do
    resolver.(value)
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end
end

# end of atproto/rich_text.ex
