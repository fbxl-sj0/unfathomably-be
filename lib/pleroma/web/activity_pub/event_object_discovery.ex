# Project: Unfathomably
# File: event_object_discovery.ex
# Purpose: Search public Event objects already received through federation.
#
# Responsibilities:
# - search accepted Event objects through a dedicated PostgreSQL text index
# - preserve schedule, Place, organizer, attendance, and access metadata
# - expose source and local-resolution identities without remote index access
#
# This file intentionally does not refresh events, crawl organizers, or submit
# attendance activities while a user is browsing discovery results.

defmodule Pleroma.Web.ActivityPub.EventObjectDiscovery do
  @moduledoc """
  Local-first discovery for received ActivityStreams Event objects.

  Event validation already normalizes Mobilizon-style Place arrays and rejects
  empty venue scaffolds. Discovery can therefore present accepted event data
  without contacting Mobilizon, Gancio, or an event organizer.
  """

  import Ecto.Query

  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.MediaProxy

  @public "https://www.w3.org/ns/activitystreams#Public"
  @default_limit 12
  @maximum_limit 20
  @maximum_offset 5_000

  @spec search(map()) :: map()
  def search(params) when is_map(params) do
    query = params |> Map.get("q", "") |> string_value() |> String.trim()
    limit = bounded_integer(Map.get(params, "limit"), @default_limit, 1, @maximum_limit)
    offset = bounded_integer(Map.get(params, "offset"), 0, 0, @maximum_offset)

    normalized =
      if query == "" or String.length(query) >= 2 do
        query
        |> search_query(limit + 1, offset)
        |> Repo.all(timeout: 30_000)
        |> Enum.map(&normalize_result/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(& &1["activitypub_url"])
        |> hydrate_event_actors()
      else
        []
      end

    has_more = length(normalized) > limit
    items = Enum.take(normalized, limit)

    %{
      "items" => items,
      "has_more" => has_more,
      "next_offset" => if(has_more, do: offset + limit),
      "providers" => [
        %{
          "type" => "local_federation_cache",
          "host" => local_host(),
          "status" => "ready"
        }
      ]
    }
  end

  defp search_query(query, limit, offset) do
    public_recipient = @public

    Activity
    |> join(:inner, [activity], object in Object,
      on:
        fragment(
          "(?->>'id') = associated_object_id(?)",
          object.data,
          activity.data
        )
    )
    |> where([activity, _object], activity.local == false)
    |> where([activity, _object], fragment("?->>'type' = 'Create'", activity.data))
    |> where([_activity, object], fragment("?->>'type' = 'Event'", object.data))
    |> where(
      [_activity, object],
      fragment(
        """
        jsonb_exists(coalesce(?->'to', '[]'::jsonb), ?) OR
        jsonb_exists(coalesce(?->'cc', '[]'::jsonb), ?) OR
        ?->>'to' = ? OR
        ?->>'cc' = ?
        """,
        object.data,
        ^public_recipient,
        object.data,
        ^public_recipient,
        object.data,
        ^@public,
        object.data,
        ^@public
      )
    )
    |> where(
      [_activity, object],
      fragment(
        """
        coalesce(
          nullif(?->>'endTime', ''),
          nullif(?->>'startTime', '')
        )::timestamptz >= now()
        """,
        object.data,
        object.data
      )
    )
    |> maybe_match_query(query)
    |> order_by(
      [_activity, object],
      asc: fragment("(?->>'startTime')::timestamptz", object.data)
    )
    |> order_by([activity, _object], desc: activity.id)
    |> limit(^limit)
    |> offset(^offset)
    |> select([activity, object], {activity, object})
  end

  defp maybe_match_query(query, ""), do: query

  defp maybe_match_query(query, search) do
    where(
      query,
      [_activity, object],
      fragment(
        "unfathomably_event_search_document(?) @@ websearch_to_tsquery('simple', ?)",
        object.data,
        ^search
      )
    )
  end

  defp normalize_result({activity, object}) do
    data = object.data || %{}
    title = first_present(data, ["name", "title"])
    begins_at = first_present(data, ["startTime", "beginsOn", "start"])
    activitypub_url = reference_url(data["id"])
    source_url = reference_url(data["url"]) || activitypub_url
    actor = data["attributedTo"] || data["actor"] || activity.data["actor"]
    actor_url = reference_url(actor)
    status = event_status(data)
    attendance_mode = attendance_mode(data, actor_url)

    if title && begins_at && activitypub_url && source_url do
      %{
        "id" => activity.id,
        "family" => "event",
        "kind" => "received_event",
        "title" => title,
        "summary" =>
          data |> first_present(["summary", "content"]) |> plain_text() |> truncate(800),
        "url" => source_url,
        "activitypub_url" => activitypub_url,
        "image_url" => data |> image_url() |> proxied_media_url(),
        "begins_at" => begins_at,
        "ends_at" => first_present(data, ["endTime", "endsOn", "end"]),
        "source_host" => source_host(source_url),
        "online" => online_event?(data),
        "online_url" => online_event_url(data),
        "participation_url" => reference_url(data["externalParticipationUrl"]),
        "phone_address" => first_present(data, ["phoneAddress"]),
        "timezone" => first_present(data, ["timezone"]),
        "language" => first_present(data, ["inLanguage", "language"]),
        "capacity" => non_negative_integer(data["maximumAttendeeCapacity"]),
        "remaining_capacity" => non_negative_integer(data["remainingAttendeeCapacity"]),
        "participant_count" => participant_count(data),
        "join_mode" => attendance_mode,
        "attendance_mode" => first_present(data, ["eventAttendanceMode"]),
        "anonymous_participation" => data["anonymousParticipationEnabled"] == true,
        "comments_enabled" => boolean_value(data["commentsEnabled"]),
        "replies_moderation" => first_present(data, ["repliesModerationOption"]),
        "replies_url" => reference_url(data["replies"]),
        "status" => status,
        "lifecycle" =>
          event_lifecycle(
            status,
            begins_at,
            first_present(data, ["endTime", "endsOn", "end"])
          ),
        "category" => category_label(data["category"]),
        "tags" => hashtag_names(data["tag"]),
        "location" => location(data["location"]),
        "organizer" => organizer(actor, actor_url),
        "contacts" => event_contacts(data["contacts"]),
        "published_at" => first_present(data, ["published"]),
        "local_action" => "resolve"
      }
    end
  end

  defp normalize_result(_), do: nil

  defp hydrate_event_actors([]), do: []

  defp hydrate_event_actors(items) do
    actor_urls =
      items
      |> Enum.flat_map(fn item ->
        [get_in(item, ["organizer", "url"])] ++
          Enum.map(item["contacts"] || [], & &1["url"])
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.take(100)

    actors =
      if actor_urls == [] do
        %{}
      else
        User
        |> where(
          [user],
          user.ap_id in ^actor_urls and user.local == false and user.is_active == true
        )
        |> Repo.all(timeout: 30_000)
        |> Map.new(&{&1.ap_id, &1})
      end

    Enum.map(items, fn item ->
      item
      |> Map.update!("organizer", &hydrate_event_actor(&1, actors))
      |> Map.update!("contacts", fn contacts ->
        Enum.map(contacts, &hydrate_event_actor(&1, actors))
      end)
    end)
  end

  defp hydrate_event_actor(%{"url" => url} = actor, actors) do
    case actors[url] do
      %User{} = user ->
        actor
        |> Map.put("id", to_string(user.id))
        |> Map.put("name", clean_text(user.name, 300) || actor["name"])
        |> Map.put("handle", organizer_handle(user))

      _ ->
        actor
    end
  end

  defp hydrate_event_actor(actor, _actors), do: actor

  defp location(%{"type" => "Place"} = place) do
    address = if is_map(place["address"]), do: place["address"], else: %{}

    %{
      "name" => first_present(place, ["name"]),
      "street_address" => first_present(address, ["streetAddress"]),
      "postal_code" => first_present(address, ["postalCode"]),
      "locality" => first_present(address, ["addressLocality", "locality"]),
      "region" => first_present(address, ["addressRegion", "region"]),
      "country" => first_present(address, ["addressCountry", "country"]),
      "latitude" => coordinate(place["latitude"], -90.0, 90.0),
      "longitude" => coordinate(place["longitude"], -180.0, 180.0)
    }
  end

  defp location(_), do: %{}

  defp organizer(actor, actor_url) when is_map(actor) do
    username = first_present(actor, ["preferredUsername"])
    host = source_host(actor_url)

    %{
      "name" => first_present(actor, ["name"]) || username || host,
      "handle" => organizer_handle(username, host),
      "url" => actor_url
    }
  end

  defp organizer(_actor, actor_url) do
    %{
      "name" => source_host(actor_url),
      "handle" => nil,
      "url" => actor_url
    }
  end

  defp organizer_handle(username, host) when is_binary(username) and is_binary(host),
    do: "@#{username}@#{host}"

  defp organizer_handle(_username, _host), do: nil

  defp organizer_handle(%User{} = user) do
    case User.full_nickname(user) do
      nickname when is_binary(nickname) and nickname != "" ->
        "@" <> String.trim_leading(nickname, "@")

      _ ->
        nil
    end
  end

  defp event_contacts(contacts) do
    contacts
    |> List.wrap()
    |> Enum.map(fn contact ->
      case reference_url(contact) do
        url when is_binary(url) -> organizer(contact, url)
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1["url"])
    |> Enum.take(8)
  end

  defp participant_count(data) do
    non_negative_integer(data["participantCount"]) ||
      non_negative_integer(data["participation_count"]) ||
      collection_count(data["attendees"]) ||
      collection_count(data["participants"])
  end

  defp collection_count(collection) when is_map(collection) do
    non_negative_integer(collection["totalItems"])
  end

  defp collection_count(_), do: nil

  defp category_label(value) when is_binary(value), do: clean_text(value, 100)
  defp category_label(value) when is_map(value), do: first_present(value, ["label", "name", "id"])
  defp category_label(_), do: nil

  defp event_status(data) do
    first_present(data, ["eventStatus", "status", "ical:status"])
  end

  defp attendance_mode(data, actor_url) do
    case first_present(data, ["joinMode"]) do
      "free" = mode -> if(gancio_service_actor?(actor_url), do: nil, else: mode)
      mode -> mode
    end
  end

  defp gancio_service_actor?(actor_url) when is_binary(actor_url) do
    case URI.parse(actor_url) do
      %URI{path: "/federation"} -> true
      _ -> false
    end
  end

  defp gancio_service_actor?(_actor_url), do: false

  defp online_event?(data) do
    data["isOnline"] == true ||
      is_binary(online_event_url(data)) ||
      online_attendance_mode?(data["eventAttendanceMode"])
  end

  defp online_event_url(data) do
    reference_url(data["onlineAddress"]) || online_attachment_url(data["attachment"])
  end

  defp online_attachment_url(attachments) do
    attachments
    |> List.wrap()
    |> Enum.find_value(fn
      %{"type" => "Link"} = attachment ->
        name = attachment |> first_present(["name"]) |> to_string_value() |> String.downcase()
        media_type = attachment |> first_present(["mediaType"]) |> to_string_value()

        if media_type == "text/html" and
             (String.contains?(name, "website") or String.contains?(name, "online")) do
          reference_url(attachment)
        end

      _ ->
        nil
    end)
  end

  defp online_attendance_mode?(mode) when is_binary(mode) do
    mode = String.downcase(mode)
    String.contains?(mode, "online") or String.contains?(mode, "mixed")
  end

  defp online_attendance_mode?(_mode), do: false

  defp event_lifecycle(status, begins_at, ends_at) do
    normalized = status |> to_string_value() |> String.downcase()

    cond do
      String.contains?(normalized, "cancel") -> "cancelled"
      String.contains?(normalized, "postpon") -> "postponed"
      String.contains?(normalized, "reschedul") -> "rescheduled"
      String.contains?(normalized, "tentative") -> "tentative"
      true -> schedule_lifecycle(begins_at, ends_at)
    end
  end

  defp schedule_lifecycle(begins_at, ends_at) do
    now = DateTime.utc_now()

    case {parse_datetime(begins_at), parse_datetime(ends_at)} do
      {{:ok, begins}, {:ok, ends}} ->
        cond do
          DateTime.compare(ends, now) == :lt -> "past"
          DateTime.compare(begins, now) in [:lt, :eq] -> "ongoing"
          true -> "upcoming"
        end

      {{:ok, begins}, :error} ->
        if DateTime.compare(begins, now) == :gt, do: "upcoming", else: "ongoing"

      _ ->
        "unknown"
    end
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp parse_datetime(_value), do: :error

  defp coordinate(value, minimum, maximum) when is_number(value) do
    if value >= minimum and value <= maximum, do: value
  end

  defp coordinate(_value, _minimum, _maximum), do: nil

  defp boolean_value(value) when is_boolean(value), do: value
  defp boolean_value(_value), do: nil

  defp image_url(data) do
    reference_url(data["image"]) ||
      reference_url(data["icon"]) ||
      reference_url(data["banner"]) ||
      attachment_image(data["attachment"])
  end

  defp attachment_image(attachments) do
    attachments
    |> List.wrap()
    |> Enum.find_value(fn
      %{"mediaType" => media_type} = attachment when is_binary(media_type) ->
        if String.starts_with?(String.downcase(media_type), "image/") do
          reference_url(attachment)
        end

      %{"type" => "Image"} = attachment ->
        reference_url(attachment)

      _ ->
        nil
    end)
  end

  defp proxied_media_url(nil), do: nil
  defp proxied_media_url(url), do: MediaProxy.browser_url(url)

  defp hashtag_names(tags) do
    tags
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"type" => "Hashtag", "name" => name} when is_binary(name) ->
        [name |> String.trim_leading("#") |> clean_text(80)]

      %{"name" => name} when is_binary(name) ->
        [name |> String.trim_leading("#") |> clean_text(80)]

      name when is_binary(name) ->
        [name |> String.trim_leading("#") |> clean_text(80)]

      _ ->
        []
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(12)
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _ -> nil
    end
  end

  defp non_negative_integer(_), do: nil

  defp first_present(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case map[key] do
        value when is_binary(value) -> clean_text(value, 500)
        _ -> nil
      end
    end)
  end

  defp first_present(_, _), do: nil

  defp reference_url(value) when is_binary(value) do
    value = String.trim(value)

    with true <- byte_size(value) <= 2_048,
         %URI{scheme: scheme, host: host, userinfo: nil} <- URI.parse(value),
         true <- scheme in ["http", "https"],
         true <- is_binary(host) and host != "" do
      value
    else
      _ -> nil
    end
  end

  defp reference_url(%{"url" => value}), do: reference_url(value)
  defp reference_url(%{"href" => value}), do: reference_url(value)
  defp reference_url(%{"id" => value}), do: reference_url(value)

  defp reference_url(values) when is_list(values) do
    Enum.find_value(values, &reference_url/1)
  end

  defp reference_url(_), do: nil

  defp plain_text(value) when is_binary(value) do
    value
    |> Pleroma.HTML.strip_non_content()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> blank_to_nil()
  end

  defp plain_text(_), do: nil

  defp clean_text(value, maximum) when is_binary(value) do
    value
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> truncate(maximum)
    |> blank_to_nil()
  end

  defp clean_text(_, _), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp truncate(nil, _maximum), do: nil
  defp truncate(value, maximum) when byte_size(value) <= maximum, do: value

  defp truncate(value, maximum) do
    value
    |> String.slice(0, maximum)
    |> Kernel.<>("...")
  end

  defp source_host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> String.downcase(host)
      _ -> nil
    end
  end

  defp source_host(_), do: nil

  defp bounded_integer(value, default, minimum, maximum) do
    parsed =
      case value do
        value when is_integer(value) ->
          value

        value when is_binary(value) ->
          case Integer.parse(value) do
            {integer, ""} -> integer
            _ -> default
          end

        _ ->
          default
      end

    parsed
    |> max(minimum)
    |> min(maximum)
  end

  defp string_value(value) when is_binary(value), do: value
  defp string_value(_), do: ""

  defp to_string_value(value) when is_binary(value), do: value
  defp to_string_value(_value), do: ""

  defp local_host do
    Config.get([Pleroma.Web.Endpoint, :url, :host], "local")
  end
end

# end of event_object_discovery.ex
