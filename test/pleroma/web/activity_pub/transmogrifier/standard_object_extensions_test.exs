# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.Transmogrifier.StandardObjectExtensionsTest do
  @moduledoc """
  Proves that bounded alien JSON-LD survives on standard ActivityStreams types.

  Ibis deliberately represents wiki pages as ordinary Articles while adding
  its edit collection, version, and protection state. NeoDB adds related mark,
  rating, review, and catalog vocabulary to ordinary Notes and Articles.
  Wanderer uses standard Notes with Place, GPX, and Note-shaped route metrics.
  Flohmarkt uses a standard Note with a structured market-data extension.
  ZenPub uses a top-level Document with publishing and education metadata.
  These properties must survive validation and later Updates without replacing
  normalized identity or authority fields.
  """

  use Pleroma.DataCase, async: false

  alias Pleroma.Activity
  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.CustomObject
  alias Pleroma.Web.ActivityPub.ObjectValidator
  alias Pleroma.Web.ActivityPub.Transmogrifier
  alias Pleroma.Web.MastodonAPI.StatusView

  import Pleroma.Factory

  require Pleroma.Constants

  setup do
    actor =
      insert(:user,
        local: false,
        ap_id: "https://ibis.example/user/wikibot",
        follower_address: "https://ibis.example/user/wikibot/followers"
      )

    %{actor: actor}
  end

  test "preserves and presents Ibis Article extensions", %{actor: actor} do
    article = ibis_article(actor)
    create = activity("Create", article, actor, "create")

    assert {:ok, %Activity{} = stored_activity} = Transmogrifier.handle_incoming(create)
    assert %Object{} = object = Object.get_by_ap_id(article["id"])

    assert object.data["edits"] == article["edits"]
    assert object.data["latestVersion"] == article["latestVersion"]
    assert object.data["protected"] == false
    assert object.data["postingRestrictedToMods"] == true
    assert object.data["ibis:proof"] == %{"retained" => true}
    assert object.data["@context"] == article["@context"]

    assert Enum.sort(
             object.data
             |> CustomObject.standard_extension_fields()
             |> Enum.reject(&(&1 == "@context"))
           ) ==
             ~w[edits ibis:proof latestVersion mediaType postingRestrictedToMods protected]

    exported = Transmogrifier.prepare_object(object.data)

    assert exported["edits"] == article["edits"]
    assert exported["latestVersion"] == article["latestVersion"]
    assert exported["ibis:proof"] == %{"retained" => true}
    refute Map.has_key?(exported, CustomObject.internal_field())

    rendered = StatusView.render("show.json", activity: stored_activity)

    assert %{
             canonical_id: "https://ibis.example/article/Alien_Wiki",
             class: "status",
             controls: ["open"],
             fields: %{
               edits: "https://ibis.example/article/Alien_Wiki/edits",
               latest_version: "11111111-1111-4111-8111-111111111111",
               posting_restricted_to_mods: true,
               protected: false
             },
             type: "Article"
           } = rendered.pleroma.native
  end

  test "updates the complete bounded Ibis extension set", %{actor: actor} do
    original = Map.put(ibis_article(actor), "ibis:legacy", "remove me")

    assert {:ok, %Activity{}} =
             Transmogrifier.handle_incoming(activity("Create", original, actor, "create"))

    updated =
      actor
      |> ibis_article()
      |> Map.merge(%{
        "content" => "<p>Updated wiki text</p>",
        "ibis:proof" => %{"retained" => "after update"},
        "latestVersion" => "22222222-2222-4222-8222-222222222222",
        "protected" => true,
        "updated" => "2026-07-17T21:00:00Z"
      })

    assert {:ok, %Activity{}} =
             Transmogrifier.handle_incoming(activity("Update", updated, actor, "update"))

    assert %Object{} = object = Object.get_by_ap_id(updated["id"])

    assert object.data["content"] == "<p>Updated wiki text</p>"
    assert object.data["latestVersion"] == "22222222-2222-4222-8222-222222222222"
    assert object.data["protected"] == true
    assert object.data["ibis:proof"] == %{"retained" => "after update"}
    refute Map.has_key?(object.data, "ibis:legacy")
  end

  test "imports an initial Ibis Article carried by Update", %{actor: actor} do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    article =
      actor
      |> ibis_article()
      |> Map.delete("actor")
      |> Map.put("published", timestamp)
      |> Map.put("updated", timestamp)

    update = activity("Update", article, actor, "initial-update")

    assert {:ok, %Activity{}} = Transmogrifier.handle_incoming(update)
    assert %Object{} = object = Object.get_by_ap_id(article["id"])
    assert object.data["attributedTo"] == actor.ap_id
    assert object.data["latestVersion"] == article["latestVersion"]

    later_timestamp =
      timestamp
      |> DateTime.from_iso8601()
      |> elem(1)
      |> DateTime.add(1)
      |> DateTime.to_iso8601()

    later_article =
      article
      |> Map.put("content", "<p>Updated wiki text</p>")
      |> Map.put("latestVersion", "22222222-2222-4222-8222-222222222222")
      |> Map.put("updated", later_timestamp)

    later_update = activity("Update", later_article, actor, "later-update")

    assert {:ok, %Activity{}} = Transmogrifier.handle_incoming(later_update)
    assert %Object{} = object = Object.get_by_ap_id(article["id"])
    assert object.data["content"] == "<p>Updated wiki text</p>"
    assert object.data["latestVersion"] == "22222222-2222-4222-8222-222222222222"
  end

  test "preserves the Group Announce around an initial Ibis Article Update", %{actor: actor} do
    group =
      insert(:user,
        actor_type: "Group",
        local: false,
        ap_id: "https://ibis.example/",
        follower_address: nil
      )

    timestamp = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    article =
      actor
      |> ibis_article()
      |> Map.delete("actor")
      |> Map.put("published", timestamp)
      |> Map.put("updated", timestamp)

    update = activity("Update", article, actor, "announced-initial-update")

    announce = %{
      "actor" => group.ap_id,
      "cc" => ["https://ibis.example/followers"],
      "id" => "https://ibis.example/activity/announce-initial-update",
      "object" => update,
      "to" => [Pleroma.Constants.as_public()],
      "type" => "Announce"
    }

    assert {:ok, %Activity{data: data}} = Transmogrifier.handle_incoming(announce)
    assert data["type"] == "Announce"
    assert data["actor"] == group.ap_id
    assert data["object"] == article["id"]
    assert data["audience"] == [group.ap_id]
    assert %Object{} = Object.get_by_ap_id(article["id"])
  end

  test "rejects an unsafe unknown field instead of silently dropping it", %{actor: actor} do
    clear_config([:activitypub, :custom_object_max_bytes], 512)

    article = Map.put(ibis_article(actor), "ibis:oversized", String.duplicate("x", 1_024))

    assert {:error, {:custom_object, :object_too_large}} =
             ObjectValidator.validate(activity("Create", article, actor, "unsafe"), local: false)
  end

  test "preserves and presents a stock ZenPub resource Document" do
    actor =
      insert(:user,
        local: false,
        ap_id: "https://zenpub.example/pub/actors/writer",
        follower_address: "https://zenpub.example/pub/actors/writer/followers"
      )

    object_id = "https://zenpub.example/pub/objects/alien-federation-handbook"

    document = %{
      "actor" => actor.ap_id,
      "attributedTo" => actor.ap_id,
      "author" => %{"name" => "Alien Federation Working Group", "type" => "Person"},
      "cc" => [actor.follower_address],
      "context" => "https://zenpub.example/pub/actors/library",
      "id" => object_id,
      "language" => "English",
      "level" => "intermediate",
      "name" => "Alien federation handbook",
      "published" => "2026-07-18T12:00:00Z",
      "subject" => "ActivityPub interoperability",
      "summary" => "A native ZenPub publishing resource.",
      "tag" => "CC-BY-SA-4.0",
      "to" => [Pleroma.Constants.as_public(), "https://zenpub.example/pub/actors/library"],
      "type" => "Document",
      "url" => "https://zenpub.example/uploads/alien-federation-handbook.pdf",
      "zenpub:proof" => %{"retained" => true}
    }

    create = %{
      "actor" => actor.ap_id,
      "cc" => document["cc"],
      "context" => document["context"],
      "id" => object_id <> "/activity",
      "object" => document,
      "to" => document["to"],
      "type" => "Create"
    }

    assert {:ok, %Activity{} = stored_activity} = Transmogrifier.handle_incoming(create)
    assert %Object{} = object = Object.get_by_ap_id(object_id)

    assert object.data["tag"] == ["CC-BY-SA-4.0"]
    assert object.data["author"] == document["author"]
    assert object.data["subject"] == "ActivityPub interoperability"
    assert object.data["level"] == "intermediate"
    assert object.data["language"] == "English"
    assert object.data["zenpub:proof"] == %{"retained" => true}

    assert Enum.sort(CustomObject.standard_extension_fields(object.data)) ==
             ~w[author language level subject tag zenpub:proof]

    exported = Transmogrifier.prepare_object(object.data)
    assert exported["tag"] == "CC-BY-SA-4.0"
    assert exported["author"] == document["author"]
    assert exported["zenpub:proof"] == %{"retained" => true}

    rendered = StatusView.render("show.json", activity: stored_activity)

    assert %{
             canonical_id: ^object_id,
             class: "status",
             controls: ["open"],
             fields: %{
               author: "Alien Federation Working Group",
               language: "English",
               level: "intermediate",
               license: "CC-BY-SA-4.0",
               platform: "zenpub",
               resource_url: "https://zenpub.example/uploads/alien-federation-handbook.pdf",
               subject: "ActivityPub interoperability"
             },
             type: "Document"
           } = rendered.pleroma.native
  end

  test "preserves and presents NeoDB Article relations and catalog tags" do
    actor =
      insert(:user,
        local: false,
        ap_id: "https://neodb.example/@reviewer@neodb.example/",
        follower_address: "https://neodb.example/@reviewer@neodb.example/followers/"
      )

    article_id = "https://neodb.example/@reviewer@neodb.example/posts/123/"
    catalog_id = "https://neodb.example/movie/catalog-123"

    article = %{
      "actor" => actor.ap_id,
      "attributedTo" => actor.ap_id,
      "cc" => [actor.follower_address],
      "content" => "<p>A native NeoDB review.</p>",
      "context" => article_id,
      "id" => article_id,
      "name" => "Alien catalog review",
      "published" => "2026-07-17T20:00:00Z",
      "relatedWith" => [
        %{
          "attributedTo" => actor.ap_id,
          "best" => 10,
          "href" => "https://neodb.example/p/rating-123",
          "id" => "https://neodb.example/p/rating-123",
          "type" => "Rating",
          "value" => 7,
          "withRegardTo" => catalog_id,
          "worst" => 1
        },
        %{
          "attributedTo" => actor.ap_id,
          "href" => "https://neodb.example/p/status-123",
          "id" => "https://neodb.example/p/status-123",
          "status" => "complete",
          "type" => "Status",
          "withRegardTo" => catalog_id
        },
        %{
          "attributedTo" => actor.ap_id,
          "content" => "Native markdown review",
          "href" => "https://neodb.example/review/review-123",
          "id" => "https://neodb.example/review/review-123",
          "mediaType" => "text/markdown",
          "name" => "Alien catalog review",
          "type" => "Review",
          "withRegardTo" => catalog_id
        }
      ],
      "source" => %{"content" => "A native NeoDB review.", "mediaType" => "text/markdown"},
      "tag" => [
        %{
          "href" => "https://neodb.example/tags/science-fiction",
          "name" => "#Science-Fiction",
          "type" => "Hashtag"
        },
        %{
          "href" => catalog_id,
          "image" => "https://neodb.example/media/catalog-123.jpg",
          "name" => "Alien Film",
          "type" => "Movie"
        }
      ],
      "to" => [Pleroma.Constants.as_public()],
      "type" => "Article",
      "updated" => "2026-07-17T20:00:00Z",
      "url" => article_id
    }

    create = %{
      "actor" => actor.ap_id,
      "cc" => article["cc"],
      "id" => "https://neodb.example/@reviewer@neodb.example/posts/123/create/",
      "object" => article,
      "to" => article["to"],
      "type" => "Create"
    }

    assert {:ok, %Activity{} = stored_activity} = Transmogrifier.handle_incoming(create)
    assert %Object{} = object = Object.get_by_ap_id(article_id)

    assert object.data["relatedWith"] == article["relatedWith"]
    assert Enum.any?(object.data["tag"], &(&1["type"] == "Movie" and &1["href"] == catalog_id))

    exported = Transmogrifier.prepare_object(object.data)
    assert exported["relatedWith"] == article["relatedWith"]
    assert Enum.any?(exported["tag"], &(&1["type"] == "Movie" and &1["href"] == catalog_id))

    rendered = StatusView.render("show.json", activity: stored_activity)

    assert %{
             class: "status",
             fields: %{
               catalog_item: ^catalog_id,
               catalog_type: "Movie",
               platform: "neodb",
               rating: 7,
               rating_best: 10,
               reading_status: "complete",
               review: "https://neodb.example/review/review-123"
             },
             type: "Article"
           } = rendered.pleroma.native
  end

  test "presents NeoDB's singleton Review relation and catalog tag shapes" do
    actor =
      insert(:user,
        local: false,
        ap_id: "https://neodb.example/@mark-reader@neodb.example/",
        follower_address: "https://neodb.example/@mark-reader@neodb.example/followers/"
      )

    catalog_id = "https://neodb.example/movie/catalog-456"
    object_id = "https://neodb.example/@mark-reader@neodb.example/posts/456/"
    review_id = "https://neodb.example/review/review-456"

    object = %{
      "actor" => actor.ap_id,
      "attributedTo" => actor.ap_id,
      "cc" => [actor.follower_address],
      "content" => "<p>A native NeoDB review.</p>",
      "context" => object_id,
      "id" => object_id,
      "published" => "2026-07-17T20:00:00Z",
      "relatedWith" => %{
        "content" => "A native NeoDB review.",
        "href" => review_id,
        "id" => review_id,
        "mediaType" => "text/markdown",
        "name" => "Alien catalog review",
        "type" => "Review",
        "withRegardTo" => catalog_id
      },
      "tag" => %{
        "href" => catalog_id,
        "image" => "https://neodb.example/media/catalog-456.jpg",
        "name" => "Alien Film",
        "type" => "Movie"
      },
      "to" => [Pleroma.Constants.as_public()],
      "type" => "Note"
    }

    create = %{
      "actor" => actor.ap_id,
      "cc" => object["cc"],
      "id" => "https://neodb.example/@mark-reader@neodb.example/posts/456/create/",
      "object" => object,
      "to" => object["to"],
      "type" => "Create"
    }

    assert {:ok, %Activity{} = stored_activity} = Transmogrifier.handle_incoming(create)
    assert %Object{} = stored_object = Object.get_by_ap_id(object_id)

    assert Enum.any?(stored_object.data["tag"], fn tag ->
             tag["type"] == "Movie" and tag["href"] == catalog_id and
               tag["image"] == "https://neodb.example/media/catalog-456.jpg"
           end)

    rendered = StatusView.render("show.json", activity: stored_activity)

    assert %{
             fields: %{
               catalog_item: ^catalog_id,
               catalog_type: "Movie",
               platform: "neodb",
               review: ^review_id
             }
           } = rendered.pleroma.native
  end

  test "preserves and presents Wanderer's standard Trail Note" do
    local_recipient = insert(:user)

    actor =
      insert(:user,
        local: false,
        ap_id: "https://wanderer.example/api/v1/activitypub/user/explorer",
        follower_address: "https://wanderer.example/api/v1/activitypub/user/explorer/followers"
      )

    trail_id = "https://wanderer.example/api/v1/trail/alien-route"
    gpx_url = "https://wanderer.example/api/v1/files/trails/alien-route/route.gpx"

    trail = %{
      "actor" => actor.ap_id,
      "attachment" => [
        %{
          "mediaType" => "application/xml+gpx",
          "type" => "Document",
          "url" => gpx_url
        }
      ],
      "attributedTo" => actor.ap_id,
      "cc" => [],
      # The inbox controller copies these outer delivery recipients into the
      # object before validation. Stock Wanderer itself omits the Trail audience.
      "cc" => [local_recipient.ap_id, actor.follower_address],
      "content" => "<h1>Alien escarpment route</h1>",
      "id" => trail_id,
      "location" => %{
        "latitude" => 47.678592,
        "longitude" => 11.196068,
        "name" => "Alien Escarpment",
        "type" => "Place"
      },
      "name" => "Alien escarpment route",
      "published" => "2026-07-17T20:00:00Z",
      "startTime" => "2026-07-17T08:00:00Z",
      "tag" => [
        %{"content" => "Hiking", "name" => "category", "type" => "Note"},
        %{"content" => "hard", "name" => "difficulty", "type" => "Note"},
        %{"content" => "12450.000000m", "name" => "distance", "type" => "Note"},
        %{"content" => "890.000000m", "name" => "elevation_gain", "type" => "Note"},
        %{"content" => "875.000000m", "name" => "elevation_loss", "type" => "Note"},
        %{"content" => "240.000000m", "name" => "duration", "type" => "Note"}
      ],
      "type" => "Note",
      "url" => "https://wanderer.example/trail/view/@explorer/alien-route"
    }

    create = %{
      "actor" => actor.ap_id,
      "cc" => [actor.follower_address, local_recipient.ap_id],
      "id" => "https://wanderer.example/api/v1/activitypub/activity/create-alien-route",
      "object" => trail,
      "to" => [Pleroma.Constants.as_public()],
      "type" => "Create"
    }

    assert {:ok, %Activity{} = stored_activity} = Transmogrifier.handle_incoming(create)
    assert %Object{} = object = Object.get_by_ap_id(trail_id)

    assert object.data["location"] == trail["location"]
    assert object.data["startTime"] == "2026-07-17T08:00:00Z"
    assert object.data["to"] == [Pleroma.Constants.as_public()]
    assert object.data["cc"] == [actor.follower_address]
    refute local_recipient.ap_id in object.data["cc"]
    assert Enum.any?(object.data["tag"], &(&1 == List.first(trail["tag"])))

    exported = Transmogrifier.prepare_object(object.data)
    assert Enum.any?(exported["tag"], &(&1["name"] == "distance"))
    assert Enum.any?(exported["attachment"], &(&1["url"] == gpx_url))

    rendered = StatusView.render("show.json", activity: stored_activity)

    assert %{
             class: "status",
             fields: %{
               category: "Hiking",
               difficulty: "hard",
               distance: "12450.000000m",
               duration: "240.000000m",
               elevation_gain: "890.000000m",
               elevation_loss: "875.000000m",
               gpx_url: ^gpx_url,
               latitude: 47.678592,
               location: "Alien Escarpment",
               longitude: 11.196068,
               platform: "wanderer",
               route_kind: "trail",
               start_time: "2026-07-17T08:00:00Z"
             },
             type: "Note"
           } = rendered.pleroma.native

    update_timestamp = "2026-07-17T21:00:00Z"

    updated_trail =
      trail
      |> Map.put("attachment", [
        %{
          "mediaType" => "application/xml+gpx",
          "type" => "Document",
          "url" => gpx_url <> "?revision=2"
        }
      ])
      |> Map.put("content", "<h1>Alien escarpment route revised</h1>")
      |> Map.put(
        "tag",
        Enum.map(trail["tag"], fn
          %{"name" => "difficulty"} = tag -> Map.put(tag, "content", "difficult")
          tag -> tag
        end)
      )

    update = %{
      "actor" => actor.ap_id,
      "cc" => [actor.follower_address, local_recipient.ap_id],
      "id" => "https://wanderer.example/api/v1/activitypub/activity/update-alien-route",
      "object" => updated_trail,
      "published" => update_timestamp,
      "to" => [Pleroma.Constants.as_public()],
      "type" => "Update"
    }

    assert {:ok, %Activity{}} = Transmogrifier.handle_incoming(update)
    assert %Object{} = revised_object = Object.get_by_ap_id(trail_id)
    assert revised_object.data["content"] == "<h1>Alien escarpment route revised</h1>"
    assert revised_object.data["updated"] == update_timestamp
    assert revised_object.data["to"] == [Pleroma.Constants.as_public()]
    assert revised_object.data["cc"] == [actor.follower_address]

    expected_gpx_url = gpx_url <> "?revision=2"

    assert [%{"url" => [%{"href" => ^expected_gpx_url}]}] =
             revised_object.data["attachment"]

    assert Enum.any?(
             revised_object.data["tag"],
             &(&1["name"] == "difficulty" and &1["content"] == "difficult")
           )

    same_second_trail =
      updated_trail
      |> Map.put("content", "<h1>Alien escarpment route final</h1>")
      |> Map.put(
        "tag",
        Enum.map(updated_trail["tag"], fn
          %{"name" => "difficulty"} = tag -> Map.put(tag, "content", "expert")
          tag -> tag
        end)
      )

    same_second_update =
      update
      |> Map.put(
        "id",
        "https://wanderer.example/api/v1/activitypub/activity/update-alien-route-again"
      )
      |> Map.put("object", same_second_trail)

    assert {:ok, %Activity{}} = Transmogrifier.handle_incoming(same_second_update)
    assert %Object{} = final_object = Object.get_by_ap_id(trail_id)
    assert final_object.data["content"] == "<h1>Alien escarpment route final</h1>"

    assert {:ok, final_updated, _offset} = DateTime.from_iso8601(final_object.data["updated"])
    assert {:ok, first_updated, _offset} = DateTime.from_iso8601(update_timestamp)
    assert DateTime.compare(final_updated, first_updated) == :gt

    assert Enum.any?(
             final_object.data["tag"],
             &(&1["name"] == "difficulty" and &1["content"] == "expert")
           )
  end

  test "preserves and presents a stock Flohmarkt listing Note" do
    actor =
      insert(:user,
        local: false,
        ap_id: "https://flohmarkt.example/users/seller",
        follower_address: "https://flohmarkt.example/users/seller/followers"
      )

    item_id = "11111111-1111-4111-8111-111111111111"
    object_id = "https://flohmarkt.example/users/seller/items/#{item_id}"
    listing = flohmarkt_listing(actor, item_id, "25", "A working receiver from another world.")
    create = flohmarkt_activity("Create", actor, listing)

    assert {:ok, %Activity{} = stored_activity} = Transmogrifier.handle_incoming(create)
    assert %Object{} = object = Object.get_by_ap_id(object_id)
    assert object.data["flohmarkt:data"] == listing["flohmarkt:data"]
    assert "flohmarkt:data" in CustomObject.standard_extension_fields(object.data)

    rendered = StatusView.render("show.json", activity: stored_activity)

    assert %{
             fields: %{
               currency: "CAD",
               latitude: 45.4215,
               listing_name: "Alien federation radio",
               longitude: -75.6972,
               original_id: ^item_id,
               platform: "flohmarkt",
               price: "25"
             },
             type: "Note"
           } = rendered.pleroma.native
  end

  test "preserves and presents a stock Castling.club chess Note" do
    actor =
      insert(:user,
        local: false,
        ap_id: "https://castling.example/@king",
        follower_address: "https://castling.example/@king/followers"
      )

    game_id = "11111111-1111-4111-8111-111111111111"
    object_id = "https://castling.example/objects/22222222-2222-4222-8222-222222222222"
    game_url = "https://castling.example/games/#{game_id}"

    note = %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        "https://castling.club/ns/chess/v0"
      ],
      "attachment" => [
        %{
          "mediaType" => "image/png",
          "type" => "Image",
          "url" => "https://castling.example/images/board.png"
        }
      ],
      "attributedTo" => actor.ap_id,
      "content" => "<p>e4</p>",
      "fen" => "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2",
      "game" => game_url,
      "id" => object_id,
      "published" => "2026-07-18T08:00:00Z",
      "san" => "e4",
      "to" => ["https://unfathomably.example/users/alice"],
      "type" => "Note"
    }

    assert {:ok, %Activity{} = stored_activity} =
             note
             |> then(&activity("Create", &1, actor, "castling-e4"))
             |> Transmogrifier.handle_incoming()

    assert %Object{} = object = Object.get_by_ap_id(object_id)
    assert object.data["fen"] == note["fen"]
    assert object.data["game"] == game_url
    assert object.data["san"] == "e4"

    assert Enum.sort(~w[@context fen game san]) ==
             object.data |> CustomObject.standard_extension_fields() |> Enum.sort()

    rendered = StatusView.render("show.json", activity: stored_activity)

    assert %{
             fields: %{
               fen: "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2",
               game: ^game_url,
               platform: "castling",
               san: "e4"
             },
             type: "Note"
           } = rendered.pleroma.native

    impostor =
      note
      |> Map.put("attributedTo", "https://castling.example/users/alice")
      |> CustomObject.put_standard_internal_metadata(~w[@context fen game san])

    assert %{fields: impostor_fields} = CustomObject.presentation(impostor)
    refute Map.has_key?(impostor_fields, :platform)
  end

  test "applies idempotent Flohmarkt Updates that reuse the Create activity ID" do
    actor =
      insert(:user,
        local: false,
        ap_id: "https://flohmarkt.example/users/seller",
        follower_address: "https://flohmarkt.example/users/seller/followers"
      )

    item_id = "22222222-2222-4222-8222-222222222222"
    listing = flohmarkt_listing(actor, item_id, "25", "The original listing.")
    create = flohmarkt_activity("Create", actor, listing)

    assert {:ok, %Activity{} = create_activity} = Transmogrifier.handle_incoming(create)

    revised_listing =
      listing
      |> Map.put("content", "Alien federation radio revised <br> Price: 30 CAD")
      |> put_in(["flohmarkt:data", "description"], "The revised listing.")
      |> put_in(["flohmarkt:data", "name"], "Alien federation radio revised")
      |> put_in(["flohmarkt:data", "price"], "30")

    update = flohmarkt_activity("Update", actor, revised_listing)

    assert {:ok, %Activity{id: activity_id}} = Transmogrifier.handle_incoming(update)
    assert activity_id == create_activity.id

    assert %Object{} = revised_object = Object.get_by_ap_id(listing["id"])
    assert revised_object.data["content"] =~ "Price: 30 CAD"
    assert revised_object.data["flohmarkt:data"]["price"] == "30"
    first_updated = revised_object.data["updated"]
    assert revised_object.data["formerRepresentations"]["totalItems"] == 1

    assert {:ok, %Activity{id: ^activity_id}} = Transmogrifier.handle_incoming(update)
    assert %Object{} = retried_object = Object.get_by_ap_id(listing["id"])
    assert retried_object.data["updated"] == first_updated
    assert retried_object.data["formerRepresentations"]["totalItems"] == 1

    final_listing =
      revised_listing
      |> Map.put("content", "Alien federation radio final <br> Price: 35 CAD")
      |> put_in(["flohmarkt:data", "description"], "The final listing.")
      |> put_in(["flohmarkt:data", "name"], "Alien federation radio final")
      |> put_in(["flohmarkt:data", "price"], "35")

    assert {:ok, %Activity{id: ^activity_id}} =
             final_listing
             |> then(&flohmarkt_activity("Update", actor, &1))
             |> Transmogrifier.handle_incoming()

    assert %Object{} = final_object = Object.get_by_ap_id(listing["id"])
    assert final_object.data["content"] =~ "Price: 35 CAD"
    assert final_object.data["flohmarkt:data"]["price"] == "35"
    assert final_object.data["formerRepresentations"]["totalItems"] == 2

    assert {:ok, final_updated, _offset} = DateTime.from_iso8601(final_object.data["updated"])
    assert {:ok, first_updated, _offset} = DateTime.from_iso8601(first_updated)
    assert DateTime.compare(final_updated, first_updated) == :gt

    assert %Activity{data: %{"type" => "Create"}} =
             Activity.get_by_ap_id(listing["id"] <> "/activity")
  end

  test "does not apply reused activity IDs to an ordinary Note" do
    actor =
      insert(:user,
        local: false,
        ap_id: "https://flohmarkt.example/users/plain",
        follower_address: "https://flohmarkt.example/users/plain/followers"
      )

    item_id = "33333333-3333-4333-8333-333333333333"

    note =
      actor
      |> flohmarkt_listing(item_id, "25", "Not native market data.")
      |> Map.delete("flohmarkt:data")

    create = flohmarkt_activity("Create", actor, note)

    assert {:ok, %Activity{} = create_activity} = Transmogrifier.handle_incoming(create)

    update =
      note
      |> Map.put("content", "A duplicate activity ID must not replace this Note.")
      |> then(&flohmarkt_activity("Update", actor, &1))

    assert {:ok, %Activity{id: activity_id}} = Transmogrifier.handle_incoming(update)
    assert activity_id == create_activity.id
    assert Object.get_by_ap_id(note["id"]).data["content"] == note["content"]
  end

  defp activity(type, object, actor, suffix) do
    %{
      "actor" => actor.ap_id,
      "cc" => object["cc"],
      "id" => "https://ibis.example/activity/#{suffix}",
      "object" => object,
      "to" => object["to"],
      "type" => type
    }
  end

  defp flohmarkt_activity(type, actor, object) do
    %{
      "actor" => actor.ap_id,
      "cc" => object["cc"],
      "id" => object["id"] <> "/activity",
      "object" => object,
      "published" => object["published"],
      "to" => object["to"],
      "type" => type
    }
  end

  defp flohmarkt_listing(actor, item_id, price, description) do
    username = actor.ap_id |> URI.parse() |> Map.fetch!(:path) |> Path.basename()
    object_id = "https://flohmarkt.example/users/#{username}/items/#{item_id}"

    %{
      "actor" => actor.ap_id,
      "attachment" => [],
      "attributedTo" => actor.ap_id,
      "cc" => [actor.follower_address],
      "content" => "Alien federation radio <br> #{description} Price: #{price} CAD",
      "flohmarkt:data" => %{
        "coordinates" => %{"lat" => 45.4215, "lng" => -75.6972},
        "currency" => "CAD",
        "description" => description,
        "name" => "Alien federation radio",
        "original_id" => item_id,
        "price" => price,
        "signature" => "Please respond with a direct message"
      },
      "id" => object_id,
      "published" => "2026-07-18T06:00:00Z",
      "to" => [Pleroma.Constants.as_public()],
      "type" => "Note",
      "url" => "https://flohmarkt.example/~#{username}/#{item_id}"
    }
  end

  defp ibis_article(actor) do
    %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        %{
          "edits" => %{"@id" => "https://ibis.wiki/ns#edits", "@type" => "@id"},
          "latestVersion" => "https://ibis.wiki/ns#latestVersion"
        }
      ],
      "actor" => actor.ap_id,
      "attributedTo" => actor.ap_id,
      "cc" => [],
      "content" => "<p>Original wiki text</p>",
      "context" => "https://ibis.example/article/Alien_Wiki",
      "edits" => "https://ibis.example/article/Alien_Wiki/edits",
      "ibis:proof" => %{"retained" => true},
      "id" => "https://ibis.example/article/Alien_Wiki",
      "latestVersion" => "11111111-1111-4111-8111-111111111111",
      "mediaType" => "text/html",
      "name" => "Alien Wiki",
      "postingRestrictedToMods" => true,
      "protected" => false,
      "published" => "2026-07-17T20:00:00Z",
      "source" => %{"content" => "Original wiki text", "mediaType" => "text/markdown"},
      "to" => [
        "https://www.w3.org/ns/activitystreams#Public",
        "https://ibis.example/"
      ],
      "type" => "Article",
      "updated" => "2026-07-17T20:00:00Z",
      "url" => "https://ibis.example/article/Alien_Wiki"
    }
  end
end

# end of test/pleroma/web/activity_pub/transmogrifier/standard_object_extensions_test.exs
