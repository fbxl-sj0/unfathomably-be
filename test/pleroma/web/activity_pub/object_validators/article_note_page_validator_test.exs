# Pleroma: A lightweight social networking server
# Copyright Â© 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.ArticleNotePageValidatorTest do
  use Pleroma.DataCase, async: true

  require Pleroma.Constants

  alias Pleroma.Web.ActivityPub.ObjectValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.ArticleNotePageValidator
  alias Pleroma.Web.ActivityPub.Utils

  import Pleroma.Factory

  describe "Notes" do
    setup do
      user = insert(:user)

      note = %{
        "id" => Utils.generate_activity_id(),
        "type" => "Note",
        "actor" => user.ap_id,
        "to" => [user.follower_address],
        "cc" => [],
        "content" => "Hellow this is content.",
        "context" => "xxx",
        "summary" => "a post"
      }

      %{user: user, note: note}
    end

    test "a basic note validates", %{note: note} do
      %{valid?: true} = ArticleNotePageValidator.cast_and_validate(note)
    end

    test "a note with malformed language does not validate", %{note: note} do
      note = Map.put(note, "language", "en<script")

      %{valid?: false} = ArticleNotePageValidator.cast_and_validate(note)
    end

    test "a note with a language descriptor validates", %{note: note} do
      note = Map.put(note, "language", %{"identifier" => "en", "name" => "English"})

      changeset = ArticleNotePageValidator.cast_and_validate(note)

      assert changeset.valid?
      assert changeset.changes.language == "en"
    end

    test "a note from factory validates" do
      note = insert(:note)
      %{valid?: true} = ArticleNotePageValidator.cast_and_validate(note.data)
    end

    test "a note with a map-shaped tag validates without crashing", %{note: note} do
      note =
        Map.put(note, "tag", %{
          "type" => "Hashtag",
          "name" => "#woodworking"
        })

      assert {:ok, validate_res, []} = ObjectValidator.validate(note, [])
      assert is_list(validate_res["tag"])
      assert %{"type" => "Hashtag", "name" => "#woodworking"} in validate_res["tag"]
    end

    test "a note with malformed attachments validates without crashing", %{note: note} do
      note =
        Map.put(note, "attachment", [
          %{
            "type" => "Document",
            "mediaType" => "image/png",
            "url" => "https://example.test/image.png"
          },
          "not an attachment",
          nil
        ])

      cng = ArticleNotePageValidator.cast_and_validate(note)

      assert cng.valid?
      assert length(cng.changes.attachment) == 1
    end

    test "bounds remote attachments and preserves overflow as safe links", %{note: note} do
      clear_config([:instance, :remote_media_attachment_limit], 1)

      attachments =
        for number <- 1..3 do
          %{
            "type" => "Document",
            "mediaType" => "image/png",
            "url" => "https://media.example/#{number}.png"
          }
        end

      cng =
        note
        |> Map.put("attachment", attachments)
        |> ArticleNotePageValidator.cast_and_validate()

      assert cng.valid?
      assert length(cng.changes.attachment) == 1
      assert cng.changes.content =~ "https://media.example/2.png"
      refute cng.changes.content =~ "https://media.example/3.png"
      assert cng.changes.content =~ "Additional attachments omitted."
    end

    test "applies the remote content limit after stripping HTML", %{note: note} do
      clear_config([:instance, :remote_limit], 4)

      valid =
        note
        |> Map.put("content", "<p><strong>1234</strong></p>")
        |> ArticleNotePageValidator.cast_and_validate()

      invalid =
        note
        |> Map.put("content", "<p><strong>12345</strong></p>")
        |> ArticleNotePageValidator.cast_and_validate()

      assert valid.valid?
      refute invalid.valid?
      assert {"is longer than the configured remote post limit", []} = invalid.errors[:content]
    end

    test "a note with a non-list attachment field drops it without crashing", %{note: note} do
      note = Map.put(note, "attachment", "not an attachment")

      cng = ArticleNotePageValidator.cast_and_validate(note)

      assert cng.valid?
      refute Map.has_key?(cng.changes, :attachment)
    end

    test "a note with a malformed replies collection drops it without crashing", %{note: note} do
      note =
        Map.put(note, "replies", %{
          "id" => "https://remote.example/%",
          "type" => "Collection"
        })

      cng = ArticleNotePageValidator.cast_and_validate(note)

      assert cng.valid?
      refute Map.has_key?(cng.changes, :replies_collection)
    end

    test "preserves a modern GoToSocial reply authorization", %{note: note} do
      authorization = "https://parent.example/authorizations/reply-1"

      note =
        note
        |> Map.put("inReplyTo", "https://parent.example/statuses/1")
        |> Map.put("replyAuthorization", authorization)

      assert {:ok, validated, []} = ObjectValidator.validate(note, local: false)
      assert validated["replyAuthorization"] == authorization
    end

    test "canonicalizes deprecated approvedBy reply authorization", %{note: note} do
      authorization = "https://parent.example/authorizations/reply-legacy"

      note =
        note
        |> Map.put("inReplyTo", "https://parent.example/statuses/1")
        |> Map.put("approvedBy", authorization)

      assert {:ok, validated, []} = ObjectValidator.validate(note, local: false)
      assert validated["replyAuthorization"] == authorization
      refute Map.has_key?(validated, "approvedBy")
    end

    test "a protected reply cannot widen the parent audience" do
      parent_author =
        insert(:user,
          local: false,
          ap_id: "https://parent.example/users/author",
          follower_address: "https://parent.example/users/author/followers"
        )

      replier =
        insert(:user,
          local: false,
          ap_id: "https://reply.example/users/replier",
          follower_address: "https://reply.example/users/replier/followers"
        )

      assert {:ok, _, _} = Pleroma.FollowingRelationship.follow(replier, parent_author)

      parent =
        insert(:note,
          user: parent_author,
          data: %{
            "id" => "https://parent.example/statuses/1",
            "type" => "Note",
            "actor" => parent_author.ap_id,
            "attributedTo" => parent_author.ap_id,
            "to" => [parent_author.follower_address],
            "cc" => [],
            "content" => "Protected parent",
            "context" => "https://parent.example/contexts/1"
          }
        )

      base_reply = %{
        "id" => "https://reply.example/statuses/1",
        "type" => "Note",
        "actor" => replier.ap_id,
        "attributedTo" => replier.ap_id,
        "inReplyTo" => parent.data["id"],
        "to" => [parent_author.follower_address, parent_author.ap_id],
        "cc" => [],
        "content" => "Protected reply",
        "context" => parent.data["context"]
      }

      assert ArticleNotePageValidator.cast_and_validate(base_reply).valid?

      widened =
        base_reply
        |> Map.put("to", [parent_author.ap_id, replier.follower_address])
        |> ArticleNotePageValidator.cast_and_validate()

      refute widened.valid?

      assert {"reply audience is broader than parent audience", []} =
               widened.errors[:inReplyTo]
    end

    test "an unresolved non-public reply is rejected" do
      actor =
        insert(:user,
          local: false,
          ap_id: "https://reply.example/users/unresolved",
          follower_address: "https://reply.example/users/unresolved/followers"
        )

      reply = %{
        "id" => "https://reply.example/statuses/unresolved",
        "type" => "Note",
        "actor" => actor.ap_id,
        "attributedTo" => actor.ap_id,
        "inReplyTo" => "https://missing.example/statuses/1",
        "to" => ["https://missing.example/users/author"],
        "cc" => [],
        "content" => "Incomplete protected reply",
        "context" => "https://missing.example/contexts/1"
      }

      changeset = ArticleNotePageValidator.cast_and_validate(reply)

      refute changeset.valid?
      assert {"protected reply parent is unavailable", []} = changeset.errors[:inReplyTo]
    end
  end

  describe "Note with history" do
    setup do
      user = insert(:user)
      {:ok, activity} = Pleroma.Web.CommonAPI.post(user, %{status: "mew mew :dinosaur:"})
      {:ok, edit} = Pleroma.Web.CommonAPI.update(user, activity, %{status: "edited :blank:"})

      {:ok, %{"object" => external_rep}} =
        Pleroma.Web.ActivityPub.Transmogrifier.prepare_outgoing(edit.data)

      %{external_rep: external_rep}
    end

    test "edited note", %{external_rep: external_rep} do
      assert %{"formerRepresentations" => %{"orderedItems" => [%{"tag" => [_]}]}} = external_rep

      {:ok, validate_res, []} = ObjectValidator.validate(external_rep, [])

      assert %{"formerRepresentations" => %{"orderedItems" => [%{"emoji" => %{"dinosaur" => _}}]}} =
               validate_res
    end

    test "edited note, badly-formed formerRepresentations", %{external_rep: external_rep} do
      external_rep = Map.put(external_rep, "formerRepresentations", %{})

      assert {:error, _} = ObjectValidator.validate(external_rep, [])
    end

    test "edited note, badly-formed history item", %{external_rep: external_rep} do
      history_item =
        Enum.at(external_rep["formerRepresentations"]["orderedItems"], 0)
        |> Map.put("type", "Foo")

      external_rep =
        put_in(
          external_rep,
          ["formerRepresentations", "orderedItems"],
          [history_item]
        )

      assert {:error, _} = ObjectValidator.validate(external_rep, [])
    end
  end

  test "a Note from Roadhouse validates" do
    insert(:user, ap_id: "https://macgirvin.com/channel/mike")

    %{"object" => note} =
      "test/fixtures/roadhouse-create-activity.json"
      |> File.read!()
      |> Jason.decode!()

    %{valid?: true} = ArticleNotePageValidator.cast_and_validate(note)
  end

  test "a note with an attachment should work", _ do
    insert(:user, %{ap_id: "https://owncast.localhost.localdomain/federation/user/streamer"})

    note =
      "test/fixtures/owncast-note-with-attachment.json"
      |> File.read!()
      |> Jason.decode!()

    %{valid?: true} = ArticleNotePageValidator.cast_and_validate(note)
  end

  test "a Note without replies/first/items validates" do
    insert(:user, ap_id: "https://mastodon.social/users/emelie")

    note =
      "test/fixtures/tesla_mock/status.emelie.json"
      |> File.read!()
      |> Jason.decode!()
      |> pop_in(["replies", "first", "items"])
      |> elem(1)

    %{valid?: true} = ArticleNotePageValidator.cast_and_validate(note)
  end

  test "a Note with a Mastodon inlined likes collection validates" do
    insert(:user, ap_id: "https://pol.social/users/mkljczk")

    %{"object" => note} =
      "test/fixtures/mastodon-update-with-likes.json"
      |> File.read!()
      |> Jason.decode!()

    %{valid?: true} = ArticleNotePageValidator.cast_and_validate(note)
  end

  test "a Note with a linked likes collection validates" do
    insert(:user, ap_id: "https://pol.social/users/mkljczk")

    %{"object" => note} =
      "test/fixtures/mastodon-update-with-likes.json"
      |> File.read!()
      |> Jason.decode!()

    note = Map.put(note, "likes", "https://pol.social/users/mkljczk/statuses/1/likes")

    %{valid?: true} = ArticleNotePageValidator.cast_and_validate(note)
  end

  test "Fedibird quote post" do
    insert(:user, ap_id: "https://fedibird.com/users/noellabo")

    data = File.read!("test/fixtures/quote_post/fedibird_quote_post.json") |> Jason.decode!()
    cng = ArticleNotePageValidator.cast_and_validate(data)

    assert cng.valid?
    assert cng.changes.quoteUrl == "https://misskey.io/notes/8vsn2izjwh"
  end

  test "Fedibird quote post with quoteUri field" do
    insert(:user, ap_id: "https://fedibird.com/users/noellabo")

    data = File.read!("test/fixtures/quote_post/fedibird_quote_uri.json") |> Jason.decode!()
    cng = ArticleNotePageValidator.cast_and_validate(data)

    assert cng.valid?
    assert cng.changes.quoteUrl == "https://fedibird.com/users/yamako/statuses/107699333438289729"
  end

  test "Misskey quote post" do
    insert(:user, ap_id: "https://misskey.io/users/7rkrarq81i")

    data = File.read!("test/fixtures/quote_post/misskey_quote_post.json") |> Jason.decode!()
    cng = ArticleNotePageValidator.cast_and_validate(data)

    assert cng.valid?
    assert cng.changes.quoteUrl == "https://misskey.io/notes/8vs6wxufd0"
  end

  test "Hubzilla quote post with quote field" do
    user = insert(:user, ap_id: "https://hubzilla.example/channel/alice")

    data = %{
      "id" => "https://hubzilla.example/item/1",
      "type" => "Note",
      "actor" => user.ap_id,
      "attributedTo" => user.ap_id,
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [user.follower_address],
      "content" => "Hubzilla-style quote.",
      "context" => "https://hubzilla.example/conversation/1",
      "quote" => "https://hubzilla.example/item/quoted"
    }

    cng = ArticleNotePageValidator.cast_and_validate(data)

    assert cng.valid?
    assert cng.changes.quoteUrl == "https://hubzilla.example/item/quoted"
  end

  test "Parse tag as quote" do
    # https://codeberg.org/fediverse/fep/src/branch/main/fep/e232/fep-e232.md

    insert(:user, ap_id: "https://server.example/users/1")

    data = File.read!("test/fixtures/quote_post/fep-e232-tag-example.json") |> Jason.decode!()
    cng = ArticleNotePageValidator.cast_and_validate(data)

    assert cng.valid?
    assert cng.changes.quoteUrl == "https://server.example/objects/123"

    assert Enum.at(cng.changes.tag, 0).changes == %{
             type: "Link",
             mediaType: "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\"",
             href: "https://server.example/objects/123",
             name: "RE: https://server.example/objects/123"
           }
  end
end
