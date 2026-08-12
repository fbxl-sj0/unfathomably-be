# Unfathomably BE
# ----------------
#
# File: native_object_controller_test.exs
#
# Purpose:
#   Cover the author-facing native-object discovery API contract.
#
# Responsibilities:
#   - prove connector state is OAuth protected
#   - prove marketplace readiness does not disclose configured peer URLs
#
# This file intentionally does not contact remote marketplace servers.

defmodule Pleroma.Web.MastodonAPI.NativeObjectControllerTest do
  use Pleroma.Web.ConnCase

  import Ecto.Query

  setup do
    Mox.stub_with(Pleroma.UnstubbedConfigMock, Pleroma.Config)
    :ok
  end

  describe "GET /api/v1/discovery/native-objects/connectors" do
    setup do: oauth_access(["read:search"])

    test "returns privacy-preserving marketplace readiness metadata", %{conn: conn} do
      response =
        conn
        |> get("/api/v1/discovery/native-objects/connectors")
        |> json_response(200)

      assert %{
               "marketplace" => %{
                 "connected_peers" => 0,
                 "ready" => false,
                 "requirements" => ["public_offer", "price", "currency", "latitude", "longitude"],
                 "service_actor" => service_actor
               }
             } = response

      assert service_actor =~ "/users/instance"
      refute Map.has_key?(response["marketplace"], "peers")
      assert response["marketplace"]["pending_peers"] == 0
      assert response["marketplace"]["unavailable_peers"] == 0
    end
  end

  describe "POST /api/v1/discovery/native-objects" do
    setup do: oauth_access(["write:statuses"])

    test "accepts signed marketplace coordinates within geographic bounds", %{conn: conn} do
      response =
        conn
        |> post("/api/v1/discovery/native-objects", %{
          "content" => "A local listing in the southern and western hemispheres.",
          "fields" => %{
            "currency" => "CAD",
            "latitude" => "-33.8688",
            "listing_type" => "offer",
            "longitude" => "-70.6693",
            "price" => "25.00"
          },
          "template" => "markets",
          "title" => "Signed-coordinate listing",
          "visibility" => "public"
        })
        |> json_response(200)

      object = Pleroma.Object.get_by_ap_id(response["uri"])

      assert object.data["latitude"] == "-33.8688"
      assert object.data["longitude"] == "-70.6693"
    end

    test "normalizes a shared giveaway and publishes searchable listing tags", %{conn: conn} do
      response =
        conn
        |> post("/api/v1/discovery/native-objects", %{
          "content" => "A working radio that needs a new home.",
          "fields" => %{
            "currency" => "cad",
            "latitude" => "43.6532",
            "listing_mode" => "giveaway",
            "longitude" => "-79.3832",
            "share_with_marketplaces" => true,
            "tags" => "radio, free stuff"
          },
          "template" => "markets",
          "title" => "Free shortwave radio",
          "visibility" => "public"
        })
        |> json_response(200)

      object = Pleroma.Object.get_by_ap_id(response["uri"])

      assert object.data["listingMode"] == "giveaway"
      assert object.data["listingType"] == "offer"
      assert object.data["marketplaceDelivery"] == true
      assert object.data["price"] == "0.00"
      assert object.data["priceCurrency"] == "CAD"

      assert object.data["tag"]
             |> Enum.map(& &1["name"])
             |> Enum.sort() == ["#free_stuff", "#radio"]
    end

    test "rejects marketplace delivery without an approximate public area", %{conn: conn} do
      response =
        conn
        |> post("/api/v1/discovery/native-objects", %{
          "content" => "A listing that is not ready for connected marketplaces.",
          "fields" => %{
            "currency" => "CAD",
            "listing_mode" => "sell",
            "price" => "25.00",
            "share_with_marketplaces" => true
          },
          "template" => "markets",
          "title" => "Incomplete marketplace listing",
          "visibility" => "public"
        })
        |> json_response(422)

      assert response["error"] ==
               "An approximate location is required for connected marketplaces"
    end

    test "rejects marketplace coordinates outside geographic bounds", %{conn: conn} do
      base_params = %{
        "content" => "A listing with invalid public coordinates.",
        "fields" => %{
          "currency" => "CAD",
          "latitude" => "43.6532",
          "listing_type" => "offer",
          "longitude" => "-79.3832",
          "price" => "25.00"
        },
        "template" => "markets",
        "title" => "Out-of-range listing",
        "visibility" => "public"
      }

      for {field, value, error} <- [
            {"latitude", "90.000001", "Latitude must be between -90 and 90"},
            {"longitude", "-180.000001", "Longitude must be between -180 and 180"}
          ] do
        params = put_in(base_params, ["fields", field], value)

        response =
          conn
          |> post("/api/v1/discovery/native-objects", params)
          |> json_response(422)

        assert response["error"] == error
      end
    end

    test "publishes Wanderer-style route tags and derived metrics", %{conn: conn} do
      response =
        conn
        |> post("/api/v1/discovery/native-objects", %{
          "content" => "A shaded riverside walk with one steep bank.",
          "fields" => %{
            "difficulty" => "easy",
            "distance" => "1240",
            "distance_unit" => "m",
            "duration" => "900",
            "elevation_gain" => "18",
            "elevation_loss" => "16",
            "route_kind" => "walk",
            "tags" => "river, dog friendly"
          },
          "reference_url" => "https://trails.example/routes/river-walk.gpx",
          "template" => "routes",
          "title" => "River walk",
          "visibility" => "public"
        })
        |> json_response(200)

      object = Pleroma.Object.get_by_ap_id(response["uri"])

      assert object.data["gpxUrl"] == "https://trails.example/routes/river-walk.gpx"
      assert object.data["routeKind"] == "walk"

      tag_names =
        object.data["tag"]
        |> Enum.filter(&is_map/1)
        |> Enum.map(& &1["name"])

      assert "#river" in tag_names
      assert "#dog_friendly" in tag_names

      assert Enum.any?(
               object.data["tag"],
               &(&1["name"] == "distance" and &1["content"] == "1240m")
             )
    end

    test "publishes Manyfold-style human metadata without manual file protocol fields", %{
      conn: conn
    } do
      response =
        conn
        |> post("/api/v1/discovery/native-objects", %{
          "content" => "A printable enclosure with assembly and attribution notes.",
          "fields" => %{
            "collection" => "Radio enclosures",
            "creator" => "Example Designer",
            "license" => "CC-BY-SA-4.0",
            "tags" => "radio, enclosure"
          },
          "reference_url" => "https://models.example/objects/radio-enclosure.stl",
          "template" => "models",
          "title" => "Shortwave radio enclosure",
          "visibility" => "public"
        })
        |> json_response(200)

      object = Pleroma.Object.get_by_ap_id(response["uri"])

      assert object.data["f3di:concreteType"] == "3DModel"
      assert object.data["creator"] == "Example Designer"
      assert object.data["collection"] == "Radio enclosures"
      assert object.data["fileFormat"] == "STL"
      assert object.data["spdx:license"] == %{"spdx:licenseId" => "CC-BY-SA-4.0"}
      assert object.data["indexable"] == true
      assert object.data["discoverable"] == true

      assert object.data["tag"]
             |> Enum.filter(&is_map/1)
             |> Enum.map(& &1["name"])
             |> Enum.sort() == ["#enclosure", "#radio"]
    end

    test "does not advertise unlisted Manyfold models for catalogue discovery", %{conn: conn} do
      response =
        conn
        |> post("/api/v1/discovery/native-objects", %{
          "content" => "A model shared by direct link rather than catalogue search.",
          "fields" => %{"file_format" => "STL", "printable" => true},
          "reference_url" => "https://models.example/objects/private-stand.stl",
          "template" => "models",
          "title" => "Unlisted tablet stand",
          "visibility" => "unlisted"
        })
        |> json_response(200)

      object = Pleroma.Object.get_by_ap_id(response["uri"])

      assert object.data["indexable"] == false
      assert object.data["discoverable"] == false
    end

    test "publishes BookWyrm-compatible review references", %{conn: conn} do
      book = "https://books.example/book/alien-federation"
      clear_config([:native_discovery, :bookwyrm_indexes], ["https://books.example"])

      response =
        conn
        |> post("/api/v1/discovery/native-objects", %{
          "content" => "A careful review.",
          "fields" => %{"author" => "A. Reader", "rating" => "4.5"},
          "reference_url" => book,
          "spoiler_text" => "Discusses the ending",
          "template" => "books",
          "title" => "Alien Federation",
          "visibility" => "public"
        })
        |> json_response(200)

      object = Pleroma.Object.get_by_ap_id(response["uri"])

      assert object.data["type"] == "Review"
      assert object.data["inReplyToBook"] == book
      assert object.data["rating"] == 4.5
      assert object.data["ratingBest"] == 5
      assert object.data["sensitive"] == true
      assert object.data["summary"] == "Discusses the ending"
      refute Map.has_key?(object.data, "readingStatus")
      refute Map.has_key?(object.data, "book")
    end

    test "publishes BookWyrm-compatible comments", %{conn: conn} do
      book = "https://books.example/book/alien-federation"
      clear_config([:native_discovery, :bookwyrm_indexes], ["https://books.example"])

      response =
        conn
        |> post("/api/v1/discovery/native-objects", %{
          "content" => "The middle chapter changes the argument.",
          "fields" => %{"book_action" => "comment", "page" => 142},
          "reference_url" => book,
          "template" => "books",
          "title" => "Alien Federation",
          "visibility" => "public"
        })
        |> json_response(200)

      object = Pleroma.Object.get_by_ap_id(response["uri"])

      assert object.data["type"] == "Comment"
      assert object.data["inReplyToBook"] == book
      assert object.data["page"] == 142
      refute Map.has_key?(object.data, "rating")
    end

    test "publishes BookWyrm-compatible quotations", %{conn: conn} do
      book = "https://books.example/book/alien-federation"
      clear_config([:native_discovery, :bookwyrm_indexes], ["https://books.example"])

      response =
        conn
        |> post("/api/v1/discovery/native-objects", %{
          "content" => "This captures the central problem.",
          "fields" => %{
            "book_action" => "quote",
            "page" => 73,
            "quote" => "Compatibility is a workflow, not a vocabulary."
          },
          "reference_url" => book,
          "template" => "books",
          "title" => "Alien Federation",
          "visibility" => "public"
        })
        |> json_response(200)

      object = Pleroma.Object.get_by_ap_id(response["uri"])

      assert object.data["type"] == "Quotation"
      assert object.data["inReplyToBook"] == book
      assert object.data["page"] == 73
      assert object.data["quote"] == "Compatibility is a workflow, not a vocabulary."
      refute Map.has_key?(object.data, "rating")
    end

    test "keeps shelf state out of Review objects", %{conn: conn} do
      response =
        conn
        |> post("/api/v1/discovery/native-objects", %{
          "content" => "Starting this today.",
          "fields" => %{"reading_status" => "reading"},
          "reference_url" => "https://books.example/book/alien-federation",
          "template" => "books",
          "title" => "Alien Federation",
          "visibility" => "public"
        })
        |> json_response(422)

      assert response["error"] =~ "Reading status is not supported"
    end

    test "publishes NeoDB-compatible cultural relationships", %{conn: conn} do
      item = "https://culture.example/movie/alien-federation"
      clear_config([:native_discovery, :neodb_indexes], ["https://culture.example"])

      response =
        conn
        |> post("/api/v1/discovery/native-objects", %{
          "content" => "A careful review of the adaptation.",
          "fields" => %{"category" => "film", "rating" => 8, "status" => "complete"},
          "reference_url" => item,
          "template" => "culture",
          "title" => "Alien Federation",
          "visibility" => "public"
        })
        |> json_response(200)

      object = Pleroma.Object.get_by_ap_id(response["uri"])
      relationships = object.data["relatedWith"]

      assert object.data["type"] == "Article"

      assert %{
               "type" => "Review",
               "name" => "Alien Federation",
               "withRegardTo" => ^item
             } = Enum.find(relationships, &(&1["type"] == "Review"))

      assert %{
               "type" => "Status",
               "status" => "complete",
               "withRegardTo" => ^item
             } = Enum.find(relationships, &(&1["type"] == "Status"))

      assert %{
               "type" => "Rating",
               "value" => 8,
               "best" => 10,
               "worst" => 1,
               "withRegardTo" => ^item
             } = Enum.find(relationships, &(&1["type"] == "Rating"))

      assert Enum.any?(
               object.data["tag"],
               &(&1["type"] == "Movie" and &1["href"] == item and
                   &1["name"] == "Alien Federation")
             )
    end

    test "publishes Wanderer-shaped trail notes", %{conn: conn} do
      gpx = "https://routes.example/alien-escarpment.gpx"

      response =
        conn
        |> post("/api/v1/discovery/native-objects", %{
          "content" => "A steep escarpment trail.",
          "fields" => %{
            "difficulty" => "hard",
            "distance" => "12.5",
            "distance_unit" => "km",
            "route_kind" => "hike"
          },
          "reference_url" => gpx,
          "template" => "routes",
          "title" => "Alien Escarpment",
          "visibility" => "public"
        })
        |> json_response(200)

      object = Pleroma.Object.get_by_ap_id(response["uri"])

      assert object.data["type"] == "Note"
      assert object.data["gpxUrl"] == gpx

      assert Enum.any?(
               object.data["tag"],
               &(&1["name"] == "distance" and &1["content"] == "12500.0m")
             )

      assert Enum.any?(
               object.data["tag"],
               &(&1["name"] == "category" and &1["content"] == "hike")
             )
    end

    test "publishes an honest Manyfold compatibility note", %{conn: conn} do
      model = "https://models.example/files/tablet-stand.stl"

      response =
        conn
        |> post("/api/v1/discovery/native-objects", %{
          "content" => "A printable tablet stand.",
          "fields" => %{"file_format" => "STL", "printable" => true},
          "reference_url" => model,
          "template" => "models",
          "title" => "Tablet stand",
          "visibility" => "public"
        })
        |> json_response(200)

      object = Pleroma.Object.get_by_ap_id(response["uri"])

      assert object.data["type"] == "Note"
      assert object.data["f3di:compatibilityNote"] == true
      assert object.data["resourceUrl"] == model
    end

    test "gives ForgeFed tickets repository context", %{conn: conn} do
      repository = "https://forge.example/projects/unfathomably"

      response =
        conn
        |> post("/api/v1/discovery/native-objects", %{
          "content" => "The ticket needs a repository context.",
          "fields" => %{"repository" => repository, "ticket_kind" => "bug"},
          "template" => "software",
          "title" => "Missing context",
          "visibility" => "public"
        })
        |> json_response(200)

      object = Pleroma.Object.get_by_ap_id(response["uri"])

      assert object.data["type"] == "Ticket"
      assert object.data["context"] == repository
      assert object.data["repository"] == repository
    end
  end

  describe "PATCH /api/v1/discovery/native-objects/:id/state" do
    setup do: oauth_access(["write:statuses"])

    test "publishes an author-owned ForgeFed lifecycle transition", %{
      conn: conn,
      token: token,
      user: user
    } do
      created =
        conn
        |> post("/api/v1/discovery/native-objects", %{
          "content" => "A ticket with a useful lifecycle.",
          "fields" => %{
            "repository" => "https://social.fbxl.net/projects/unfathomably",
            "ticket_kind" => "bug"
          },
          "template" => "software",
          "title" => "Lifecycle test",
          "visibility" => "public"
        })
        |> json_response(200)

      transitioned =
        conn
        |> recycle()
        |> assign(:user, user)
        |> assign(:token, token)
        |> patch("/api/v1/discovery/native-objects/#{created["id"]}/state", %{
          "state" => "resolved"
        })
        |> json_response(200)

      object = Pleroma.Object.get_by_ap_id(transitioned["uri"])
      assert object.data["state"] == "resolved"
      assert is_binary(object.data["updated"])
    end

    test "does not publish another Update when the lifecycle state is unchanged", %{
      conn: conn,
      token: token,
      user: user
    } do
      created =
        conn
        |> post("/api/v1/discovery/native-objects", %{
          "content" => "A ticket whose resolved state is idempotent.",
          "fields" => %{
            "repository" => "https://social.fbxl.net/projects/unfathomably",
            "ticket_kind" => "bug"
          },
          "template" => "software",
          "title" => "Repeated lifecycle test",
          "visibility" => "public"
        })
        |> json_response(200)

      first =
        conn
        |> recycle()
        |> assign(:user, user)
        |> assign(:token, token)
        |> patch("/api/v1/discovery/native-objects/#{created["id"]}/state", %{
          "state" => "resolved"
        })
        |> json_response(200)

      update_count = lifecycle_update_count(first["uri"])

      second =
        conn
        |> recycle()
        |> assign(:user, user)
        |> assign(:token, token)
        |> patch("/api/v1/discovery/native-objects/#{created["id"]}/state", %{
          "state" => "resolved"
        })
        |> json_response(200)

      assert second["uri"] == first["uri"]
      assert lifecycle_update_count(first["uri"]) == update_count
    end

    test "rejects states outside the native family's vocabulary", %{
      conn: conn,
      token: token,
      user: user
    } do
      created =
        conn
        |> post("/api/v1/discovery/native-objects", %{
          "content" => "A listing awaiting a response.",
          "fields" => %{
            "currency" => "CAD",
            "latitude" => "43.6532",
            "listing_type" => "offer",
            "longitude" => "-79.3832",
            "price" => "25.00"
          },
          "template" => "markets",
          "title" => "Marketplace offer",
          "visibility" => "public"
        })
        |> json_response(200)

      response =
        conn
        |> recycle()
        |> assign(:user, user)
        |> assign(:token, token)
        |> patch("/api/v1/discovery/native-objects/#{created["id"]}/state", %{
          "state" => "resolved"
        })
        |> json_response(422)

      assert response["error"] == "Invalid lifecycle state"
    end
  end

  defp lifecycle_update_count(object_id) do
    Pleroma.Activity
    |> where([activity], fragment("?->>'type' = 'Update'", activity.data))
    |> where(
      [activity],
      fragment("?->'object'->>'id' = ?", activity.data, ^object_id)
    )
    |> select([activity], count(activity.id))
    |> Pleroma.Repo.one()
  end
end

# end of test/pleroma/web/mastodon_api/controllers/native_object_controller_test.exs
