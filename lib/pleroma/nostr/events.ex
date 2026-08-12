# Unfathomably BE
# ----------------
#
# File: nostr/events.ex
#
# Purpose:
#   Translate NIP-52 calendar events and NIP-53 live activities.
#
# Responsibilities:
#   - validate bounded event, live-chat, and RSVP event shapes
#   - project calendar and live announcements into ActivityPub Event objects
#   - preserve banners, locations, stream links, and participation metadata
#   - publish local Event objects, replies, and accepted joins in Nostr form
#
# This file intentionally does NOT implement recurring calendars, meeting-space
# access control, room presence, or automatic attendance authorization.

defmodule Pleroma.Nostr.Events do
  alias Pleroma.Activity
  alias Pleroma.Nostr.Event
  alias Pleroma.Nostr.Identity
  alias Pleroma.Nostr.Protocol
  alias Pleroma.Nostr.Store
  alias Pleroma.Web.CommonAPI

  @calendar_kinds [31_922, 31_923]
  @live_kind 30_311
  @live_chat_kind 1_311
  @rsvp_kind 31_925
  @rsvp_statuses ~w(accepted declined tentative)
  @live_statuses ~w(planned live ended)
  @max_identifier_bytes 256
  @max_title_chars 500
  @max_summary_chars 2_000
  @max_location_chars 500
  @max_event_days 366

  def validate(%{"kind" => 31_922} = event), do: validate_date_event(event)
  def validate(%{"kind" => 31_923} = event), do: validate_time_event(event)
  def validate(%{"kind" => @live_kind} = event), do: validate_live_event(event)
  def validate(_event), do: invalid("invalid calendar or live event")

  def validate_chat(%{"kind" => @live_chat_kind} = event) do
    with {:ok, {@live_kind, _pubkey, _identifier}} <-
           event |> Protocol.tag_value("a") |> parse_coordinate() do
      :ok
    else
      _coordinate -> invalid("live chat requires a valid live activity address")
    end
  end

  def validate_chat(_event), do: invalid("invalid live chat event")

  def validate_rsvp(%{"kind" => @rsvp_kind} = event) do
    with {:ok, {kind, _pubkey, _identifier}} when kind in @calendar_kinds <-
           event |> Protocol.tag_value("a") |> parse_coordinate(),
         identifier when is_binary(identifier) <- Protocol.tag_value(event, "d"),
         true <- valid_identifier?(identifier),
         status when status in @rsvp_statuses <- Protocol.tag_value(event, "status") do
      :ok
    else
      _value -> invalid("RSVP requires an event address, identifier, and supported status")
    end
  end

  def validate_rsvp(_event), do: invalid("invalid calendar RSVP")

  def put_inbound_params(params, %{"kind" => @live_chat_kind} = event) when is_map(params) do
    case referenced_event(event) do
      %Event{ap_activity_id: activity_id} when not is_nil(activity_id) ->
        Map.put_new(params, :in_reply_to_status_id, activity_id)

      _event ->
        params
    end
  end

  def put_inbound_params(params, _event), do: params

  def put_object_metadata(object, %{"kind" => kind} = event) when kind in @calendar_kinds do
    event_data = calendar_object_data(event)

    object
    |> Map.merge(event_data)
    |> put_event_attachments(event)
  end

  def put_object_metadata(object, %{"kind" => @live_kind} = event) do
    event_data = live_object_data(event)

    object
    |> Map.merge(event_data)
    |> put_event_attachments(event)
  end

  def put_object_metadata(object, _event), do: object

  def outbound_destination(destination, %{"type" => "Event"} = object) do
    if live_object?(object) do
      live_destination(destination, object)
    else
      calendar_destination(destination, object)
    end
  end

  def outbound_destination(destination, %{"inReplyTo" => parent_id} = object)
      when is_binary(parent_id) do
    chat_destination(destination, object, Store.get_by_ap_object_id(parent_id))
  end

  def outbound_destination(destination, _object), do: destination

  def outbound_rsvp(%Activity{data: %{"type" => "Join", "object" => object_id} = data})
      when is_binary(object_id) do
    with %Event{kind: kind} = target <- Store.get_by_ap_object_id(object_id),
         true <- kind in @calendar_kinds,
         coordinate when is_binary(coordinate) <- event_coordinate(target),
         actor when is_binary(actor) <- data["actor"] do
      relay = target.relay_url || ""

      tags = [
        ["d", stable_identifier("#{actor}\n#{coordinate}")],
        ["a", coordinate, relay],
        ["e", target.id, relay],
        ["status", "accepted"],
        ["p", target.pubkey, relay]
      ]

      {:ok, tags, destination_relays(target), bounded_text(data["content"], @max_summary_chars)}
    else
      _target -> {:error, :not_calendar_event}
    end
  end

  def outbound_rsvp(_activity), do: {:error, :not_calendar_event}

  def import_rsvp(event, stored, relay_url) do
    case Protocol.tag_value(event, "status") do
      "accepted" -> import_accepted_rsvp(event, stored, relay_url)
      _status -> :ok
    end
  end

  defp import_accepted_rsvp(event, stored, relay_url) do
    with {:ok, actor} <-
           Identity.resolve(%{type: :profile, pubkey: event["pubkey"], relays: [relay_url]}),
         %Event{ap_activity_id: activity_id, ap_object_id: object_id}
         when not is_nil(activity_id) <- referenced_event(event),
         {:ok, %Activity{} = activity} <-
           CommonAPI.join(actor, activity_id, %{
             participation_message: bounded_text(event["content"], @max_summary_chars)
           }) do
      Store.map_activity(stored.id, activity.id, object_id)
    else
      # Declined/tentative responses and duplicate joins remain queryable Nostr
      # events without fabricating an ActivityPub attendance state.
      _error -> :ok
    end
  end

  defp validate_date_event(event) do
    with :ok <- validate_common_event(event),
         {:ok, start_date} <- event |> Protocol.tag_value("start") |> parse_date(),
         :ok <- validate_optional_end_date(start_date, Protocol.tag_value(event, "end")) do
      :ok
    else
      _value -> invalid("date event requires valid start and end dates")
    end
  end

  defp validate_time_event(event) do
    with :ok <- validate_common_event(event),
         {:ok, start_time} <- event |> Protocol.tag_value("start") |> parse_timestamp(),
         :ok <- validate_optional_end_time(start_time, Protocol.tag_value(event, "end")) do
      :ok
    else
      _value -> invalid("time event requires valid start and end timestamps")
    end
  end

  defp validate_live_event(event) do
    identifier = Protocol.tag_value(event, "d")
    status = Protocol.tag_value(event, "status")

    cond do
      not valid_identifier?(identifier) ->
        invalid("live activity requires a valid identifier")

      is_binary(status) and status not in @live_statuses ->
        invalid("live activity status is invalid")

      not valid_optional_url?(Protocol.tag_value(event, "streaming")) ->
        invalid("stream URL is invalid")

      not valid_optional_url?(Protocol.tag_value(event, "recording")) ->
        invalid("recording URL is invalid")

      true ->
        :ok
    end
  end

  defp validate_common_event(event) do
    identifier = Protocol.tag_value(event, "d")
    title = Protocol.tag_value(event, "title") || Protocol.tag_value(event, "name")

    cond do
      not valid_identifier?(identifier) ->
        invalid("calendar event requires a valid identifier")

      not is_binary(title) or String.length(title) not in 1..@max_title_chars ->
        invalid("calendar event requires a bounded title")

      true ->
        :ok
    end
  end

  defp calendar_object_data(%{"kind" => 31_922} = event) do
    %{
      "type" => "Event",
      "name" => event_title(event),
      "summary" => bounded_tag(event, "summary", @max_summary_chars),
      "startTime" => date_to_iso(Protocol.tag_value(event, "start")),
      "endTime" => date_to_iso(Protocol.tag_value(event, "end")),
      "joinMode" => "free",
      "location" => event_location(event),
      "unfathomably:allDay" => true
    }
    |> compact_map()
  end

  defp calendar_object_data(event) do
    %{
      "type" => "Event",
      "name" => event_title(event),
      "summary" => bounded_tag(event, "summary", @max_summary_chars),
      "startTime" => timestamp_to_iso(Protocol.tag_value(event, "start")),
      "endTime" => timestamp_to_iso(Protocol.tag_value(event, "end")),
      "joinMode" => "free",
      "location" => event_location(event)
    }
    |> compact_map()
  end

  defp live_object_data(event) do
    status = Protocol.tag_value(event, "status") || "planned"
    streaming = valid_url(Protocol.tag_value(event, "streaming"))
    recording = valid_url(Protocol.tag_value(event, "recording"))

    %{
      "type" => "Event",
      "name" => bounded_tag(event, "title", @max_title_chars) || "Nostr live activity",
      "summary" => bounded_tag(event, "summary", @max_summary_chars),
      "startTime" => timestamp_to_iso(Protocol.tag_value(event, "starts")),
      "endTime" => timestamp_to_iso(Protocol.tag_value(event, "ends")),
      "joinMode" => "free",
      "url" => streaming || recording,
      "streaming" => streaming,
      "recording" => recording,
      "eventStatus" => status,
      "isLiveBroadcast" => status == "live",
      "participation_count" => bounded_integer_tag(event, "current_participants"),
      "https://unfathomably.social/ns#family" => "video",
      "https://unfathomably.social/ns#kind" => "live_stream",
      "https://unfathomably.social/ns#detail" => status,
      "https://unfathomably.social/ns#reference" => streaming || recording
    }
    |> compact_map()
  end

  defp put_event_attachments(object, event) do
    attachments =
      [
        image_attachment(valid_url(Protocol.tag_value(event, "image"))),
        link_attachment("Live stream", valid_url(Protocol.tag_value(event, "streaming"))),
        link_attachment("Recording", valid_url(Protocol.tag_value(event, "recording")))
      ]
      |> Enum.reject(&is_nil/1)

    existing = object |> Map.get("attachment", []) |> List.wrap()
    Map.put(object, "attachment", Enum.uniq_by(existing ++ attachments, &attachment_url/1))
  end

  defp calendar_destination(destination, object) do
    with {:ok, start_time} <- parse_iso_datetime(object["startTime"]) do
      end_time = parse_optional_iso_datetime(object["endTime"])
      relays = destination_relays(destination)

      tags =
        destination_tags(destination) ++
          [
            ["d", stable_identifier(object["id"] || object["name"] || inspect(object))],
            ["title", bounded_text(object["name"], @max_title_chars)],
            ["start", to_string(DateTime.to_unix(start_time))]
          ] ++
          optional_tag("end", end_time && DateTime.to_unix(end_time)) ++
          optional_tag("summary", bounded_text(object["summary"], @max_summary_chars)) ++
          optional_tag("image", object_image(object)) ++
          optional_tag("location", object_location(object)) ++
          day_tags(start_time, end_time)

      {31_923, tags, relays}
    else
      _start -> destination
    end
  end

  defp live_destination(destination, object) do
    relays = destination_relays(destination)
    starts = parse_optional_iso_datetime(object["startTime"])
    ends = parse_optional_iso_datetime(object["endTime"])
    streaming = live_stream_url(object)
    recording = valid_url(object["recording"])
    status = live_status(object, ends)

    tags =
      destination_tags(destination) ++
        [
          ["d", stable_identifier(object["id"] || object["name"] || inspect(object))],
          ["title", bounded_text(object["name"], @max_title_chars) || "Live activity"],
          ["status", status]
        ] ++
        optional_tag("summary", bounded_text(object["summary"], @max_summary_chars)) ++
        optional_tag("image", object_image(object)) ++
        optional_tag("streaming", streaming) ++
        optional_tag("recording", recording) ++
        optional_tag("starts", starts && DateTime.to_unix(starts)) ++
        optional_tag("ends", ends && DateTime.to_unix(ends)) ++
        live_relay_tags(relays)

    {@live_kind, tags, relays}
  end

  defp chat_destination(destination, _object, %Event{kind: kind} = target)
       when kind in [@live_kind, @live_chat_kind] do
    root = if target.kind == @live_kind, do: target, else: referenced_event(target.data)

    case event_coordinate(root) do
      coordinate when is_binary(coordinate) ->
        relay = target.relay_url || root.relay_url || ""
        root_tag = ["a", coordinate, relay, "root"]
        reply_tags = if target.kind == @live_chat_kind, do: [["e", target.id, relay]], else: []
        {@live_chat_kind, [root_tag | reply_tags], destination_relays(target)}

      _coordinate ->
        destination
    end
  end

  defp chat_destination(destination, _object, _target), do: destination

  defp referenced_event(event) do
    case Protocol.tag_value(event, "e") do
      event_id when is_binary(event_id) -> Store.get(event_id) || referenced_address(event)
      _event_id -> referenced_address(event)
    end
  end

  defp referenced_address(event) do
    with {:ok, {kind, pubkey, identifier}} <-
           event |> Protocol.tag_value("a") |> parse_coordinate(),
         [target | _events] <-
           Store.query([
             %{"kinds" => [kind], "authors" => [pubkey], "#d" => [identifier], "limit" => 1}
           ]) do
      target
    else
      _target -> nil
    end
  end

  defp event_coordinate(%Event{kind: kind, pubkey: pubkey, data: data}) do
    case Protocol.tag_value(data, "d") do
      identifier when is_binary(identifier) -> "#{kind}:#{pubkey}:#{identifier}"
      _identifier -> nil
    end
  end

  defp event_coordinate(_event), do: nil

  defp parse_coordinate(value) when is_binary(value) do
    case String.split(value, ":", parts: 3) do
      [kind, pubkey, identifier] ->
        with {kind, ""} <- Integer.parse(kind),
             true <- Regex.match?(~r/^[0-9a-f]{64}$/, pubkey),
             true <- valid_identifier?(identifier) do
          {:ok, {kind, pubkey, identifier}}
        else
          _value -> {:error, :invalid_coordinate}
        end

      _parts ->
        {:error, :invalid_coordinate}
    end
  end

  defp parse_coordinate(_value), do: {:error, :invalid_coordinate}

  defp event_title(event) do
    bounded_tag(event, "title", @max_title_chars) ||
      bounded_tag(event, "name", @max_title_chars) || "Calendar event"
  end

  defp event_location(event) do
    names =
      event
      |> Protocol.tag_values("location")
      |> Enum.map(&bounded_text(&1, @max_location_chars))
      |> Enum.reject(&is_nil/1)
      |> Enum.take(4)

    case names do
      [] -> nil
      names -> %{"type" => "Place", "name" => Enum.join(names, " / ")}
    end
  end

  defp image_attachment(nil), do: nil

  defp image_attachment(url) do
    %{
      "type" => "Image",
      "mediaType" => "image/*",
      "name" => "Event banner",
      "url" => [%{"href" => url}]
    }
  end

  defp link_attachment(_name, nil), do: nil

  defp link_attachment(name, url) do
    %{
      "type" => "Document",
      "mediaType" => "text/html",
      "name" => name,
      "url" => [%{"href" => url}]
    }
  end

  defp attachment_url(%{"url" => [%{"href" => href} | _rest]}), do: href
  defp attachment_url(%{"url" => href}) when is_binary(href), do: href
  defp attachment_url(attachment), do: inspect(attachment)

  defp object_image(object) do
    object
    |> Map.get("attachment", [])
    |> List.wrap()
    |> Enum.find_value(fn
      %{"type" => "Image"} = attachment ->
        attachment_url(attachment) |> valid_url()

      %{"mediaType" => "image/" <> _rest} = attachment ->
        attachment_url(attachment) |> valid_url()

      _attachment ->
        nil
    end)
  end

  defp object_location(%{"location" => %{"name" => name}}),
    do: bounded_text(name, @max_location_chars)

  defp object_location(_object), do: nil

  defp live_object?(object) do
    object["isLiveBroadcast"] == true or object["is_live_broadcast"] == true or
      is_binary(object["streaming"]) or object["eventStatus"] == "live"
  end

  defp live_stream_url(object) do
    valid_url(object["streaming"]) || valid_url(object["embedUrl"]) ||
      valid_url(object["embed_url"]) || valid_url(object["url"])
  end

  defp live_status(object, ends) do
    status = object["eventStatus"] || object["status"]

    cond do
      status in @live_statuses -> status
      object["isLiveBroadcast"] == true or object["is_live_broadcast"] == true -> "live"
      match?(%DateTime{}, ends) and DateTime.compare(ends, DateTime.utc_now()) == :lt -> "ended"
      true -> "planned"
    end
  end

  defp live_relay_tags([]), do: []
  defp live_relay_tags(relays), do: [["relays" | Enum.take(relays, 8)]]

  defp day_tags(start_time, end_time) do
    first_day = div(DateTime.to_unix(start_time), 86_400)
    last_day = if end_time, do: div(DateTime.to_unix(end_time), 86_400), else: first_day

    first_day..min(last_day, first_day + @max_event_days - 1)
    |> Enum.map(&["D", to_string(&1)])
  end

  defp destination_tags({_kind, tags, _relays}), do: List.wrap(tags)
  defp destination_relays({_kind, _tags, relays}), do: List.wrap(relays)

  defp destination_relays(%Event{relay_url: relay_url, data: data}) do
    ([relay_url] ++ Protocol.tag_values(data, "relay") ++ Protocol.tag_values(data, "relays"))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp optional_tag(_key, nil), do: []
  defp optional_tag(_key, ""), do: []
  defp optional_tag(key, value), do: [[key, to_string(value)]]

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_value), do: {:error, :invalid_date}

  defp validate_optional_end_date(_start_date, nil), do: :ok

  defp validate_optional_end_date(start_date, end_value) do
    with {:ok, end_date} <- parse_date(end_value),
         comparison when comparison in [:lt, :eq] <- Date.compare(start_date, end_date) do
      :ok
    else
      _value -> {:error, :invalid_end_date}
    end
  end

  defp parse_timestamp(value) when is_binary(value) do
    case Integer.parse(value) do
      {timestamp, ""} when timestamp > 0 -> {:ok, timestamp}
      _timestamp -> {:error, :invalid_timestamp}
    end
  end

  defp parse_timestamp(_value), do: {:error, :invalid_timestamp}

  defp validate_optional_end_time(_start_time, nil), do: :ok

  defp validate_optional_end_time(start_time, end_value) do
    with {:ok, end_time} <- parse_timestamp(end_value),
         true <- end_time >= start_time do
      :ok
    else
      _value -> {:error, :invalid_end_time}
    end
  end

  defp timestamp_to_iso(value) do
    with {:ok, timestamp} <- parse_timestamp(value),
         {:ok, datetime} <- DateTime.from_unix(timestamp) do
      DateTime.to_iso8601(datetime)
    else
      _value -> nil
    end
  end

  defp date_to_iso(value) do
    with {:ok, date} <- parse_date(value),
         {:ok, naive} <- NaiveDateTime.new(date, ~T[00:00:00]) do
      naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
    else
      _value -> nil
    end
  end

  defp parse_iso_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _datetime -> {:error, :invalid_datetime}
    end
  end

  defp parse_iso_datetime(_value), do: {:error, :invalid_datetime}

  defp parse_optional_iso_datetime(nil), do: nil

  defp parse_optional_iso_datetime(value) do
    case parse_iso_datetime(value) do
      {:ok, datetime} -> datetime
      _datetime -> nil
    end
  end

  defp bounded_tag(event, key, limit),
    do: event |> Protocol.tag_value(key) |> bounded_text(limit)

  defp bounded_integer_tag(event, key) do
    case event |> Protocol.tag_value(key) |> to_string() |> Integer.parse() do
      {value, ""} when value >= 0 -> min(value, 1_000_000_000)
      _value -> nil
    end
  end

  defp bounded_text(value, limit) when is_binary(value) do
    value
    |> String.replace("\0", "")
    |> String.slice(0, limit)
  end

  defp bounded_text(_value, _limit), do: nil

  defp valid_identifier?(value) do
    is_binary(value) and byte_size(value) in 1..@max_identifier_bytes and
      not String.contains?(value, ["\0", "\r", "\n"])
  end

  defp valid_optional_url?(nil), do: true
  defp valid_optional_url?(value), do: is_binary(valid_url(value))

  defp valid_url(value) when is_binary(value) and byte_size(value) <= 2_048 do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        value

      _uri ->
        nil
    end
  end

  defp valid_url(_value), do: nil

  defp stable_identifier(value) do
    value
    |> to_string()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
  end

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp invalid(reason), do: {:error, "invalid", reason}
end

# end of nostr/events.ex
