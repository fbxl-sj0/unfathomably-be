# Unfathomably BE
# ----------------
#
# File: native_object.ex
#
# Purpose:
#   Build locally authored ActivityPub objects for the bounded workflows
#   exposed by the Worlds frontend.
#
# Responsibilities:
#   - validate per-workflow fields and uploaded media identifiers
#   - map safe inputs to fixed ActivityPub vocabularies
#   - reuse normal post formatting, addressing, attachments, MRF, and delivery
#
# This file intentionally does not accept arbitrary JSON-LD, fetch reference
# URLs, store uploads, or implement object rendering.

defmodule Pleroma.Web.ActivityPub.NativeObject do
  @moduledoc """
  Creates safe, locally authored objects for the Worlds interface.

  The public API selects a workflow and supplies only fields defined for that
  workflow. Unknown fields are rejected instead of being copied to JSON-LD.
  Uploaded media IDs are resolved by `ActivityDraft`, which preserves the same
  ownership and attachment limits used for ordinary posts.
  """

  alias Pleroma.BookShelfEntry
  alias Pleroma.Formatter
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Builder
  alias Pleroma.Web.ActivityPub.Marketplace
  alias Pleroma.Web.ActivityPub.NeoDBActivityDiscovery
  alias Pleroma.Web.ActivityPub.Pipeline
  alias Pleroma.Web.ActivityPub.Utils
  alias Pleroma.Web.CommonAPI.ActivityDraft

  @namespace "https://unfathomably.social/ns#"
  @family_field @namespace <> "family"
  @kind_field @namespace <> "kind"
  @detail_field @namespace <> "detail"
  @secondary_field @namespace <> "secondary"
  @reference_field @namespace <> "reference"
  @software_project_type @namespace <> "SoftwareProject"

  @templates %{
    "audio" => %{type: "Audio", kind: "audio_release"},
    "video" => %{type: "Video", kind: "video"},
    "longform" => %{type: "Article", kind: "longform_article"},
    "photo" => %{type: "Image", kind: "photo_story"},
    "books" => %{type: "Review", kind: "book_review"},
    "bookmarks" => %{type: "Note", kind: "bookmark"},
    "software" => %{type: "Ticket", kind: "software_ticket"},
    "software_project" => %{
      type: @software_project_type,
      kind: "software_project",
      family: "software",
      defaults: %{"project_status" => "active"}
    },
    "models" => %{type: "Note", kind: "three_dimensional_model"},
    "markets" => %{type: "maid:Offer", kind: "market_listing"},
    "games" => %{type: "Game", kind: "game"},
    "routes" => %{type: "Note", kind: "route"},
    "culture" => %{type: "Article", kind: "culture_activity"},
    "coordination" => %{type: "ValueFlows:Proposal", kind: "coordination_proposal"},
    "publishing" => %{type: "Document", kind: "publication"}
  }

  @field_specs %{
    "audio" => %{
      "album" => {:text, 160},
      "artist" => {:text, 160},
      "genres" => {:text, 200},
      "license" => {:text, 120},
      "release_date" => :date,
      "track_number" => {:integer, 1, 9_999}
    },
    "video" => %{
      "category" => {:text, 80},
      "channel" => {:text, 160},
      "language" => {:text, 32},
      "license" => {:text, 120},
      "tags" => {:text, 200}
    },
    "longform" => %{
      "byline" => {:text, 160},
      "language" => {:text, 32},
      "license" => {:text, 120},
      "published_at" => :date,
      "subtitle" => {:text, 200},
      "tags" => {:text, 200}
    },
    "photo" => %{
      "album" => {:text, 160},
      "license" => {:text, 120},
      "location" => {:text, 160},
      "taken_at" => :datetime
    },
    "books" => %{
      "author" => {:text, 160},
      "book_action" => {:enum, ~w[review comment quote]},
      "edition" => {:text, 120},
      "isbn" => :isbn,
      "language" => {:text, 32},
      "page" => {:integer, 1, 1_000_000},
      "quote" => {:text, 5_000},
      "rating" => :book_rating,
      "series" => {:text, 160},
      "series_number" => {:text, 80}
    },
    "bookmarks" => %{
      "site_name" => {:text, 160},
      "tags" => {:text, 200},
      "url" => :url
    },
    "software" => %{
      "homepage" => :url,
      "labels" => {:text, 200},
      "license" => {:text, 120},
      "priority" => {:enum, ~w[low normal high urgent]},
      "project_status" => {:enum, ~w[active maintenance archived]},
      "repository" => :url,
      "state" => {:enum, ~w[open in_progress resolved closed]},
      "ticket_kind" => {:enum, ~w[bug feature task security documentation]},
      "topics" => {:text, 200},
      "version" => {:text, 80}
    },
    "models" => %{
      "category" => {:text, 80},
      "collection" => {:text, 160},
      "creator" => {:text, 160},
      "file_format" => {:text, 40},
      "license" => {:text, 120},
      "printable" => :boolean,
      "scale" => {:text, 60},
      "tags" => {:text, 200},
      "version" => {:text, 80}
    },
    "markets" => %{
      "condition" => {:enum, ~w[new like_new good fair parts]},
      "currency" => :currency,
      "delivery" => {:enum, ~w[pickup shipping either digital]},
      "expires" => :date,
      "latitude" => {:decimal_range, 3, 6, -90, 90},
      "listing_mode" => {:enum, ~w[sell giveaway wanted]},
      "listing_type" => {:enum, ~w[offer request]},
      "location" => {:text, 160},
      "longitude" => {:decimal_range, 3, 6, -180, 180},
      "price" => {:decimal, 9, 2},
      "quantity" => {:decimal, 7, 2},
      "share_with_marketplaces" => :boolean,
      "tags" => {:text, 200}
    },
    "games" => %{
      "fen" => {:text, 120},
      "game_kind" => {:enum, ~w[chess tabletop video puzzle match other]},
      "platform" => {:text, 80},
      "players" => {:text, 160},
      "start_time" => :datetime,
      "state" => {:enum, ~w[planned active complete abandoned]}
    },
    "routes" => %{
      "difficulty" => {:enum, ~w[easy moderate hard expert]},
      "distance" => {:decimal, 7, 2},
      "distance_unit" => {:enum, ~w[km mi m]},
      "duration" => {:text, 80},
      "elevation_gain" => {:decimal, 7, 2},
      "elevation_loss" => {:decimal, 7, 2},
      "location" => {:text, 160},
      "route_kind" => {:enum, ~w[trail hike run ride walk paddle other]},
      "start_time" => :datetime,
      "tags" => {:text, 200}
    },
    "culture" => %{
      "category" => {:enum, ~w[film series album podcast performance exhibition game other]},
      "rating" => {:integer, 1, 10},
      "status" => {:enum, ~w[wishlist progress complete dropped]}
    },
    "coordination" => %{
      "due" => :datetime,
      "flow_action" => {:enum, ~w[transfer work use produce deliver-service consume]},
      "location" => {:text, 160},
      "purpose" => {:enum, ~w[offer request]},
      "quantity" => {:decimal, 9, 2},
      "resource" => {:text, 200},
      "skills" => {:text, 200},
      "unit" => {:text, 40}
    },
    "publishing" => %{
      "author" => {:text, 160},
      "format" => {:text, 80},
      "language" => {:text, 32},
      "level" => {:text, 80},
      "license" => {:text, 120},
      "published_at" => :date,
      "subject" => {:text, 160}
    }
  }

  @default_fields %{
    "books" => %{"book_action" => "review"},
    "software" => %{"priority" => "normal", "state" => "open", "ticket_kind" => "bug"},
    "markets" => %{"listing_type" => "offer", "share_with_marketplaces" => false},
    "games" => %{"game_kind" => "other", "state" => "planned"},
    "routes" => %{"distance_unit" => "km", "route_kind" => "trail"},
    "culture" => %{"category" => "other"},
    "coordination" => %{"flow_action" => "transfer", "purpose" => "offer"}
  }

  @maximum_title_length 200
  @maximum_spoiler_text_length 500
  @maximum_reference_length 2_048
  @maximum_media_count 4
  @maximum_field_count 16
  @visibility_values ~w[public unlisted private]

  @spec create(User.t(), map()) :: {:ok, Pleroma.Activity.t()} | {:error, term()}
  def create(%User{} = user, params) when is_map(params) do
    with {:ok, family, template} <- validate_template(param(params, :template)),
         {:ok, title} <-
           validate_required_text(param(params, :title), "Title", @maximum_title_length),
         {:ok, content} <- validate_required_text(param(params, :content), "Description", nil),
         {:ok, spoiler_text} <-
           validate_optional_text(
             param(params, :spoiler_text) || "",
             "Content warning",
             @maximum_spoiler_text_length
           ),
         {:ok, reference} <- validate_reference(param(params, :reference_url)),
         {:ok, media_ids} <- validate_media_ids(param(params, :media_ids)),
         {:ok, fields} <- prepare_fields(family, param(params, :fields), params, template),
         :ok <- validate_workflow(family, fields, reference, media_ids),
         {:ok, visibility} <- validate_visibility(param(params, :visibility)),
         {:ok, draft} <-
           ActivityDraft.create(user, %{
             content_type: "text/plain",
             media_ids: media_ids,
             sensitive: is_binary(spoiler_text),
             spoiler_text: spoiler_text || "",
             status: content,
             visibility: visibility
           }),
         object <-
           build_object(
             draft.object,
             user,
             family,
             template,
             title,
             reference,
             fields,
             visibility
           ),
         recipients <- Enum.uniq(draft.to ++ draft.cc),
         {:ok, create_data, _meta} <- Builder.create(user, object, recipients),
         {:ok, create_data} <- Marketplace.add_peer_recipients(create_data, object),
         {:ok, activity, _meta} <- Pipeline.common_pipeline(create_data, local: true) do
      {:ok, activity}
    end
  end

  def create(_user, _params), do: {:error, "Invalid native object request"}

  defp build_object(object, user, family, template, title, reference, fields, visibility) do
    object
    |> Map.put("id", Utils.generate_object_id())
    |> Map.put("published", Utils.make_date())
    |> Map.put("type", object_type(template, family, fields))
    |> Map.put("actor", user.ap_id)
    |> Map.put("attributedTo", user.ap_id)
    |> Map.put("name", Formatter.html_escape(title, "text/plain"))
    |> Map.put(@family_field, family)
    |> Map.put(@kind_field, object_kind(template, family, fields))
    |> maybe_put(@detail_field, primary_detail(family, fields))
    |> maybe_put(@secondary_field, secondary_detail(family, fields))
    |> maybe_put(@reference_field, reference)
    |> put_namespaced_fields(fields)
    |> put_template_fields(family, title, reference, fields)
    |> put_discovery_hints(family, visibility)
  end

  # Manyfold uses Mastodon's object-level indexable and discoverable terms to
  # decide whether a federated model belongs in its public catalogue. Keep the
  # hint tied to the author's explicit post visibility rather than inferring it
  # later from recipients, where public and unlisted both include as:Public.
  defp put_discovery_hints(object, "models", "public") do
    object
    |> Map.put("indexable", true)
    |> Map.put("discoverable", true)
  end

  defp put_discovery_hints(object, "models", _visibility) do
    object
    |> Map.put("indexable", false)
    |> Map.put("discoverable", false)
  end

  defp put_discovery_hints(object, _family, _visibility), do: object

  defp object_type(_template, "books", %{"book_action" => "comment"}), do: "Comment"
  defp object_type(_template, "books", %{"book_action" => "quote"}), do: "Quotation"
  defp object_type(_template, "markets", %{"listing_type" => "request"}), do: "maid:Request"
  defp object_type(template, _family, _fields), do: template.type

  defp object_kind(_template, "books", %{"book_action" => "comment"}), do: "book_comment"
  defp object_kind(_template, "books", %{"book_action" => "quote"}), do: "book_quote"
  defp object_kind(template, _family, _fields), do: template.kind

  defp put_template_fields(object, "audio", _title, reference, fields) do
    object
    |> maybe_put("url", first_attachment_url(object) || reference)
    |> maybe_put("artist", fields["artist"])
    |> maybe_put("album", fields["album"])
    |> maybe_put("trackNumber", fields["track_number"])
    |> maybe_put("releaseDate", fields["release_date"])
    |> maybe_put("genres", fields["genres"])
    |> maybe_put("license", fields["license"])
  end

  defp put_template_fields(object, "video", _title, reference, fields) do
    object
    |> maybe_put("url", first_attachment_url(object) || reference)
    |> maybe_put("channel", fields["channel"])
    |> maybe_put("category", fields["category"])
    |> maybe_put("language", fields["language"])
    |> maybe_put("tags", fields["tags"])
    |> maybe_put("license", fields["license"])
  end

  defp put_template_fields(object, "longform", _title, reference, fields) do
    object
    |> maybe_put("url", reference)
    |> maybe_put("subtitle", fields["subtitle"])
    |> maybe_put("author", fields["byline"] || object["actor"])
    |> maybe_put("language", fields["language"])
    |> maybe_put("tags", fields["tags"])
    |> maybe_put("license", fields["license"])
    |> maybe_put("publishedAt", fields["published_at"])
  end

  defp put_template_fields(object, "photo", _title, reference, fields) do
    object
    |> maybe_put("url", first_attachment_url(object) || reference)
    |> maybe_put("album", fields["album"])
    |> maybe_put("takenAt", fields["taken_at"])
    |> maybe_put("license", fields["license"])
    |> maybe_put_location(fields["location"])
  end

  defp put_template_fields(object, "bookmarks", _title, _reference, fields) do
    object
    |> maybe_put("url", fields["url"])
    |> maybe_put("target", fields["url"])
    |> maybe_put("siteName", fields["site_name"])
    |> maybe_put("tags", fields["tags"])
  end

  defp put_template_fields(object, "books", _title, reference, fields) do
    object
    |> maybe_put("inReplyToBook", reference)
    |> maybe_put("inReplyTo", if(fields["book_action"] == "comment", do: reference))
    |> maybe_put("context", if(fields["book_action"] == "comment", do: reference))
    |> maybe_put("author", fields["author"])
    |> maybe_put("edition", fields["edition"])
    |> maybe_put("isbn", fields["isbn"])
    |> maybe_put("language", fields["language"])
    |> maybe_put("page", fields["page"])
    |> maybe_put("quote", fields["quote"])
    |> maybe_put("rating", fields["rating"])
    |> maybe_put("ratingBest", if(fields["rating"], do: 5))
    |> maybe_put("series", fields["series"])
    |> maybe_put("seriesNumber", fields["series_number"])
  end

  defp put_template_fields(
         %{"type" => @software_project_type} = object,
         "software",
         _title,
         reference,
         fields
       ) do
    project_url = fields["homepage"] || reference || fields["repository"]

    object
    |> maybe_put("url", project_url)
    |> maybe_put("repository", fields["repository"])
    |> maybe_put("homepage", fields["homepage"])
    |> maybe_put("license", fields["license"])
    |> maybe_put("projectStatus", fields["project_status"])
    |> maybe_put("tag", topic_tags(fields["topics"]))
  end

  defp put_template_fields(object, "software", _title, reference, fields) do
    repository = fields["repository"] || reference

    object
    |> maybe_put("context", repository)
    |> maybe_put("target", repository)
    |> maybe_put("repository", repository)
    |> maybe_put("state", fields["state"])
    |> maybe_put("ticketKind", fields["ticket_kind"])
    |> maybe_put("priority", fields["priority"])
    |> maybe_put("version", fields["version"])
    |> maybe_put("labels", fields["labels"])
  end

  defp put_template_fields(object, "models", _title, reference, fields) do
    resource_url = first_attachment_url(object) || reference
    file_format = fields["file_format"] || model_file_format(resource_url)

    object
    |> Map.put("f3di:compatibilityNote", true)
    |> Map.put("f3di:concreteType", "3DModel")
    |> maybe_put("latestVersion", reference)
    |> maybe_put("resourceUrl", resource_url)
    |> maybe_put("version", fields["version"])
    |> maybe_put("license", fields["license"])
    |> maybe_put("spdx:license", spdx_license(fields["license"]))
    |> maybe_put("fileFormat", file_format)
    |> maybe_put("scale", fields["scale"])
    |> maybe_put("category", fields["category"])
    |> maybe_put("printable", fields["printable"])
    |> maybe_put("creator", fields["creator"])
    |> maybe_put("collection", fields["collection"])
    |> maybe_put("tag", topic_tags(fields["tags"]))
  end

  defp put_template_fields(object, "markets", title, reference, fields) do
    object
    |> Map.put("pair:label", title)
    |> Map.put("listingName", title)
    |> maybe_put("maid:offerOfResourceType", reference)
    |> maybe_put("price", fields["price"])
    |> maybe_put("priceCurrency", fields["currency"])
    |> maybe_put("condition", fields["condition"])
    |> maybe_put("listingMode", fields["listing_mode"])
    |> maybe_put("listingType", fields["listing_type"])
    |> maybe_put_location(fields["location"])
    |> maybe_put("latitude", fields["latitude"])
    |> maybe_put("longitude", fields["longitude"])
    |> maybe_put("delivery", fields["delivery"])
    |> maybe_put("quantity", fields["quantity"])
    |> maybe_put("expires", fields["expires"])
    |> maybe_put("marketplaceDelivery", fields["share_with_marketplaces"])
    |> maybe_put("tag", topic_tags(fields["tags"]))
  end

  defp put_template_fields(object, "games", _title, reference, fields) do
    object
    |> maybe_put("target", reference)
    |> maybe_put("resourceUrl", first_attachment_url(object) || reference)
    |> maybe_put("state", fields["state"])
    |> maybe_put("gameKind", fields["game_kind"])
    |> maybe_put("players", fields["players"])
    |> maybe_put("startTime", fields["start_time"])
    |> maybe_put("fen", fields["fen"])
    |> maybe_put("platform", fields["platform"])
  end

  defp put_template_fields(object, "routes", _title, reference, fields) do
    distance = join_measure(fields["distance"], fields["distance_unit"])
    resource_url = route_attachment_url(object) || reference

    object
    |> maybe_put("target", reference)
    |> maybe_put("url", reference || resource_url)
    |> maybe_put("gpxUrl", resource_url)
    |> maybe_put("distance", distance)
    |> maybe_put("difficulty", fields["difficulty"])
    |> maybe_put("duration", fields["duration"])
    |> maybe_put("elevationGain", fields["elevation_gain"])
    |> maybe_put("elevationLoss", fields["elevation_loss"])
    |> maybe_put("routeKind", fields["route_kind"])
    |> maybe_put("startTime", fields["start_time"])
    |> maybe_put_location(fields["location"])
    |> maybe_put("tag", topic_tags(fields["tags"]))
    |> put_wanderer_tags(fields)
  end

  defp put_template_fields(object, "culture", title, reference, fields) do
    catalog = %{
      "href" => reference,
      "name" => title,
      "type" => neodb_catalog_type(fields["category"])
    }

    object
    |> maybe_put("target", reference)
    |> Map.put("relatedWith", neodb_relationships(object, title, reference, fields))
    |> Map.update("tag", [catalog], &(List.wrap(&1) ++ [catalog]))
  end

  defp put_template_fields(object, "coordination", title, reference, fields) do
    purpose = fields["purpose"] || "offer"
    local_actor = object["actor"] || object["attributedTo"]

    intent =
      %{
        "action" => fields["flow_action"] || "transfer",
        "name" => title,
        "type" => "ValueFlows:Intent"
      }
      |> maybe_put("resource", fields["resource"])
      |> maybe_put("hasEnd", fields["due"])
      |> maybe_put("skills", fields["skills"])
      |> maybe_put_location(fields["location"])
      |> maybe_put_resource_quantity(fields["quantity"], fields["unit"])
      |> maybe_put_intent_participant(purpose, local_actor)

    object
    |> maybe_put("target", reference)
    |> Map.put("purpose", purpose)
    |> Map.put("publishes", [intent])
  end

  defp put_template_fields(object, "publishing", title, reference, fields) do
    object
    |> Map.put("author", fields["author"] || object["actor"])
    |> Map.put("subject", fields["subject"] || title)
    |> maybe_put("relatedLink", reference)
    |> maybe_put("resourceUrl", first_attachment_url(object) || reference)
    |> maybe_put("license", fields["license"])
    |> maybe_put("language", fields["language"])
    |> maybe_put("level", fields["level"])
    |> maybe_put("mediaType", fields["format"])
    |> maybe_put("publishedAt", fields["published_at"])
  end

  # NeoDB keeps the human-readable post compatible with general ActivityPub
  # clients while attaching machine-readable Status, Rating, and Review records
  # for catalog-aware peers. Relationship identifiers are stable fragments of
  # the immutable local object URI and therefore require no parallel database.
  defp neodb_relationships(object, title, reference, fields) do
    actor = object["attributedTo"] || object["actor"]
    published = object["published"]
    object_id = object["id"]
    source_content = get_in(object, ["source", "content"]) || object["content"]

    [
      %{
        "attributedTo" => actor,
        "content" => source_content,
        "href" => object_id <> "#review",
        "id" => object_id <> "#review",
        "mediaType" => "text/markdown",
        "name" => title,
        "published" => published,
        "type" => "Review",
        "withRegardTo" => reference
      },
      neodb_status_relationship(object_id, actor, published, reference, fields["status"]),
      neodb_rating_relationship(object_id, actor, published, reference, fields["rating"])
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp neodb_status_relationship(_object_id, _actor, _published, _reference, nil), do: nil

  defp neodb_status_relationship(object_id, actor, published, reference, status) do
    %{
      "attributedTo" => actor,
      "href" => object_id <> "#status",
      "id" => object_id <> "#status",
      "published" => published,
      "status" => status,
      "type" => "Status",
      "withRegardTo" => reference
    }
  end

  defp neodb_rating_relationship(_object_id, _actor, _published, _reference, nil), do: nil

  defp neodb_rating_relationship(object_id, actor, published, reference, rating) do
    %{
      "attributedTo" => actor,
      "best" => 10,
      "href" => object_id <> "#rating",
      "id" => object_id <> "#rating",
      "published" => published,
      "type" => "Rating",
      "value" => rating,
      "withRegardTo" => reference,
      "worst" => 1
    }
  end

  defp neodb_catalog_type("film"), do: "Movie"
  defp neodb_catalog_type("series"), do: "TVShow"
  defp neodb_catalog_type("album"), do: "Album"
  defp neodb_catalog_type("podcast"), do: "Podcast"
  defp neodb_catalog_type("performance"), do: "Performance"
  defp neodb_catalog_type("exhibition"), do: "Performance"
  defp neodb_catalog_type("game"), do: "Game"
  defp neodb_catalog_type(_category), do: "Work"

  defp maybe_put_intent_participant(intent, "request", actor),
    do: maybe_put(intent, "receiver", actor)

  defp maybe_put_intent_participant(intent, _purpose, actor),
    do: maybe_put(intent, "provider", actor)

  defp put_wanderer_tags(object, fields) do
    metric_tags =
      [
        {"category", fields["route_kind"]},
        {"difficulty", fields["difficulty"]},
        {"distance", wanderer_distance(fields["distance"], fields["distance_unit"])},
        {"duration", fields["duration"]},
        {"elevation_gain", suffix_measure(fields["elevation_gain"], "m")},
        {"elevation_loss", suffix_measure(fields["elevation_loss"], "m")}
      ]
      |> Enum.flat_map(fn
        {_name, nil} -> []
        {name, value} -> [%{"content" => value, "name" => name, "type" => "Note"}]
      end)

    Map.update(object, "tag", metric_tags, &(List.wrap(&1) ++ metric_tags))
  end

  defp topic_tags(nil), do: nil

  defp topic_tags(topics) when is_binary(topics) do
    topics
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.trim_leading(&1, "#"))
    |> Enum.map(&String.replace(&1, ~r/\s+/, "_"))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(12)
    |> Enum.map(&%{"type" => "Hashtag", "name" => "##{String.slice(&1, 0, 64)}"})
    |> case do
      [] -> nil
      tags -> tags
    end
  end

  defp spdx_license(nil), do: nil
  defp spdx_license(identifier), do: %{"spdx:licenseId" => identifier}

  defp model_file_format(nil), do: nil

  defp model_file_format(url) when is_binary(url) do
    extension =
      url
      |> URI.parse()
      |> Map.get(:path, "")
      |> Path.extname()
      |> String.trim_leading(".")
      |> String.upcase()

    if Regex.match?(~r/^[A-Z0-9]{1,10}$/, extension), do: extension
  rescue
    _ -> nil
  end

  defp wanderer_distance(nil, _unit), do: nil

  defp wanderer_distance(value, unit) do
    multiplier =
      case unit do
        "km" -> "1000"
        "mi" -> "1609.344"
        _unit -> "1"
      end

    value
    |> Decimal.new()
    |> Decimal.mult(multiplier)
    |> Decimal.to_string(:normal)
    |> suffix_measure("m")
  end

  defp suffix_measure(nil, _unit), do: nil
  defp suffix_measure(value, unit), do: "#{value}#{unit}"

  defp put_namespaced_fields(object, fields) do
    Enum.reduce(fields, object, fn {key, value}, result ->
      maybe_put(result, @namespace <> key, value)
    end)
  end

  defp maybe_put_location(object, nil), do: object

  defp maybe_put_location(object, location) do
    Map.put(object, "location", %{"type" => "Place", "name" => location})
  end

  defp maybe_put_resource_quantity(object, nil, _unit), do: object

  defp maybe_put_resource_quantity(object, quantity, unit) do
    Map.put(object, "resourceQuantity", %{
      "hasNumericalValue" => quantity,
      "hasUnit" => unit
    })
  end

  defp prepare_fields(family, raw_fields, params, template) when is_map(raw_fields) do
    if map_size(raw_fields) <= @maximum_field_count do
      defaults = Map.get(template, :defaults, Map.get(@default_fields, family, %{}))

      fields =
        defaults
        |> Map.merge(legacy_fields(family, params))
        |> Map.merge(string_key_map(raw_fields))

      with {:ok, fields} <- validate_fields(family, fields) do
        {:ok, normalize_workflow_fields(family, fields)}
      end
    else
      {:error, "Too many workflow fields were supplied"}
    end
  end

  defp prepare_fields(family, nil, params, template),
    do: prepare_fields(family, %{}, params, template)

  defp prepare_fields(_family, _fields, _params, _template),
    do: {:error, "Workflow fields must be an object"}

  defp validate_fields(family, fields) do
    specs = Map.fetch!(@field_specs, family)

    Enum.reduce_while(fields, {:ok, %{}}, fn {key, value}, {:ok, validated} ->
      case Map.fetch(specs, key) do
        {:ok, spec} ->
          case validate_field_value(key, value, spec) do
            {:ok, nil} -> {:cont, {:ok, validated}}
            {:ok, normalized} -> {:cont, {:ok, Map.put(validated, key, normalized)}}
            {:error, _reason} = error -> {:halt, error}
          end

        :error ->
          {:halt, {:error, "#{humanize_field(key)} is not supported for this workflow"}}
      end
    end)
  end

  # Flohmarkt presents selling, giving away, and wanted ads as user choices.
  # The wire protocol still represents the first two as offers and the last as
  # a request. A zero price is added only for an explicitly shared giveaway,
  # because stock Flohmarkt requires a price and currency for imported items.
  defp normalize_workflow_fields("markets", %{"listing_mode" => "giveaway"} = fields) do
    fields = Map.put(fields, "listing_type", "offer")

    if fields["share_with_marketplaces"] == true do
      Map.put(fields, "price", "0.00")
    else
      fields
      |> Map.delete("price")
      |> Map.delete("currency")
    end
  end

  defp normalize_workflow_fields("markets", %{"listing_mode" => "wanted"} = fields) do
    fields
    |> Map.put("listing_type", "request")
    |> Map.put("share_with_marketplaces", false)
  end

  defp normalize_workflow_fields("markets", %{"listing_mode" => "sell"} = fields),
    do: Map.put(fields, "listing_type", "offer")

  defp normalize_workflow_fields(_family, fields), do: fields

  defp validate_field_value(_key, nil, _spec), do: {:ok, nil}
  defp validate_field_value(_key, "", _spec), do: {:ok, nil}

  defp validate_field_value(key, value, {:text, maximum}) when is_binary(value) do
    validate_optional_text(value, humanize_field(key), maximum)
  end

  defp validate_field_value(key, value, {:enum, allowed}) do
    normalized = value |> to_string() |> String.trim() |> String.downcase()

    if normalized in allowed,
      do: {:ok, normalized},
      else: {:error, "#{humanize_field(key)} is not supported"}
  end

  defp validate_field_value(key, value, {:integer, minimum, maximum}) do
    case Integer.parse(to_string(value)) do
      {integer, ""} when integer >= minimum and integer <= maximum -> {:ok, integer}
      _result -> {:error, "#{humanize_field(key)} must be between #{minimum} and #{maximum}"}
    end
  end

  defp validate_field_value(key, value, {:decimal, digits, decimals}) do
    value = value |> to_string() |> String.trim()
    pattern = Regex.compile!("^\\d{1,#{digits}}(?:\\.\\d{1,#{decimals}})?$")

    if Regex.match?(pattern, value),
      do: {:ok, value},
      else: {:error, "#{humanize_field(key)} must be a positive number"}
  end

  defp validate_field_value(_key, value, :book_rating) do
    case Float.parse(to_string(value)) do
      {rating, ""}
      when rating >= 1.0 and rating <= 5.0 and trunc(rating * 2) == rating * 2 ->
        {:ok, rating}

      _ ->
        {:error, "Rating must be between 1 and 5 in half-star steps"}
    end
  end

  defp validate_field_value(
         key,
         value,
         {:decimal_range, integer_digits, decimals, minimum, maximum}
       ) do
    value = value |> to_string() |> String.trim()
    pattern = Regex.compile!("^-?\\d{1,#{integer_digits}}(?:\\.\\d{1,#{decimals}})?$")

    with true <- Regex.match?(pattern, value),
         {decimal, ""} <- Decimal.parse(value),
         true <- Decimal.compare(decimal, Decimal.new(minimum)) in [:gt, :eq],
         true <- Decimal.compare(decimal, Decimal.new(maximum)) in [:lt, :eq] do
      {:ok, value}
    else
      _result -> {:error, "#{humanize_field(key)} must be between #{minimum} and #{maximum}"}
    end
  end

  defp validate_field_value(_key, value, :url), do: validate_reference(value)

  defp validate_field_value(key, value, :date) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> {:ok, Date.to_iso8601(date)}
      _error -> {:error, "#{humanize_field(key)} must be a valid date"}
    end
  end

  defp validate_field_value(key, value, :datetime) when is_binary(value) do
    value = String.trim(value)

    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.to_iso8601(datetime)}
      _error -> validate_naive_datetime(key, value)
    end
  end

  defp validate_field_value(_key, value, :boolean) when is_boolean(value), do: {:ok, value}

  defp validate_field_value(key, value, :currency) when is_binary(value) do
    currency = value |> String.trim() |> String.upcase()

    if Regex.match?(~r/^[A-Z]{3}$/, currency),
      do: {:ok, currency},
      else: {:error, "#{humanize_field(key)} must be a three-letter code"}
  end

  defp validate_field_value(key, value, :isbn) when is_binary(value) do
    isbn = String.trim(value)

    if Regex.match?(~r/^[0-9Xx -]{10,24}$/, isbn),
      do: {:ok, isbn},
      else: {:error, "#{humanize_field(key)} must be an ISBN-10 or ISBN-13"}
  end

  defp validate_field_value(key, _value, _spec), do: {:error, "#{humanize_field(key)} is invalid"}

  defp validate_naive_datetime(key, value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, datetime} -> {:ok, NaiveDateTime.to_iso8601(datetime)}
      _error -> {:error, "#{humanize_field(key)} must be a valid date and time"}
    end
  end

  defp validate_workflow("markets", fields, _reference, _media_ids) do
    cond do
      fields["share_with_marketplaces"] == true and fields["listing_type"] != "offer" ->
        {:error, "Only public offers can be shared with connected marketplaces"}

      fields["share_with_marketplaces"] == true and
          (is_nil(fields["price"]) or is_nil(fields["currency"])) ->
        {:error, "Price and currency are required for connected marketplaces"}

      fields["share_with_marketplaces"] == true and
          (is_nil(fields["latitude"]) or is_nil(fields["longitude"])) ->
        {:error, "An approximate location is required for connected marketplaces"}

      fields["price"] && is_nil(fields["currency"]) ->
        {:error, "Currency is required when a price is supplied"}

      fields["currency"] && is_nil(fields["price"]) ->
        {:error, "Price is required when a currency is supplied"}

      true ->
        :ok
    end
  end

  defp validate_workflow("models", _fields, nil, []),
    do: {:error, "Upload a model file or provide its canonical download page"}

  defp validate_workflow("routes", _fields, nil, []),
    do: {:error, "Upload a GPX track or provide the canonical route page"}

  defp validate_workflow("publishing", _fields, nil, []),
    do: {:error, "Upload the publication or provide its canonical document page"}

  defp validate_workflow("coordination", %{"resource" => resource}, _reference, _media_ids)
       when is_binary(resource),
       do: :ok

  defp validate_workflow("coordination", _fields, _reference, _media_ids),
    do: {:error, "Resource or help being offered or requested is required"}

  defp validate_workflow(
         "software",
         %{"state" => _state, "repository" => repository},
         nil,
         _media_ids
       )
       when is_binary(repository),
       do: :ok

  defp validate_workflow("software", %{"state" => _state}, nil, _media_ids),
    do: {:error, "Choose the project repository or provide the project object URL"}

  defp validate_workflow(family, _fields, _reference, []) when family in ~w[audio video photo],
    do: {:error, "Upload the media file before publishing"}

  defp validate_workflow("bookmarks", %{"url" => url}, _reference, _media_ids)
       when is_binary(url),
       do: :ok

  defp validate_workflow("bookmarks", _fields, _reference, _media_ids),
    do: {:error, "Web address is required"}

  defp validate_workflow("books", fields, reference, _media_ids) when is_binary(reference) do
    if BookShelfEntry.federatable_book_uri?(reference) do
      validate_book_action(fields)
    else
      {:error, "Choose a federated BookWyrm book or edition before sharing reading activity"}
    end
  end

  defp validate_workflow("books", _fields, _reference, _media_ids),
    do: {:error, "Choose a federated BookWyrm book or edition before sharing reading activity"}

  defp validate_workflow("culture", _fields, reference, _media_ids)
       when is_binary(reference) do
    if NeoDBActivityDiscovery.federatable_catalog_uri?(reference) do
      :ok
    else
      {:error, "Choose a federated NeoDB catalog item before tracking or reviewing it"}
    end
  end

  defp validate_workflow("culture", _fields, _reference, _media_ids),
    do: {:error, "Choose a federated NeoDB catalog item before tracking or reviewing it"}

  defp validate_workflow(_family, _fields, _reference, _media_ids), do: :ok

  defp validate_book_action(%{"book_action" => "quote", "quote" => quote})
       when is_binary(quote) and byte_size(quote) > 0,
       do: :ok

  defp validate_book_action(%{"book_action" => "quote"}),
    do: {:error, "A quoted passage is required"}

  defp validate_book_action(%{"book_action" => action}) when action in ~w[review comment], do: :ok

  defp validate_book_action(_fields), do: {:error, "Book activity is not supported"}

  defp validate_media_ids(nil), do: {:ok, []}
  defp validate_media_ids([]), do: {:ok, []}

  defp validate_media_ids(ids) when is_list(ids) and length(ids) <= @maximum_media_count do
    if Enum.all?(ids, &(is_binary(&1) and byte_size(&1) in 1..255)) do
      {:ok, Enum.uniq(ids)}
    else
      {:error, "Media identifiers are invalid"}
    end
  end

  defp validate_media_ids(_ids), do: {:error, "At most four uploaded files may be attached"}

  defp validate_template(value) when is_binary(value) do
    template_key = String.trim(value)

    case Map.fetch(@templates, template_key) do
      {:ok, template} -> {:ok, Map.get(template, :family, template_key), template}
      :error -> {:error, "Unsupported native object template"}
    end
  end

  defp validate_template(_value), do: {:error, "A native object template is required"}

  defp validate_required_text(value, label, maximum) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> {:error, "#{label} is required"}
      is_integer(maximum) and String.length(value) > maximum -> {:error, "#{label} is too long"}
      true -> {:ok, value}
    end
  end

  defp validate_required_text(_value, label, _maximum), do: {:error, "#{label} is required"}

  defp validate_reference(nil), do: {:ok, nil}
  defp validate_reference(""), do: {:ok, nil}

  defp validate_reference(value) when is_binary(value) do
    value = String.trim(value)
    uri = URI.parse(value)

    if byte_size(value) <= @maximum_reference_length and uri.scheme in ["http", "https"] and
         is_binary(uri.host) and uri.host != "" and is_nil(uri.userinfo) do
      {:ok, value}
    else
      {:error, "Reference URL must be an absolute HTTP or HTTPS URL"}
    end
  rescue
    URI.Error -> {:error, "Reference URL must be an absolute HTTP or HTTPS URL"}
  end

  defp validate_reference(_value),
    do: {:error, "Reference URL must be an absolute HTTP or HTTPS URL"}

  defp validate_optional_text(value, label, maximum) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> {:ok, nil}
      String.length(value) > maximum -> {:error, "#{label} is too long"}
      true -> {:ok, value}
    end
  end

  defp validate_visibility(nil), do: {:ok, "public"}
  defp validate_visibility(""), do: {:ok, "public"}

  defp validate_visibility(value) when is_binary(value) do
    value = String.trim(value)

    if value in @visibility_values,
      do: {:ok, value},
      else: {:error, "Visibility is not supported"}
  end

  defp validate_visibility(_value), do: {:error, "Visibility is not supported"}

  defp legacy_fields(family, params) do
    detail = param(params, :detail)
    secondary = param(params, :secondary)

    case family do
      "audio" -> compact_map(%{"artist" => detail, "album" => secondary})
      "video" -> compact_map(%{"category" => detail, "channel" => secondary})
      "longform" -> compact_map(%{"byline" => detail})
      "photo" -> compact_map(%{"album" => detail, "location" => secondary})
      "books" -> compact_map(%{"rating" => detail})
      "bookmarks" -> compact_map(%{"url" => detail})
      "software" -> compact_map(%{"state" => detail})
      "models" -> compact_map(%{"version" => detail})
      "markets" -> compact_map(%{"price" => detail, "currency" => secondary})
      "games" -> compact_map(%{"state" => detail})
      "routes" -> compact_map(%{"distance" => detail, "difficulty" => secondary})
      "culture" -> compact_map(%{"category" => detail})
      "coordination" -> compact_map(%{"purpose" => detail})
      "publishing" -> compact_map(%{"license" => detail})
    end
  end

  defp primary_detail("audio", fields), do: fields["artist"]
  defp primary_detail("video", fields), do: fields["category"]
  defp primary_detail("longform", fields), do: fields["byline"]
  defp primary_detail("photo", fields), do: fields["album"]
  defp primary_detail("books", fields), do: fields["rating"] || fields["book_action"]
  defp primary_detail("bookmarks", fields), do: fields["url"]
  defp primary_detail("software", fields), do: fields["project_status"] || fields["state"]
  defp primary_detail("models", fields), do: fields["version"]
  defp primary_detail("markets", fields), do: fields["price"]
  defp primary_detail("games", fields), do: fields["state"]
  defp primary_detail("routes", fields), do: fields["distance"]
  defp primary_detail("culture", fields), do: fields["status"] || fields["category"]
  defp primary_detail("coordination", fields), do: fields["purpose"]
  defp primary_detail("publishing", fields), do: fields["license"]

  defp secondary_detail("markets", fields), do: fields["currency"]
  defp secondary_detail("routes", fields), do: fields["difficulty"]
  defp secondary_detail("audio", fields), do: fields["album"]
  defp secondary_detail("video", fields), do: fields["channel"]
  defp secondary_detail("photo", fields), do: fields["location"]
  defp secondary_detail(_family, _fields), do: nil

  defp first_attachment_url(%{"attachment" => attachments}), do: attachment_url(attachments)
  defp first_attachment_url(_object), do: nil

  defp route_attachment_url(%{"attachment" => attachments}) do
    Enum.find_value(List.wrap(attachments), fn attachment ->
      url = attachment_url(attachment)
      if route_file_url?(url), do: url
    end)
  end

  defp route_attachment_url(_object), do: nil

  defp route_file_url?(url) when is_binary(url) do
    extension = url |> URI.parse() |> Map.get(:path, "") |> Path.extname() |> String.downcase()
    extension in ~w[.fit .gpx .kml .tcx]
  rescue
    _ -> false
  end

  defp route_file_url?(_url), do: false

  defp attachment_url(values) when is_list(values), do: Enum.find_value(values, &attachment_url/1)
  defp attachment_url(%{"href" => href}) when is_binary(href), do: href
  defp attachment_url(%{"url" => url}), do: attachment_url(url)
  defp attachment_url(%{"id" => id}) when is_binary(id), do: id
  defp attachment_url(value) when is_binary(value), do: value
  defp attachment_url(_value), do: nil

  defp join_measure(nil, _unit), do: nil
  defp join_measure(value, nil), do: value
  defp join_measure(value, unit), do: "#{value} #{unit}"

  defp compact_map(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) or value == "" end)
  end

  defp string_key_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp humanize_field(key) do
    key
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp param(params, key), do: Map.get(params, key, Map.get(params, Atom.to_string(key)))

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

# end of lib/pleroma/web/activity_pub/native_object.ex
