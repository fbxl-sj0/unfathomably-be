# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.EventValidator do
  use Ecto.Schema

  alias Pleroma.Object.Containment
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonFixes
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonValidations
  alias Pleroma.Web.ActivityPub.Transmogrifier

  import Ecto.Changeset

  @primary_key false
  @derive Jason.Encoder

  # Extends from NoteValidator
  embedded_schema do
    quote do
      unquote do
        import Elixir.Pleroma.Web.ActivityPub.ObjectValidators.CommonFields
        message_fields()
        object_fields()
        status_object_fields()
        event_object_fields()
      end
    end
  end

  def cast_and_apply(data) do
    data
    |> cast_data
    |> apply_action(:insert)
  end

  def cast_and_validate(data) do
    data
    |> cast_data()
    |> validate_data()
  end

  def cast_data(data) do
    %__MODULE__{}
    |> changeset(data)
  end

  defp fix(data) do
    data
    |> CommonFixes.fix_actor()
    |> CommonFixes.fix_object_defaults()
    |> CommonFixes.fix_likes()
    |> fix_featured_image()
    |> fix_event_metadata()
    |> fix_location()
    |> Transmogrifier.fix_emoji()
  end

  # Mobilizon publishes the event banner as a top-level Image. Event storage
  # uses the common attachment shape, so normalize the image before schema
  # casting instead of silently dropping it or introducing event-only media.
  defp fix_featured_image(%{"image" => image} = data) do
    data = Map.delete(data, "image")

    case featured_image_attachment(image) do
      nil ->
        data

      image ->
        attachments =
          data
          |> Map.get("attachment", [])
          |> List.wrap()
          |> Enum.filter(&is_map/1)

        image_url = http_url(image["url"])

        attachments =
          if Enum.any?(attachments, &(attachment_url(&1) == image_url)) do
            attachments
          else
            [image | attachments]
          end

        data
        |> Map.put("attachment", attachments)
        |> Transmogrifier.fix_attachments()
    end
  end

  defp fix_featured_image(data), do: data

  defp featured_image_attachment(%{} = image) do
    case http_url(image["url"] || image["href"] || image["id"]) do
      nil ->
        nil

      url ->
        image
        |> Map.take(~w[type mediaType mimeType name summary blurhash width height])
        |> Map.put("type", "Image")
        |> Map.put("url", url)
    end
  end

  defp featured_image_attachment(image) when is_binary(image) do
    case http_url(image) do
      nil -> nil
      url -> %{"type" => "Image", "url" => url}
    end
  end

  defp featured_image_attachment(_image), do: nil

  defp attachment_url(%{} = attachment) do
    http_url(attachment["url"] || attachment["href"] || attachment["id"])
  end

  defp fix_location(%{"location" => locations} = data) when is_list(locations) do
    data = preserve_virtual_location(data, locations)

    case Enum.find(locations, &physical_location?/1) do
      nil -> Map.delete(data, "location")
      location -> Map.put(data, "location", location)
    end
  end

  # Mobilizon may publish a Place scaffold when an offline event has no venue
  # details yet. It is not a meaningful location and fails the Place contract,
  # so omit it rather than rejecting the otherwise valid public Event.
  defp fix_location(%{"location" => %{"type" => "Place"} = location} = data) do
    if useful_place?(location), do: data, else: Map.delete(data, "location")
  end

  defp fix_location(%{"location" => %{"type" => type}} = data) when type != "Place" do
    Map.delete(data, "location")
  end

  defp fix_location(data), do: data

  # Mobilizon historically used ical:status while Gancio and the developing
  # Event interoperability profile use eventStatus. Keep one bounded field in
  # storage so updates can reliably replace the event lifecycle.
  defp fix_event_metadata(data) do
    data
    |> normalize_event_status()
    |> normalize_event_category()
    |> normalize_online_address()
  end

  defp normalize_event_status(%{"eventStatus" => status} = data) when is_binary(status),
    do: data

  defp normalize_event_status(%{"ical:status" => status} = data) when is_binary(status),
    do: Map.put(data, "eventStatus", status)

  defp normalize_event_status(%{"status" => status} = data) when is_binary(status),
    do: Map.put(data, "eventStatus", status)

  defp normalize_event_status(data), do: data

  defp normalize_event_category(%{"category" => category} = data) when is_map(category) do
    case Enum.find_value(["name", "label", "id"], &text_value(category[&1])) do
      nil -> Map.delete(data, "category")
      value -> Map.put(data, "category", value)
    end
  end

  defp normalize_event_category(data), do: data

  defp normalize_online_address(%{"onlineAddress" => value} = data) do
    case http_url(value) do
      nil -> Map.delete(data, "onlineAddress")
      url -> Map.put(data, "onlineAddress", url)
    end
  end

  defp normalize_online_address(data), do: data

  # Gancio emits VirtualLocation and Place entries together. The Place is kept
  # for physical presentation while the virtual URL is retained separately so
  # clients can correctly describe an online or hybrid event.
  defp preserve_virtual_location(data, locations) do
    case Enum.find_value(locations, &virtual_location_url/1) do
      nil ->
        data

      url ->
        data
        |> Map.put("isOnline", true)
        |> Map.put_new("onlineAddress", url)
    end
  end

  defp virtual_location_url(%{"type" => "VirtualLocation"} = location) do
    http_url(location["url"]) || http_url(location["href"]) || http_url(location["id"])
  end

  defp virtual_location_url(_location), do: nil

  defp http_url(value) when is_binary(value) do
    value = String.trim(value)

    case {byte_size(value) <= 2_000, URI.parse(value)} do
      {true, %URI{scheme: scheme, host: host, userinfo: nil}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        value

      _ ->
        nil
    end
  end

  defp http_url(%{"href" => value}), do: http_url(value)
  defp http_url(%{"url" => value}), do: http_url(value)
  defp http_url(%{"id" => value}), do: http_url(value)

  defp http_url(values) when is_list(values) do
    Enum.find_value(values, &http_url/1)
  end

  defp http_url(_value), do: nil

  defp text_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp text_value(_value), do: nil

  defp physical_location?(%{"type" => "Place"} = location), do: useful_place?(location)
  defp physical_location?(_), do: false

  defp useful_place?(location) do
    Enum.any?(
      [
        location["name"],
        location["longitude"],
        location["latitude"],
        location["accuracy"],
        location["altitude"],
        location["radius"]
      ] ++ place_address_values(location["address"]),
      &present_location_value?/1
    )
  end

  # PlaceValidator normalizes Gancio's plain-text address after this usefulness
  # check. Inspect both wire shapes here without calling Access on a string.
  defp place_address_values(%{} = address) do
    [
      address["postalCode"],
      address["addressRegion"],
      address["streetAddress"],
      address["addressCountry"],
      address["addressLocality"]
    ]
  end

  defp place_address_values(address) when is_binary(address), do: [address]
  defp place_address_values(_address), do: []

  defp present_location_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_location_value?(value) when is_number(value), do: true
  defp present_location_value?(_value), do: false

  def changeset(struct, data) do
    data = fix(data)

    struct
    |> cast(data, __schema__(:fields) -- [:attachment, :tag, :location])
    |> cast_embed(:attachment)
    |> cast_embed(:tag)
    |> cast_embed(:location)
  end

  defp validate_data(data_cng) do
    data_cng
    |> validate_inclusion(:type, ["Event"])
    |> validate_inclusion(:joinMode, ~w[free restricted invite])
    |> validate_length(:eventStatus, max: 100)
    |> validate_length(:eventAttendanceMode, max: 200)
    |> validate_length(:category, max: 200)
    |> validate_length(:onlineAddress, max: 2_000)
    |> validate_length(:timezone, max: 100)
    |> validate_number(:maximumAttendeeCapacity, greater_than_or_equal_to: 0)
    |> validate_number(:remainingAttendeeCapacity, greater_than_or_equal_to: 0)
    |> validate_number(:participantCount, greater_than_or_equal_to: 0)
    |> validate_required([:id, :actor, :attributedTo, :type, :context])
    |> CommonValidations.validate_any_presence([:cc, :to])
    |> validate_event_attribution()
    |> CommonValidations.validate_actor_presence()
    |> CommonValidations.validate_host_match()
  end

  defp validate_event_attribution(changeset) do
    actor = get_field(changeset, :actor)
    attributed_to = get_field(changeset, :attributedTo)

    cond do
      actor == attributed_to ->
        changeset

      valid_group_attribution?(actor, attributed_to) ->
        changeset

      is_binary(actor) and is_binary(attributed_to) ->
        add_error(changeset, :attributedTo, "must match actor or identify a same-host Group")

      true ->
        changeset
    end
  end

  defp valid_group_attribution?(actor, attributed_to)
       when is_binary(actor) and is_binary(attributed_to) do
    Containment.contain_origin(attributed_to, %{"actor" => actor}) == :ok and
      match?(%User{actor_type: "Group"}, User.get_cached_by_ap_id(attributed_to))
  end

  defp valid_group_attribution?(_actor, _attributed_to), do: false
end
