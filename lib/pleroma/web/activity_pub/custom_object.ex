# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.CustomObject do
  @moduledoc """
  Classifies ActivityPub objects whose vocabulary is not built into Pleroma.

  Alien ActivityPub applications commonly use ordinary ActivityStreams
  delivery with domain-specific object types. BookWyrm Reviews, ForgeFed
  Tickets, and ValueFlows processes are examples. The raw JSON-LD must remain
  intact, while internal code still needs a small amount of trusted metadata
  for authority, lifecycle, and presentation decisions. Standard objects may
  carry native vocabulary too, such as Flohmarkt's structured listing data.

  This module intentionally does not fetch linked resources, apply side
  effects, or decide whether an inbox request is authenticated. It only
  classifies an already decoded object and derives facts present in that
  object.
  """

  require Pleroma.Constants

  alias Pleroma.Web.ActivityPub.CustomActivity

  @known_object_types ~w[
    Answer Article Audio ChatMessage Document Emoji Event Hashtag Image Link
    Mention Note Page Place Profile PropertyValue Question Relationship
    Tombstone Track Video
  ]

  @collection_types ~w[
    Collection CollectionPage OrderedCollection OrderedCollectionPage
  ]

  @status_types ~w[
    Comment Quotation Rating Review
  ]

  @collection_object_types ~w[
    BookList Shelf ListItem ShelfItem Series SeriesBook Playlist PlaylistTrack
  ]

  @process_types ~w[
    Branch Commit Issue MergeRequest Offer Patch Proposal PullRequest Push
    Ticket TicketDependency
  ]

  @resource_types ~w[
    Author Book Edition Work Model Print Repository Route
  ]

  @valueflows_status_types ~w[
    Claim Commitment EconomicEvent Intent Need Offer Proposal
  ]

  @valueflows_process_types ~w[
    Agreement Plan Process ProposedIntent ProposedTo Satisfaction Scenario
  ]

  @valueflows_resource_types ~w[
    EconomicResource Measure ProcessSpecification ResourceSpecification Unit
  ]

  # ValueFlows payloads in the wild use both the original compact IRI and the
  # current ontology IRI. JSON-LD context is inspected as data only; this
  # module never dereferences a remote context document to classify an object.
  @valueflows_iri_prefixes [
    "https://w3id.org/valueflows#",
    "https://w3id.org/valueflows/ont/vf#"
  ]

  @valueflows_context_prefixes [
    "https://w3id.org/valueflows#",
    "https://w3id.org/valueflows/ont/vf"
  ]

  @valueflows_scalar_fields %{
    "due" => :due,
    "finished" => :finished,
    "hasBeginning" => :has_beginning,
    "hasEnd" => :has_end,
    "hasPointInTime" => :has_point_in_time,
    "trackingIdentifier" => :tracking_identifier
  }

  @valueflows_reference_fields %{
    "atLocation" => :at_location,
    "eligibleLocation" => :eligible_location,
    "inputOf" => :input_of,
    "outputOf" => :output_of,
    "plannedWithin" => :planned_within,
    "primaryAccountable" => :primary_accountable,
    "provider" => :provider,
    "receiver" => :receiver,
    "resourceClassifiedAs" => :resource_classified_as,
    "resourceConformsTo" => :resource_conforms_to,
    "resourceInventoriedAs" => :resource_inventoried_as,
    "toResourceInventoriedAs" => :to_resource_inventoried_as
  }

  @valueflows_quantity_fields %{
    "accountingQuantity" => {:accounting_quantity, :accounting_quantity_unit},
    "availableQuantity" => {:available_quantity, :available_quantity_unit},
    "effortQuantity" => {:effort_quantity, :effort_quantity_unit},
    "onhandQuantity" => {:onhand_quantity, :onhand_quantity_unit},
    "resourceQuantity" => {:resource_quantity, :resource_quantity_unit}
  }

  @mutual_aid_types %{
    "maid:Offer" => "offer",
    "maid:Request" => "request",
    "https://mutual-aid.app/ns/core#Offer" => "offer",
    "https://mutual-aid.app/ns/core#Request" => "request"
  }

  @compatibility_status_types ~w[Article Note Page]

  @neodb_catalog_types ~w[
    Album Edition Game Movie Performance PerformanceProduction Podcast
    PodcastEpisode TVEpisode TVSeason TVShow
  ]

  @wanderer_metric_fields %{
    "category" => :category,
    "difficulty" => :difficulty,
    "distance" => :distance,
    "duration" => :duration,
    "elevation_gain" => :elevation_gain,
    "elevation_loss" => :elevation_loss
  }

  @uuid_path_segment ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

  @flohmarkt_update_fields ~w[
    attachment attributedTo cc content contentMap flohmarkt:data id sensitive
    summary tag to type url
  ]

  @authority_fields ~w[actor attributedTo owner lastEditedBy]
  @delete_authority_fields ~w[actor attributedTo owner]
  @managed_authority_field "managedBy"

  @internal_field "_unfathomably_native"

  @native_family_field "https://unfathomably.social/ns#family"
  @native_kind_field "https://unfathomably.social/ns#kind"
  @native_detail_field "https://unfathomably.social/ns#detail"
  @native_secondary_field "https://unfathomably.social/ns#secondary"
  @native_reference_field "https://unfathomably.social/ns#reference"
  @native_namespace "https://unfathomably.social/ns#"
  @native_families ~w[audio video longform photo books bookmarks software models markets games routes culture coordination publishing]
  @discoverable_standard_types ~w[Audio Event Image Video]
  @native_presentation_fields %{
    "action" => :action,
    "album" => :album,
    "artist" => :artist,
    "author" => :author,
    "byline" => :byline,
    "category" => :category,
    "channel" => :channel,
    "condition" => :condition,
    "creator" => :creator,
    "currency" => :currency,
    "delivery" => :delivery,
    "difficulty" => :difficulty,
    "distance" => :distance,
    "distance_unit" => :distance_unit,
    "due" => :due,
    "duration" => :duration,
    "edition" => :edition,
    "elevation_gain" => :elevation_gain,
    "elevation_loss" => :elevation_loss,
    "expires" => :expires,
    "fen" => :fen,
    "file_name" => :file_name,
    "file_format" => :file_format,
    "format" => :format,
    "game_kind" => :game_kind,
    "genres" => :genres,
    "isbn" => :isbn,
    "labels" => :labels,
    "language" => :language,
    "level" => :level,
    "license" => :license,
    "live_start" => :live_start,
    "is_live_broadcast" => :is_live_broadcast,
    "embed_url" => :embed_url,
    "listing_type" => :listing_type,
    "location" => :location,
    "platform" => :platform_name,
    "players" => :players,
    "price" => :price,
    "printable" => :printable,
    "priority" => :priority,
    "project_status" => :project_status,
    "provider" => :provider,
    "published_at" => :published_at,
    "quantity" => :quantity,
    "reading_status" => :reading_status,
    "receiver" => :receiver,
    "release_date" => :release_date,
    "release_year" => :release_year,
    "repository" => :repository,
    "resource" => :resource,
    "route_kind" => :route_kind,
    "scale" => :scale,
    "site_name" => :site_name,
    "skills" => :skills,
    "start_time" => :start_time,
    "state" => :state,
    "status" => :status,
    "subject" => :subject,
    "subtitle" => :subtitle,
    "tags" => :tags,
    "taken_at" => :taken_at,
    "ticket_kind" => :ticket_kind,
    "track_number" => :track_number,
    "unit" => :unit,
    "url" => :url,
    "version" => :version
  }

  @presentation_scalar_fields %{
    "hashAfter" => :hash_after,
    "hashBefore" => :hash_before,
    "latestVersion" => :latest_version,
    "postingRestrictedToMods" => :posting_restricted_to_mods,
    "protected" => :protected,
    "rating" => :rating,
    "readingStatus" => :reading_status,
    "seriesNumber" => :series_number,
    "index" => :index,
    "ref" => :ref,
    "relationship" => :relationship,
    "state" => :state,
    "verdict" => :verdict
  }

  @presentation_reference_fields %{
    "book" => :book,
    "edition" => :edition,
    "edits" => :edits,
    "gpxUrl" => :gpx_url,
    "inReplyToBook" => :in_reply_to_book,
    "managedBy" => :managed_by,
    "resourceUrl" => :resource_url,
    "result" => :result,
    "target" => :target,
    "work" => :work,
    "series" => :series,
    "seriesBooks" => :series_books,
    "seriesIds" => :series_ids,
    "playlist" => :playlist,
    "track" => :track,
    "shapeTreeUri" => :shape_tree_uri,
    "interop:registeredShapeTree" => :registered_shape_tree
  }

  @type object_class :: String.t()

  @spec internal_field() :: String.t()
  def internal_field, do: @internal_field

  @doc "Returns true when an object has a meaningful specialized presentation."
  @spec discoverable?(map()) :: boolean()
  def discoverable?(%{} = object) do
    metadata = object[@internal_field] || %{}

    not discovery_opted_out?(object) and
      not bare_audio_activity?(object) and
      (metadata["discoverable"] == true or
         custom_object?(object) or
         object[@native_family_field] in @native_families or
         short_type(object["type"]) in @discoverable_standard_types or
         "capabilities" in standard_extension_fields(object) or
         not is_nil(wanderer_object_kind(object)) or
         map_size(presentation_fields(object)) > 0)
  end

  def discoverable?(_object), do: false

  # Some specialized publishers, notably Manyfold, use Mastodon's indexable
  # extension on objects rather than only on actors. Keep an explicitly hidden
  # object directly resolvable, but do not promote it into Worlds or search.
  defp discovery_opted_out?(object) do
    object["indexable"] == false or object["discoverable"] == false
  end

  # Legacy Pleroma scrobbles use Audio as a listening-activity envelope. They
  # carry a title, artist, and external Last.fm link, but no post body or media
  # that a status card can play. Explicit native objects remain eligible so a
  # locally authored music entry is never mistaken for a legacy scrobble.
  defp bare_audio_activity?(%{} = object) do
    metadata = object[@internal_field] || %{}

    short_type(object["type"]) == "Audio" and
      metadata["discoverable"] != true and
      blank_audio_value?(object[@native_family_field]) and
      blank_audio_value?(object["content"]) and
      blank_audio_value?(object["attachment"]) and
      blank_audio_value?(object["url"])
  end

  defp blank_audio_value?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_audio_value?(value), do: value in [nil, [], %{}]

  @spec custom_object?(map()) :: boolean()
  def custom_object?(%{"type" => type}), do: custom_type?(type)
  def custom_object?(_object), do: false

  @spec custom_type?(term()) :: boolean()
  def custom_type?(type) when is_binary(type) do
    type != "" and
      type not in Pleroma.Constants.activity_types() and
      type not in Pleroma.Constants.actor_types() and
      not CustomActivity.custom_activity_type?(type) and
      type not in @known_object_types and
      type not in @collection_types
  end

  def custom_type?(_type), do: false

  @spec class(map()) :: object_class()
  def class(%{"type" => type} = object) do
    short_type = short_type(type)
    valueflows_class = valueflows_class(object)

    cond do
      valueflows_class -> valueflows_class
      short_type in @status_types -> "status"
      short_type in @collection_object_types -> "collection"
      short_type in @process_types -> "process"
      short_type in @resource_types -> "resource"
      collection_shape?(object) -> "collection"
      status_shape?(object) -> "status"
      true -> "resource"
    end
  end

  def class(_object), do: "resource"

  @spec timeline_object?(map()) :: boolean()
  def timeline_object?(%{} = object) do
    not custom_object?(object) or class(object) == "status" or locally_authored?(object)
  end

  def timeline_object?(_object), do: false

  @spec direct_resource?(map()) :: boolean()
  def direct_resource?(%{} = object) do
    custom_object?(object) and class(object) != "status"
  end

  def direct_resource?(_object), do: false

  @spec authorities(map(), :delete | :write) :: [String.t()]
  def authorities(object, action \\ :write)

  def authorities(%{} = object, action) do
    managed_authorities = authority_ids(object[@managed_authority_field])

    if managed_authorities == [] do
      fields = if action == :delete, do: @delete_authority_fields, else: @authority_fields

      fields
      |> Enum.flat_map(fn field -> authority_ids(object[field]) end)
      |> Enum.uniq()
    else
      Enum.uniq(managed_authorities)
    end
  end

  def authorities(_object, _action), do: []

  @spec authorized?(map(), String.t(), :delete | :write) :: boolean()
  def authorized?(object, actor, action \\ :write)

  def authorized?(%{} = object, actor, action) when is_binary(actor) do
    actor in authorities(object, action)
  end

  def authorized?(_object, _actor, _action), do: false

  @doc """
  Returns true when a native status may replace its compatibility rendering.

  Some applications serialize one logical status differently for peers that do
  not understand their vocabulary. Canonical identity, authority, addressing,
  and context must still agree before the richer form may upgrade local state.
  """
  @spec compatibility_upgrade?(map(), map(), String.t()) :: boolean()
  def compatibility_upgrade?(stored, incoming, actor)
      when is_map(stored) and is_map(incoming) and is_binary(actor) do
    stored["type"] in @compatibility_status_types and
      custom_object?(incoming) and
      timeline_object?(incoming) and
      stored["id"] == incoming["id"] and
      actor in authorities(stored) and
      authorized?(incoming, actor) and
      recipient_set(stored) == recipient_set(incoming) and
      compatible_context?(stored, incoming)
  end

  def compatibility_upgrade?(_stored, _incoming, _actor), do: false

  @spec put_internal_metadata(map(), keyword()) :: map()
  def put_internal_metadata(object, options \\ [])

  def put_internal_metadata(%{"id" => id, "type" => type} = object, options) do
    metadata = %{
      "authority" => %{
        "delete" => authorities(object, :delete),
        "write" => authorities(object, :write)
      },
      "canonicalId" => id,
      "class" => class(object),
      "context" => reference_id(object["context"]),
      "discoverable" => true,
      "type" => type
    }

    metadata =
      if Keyword.get(options, :local, false) do
        Map.put(metadata, "localAuthored", true)
      else
        metadata
      end

    object = Map.put(object, @internal_field, metadata)

    put_in(object, [@internal_field, "discoverable"], discoverable?(object))
  end

  def put_internal_metadata(object, _options), do: object

  @doc "Marks bounded extension fields retained on a standard ActivityStreams object."
  @spec put_standard_internal_metadata(map(), [String.t()]) :: map()
  def put_standard_internal_metadata(%{"id" => id, "type" => type} = object, fields)
      when is_list(fields) do
    fields =
      fields
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.take(64)

    metadata = %{
      "authority" => %{
        "delete" => authorities(object, :delete),
        "write" => authorities(object, :write)
      },
      "canonicalId" => id,
      "class" => class(object),
      "context" => reference_id(object["context"]),
      "extensionFields" => fields,
      "type" => type
    }

    Map.put(object, @internal_field, metadata)
  end

  def put_standard_internal_metadata(object, _fields), do: object

  @doc "Returns the trusted standard-object extension field names recorded at validation time."
  @spec standard_extension_fields(map()) :: [String.t()]
  def standard_extension_fields(%{
        "id" => id,
        "type" => type,
        @internal_field => %{
          "canonicalId" => id,
          "type" => type,
          "extensionFields" => fields
        }
      })
      when is_binary(id) and is_binary(type) and is_list(fields) do
    if length(fields) <= 64 and Enum.all?(fields, &(is_binary(&1) and &1 != "")) do
      Enum.uniq(fields)
    else
      []
    end
  end

  def standard_extension_fields(_object), do: []

  @doc "Returns bounded native metadata suitable for Mastodon API and preview clients."
  @spec presentation(map()) :: map() | nil
  def presentation(%{} = object) do
    if discoverable?(object) do
      fields = presentation_fields(object)

      %{
        canonical_id: object["id"],
        class: class(object),
        context: reference_id(object["context"]),
        controls: presentation_controls(object, fields),
        fields: fields,
        type: object["type"]
      }
    end
  end

  def presentation(_object), do: nil

  defp presentation_controls(object, fields) do
    type = short_type(object["type"])
    family = fields[:family]
    platform = fields[:platform]

    ["open"]
    |> maybe_add_control(
      is_binary(fields[:gpx_url]) or is_binary(fields[:resource_url]),
      "download"
    )
    |> maybe_add_control(
      family in ["books", "culture"] or platform == "neodb" or type in ["Book", "Edition"],
      "review"
    )
    |> maybe_add_control(family == "markets" or platform == "flohmarkt", "contact")
    |> maybe_add_control(
      family in ["coordination", "games"] or
        platform in ["activitypods", "bonfire_valueflows", "mutual_aid"],
      "respond"
    )
    |> maybe_add_control(
      family in [
        "software",
        "longform",
        "publishing",
        "bookmarks",
        "routes",
        "models",
        "video",
        "photo"
      ] or
        (type in ["Issue", "Repository", "Ticket"] and platform != "activitypods"),
      "discuss"
    )
    |> maybe_add_control(
      type in ["Audio", "Track"] and is_binary(object["id"]) and object["id"] != "",
      "listen"
    )
  end

  defp maybe_add_control(controls, true, control), do: controls ++ [control]
  defp maybe_add_control(controls, false, _control), do: controls

  @spec short_type(term()) :: String.t() | nil
  def short_type(type) when is_binary(type) do
    type
    |> String.split(["#", "/", ":"], trim: true)
    |> List.last()
  end

  def short_type(_type), do: nil

  defp collection_shape?(object) do
    Enum.any?(~w[first items last orderedItems totalItems], &Map.has_key?(object, &1))
  end

  defp status_shape?(object) do
    Enum.any?(~w[content inReplyTo published quote summary], &Map.has_key?(object, &1)) and
      authorities(object) != []
  end

  defp recipient_set(object) do
    object
    |> Map.take(["to", "cc"])
    |> Map.values()
    |> List.flatten()
    |> Enum.map(&reference_id/1)
    |> Enum.map(&normalize_public/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp compatible_context?(stored, incoming) do
    stored_context = reference_id(stored["context"])
    incoming_context = reference_id(incoming["context"])

    is_nil(stored_context) or is_nil(incoming_context) or stored_context == incoming_context
  end

  defp presentation_fields(object) do
    scalar_fields =
      Enum.reduce(@presentation_scalar_fields, %{}, fn {source, target}, fields ->
        case presentation_scalar(object[source]) do
          nil -> fields
          value -> Map.put(fields, target, value)
        end
      end)

    @presentation_reference_fields
    |> Enum.reduce(scalar_fields, fn {source, target}, fields ->
      case presentation_reference(object[source]) do
        nil -> fields
        value -> Map.put(fields, target, value)
      end
    end)
    |> put_activitypods_presentation_fields(object)
    |> put_mutual_aid_presentation_fields(object)
    |> put_valueflows_presentation_fields(object)
    |> put_zenpub_presentation_fields(object)
    |> put_neodb_presentation_fields(object)
    |> put_audio_presentation_fields(object)
    |> put_music_catalog_presentation_fields(object)
    |> put_wanderer_presentation_fields(object)
    |> put_model_presentation_fields(object)
    |> put_live_video_presentation_fields(object)
    |> put_castling_presentation_fields(object)
    |> put_flohmarkt_presentation_fields(object)
    |> put_photo_capabilities_presentation_fields(object)
    |> put_unfathomably_presentation_fields(object)
  end

  defp put_photo_capabilities_presentation_fields(fields, object) do
    if "capabilities" in standard_extension_fields(object) and image_attachment?(object) do
      fields
      |> Map.put_new(:family, "photo")
      |> Map.put_new(:kind, "photo_story")
    else
      fields
    end
  end

  # Funkwhale publishes ordinary ActivityStreams Audio and Track objects. Their
  # music metadata is not extension-vocabulary data, so retain the bounded
  # standard fields explicitly instead of requiring a platform-specific shape.
  defp put_audio_presentation_fields(fields, object) do
    case short_type(object["type"]) do
      type when type in ["Audio", "Track"] ->
        fields
        |> Map.put_new(:family, "audio")
        |> Map.put_new(:kind, String.downcase(type))
        |> put_presentation_scalar(
          :title,
          presentation_scalar(object["title"] || object["name"])
        )
        |> put_presentation_scalar(:artist, presentation_scalar(object["artist"]))
        |> put_presentation_scalar(:album, presentation_scalar(object["album"]))
        |> put_presentation_reference(:external_link, audio_external_link(object["externalLink"]))

      _type ->
        fields
    end
  end

  defp audio_external_link(value) do
    case presentation_reference(value) do
      value when is_binary(value) ->
        if native_resource_http_url?(value), do: value

      _value ->
        nil
    end
  end

  defp put_music_catalog_presentation_fields(fields, object) do
    type = short_type(object["type"])

    if type in ["Artist", "Album", "Library", "Playlist"] and
         music_catalog_presentation_shape?(type, object) do
      fields
      |> Map.put_new(:platform, "funkwhale")
      |> Map.put_new(:family, "audio")
      |> Map.put_new(:kind, String.downcase(type))
      |> put_presentation_scalar(:title, presentation_scalar(object["name"] || object["title"]))
      |> put_presentation_scalar(
        :description,
        presentation_scalar(object["summary"] || object["content"])
      )
      |> put_presentation_scalar(:artist, music_catalog_artist(object["artist_credit"]))
      |> put_presentation_scalar(
        :released,
        presentation_scalar(object["released"] || object["release_date"])
      )
      |> put_presentation_scalar(
        :musicbrainz_id,
        presentation_scalar(object["musicbrainzId"] || object["musicbrainz_id"])
      )
      |> put_presentation_scalar(:total_items, presentation_scalar(object["totalItems"]))
      |> put_presentation_reference(
        :image,
        presentation_reference(object["cover"] || object["image"] || object["icon"])
      )
      |> put_presentation_reference(:owner, presentation_reference(object["attributedTo"]))
      |> put_presentation_reference(
        :collection,
        presentation_reference(object["current"] || object["first"] || object["id"])
      )
    else
      fields
    end
  end

  defp music_catalog_presentation_shape?("Artist", object) do
    music_catalog_musicbrainz?(object) or music_catalog_context?(object)
  end

  defp music_catalog_presentation_shape?("Album", object) do
    music_catalog_musicbrainz?(object) or
      Map.has_key?(object, "artist_credit") or
      Map.has_key?(object, "cover") or
      music_catalog_context?(object)
  end

  defp music_catalog_presentation_shape?("Library", object) do
    is_binary(presentation_reference(object["followers"])) and
      is_binary(presentation_reference(object["first"])) and
      is_integer(presentation_scalar(object["totalItems"]))
  end

  defp music_catalog_presentation_shape?("Playlist", object) do
    is_binary(presentation_reference(object["first"])) and
      is_binary(presentation_reference(object["last"])) and
      is_integer(presentation_scalar(object["totalItems"]))
  end

  defp music_catalog_presentation_shape?(_type, _object), do: false

  defp music_catalog_musicbrainz?(object) do
    is_binary(presentation_scalar(object["musicbrainzId"] || object["musicbrainz_id"]))
  end

  defp music_catalog_context?(object) do
    object
    |> Map.get("@context", [])
    |> List.wrap()
    |> Enum.any?(fn
      value when is_binary(value) ->
        String.starts_with?(value, "https://funkwhale.audio/ns")

      value when is_map(value) ->
        value
        |> Map.values()
        |> Enum.any?(&(is_binary(&1) and String.contains?(&1, "funkwhale.audio/ns")))

      _ ->
        false
    end)
  end

  defp music_catalog_artist(value) when is_binary(value), do: presentation_scalar(value)

  defp music_catalog_artist(values) when is_list(values) do
    values
    |> Enum.map(fn
      %{"credit" => credit} when is_binary(credit) ->
        presentation_scalar(credit)

      %{"artist" => %{} = artist} ->
        presentation_scalar(artist["name"] || artist["preferredUsername"])

      %{"name" => name} when is_binary(name) ->
        presentation_scalar(name)

      value when is_binary(value) ->
        presentation_scalar(value)

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.join(", ")
    |> presentation_scalar()
  end

  defp music_catalog_artist(_value), do: nil

  defp put_model_presentation_fields(fields, object) do
    descriptor = model_file_descriptor(object["attachment"])
    manyfold_model? = manyfold_model_shape?(object)

    if manyfold_model? or not is_nil(descriptor) do
      fields
      |> Map.put_new(:family, "models")
      |> Map.put_new(:kind, "3d_model")
      |> put_presentation_scalar(:platform, if(manyfold_model?, do: "manyfold"))
      |> put_model_file_descriptor(descriptor)
    else
      fields
    end
  end

  defp put_live_video_presentation_fields(fields, %{"type" => "Video"} = object) do
    live_broadcast = object["isLiveBroadcast"]
    live_start = live_video_start(object["schedules"])
    embed_url = presentation_reference(object["embedUrl"])

    if live_broadcast == true or not is_nil(live_start) or not is_nil(embed_url) do
      fields
      |> Map.put_new(:family, "video")
      |> Map.put_new(:kind, if(live_start, do: "scheduled_live_video", else: "live_video"))
      |> put_presentation_scalar(:is_live_broadcast, live_broadcast)
      |> put_presentation_scalar(:live_start, live_start)
      |> put_presentation_reference(:embed_url, embed_url)
    else
      fields
    end
  end

  defp put_live_video_presentation_fields(fields, _object), do: fields

  defp live_video_start(schedules) when is_list(schedules) do
    Enum.find_value(schedules, fn
      %{"startDate" => start_date} when is_binary(start_date) -> start_date
      _schedule -> nil
    end)
  end

  defp live_video_start(_schedules), do: nil

  defp put_model_file_descriptor(fields, nil), do: fields

  defp put_model_file_descriptor(fields, descriptor) do
    fields
    |> put_presentation_reference(:resource_url, descriptor.url)
    |> put_presentation_scalar(:file_format, descriptor.format)
    |> put_presentation_scalar(:file_name, descriptor.name)
  end

  defp manyfold_model_shape?(object) do
    Enum.any?(object, fn
      {key, value} when is_binary(key) ->
        String.ends_with?(key, "concreteType") and
          short_type(reference_id(value) || presentation_scalar(value)) == "3DModel"

      _field ->
        false
    end)
  end

  defp model_file_descriptor(attachments) do
    attachments
    |> List.wrap()
    |> Enum.find_value(&model_attachment_descriptor/1)
  end

  defp model_attachment_descriptor(%{} = attachment) do
    url = model_media_url(attachment["url"] || attachment["href"])
    media_type = presentation_scalar(attachment["mediaType"])

    if model_media?(media_type, url) do
      %{
        format: media_type || model_file_extension(url),
        name: presentation_scalar(attachment["name"]),
        url: url
      }
    end
  end

  defp model_attachment_descriptor(_attachment), do: nil

  defp model_media_url(values) when is_list(values) do
    Enum.find_value(values, &model_media_url/1)
  end

  defp model_media_url(value) when is_binary(value) do
    if native_resource_http_url?(value), do: value
  end

  defp model_media_url(%{"href" => href}), do: model_media_url(href)
  defp model_media_url(%{"id" => id}), do: model_media_url(id)
  defp model_media_url(_value), do: nil

  defp model_media?(media_type, url) when is_binary(url) do
    normalized_media_type =
      if is_binary(media_type), do: String.downcase(media_type), else: nil

    normalized_media_type in [
      "application/sla",
      "application/vnd.flock+json",
      "application/vnd.ms-pki.stl",
      "model/3mf",
      "model/gltf+json",
      "model/gltf-binary",
      "model/obj",
      "model/stl"
    ] or model_file_extension(url) in ~w[3mf amf flock glb gltf obj ply step stl stp]
  end

  defp model_media?(_media_type, _url), do: false

  defp model_file_extension(url) do
    url
    |> URI.parse()
    |> Map.get(:path)
    |> to_string()
    |> Path.extname()
    |> String.trim_leading(".")
    |> String.downcase()
    |> case do
      "" -> nil
      extension -> extension
    end
  end

  defp native_resource_http_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _uri ->
        false
    end
  end

  defp image_attachment?(%{"attachment" => attachments}) do
    attachments
    |> List.wrap()
    |> Enum.any?(fn
      %{"mediaType" => "image/" <> _subtype} -> true
      %{"type" => "Image"} -> true
      _attachment -> false
    end)
  end

  defp image_attachment?(_object), do: false

  defp put_unfathomably_presentation_fields(fields, object) do
    family = presentation_scalar(object[@native_family_field])
    kind = presentation_scalar(object[@native_kind_field])
    producer = object |> authorities() |> List.first()

    if family in @native_families and is_binary(kind) and is_binary(producer) and
         same_web_origin?(object["id"], producer) do
      fields
      |> Map.put_new(:platform, "unfathomably")
      |> Map.put(:family, family)
      |> Map.put(:kind, kind)
      |> put_presentation_scalar(:detail, presentation_scalar(object[@native_detail_field]))
      |> put_presentation_scalar(:secondary, presentation_scalar(object[@native_secondary_field]))
      |> put_presentation_reference(
        :reference,
        presentation_reference(object[@native_reference_field])
      )
      |> put_unfathomably_detail_fields(object)
    else
      fields
    end
  end

  defp put_unfathomably_detail_fields(fields, object) do
    Enum.reduce(@native_presentation_fields, fields, fn {source, target}, result ->
      put_presentation_scalar(
        result,
        target,
        presentation_scalar(object[@native_namespace <> source])
      )
    end)
  end

  defp locally_authored?(%{
         "id" => id,
         "type" => type,
         @internal_field => %{
           "canonicalId" => id,
           "localAuthored" => true,
           "type" => type
         }
       }),
       do: true

  defp locally_authored?(_object), do: false

  defp put_activitypods_presentation_fields(fields, %{"type" => type} = object)
       when type in [
              "pair:Project",
              "http://virtual-assembly.org/ontologies/pair#Project"
            ] do
    fields
    |> Map.put(:platform, "activitypods")
    |> put_presentation_scalar(
      :project_label,
      presentation_scalar(
        object["pair:label"] ||
          object["http://virtual-assembly.org/ontologies/pair#label"]
      )
    )
    |> put_presentation_scalar(
      :project_description,
      presentation_scalar(
        object["pair:description"] ||
          object["http://virtual-assembly.org/ontologies/pair#description"]
      )
    )
  end

  defp put_activitypods_presentation_fields(fields, _object), do: fields

  defp put_mutual_aid_presentation_fields(fields, %{"type" => type} = object) do
    case @mutual_aid_types[type] do
      nil ->
        fields

      kind ->
        resource_type_field =
          if kind == "offer", do: "offerOfResourceType", else: "requestOfResourceType"

        fields
        |> Map.put(:platform, "mutual_aid")
        |> Map.put(:listing_kind, kind)
        |> put_presentation_scalar(
          :listing_label,
          presentation_scalar(
            object["pair:label"] ||
              object["http://virtual-assembly.org/ontologies/pair#label"] ||
              object["name"]
          )
        )
        |> put_presentation_reference(
          :resource_type,
          presentation_reference(mutual_aid_field(object, resource_type_field))
        )
    end
  end

  defp put_mutual_aid_presentation_fields(fields, _object), do: fields

  defp mutual_aid_field(object, field) do
    object["maid:#{field}"] || object["https://mutual-aid.app/ns/core##{field}"]
  end

  defp put_valueflows_presentation_fields(fields, %{"type" => _type} = object) do
    case valueflows_name(object) do
      nil ->
        fields

      name ->
        fields
        |> Map.put(:platform, "bonfire_valueflows")
        |> Map.put(:valueflows_type, name)
        |> put_presentation_scalar(:action, valueflows_action(valueflows_field(object, "action")))
        |> put_valueflows_fields(object, @valueflows_scalar_fields, &presentation_scalar/1)
        |> put_valueflows_fields(object, @valueflows_reference_fields, &presentation_reference/1)
        |> put_valueflows_quantities(object)
    end
  end

  defp put_valueflows_presentation_fields(fields, _object), do: fields

  defp put_zenpub_presentation_fields(fields, object) do
    if zenpub_document?(object) do
      fields
      |> Map.put(:platform, "zenpub")
      |> put_presentation_scalar(:author, zenpub_author(object["author"]))
      |> put_presentation_scalar(:subject, presentation_scalar(object["subject"]))
      |> put_presentation_scalar(:level, presentation_scalar(object["level"]))
      |> put_presentation_scalar(:language, presentation_scalar(object["language"]))
      |> put_presentation_scalar(:license, zenpub_license(object["tag"]))
      |> put_presentation_reference(:resource_url, presentation_reference(object["url"]))
    else
      fields
    end
  end

  def zenpub_document?(
        %{
          "actor" => actor,
          "attributedTo" => attributed_to,
          "id" => id,
          "tag" => tag,
          "type" => "Document"
        } = object
      )
      when is_binary(actor) and is_binary(attributed_to) and is_binary(id) do
    extension_fields = MapSet.new(standard_extension_fields(object))

    actor == attributed_to and not is_nil(zenpub_license(tag)) and
      MapSet.member?(extension_fields, "tag") and
      Enum.any?(~w[author level subject], &MapSet.member?(extension_fields, &1)) and
      same_web_origin?(id, actor)
  end

  def zenpub_document?(_object), do: false

  defp zenpub_author(%{"url" => url}) when is_binary(url), do: url
  defp zenpub_author(%{"name" => name}) when is_binary(name), do: name
  defp zenpub_author(author), do: presentation_scalar(author)

  defp zenpub_license(value) when is_binary(value), do: value
  defp zenpub_license(values) when is_list(values), do: Enum.find(values, &is_binary/1)
  defp zenpub_license(_value), do: nil

  defp put_valueflows_fields(fields, object, field_map, value_fun) do
    Enum.reduce(field_map, fields, fn {source, target}, result ->
      put_presentation_scalar(result, target, value_fun.(valueflows_field(object, source)))
    end)
  end

  defp put_valueflows_quantities(fields, object) do
    Enum.reduce(@valueflows_quantity_fields, fields, fn
      {source, {value_key, unit_key}}, result ->
        case valueflows_field(object, source) do
          %{} = quantity ->
            result
            |> put_presentation_scalar(
              value_key,
              presentation_scalar(quantity["hasNumericalValue"])
            )
            |> put_presentation_reference(unit_key, presentation_reference(quantity["hasUnit"]))

          _quantity ->
            result
        end
    end)
  end

  defp valueflows_action(action) when is_binary(action) do
    action
    |> valueflows_term()
    |> presentation_scalar()
  end

  defp valueflows_action(action), do: presentation_scalar(action)

  defp valueflows_class(object) do
    case valueflows_name(object) do
      name when name in @valueflows_status_types -> "status"
      name when name in @valueflows_process_types -> "process"
      name when name in @valueflows_resource_types -> "resource"
      _name -> nil
    end
  end

  defp valueflows_name(%{"type" => types} = object) do
    Enum.find_value(List.wrap(types), &valueflows_name/1) ||
      valueflows_context_type_name(types, object)
  end

  defp valueflows_name("ValueFlows:" <> name), do: known_valueflows_name(name)

  defp valueflows_name(type) when is_binary(type) do
    Enum.find_value(@valueflows_iri_prefixes, fn prefix ->
      if String.starts_with?(type, prefix) do
        type
        |> String.replace_prefix(prefix, "")
        |> known_valueflows_name()
      end
    end)
  end

  defp valueflows_name(_type), do: nil

  defp valueflows_context_type_name(types, object) do
    if valueflows_context?(object) do
      types
      |> List.wrap()
      |> Enum.find_value(fn type -> type |> short_type() |> known_valueflows_name() end)
    end
  end

  defp valueflows_context?(object) do
    object
    |> Map.get("@context", [])
    |> List.wrap()
    |> Enum.any?(&valueflows_context_entry?/1)
  end

  defp valueflows_context_entry?(context) when is_binary(context),
    do: valueflows_context_iri?(context)

  defp valueflows_context_entry?(context) when is_map(context) do
    Enum.any?(context, fn {_term, value} -> valueflows_context_iri?(value) end)
  end

  defp valueflows_context_entry?(_context), do: false

  defp valueflows_context_iri?(value) when is_binary(value) do
    Enum.any?(@valueflows_context_prefixes, &String.starts_with?(value, &1))
  end

  defp valueflows_context_iri?(_value), do: false

  defp valueflows_field(object, field) when is_map(object) and is_binary(field) do
    object[field] || object["vf:" <> field] ||
      Enum.find_value(@valueflows_iri_prefixes, &object[&1 <> field])
  end

  defp valueflows_field(_object, _field), do: nil

  defp valueflows_term(value) when is_binary(value) do
    Enum.find_value(@valueflows_iri_prefixes, value, fn prefix ->
      if String.starts_with?(value, prefix), do: String.replace_prefix(value, prefix, "")
    end)
    |> String.replace_prefix("vf:", "")
  end

  defp known_valueflows_name(name) do
    if name in (@valueflows_status_types ++
                  @valueflows_process_types ++ @valueflows_resource_types) do
      name
    end
  end

  defp put_castling_presentation_fields(fields, object) do
    case castling_note_data(object) do
      nil ->
        fields

      data ->
        fields
        |> Map.put(:platform, "castling")
        |> Map.put(:fen, data.fen)
        |> Map.put(:game, data.game)
        |> put_presentation_scalar(:san, data.san)
    end
  end

  defp castling_note_data(
         %{
           "attributedTo" => attributed_to,
           "fen" => fen,
           "game" => game,
           "id" => id,
           "type" => "Note"
         } = object
       )
       when is_binary(fen) and is_binary(game) and is_binary(id) do
    actor = reference_id(attributed_to)
    san = object["san"]

    if is_binary(actor) and castling_extension_fields?(object) and castling_fen?(fen) and
         castling_san?(san) and castling_actor_id?(actor) and
         castling_object_id?(id) and castling_game_id?(game) and
         same_web_origin?(id, actor) and same_web_origin?(game, actor) do
      %{fen: fen, game: game, san: san}
    end
  end

  defp castling_note_data(_object), do: nil

  defp castling_extension_fields?(object) do
    fields = MapSet.new(standard_extension_fields(object))

    MapSet.subset?(MapSet.new(["fen", "game"]), fields) and
      (is_nil(object["san"]) or MapSet.member?(fields, "san"))
  end

  defp castling_fen?(fen) do
    byte_size(fen) <= 128 and
      match?([_board, _turn, _castling, _en_passant, _halfmove, _fullmove], String.split(fen))
  end

  defp castling_san?(nil), do: true
  defp castling_san?(san) when is_binary(san), do: san != "" and byte_size(san) <= 16
  defp castling_san?(_san), do: false

  defp castling_actor_id?(id), do: uri_path_segments(id) == ["@king"]

  defp castling_object_id?(id) do
    case uri_path_segments(id) do
      ["objects", uuid] -> Regex.match?(@uuid_path_segment, uuid)
      _segments -> false
    end
  end

  defp castling_game_id?(id) do
    case uri_path_segments(id) do
      ["games", uuid] -> Regex.match?(@uuid_path_segment, uuid)
      _segments -> false
    end
  end

  defp uri_path_segments(id) do
    case URI.parse(id) do
      %URI{path: path} when is_binary(path) -> String.split(path, "/", trim: true)
      _uri -> []
    end
  rescue
    URI.Error -> []
  end

  defp put_flohmarkt_presentation_fields(fields, object) do
    case flohmarkt_listing_data(object) || fep0837_listing_presentation_data(object) do
      nil ->
        fields

      data ->
        fields
        |> Map.put(:platform, "flohmarkt")
        |> Map.put_new(:family, "markets")
        |> Map.put_new(:kind, "market_listing")
        |> put_presentation_scalar(:listing_name, presentation_scalar(data["name"]))
        |> put_presentation_scalar(:price, presentation_scalar(data["price"]))
        |> put_presentation_scalar(:currency, presentation_scalar(data["currency"]))
        |> put_presentation_scalar(:original_id, presentation_scalar(data["original_id"]))
        |> put_presentation_scalar(:listing_location, presentation_scalar(data["location"]))
        |> put_flohmarkt_coordinates(data["coordinates"])
    end
  end

  # New Flohmarkt instances can send an interoperable FEP-0837 Proposal
  # attachment without the older flohmarkt:data extension. This is presentation
  # metadata only: lifecycle and update validation remain limited to the fully
  # verified legacy listing shape below.
  defp fep0837_listing_presentation_data(
         %{
           "attachment" => attachments,
           "attributedTo" => actor,
           "type" => "Note"
         } = object
       )
       when is_binary(actor) do
    attachments
    |> List.wrap()
    |> Enum.find_value(&fep0837_listing_attachment_data(&1, actor, object))
  end

  defp fep0837_listing_presentation_data(_object), do: nil

  defp fep0837_listing_attachment_data(%{} = proposal, actor, object) do
    publishes = valueflows_field(proposal, "publishes")
    reciprocal = valueflows_field(proposal, "reciprocal")
    quantity = valueflows_field(reciprocal, "resourceQuantity")
    location = valueflows_field(proposal, "location")

    if fep0837_proposal?(proposal, object) and proposal["attributedTo"] == actor and
         presentation_scalar(valueflows_field(proposal, "purpose")) == "offer" and
         fep0837_transfer?(publishes) and is_map(quantity) do
      name = presentation_scalar(proposal["name"])
      price = presentation_scalar(valueflows_field(quantity, "hasNumericalValue"))
      currency = presentation_scalar(valueflows_field(quantity, "hasUnit"))

      if is_binary(name) and not is_nil(price) and is_binary(currency) do
        %{
          "currency" => currency,
          "location" => fep0837_location_name(location),
          "name" => name,
          "original_id" => presentation_scalar(proposal["id"]),
          "price" => price
        }
      end
    end
  end

  defp fep0837_listing_attachment_data(_proposal, _actor, _object), do: nil

  defp fep0837_proposal?(proposal, object) do
    valueflows_name(proposal) == "Proposal" or
      (short_type(proposal["type"]) == "Proposal" and valueflows_context?(object))
  end

  defp fep0837_transfer?(%{} = intent) do
    short_type(intent["type"]) == "Intent" and
      valueflows_term(valueflows_field(intent, "action")) == "transfer"
  end

  defp fep0837_transfer?(_intent), do: false

  defp fep0837_location_name(%{} = location), do: presentation_scalar(location["name"])
  defp fep0837_location_name(_location), do: nil

  @doc "Returns true for a canonical stock Flohmarkt listing Note."
  @spec flohmarkt_listing?(map()) :: boolean()
  def flohmarkt_listing?(%{} = object), do: not is_nil(flohmarkt_listing_data(object))
  def flohmarkt_listing?(_object), do: false

  @doc "Compares the stock-controlled fields of two Flohmarkt listing revisions."
  @spec same_flohmarkt_listing?(map(), map()) :: boolean()
  def same_flohmarkt_listing?(%{} = left, %{} = right) do
    flohmarkt_listing?(left) and flohmarkt_listing?(right) and
      Map.take(left, @flohmarkt_update_fields) == Map.take(right, @flohmarkt_update_fields)
  end

  def same_flohmarkt_listing?(_left, _right), do: false

  defp flohmarkt_listing_data(%{
         "attributedTo" => attributed_to,
         "flohmarkt:data" => %{} = data,
         "id" => id,
         "type" => "Note"
       })
       when is_binary(id) do
    actor = reference_id(attributed_to)
    original_id = data["original_id"]

    if is_binary(actor) and is_binary(original_id) and original_id != "" and
         is_binary(data["name"]) and not is_nil(presentation_scalar(data["price"])) and
         is_binary(data["currency"]) and flohmarkt_item_id?(id, original_id) and
         flohmarkt_actor_item_path?(id, actor, original_id) and
         same_web_origin?(id, actor) do
      data
    end
  end

  defp flohmarkt_listing_data(_object), do: nil

  defp flohmarkt_item_id?(id, original_id) do
    case URI.parse(id) do
      %URI{path: path} when is_binary(path) ->
        String.ends_with?(path, "/items/" <> original_id)

      _uri ->
        false
    end
  end

  defp flohmarkt_actor_item_path?(item_id, actor_id, original_id) do
    with %URI{path: item_path} when is_binary(item_path) <- URI.parse(item_id),
         %URI{path: actor_path} when is_binary(actor_path) <- URI.parse(actor_id) do
      item_path == String.trim_trailing(actor_path, "/") <> "/items/" <> original_id
    else
      _uri -> false
    end
  end

  defp same_web_origin?(left, right) do
    with %URI{host: left_host, port: left_port, scheme: left_scheme}
         when left_scheme in ["http", "https"] and is_binary(left_host) <- URI.parse(left),
         %URI{host: right_host, port: right_port, scheme: right_scheme}
         when right_scheme in ["http", "https"] and is_binary(right_host) <- URI.parse(right) do
      left_scheme == right_scheme and left_host == right_host and left_port == right_port
    else
      _uri -> false
    end
  end

  defp put_flohmarkt_coordinates(fields, %{"lat" => latitude, "lng" => longitude}) do
    fields
    |> put_presentation_scalar(:latitude, presentation_scalar(latitude))
    |> put_presentation_scalar(:longitude, presentation_scalar(longitude))
  end

  defp put_flohmarkt_coordinates(fields, _coordinates), do: fields

  defp put_neodb_presentation_fields(fields, %{"relatedWith" => related} = object)
       when is_list(related) do
    if Enum.any?(related, &neodb_related_activity?/1) do
      catalog = neodb_catalog_tag(object["tag"])

      fields
      |> Map.put(:platform, "neodb")
      |> put_presentation_scalar(:rating, related_scalar(related, "Rating", "value"))
      |> put_presentation_scalar(:rating_best, related_scalar(related, "Rating", "best"))
      |> put_presentation_scalar(
        :reading_status,
        related_scalar(related, "Status", "status")
      )
      |> put_presentation_reference(:catalog_item, related_reference(related, "withRegardTo"))
      |> put_presentation_scalar(:catalog_type, catalog && short_type(catalog["type"]))
      |> put_presentation_reference(:review, related_type_reference(related, "Review"))
    else
      fields
    end
  end

  defp put_neodb_presentation_fields(fields, %{"relatedWith" => %{} = related} = object) do
    put_neodb_presentation_fields(fields, Map.put(object, "relatedWith", [related]))
  end

  defp put_neodb_presentation_fields(fields, _object), do: fields

  defp put_wanderer_presentation_fields(fields, object) do
    case wanderer_object_kind(object) do
      nil ->
        fields

      kind ->
        fields
        |> Map.put(:platform, "wanderer")
        |> Map.put(:family, "routes")
        |> Map.put(:kind, kind)
        |> Map.put(:route_kind, kind)
        |> put_presentation_scalar(:start_time, presentation_scalar(object["startTime"]))
        |> put_wanderer_location(object["location"])
        |> put_wanderer_metrics(object["tag"])
        |> put_presentation_reference(:gpx_url, wanderer_gpx_url(object["attachment"]))
    end
  end

  defp wanderer_object_kind(%{"id" => id, "type" => "Note"} = object)
       when is_binary(id) do
    case URI.parse(id).path |> to_string() |> String.split("/", trim: true) do
      ["api", "v1", "trail", _id] ->
        if wanderer_trail_shape?(object), do: "trail"

      ["api", "v1", "summit-log", _id] ->
        if wanderer_trail_reply_shape?(object), do: "summit_log"

      ["api", "v1", "comment", _id] ->
        if wanderer_trail_reply_shape?(object), do: "comment"

      ["api", "v1", "list", _id] ->
        if wanderer_list_shape?(object), do: "list"

      _path ->
        nil
    end
  rescue
    URI.Error -> nil
  end

  defp wanderer_object_kind(_object), do: nil

  defp wanderer_trail_shape?(object) do
    not is_nil(wanderer_gpx_url(object["attachment"])) or
      not is_nil(wanderer_metric(object["tag"], "distance")) or
      match?(%{"type" => "Place"}, object["location"])
  end

  defp wanderer_trail_reply_shape?(%{"inReplyTo" => trail} = object) do
    wanderer_trail_reference?(trail) and
      (not is_nil(wanderer_gpx_url(object["attachment"])) or
         is_binary(object["content"]))
  end

  defp wanderer_trail_reply_shape?(_object), do: false

  defp wanderer_list_shape?(%{"url" => url}) when is_binary(url) do
    String.contains?(url, "/lists/@")
  end

  defp wanderer_list_shape?(_object), do: false

  defp wanderer_trail_reference?(value) do
    case reference_id(value) do
      id when is_binary(id) -> String.contains?(id, "/api/v1/trail/")
      _id -> false
    end
  end

  defp put_wanderer_location(fields, %{"type" => "Place"} = location) do
    fields
    |> put_presentation_scalar(:location, presentation_scalar(location["name"]))
    |> put_presentation_scalar(:latitude, presentation_scalar(location["latitude"]))
    |> put_presentation_scalar(:longitude, presentation_scalar(location["longitude"]))
  end

  defp put_wanderer_location(fields, _location), do: fields

  defp put_wanderer_metrics(fields, tags) do
    Enum.reduce(@wanderer_metric_fields, fields, fn {name, key}, result ->
      put_presentation_scalar(result, key, wanderer_metric(tags, name))
    end)
  end

  defp wanderer_metric(tags, name) when is_list(tags) do
    tags
    |> Enum.find(fn
      %{"content" => content, "name" => ^name, "type" => "Note"}
      when is_binary(content) ->
        true

      _tag ->
        false
    end)
    |> then(fn
      %{"content" => content} -> presentation_scalar(content)
      _tag -> nil
    end)
  end

  defp wanderer_metric(_tags, _name), do: nil

  defp wanderer_gpx_url(attachments) when is_list(attachments) do
    Enum.find_value(attachments, fn
      %{} = attachment ->
        url = wanderer_media_url(attachment["url"] || attachment["href"])

        if wanderer_gpx_attachment?(attachment["mediaType"], url), do: url

      _attachment ->
        nil
    end)
  end

  defp wanderer_gpx_url(%{} = attachment), do: wanderer_gpx_url([attachment])
  defp wanderer_gpx_url(_attachments), do: nil

  defp wanderer_media_url(values) when is_list(values) do
    Enum.find_value(values, &wanderer_media_url/1)
  end

  defp wanderer_media_url(value) when is_binary(value), do: value
  defp wanderer_media_url(%{"href" => href}) when is_binary(href), do: href
  defp wanderer_media_url(%{"id" => id}) when is_binary(id), do: id
  defp wanderer_media_url(_value), do: nil

  defp wanderer_gpx_attachment?(media_type, url) when is_binary(url) do
    normalized_media_type =
      if is_binary(media_type), do: String.downcase(media_type), else: nil

    normalized_media_type in [
      "application/gpx",
      "application/gpx+xml",
      "application/xml+gpx"
    ] or
      (normalized_media_type == "application/octet-stream" and
         model_file_extension(url) == "gpx")
  end

  defp wanderer_gpx_attachment?(_media_type, _url), do: false

  defp neodb_related_activity?(%{"type" => type, "withRegardTo" => target})
       when type in ~w[Comment Note Rating Review Status] do
    is_binary(reference_id(target))
  end

  defp neodb_related_activity?(_activity), do: false

  defp neodb_catalog_tag(tags) when is_list(tags) do
    Enum.find(tags, &neodb_catalog_tag?/1)
  end

  defp neodb_catalog_tag(%{} = tag) do
    if neodb_catalog_tag?(tag), do: tag
  end

  defp neodb_catalog_tag(_tags), do: nil

  defp neodb_catalog_tag?(%{"type" => type} = tag) do
    short_type(type) in @neodb_catalog_types and
      is_binary(reference_id(tag["id"] || tag["href"]))
  end

  defp neodb_catalog_tag?(_tag), do: false

  defp related_scalar(related, type, field) do
    related
    |> Enum.find(&related_type?(&1, type))
    |> then(fn
      %{} = activity -> presentation_scalar(activity[field])
      _activity -> nil
    end)
  end

  defp related_reference(related, field) do
    related
    |> Enum.find_value(fn
      %{} = activity -> presentation_reference(activity[field])
      _activity -> nil
    end)
  end

  defp related_type_reference(related, type) do
    related
    |> Enum.find(&related_type?(&1, type))
    |> presentation_reference()
  end

  defp related_type?(%{"type" => value}, type), do: short_type(value) == type
  defp related_type?(_activity, _type), do: false

  defp put_presentation_scalar(fields, _key, nil), do: fields
  defp put_presentation_scalar(fields, key, value), do: Map.put(fields, key, value)

  defp put_presentation_reference(fields, _key, nil), do: fields
  defp put_presentation_reference(fields, key, value), do: Map.put(fields, key, value)

  defp presentation_scalar(value) when is_binary(value), do: value
  defp presentation_scalar(value) when is_number(value), do: value
  defp presentation_scalar(value) when is_boolean(value), do: value
  defp presentation_scalar(_value), do: nil

  defp presentation_reference(value) when is_list(value) do
    values =
      value
      |> Enum.map(&reference_id/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.take(20)

    if values == [], do: nil, else: values
  end

  defp presentation_reference(value), do: reference_id(value)

  defp authority_ids(value) when is_binary(value), do: [value]
  defp authority_ids(%{"id" => id}) when is_binary(id), do: [id]
  defp authority_ids(values) when is_list(values), do: Enum.flat_map(values, &authority_ids/1)
  defp authority_ids(_value), do: []

  defp reference_id(value) when is_binary(value), do: value
  defp reference_id(%{"id" => id}) when is_binary(id), do: id
  defp reference_id(_value), do: nil

  defp normalize_public(value) when value in ["Public", "as:Public"],
    do: Pleroma.Constants.as_public()

  defp normalize_public(value), do: value
end

# end of lib/pleroma/web/activity_pub/custom_object.ex
