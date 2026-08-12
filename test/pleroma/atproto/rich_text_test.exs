# Unfathomably BE
# ----------------
#
# File: test/pleroma/atproto/rich_text_test.exs
#
# Purpose:
#   Verify safe translation of AT Protocol account mention facets.
#
# Responsibilities:
#   - preserve UTF-8 byte-index semantics
#   - reject malformed facet boundaries
#   - emit native facets for ActivityPub mention tags
#
# This file intentionally does NOT contact an AppView or write repository data.

defmodule Pleroma.ATProto.RichTextTest do
  use ExUnit.Case, async: true

  alias Pleroma.ATProto.RichText
  alias Pleroma.User

  @did "did:plc:alice"
  @handle "alice.example"
  @ap_id "https://social.example/users/atproto_alice"

  test "rewrites a valid UTF-8 byte-indexed mention through the local actor" do
    text = "caf\u00E9 says hello to @alice.example"
    {start, length} = :binary.match(text, "@alice.example")

    record = %{
      "text" => text,
      "facets" => [mention_facet(start, start + length)]
    }

    resolver = fn @did ->
      {:ok, %User{id: "1", nickname: "atproto_alice", ap_id: @ap_id}}
    end

    assert RichText.inbound(record, resolver) == "caf\u00E9 says hello to @atproto_alice"
  end

  test "ignores a facet that splits a UTF-8 codepoint" do
    record = %{"text" => "\u00E9 @alice.example", "facets" => [mention_facet(1, 3)]}
    resolver = fn _did -> raise "malformed facets must not resolve identities" end

    assert RichText.inbound(record, resolver) == record["text"]
  end

  test "keeps a possessive suffix outside the mention token" do
    text = "read @alice.example\u2019s post"
    {start, length} = :binary.match(text, "@alice.example")
    record = %{"text" => text, "facets" => [mention_facet(start, start + length)]}

    resolver = fn @did ->
      {:ok, %User{id: "1", nickname: "atproto_alice", ap_id: @ap_id}}
    end

    assert RichText.inbound(record, resolver) == "read @atproto_alice\u200B\u2019s post"
  end

  test "emits byte-indexed facets for an ActivityPub mention" do
    user = %User{id: "1", nickname: "atproto_alice", ap_id: @ap_id}
    tags = [%{"type" => "Mention", "href" => @ap_id, "name" => "@atproto_alice"}]

    resolver = fn @ap_id ->
      {:ok, %{did: @did, handle: @handle, user: user}}
    end

    assert {"hello @alice.example", [facet]} =
             RichText.outbound("hello @atproto_alice", tags, resolver)

    assert facet["features"] == [%{"$type" => "app.bsky.richtext.facet#mention", "did" => @did}]
    assert facet["index"] == %{"byteStart" => 6, "byteEnd" => 20}
  end

  test "writes canonical ActivityPub mention fields without relying on linkify" do
    text = "read @alice.example\u2019s post"
    {start, length} = :binary.match(text, "@alice.example")
    record = %{"text" => text, "facets" => [mention_facet(start, start + length)]}
    user = %User{id: "1", local: true, nickname: "atproto_alice", ap_id: @ap_id}
    resolver = fn @did -> {:ok, user} end

    object =
      RichText.put_inbound_mentions(
        %{"content" => "read @atproto_alice\u2019s post", "to" => [], "tag" => []},
        record,
        resolver
      )

    assert object["content"] =~ ~s(href="#{@ap_id}")
    assert @ap_id in object["to"]

    assert [%{"type" => "Mention", "href" => @ap_id}] =
             Enum.map(object["tag"], &Map.take(&1, ["type", "href"]))
  end

  test "emits non-overlapping URL and hashtag facets" do
    text = "Read https://example.com/story, then discuss #books."

    assert {^text, facets} = RichText.outbound(text, [])

    assert [
             %{
               "features" => [
                 %{
                   "$type" => "app.bsky.richtext.facet#link",
                   "uri" => "https://example.com/story"
                 }
               ]
             },
             %{
               "features" => [
                 %{"$type" => "app.bsky.richtext.facet#tag", "tag" => "books"}
               ]
             }
           ] = facets
  end

  defp mention_facet(start, stop) do
    %{
      "index" => %{"byteStart" => start, "byteEnd" => stop},
      "features" => [%{"$type" => "app.bsky.richtext.facet#mention", "did" => @did}]
    }
  end
end

# end of test/pleroma/atproto/rich_text_test.exs
