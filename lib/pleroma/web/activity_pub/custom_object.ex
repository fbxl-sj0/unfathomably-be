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
    BookList Shelf ListItem ShelfItem
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
  @native_families ~w[books software models markets games routes culture coordination publishing]

  @presentation_scalar_fields %{
    "hashAfter" => :hash_after,
    "hashBefore" => :hash_before,
    "latestVersion" => :latest_version,
    "postingRestrictedToMods" => :posting_restricted_to_mods,
    "protected" => :protected,
    "rating" => :rating,
    "readingStatus" => :reading_status,
    "ref" => :ref,
    "relationship" => :relationship,
    "state" => :state,
    "verdict" => :verdict
  }

  @presentation_reference_fields %{
    "book" => :book,
    "edition" => :edition,
    "edits" => :edits,
    "inReplyToBook" => :in_reply_to_book,
    "managedBy" => :managed_by,
    "result" => :result,
    "target" => :target,
    "work" => :work
  }

  @type object_class :: String.t()

  @spec internal_field() :: String.t()
  def internal_field, do: @internal_field

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
    valueflows_class = valueflows_class(type)

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
      "type" => type
    }

    metadata =
      if Keyword.get(options, :local, false) do
        Map.put(metadata, "localAuthored", true)
      else
        metadata
      end

    Map.put(object, @internal_field, metadata)
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
    if custom_object?(object) or standard_extension_fields(object) != [] or
         not is_nil(wanderer_object_kind(object)) do
      %{
        canonical_id: object["id"],
        class: class(object),
        context: reference_id(object["context"]),
        controls: ["open"],
        fields: presentation_fields(object),
        type: object["type"]
      }
    end
  end

  def presentation(_object), do: nil

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
    |> put_wanderer_presentation_fields(object)
    |> put_castling_presentation_fields(object)
    |> put_flohmarkt_presentation_fields(object)
    |> put_unfathomably_presentation_fields(object)
  end

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
      |> put_presentation_reference(:reference, presentation_reference(object[@native_reference_field]))
    else
      fields
    end
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

  defp put_valueflows_presentation_fields(fields, %{"type" => type} = object) do
    case valueflows_name(type) do
      nil ->
        fields

      name ->
        fields
        |> Map.put(:platform, "bonfire_valueflows")
        |> Map.put(:valueflows_type, name)
        |> put_presentation_scalar(:action, valueflows_action(object["action"]))
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
      put_presentation_scalar(result, target, value_fun.(object[source]))
    end)
  end

  defp put_valueflows_quantities(fields, object) do
    Enum.reduce(@valueflows_quantity_fields, fields, fn
      {source, {value_key, unit_key}}, result ->
        case object[source] do
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

  defp valueflows_action("https://w3id.org/valueflows#" <> action),
    do: presentation_scalar(action)

  defp valueflows_action(action), do: presentation_scalar(action)

  defp valueflows_class(type) do
    case valueflows_name(type) do
      name when name in @valueflows_status_types -> "status"
      name when name in @valueflows_process_types -> "process"
      name when name in @valueflows_resource_types -> "resource"
      _name -> nil
    end
  end

  defp valueflows_name("ValueFlows:" <> name), do: known_valueflows_name(name)
  defp valueflows_name("https://w3id.org/valueflows#" <> name), do: known_valueflows_name(name)
  defp valueflows_name(_type), do: nil

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
    case flohmarkt_listing_data(object) do
      nil ->
        fields

      data ->
        fields
        |> Map.put(:platform, "flohmarkt")
        |> put_presentation_scalar(:listing_name, presentation_scalar(data["name"]))
        |> put_presentation_scalar(:price, presentation_scalar(data["price"]))
        |> put_presentation_scalar(:currency, presentation_scalar(data["currency"]))
        |> put_presentation_scalar(:original_id, presentation_scalar(data["original_id"]))
        |> put_flohmarkt_coordinates(data["coordinates"])
    end
  end

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
      %{"mediaType" => "application/xml+gpx", "url" => url} -> wanderer_media_url(url)
      _attachment -> nil
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
