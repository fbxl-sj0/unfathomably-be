# Unfathomably BE
# ----------------
#
# File: nostr/thread.ex
#
# Purpose:
#   Interpret Nostr thread references consistently across projection and
#   bounded relay hydration.
#
# Responsibilities:
#   - apply preferred NIP-10 root and reply marker semantics
#   - recognize NIP-C7 kind-9 chat replies carried by q tags
#   - retain compatibility with deprecated positional e tags
#   - expose NIP-22 root references without treating citations as replies
#
# This file intentionally does NOT fetch events, mutate projections, or trust
# relay hints as authorization.

defmodule Pleroma.Nostr.Thread do
  def reply_id(event) do
    tags = tags(event)

    chat_reply_id(event, tags) ||
      marked_id(tags, "reply") ||
      nip22_reply_id(event, tags) ||
      marked_id(tags, "root") ||
      legacy_reply_id(tags)
  end

  def reference_ids(event) do
    tags = tags(event)

    upper_roots =
      Enum.flat_map(tags, fn
        ["E", event_id | _rest] when is_binary(event_id) -> [event_id]
        _tag -> []
      end)

    marked =
      Enum.flat_map(tags, fn
        ["e", event_id, _relay_url, marker | _rest]
        when is_binary(event_id) and marker in ["root", "reply"] ->
          [event_id]

        _tag ->
          []
      end)

    chat_replies =
      if event_kind(event) == 9 do
        Enum.flat_map(tags, fn
          ["q", event_id | _rest] when is_binary(event_id) -> [event_id]
          _tag -> []
        end)
      else
        []
      end

    nip22_parents = nip22_parent_ids(event, tags)

    legacy =
      tags
      |> legacy_event_ids()
      |> first_and_last()

    Enum.uniq(upper_roots ++ marked ++ chat_replies ++ nip22_parents ++ legacy)
  end

  def parent_author_pubkeys(event) do
    tags = tags(event)
    reply_id = reply_id(event)

    tagged_parent =
      Enum.flat_map(tags, fn
        ["e", ^reply_id, _relay_url, pubkey] -> valid_pubkey(pubkey)
        ["e", ^reply_id, _relay_url, _marker, pubkey | _rest] -> valid_pubkey(pubkey)
        ["q", ^reply_id, _relay_url, pubkey | _rest] -> valid_pubkey(pubkey)
        _tag -> []
      end)

    participants =
      Enum.flat_map(tags, fn
        [tag_name, pubkey | _rest] when tag_name in ["p", "P"] -> valid_pubkey(pubkey)
        _tag -> []
      end)

    (tagged_parent ++ participants)
    |> Enum.uniq()
    |> Enum.take(4)
  end

  def tags(%Pleroma.Nostr.Event{data: data}), do: tags(data)
  def tags(%{"tags" => tags}) when is_list(tags), do: tags
  def tags(_event), do: []

  # NIP-C7 reuses the NIP-18 q tag for chat replies. The event-kind guard is
  # important: q tags on ordinary notes and articles remain citations and
  # must not silently move those objects into another ActivityPub thread.
  defp chat_reply_id(event, tags) do
    if event_kind(event) == 9 do
      tags
      |> Enum.flat_map(fn
        ["q", event_id | _rest] when is_binary(event_id) -> [event_id]
        _tag -> []
      end)
      |> List.last()
    end
  end

  defp event_kind(%Pleroma.Nostr.Event{kind: kind}) when is_integer(kind), do: kind
  defp event_kind(%{"kind" => kind}) when is_integer(kind), do: kind
  defp event_kind(%{"kind" => "9"}), do: 9
  defp event_kind(%{"kind" => "1111"}), do: 1_111
  defp event_kind(_event), do: nil

  defp marked_id(tags, marker) do
    tags
    |> Enum.flat_map(fn
      ["e", event_id, _relay_url, ^marker | _rest] when is_binary(event_id) -> [event_id]
      _tag -> []
    end)
    |> List.last()
  end

  # NIP-22 deliberately uses an uppercase E tag for the thread root and a
  # lowercase e tag whose fourth field is the immediate parent's pubkey. That
  # fourth field is not a NIP-10 marker, so treating only marked e tags as
  # ancestry leaves nested comments orphaned in Mastodon-compatible views.
  defp nip22_reply_id(event, tags) do
    event
    |> nip22_parent_ids(tags)
    |> List.last()
  end

  defp nip22_parent_ids(event, tags) do
    if event_kind(event) == 1_111 do
      Enum.flat_map(tags, fn
        ["e", event_id, _relay_url, parent_pubkey]
        when is_binary(event_id) and is_binary(parent_pubkey) ->
          if valid_pubkey(parent_pubkey) == [], do: [], else: [event_id]

        _tag ->
          []
      end)
    else
      []
    end
  end

  defp legacy_reply_id(tags) do
    tags
    |> legacy_event_ids()
    |> List.last()
  end

  # An empty marker is emitted by some older clients and remains equivalent
  # to a markerless positional tag. Explicit markers such as "mention" are
  # references only and must not influence thread ancestry.
  defp legacy_event_ids(tags) do
    Enum.flat_map(tags, fn
      ["e", event_id] when is_binary(event_id) -> [event_id]
      ["e", event_id, _relay_url] when is_binary(event_id) -> [event_id]
      ["e", event_id, _relay_url, "" | _rest] when is_binary(event_id) -> [event_id]
      _tag -> []
    end)
  end

  defp first_and_last([]), do: []
  defp first_and_last([event_id]), do: [event_id]
  defp first_and_last(event_ids), do: Enum.uniq([List.first(event_ids), List.last(event_ids)])

  defp valid_pubkey(pubkey) when is_binary(pubkey) do
    if Regex.match?(~r/^[0-9a-f]{64}$/, pubkey), do: [pubkey], else: []
  end

  defp valid_pubkey(_pubkey), do: []
end

# end of nostr/thread.ex
