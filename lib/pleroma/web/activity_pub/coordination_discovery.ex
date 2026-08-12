# Unfathomably coordination discovery
# ------------------------------------
#
# File: coordination_discovery.ex
#
# Purpose:
#   Search public ValueFlows and mutual-aid objects already stored locally.
#
# Responsibilities:
#   - use the native family and full-text database indexes
#   - enforce exact ActivityPub public visibility before returning an object
#   - project bounded coordination fields into a stable discovery record
#   - hand interaction back to the normal local object resolver
#
# This file intentionally does not crawl Bonfire servers, query private
# GraphQL APIs, infer locality, or expose arbitrary JSON-LD fields.

defmodule Pleroma.Web.ActivityPub.CoordinationDiscovery do
  import Ecto.Query

  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Visibility
  alias Pleroma.Web.Endpoint

  @max_limit 24
  @max_scan 800
  @namespace "https://unfathomably.social/ns#"

  @type provider_result :: %{
          items: [map()],
          total: non_neg_integer(),
          has_more: boolean(),
          provider: map()
        }

  @spec searches(String.t(), pos_integer(), non_neg_integer()) :: [provider_result()]
  def searches(query, limit, offset)
      when is_binary(query) and is_integer(limit) and limit > 0 and is_integer(offset) and
             offset >= 0 do
    query = query |> String.trim() |> String.slice(0, 200)
    limit = min(limit, @max_limit)
    scan_limit = min(max((offset + limit) * 5, limit), @max_scan)

    candidates =
      Object
      |> where(
        [object],
        fragment("unfathomably_native_discoverable(?)", object.data)
      )
      |> where([object], fragment("unfathomably_native_family(?) = 'coordination'", object.data))
      |> maybe_search(query)
      |> order_by([object], desc: object.id)
      |> limit(^scan_limit)
      |> Repo.all()

    matching_items =
      candidates
      |> Enum.filter(&(Visibility.is_public?(&1) and not Visibility.is_local_public?(&1)))
      |> Enum.map(&normalize_object/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(
        &(query != "" or &1.actionable or (&1.availability == "active" and not &1.historical))
      )

    items =
      matching_items
      |> Enum.drop(offset)
      |> Enum.take(limit)
      |> hydrate_participant_labels()

    [
      %{
        items: items,
        total: max(length(matching_items), offset + length(items)),
        has_more:
          length(matching_items) > offset + length(items) or
            length(candidates) == scan_limit,
        provider: %{
          type: "local_coordination",
          host: Endpoint.host(),
          status: "ready",
          accepted_peer_count: 0
        }
      }
    ]
  end

  def searches(_query, _limit, _offset), do: []

  defp maybe_search(query, ""), do: query

  defp maybe_search(query, search_term) do
    where(
      query,
      [object],
      fragment(
        "unfathomably_native_search_document(?) @@ websearch_to_tsquery('simple', ?)",
        object.data,
        ^search_term
      )
    )
  end

  defp normalize_object(%Object{data: data}) when is_map(data) do
    object_url = secure_url(data["id"])
    source_host = if object_url, do: URI.parse(object_url).host
    type = short_type(data["type"])
    role = coordination_role(type, data)
    title = first_text(title_candidates(data), 300) || role_title(role)
    primary_intents = normalize_intents(data["publishes"])
    reciprocal_intents = normalize_intents(data["reciprocal"] || data["reciprocalIntents"])
    publisher_url = reference_url(data["attributedTo"])
    provider_url = participant_url(data, primary_intents, "provider_url")
    receiver_url = participant_url(data, primary_intents, "receiver_url")
    availability = coordination_availability(type, data, primary_intents)

    with object_url when is_binary(object_url) <- object_url,
         source_host when is_binary(source_host) <- source_host,
         title when is_binary(title) <- title do
      %{
        id: "coordination:" <> object_url,
        family: "coordination",
        kind: type || "CoordinationObject",
        role: role,
        title: title,
        summary: first_text(summary_candidates(data), 1_500),
        url: secure_url(data["url"]) || object_url,
        activitypub_url: object_url,
        actor_url: publisher_url,
        publisher_url: publisher_url,
        publisher_label: nil,
        provider_url: provider_url,
        provider_label: nil,
        receiver_url: receiver_url,
        receiver_label: nil,
        purpose: coordination_purpose(data, role),
        action: action_label(data),
        state: first_text([data["state"], data["status"], native_field(data, "state")], 100),
        quantity: quantity(data) || first_intent_value(primary_intents, :quantity),
        location: location(data) || first_intent_value(primary_intents, :location),
        tags: tags(data),
        primary_intents: primary_intents,
        reciprocal_intents: reciprocal_intents,
        primary_intent_count: intent_count(data["publishes"]),
        reciprocal_intent_count: intent_count(data["reciprocal"] || data["reciprocalIntents"]),
        exchange: reciprocal_intents != [],
        availability: availability,
        actionable: actionable?(role, availability),
        historical: role == "economic_event",
        begins_at:
          timestamp(data["hasBeginning"]) || first_intent_value(primary_intents, :begins_at),
        ends_at:
          timestamp(data["hasEnd"] || data["due"]) ||
            first_intent_value(primary_intents, :ends_at),
        published_at: timestamp(data["published"] || data["updated"]),
        source_host: String.downcase(source_host),
        local_action: "resolve"
      }
    else
      _ -> nil
    end
  end

  defp normalize_object(_object), do: nil

  defp hydrate_participant_labels(items) do
    participant_urls =
      items
      |> Enum.flat_map(&[&1.publisher_url, &1.provider_url, &1.receiver_url])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    labels =
      if participant_urls == [] do
        %{}
      else
        from(user in User,
          where: user.ap_id in ^participant_urls,
          select: {user.ap_id, user.name, user.nickname}
        )
        |> Repo.all()
        |> Map.new(fn {ap_id, name, nickname} ->
          {ap_id, first_text([name, nickname], 300)}
        end)
      end

    Enum.map(items, fn item ->
      %{
        item
        | publisher_label: labels[item.publisher_url],
          provider_label: labels[item.provider_url],
          receiver_label: labels[item.receiver_url]
      }
    end)
  end

  defp title_candidates(data) do
    [
      data["name"],
      data["title"],
      data["subject"],
      data["resourceClassifiedAs"],
      map_name(data["resourceConformsTo"]),
      native_field(data, "detail")
    ]
  end

  defp summary_candidates(data) do
    [
      data["summary"],
      data["content"],
      data["description"],
      data["note"],
      native_field(data, "secondary")
    ]
  end

  defp coordination_role(type, data) do
    type = String.downcase(type || "")
    purpose = first_text(data["purpose"], 40) |> to_string() |> String.downcase()
    directions = intent_directions(data["publishes"])

    cond do
      String.contains?(type, "offer") or purpose == "offer" -> "offer"
      String.contains?(type, "need") or String.contains?(type, "request") -> "need"
      purpose in ["request", "need"] -> "need"
      directions == ["offer"] -> "offer"
      directions == ["need"] -> "need"
      String.contains?(type, "proposal") -> "proposal"
      participant_direction(data) == "offer" -> "offer"
      participant_direction(data) == "need" -> "need"
      String.contains?(type, "resource") -> "resource"
      String.contains?(type, "process") -> "process"
      String.contains?(type, "event") -> "economic_event"
      String.contains?(type, "intent") -> "intent"
      true -> "coordination"
    end
  end

  defp role_title("offer"), do: "Offer"
  defp role_title("need"), do: "Need"
  defp role_title("proposal"), do: "Proposal"
  defp role_title("resource"), do: "Resource"
  defp role_title("process"), do: "Process"
  defp role_title("economic_event"), do: "Economic event"
  defp role_title("intent"), do: "Intent"
  defp role_title(_role), do: "Coordination record"

  defp coordination_purpose(data, "offer"),
    do: first_text(data["purpose"], 40) || "offer"

  defp coordination_purpose(data, "need"),
    do: first_text(data["purpose"], 40) || "request"

  defp coordination_purpose(data, _role), do: first_text(data["purpose"], 40)

  defp action_label(data) do
    case data["action"] || data["resourceAction"] do
      action when is_binary(action) ->
        short_type(action) |> first_text(100)

      action when is_map(action) ->
        first_text([action["label"], action["name"], action["id"]], 100)

      _ ->
        nil
    end
  end

  defp quantity(data) do
    quantity =
      data["resourceQuantity"] || data["availableQuantity"] || data["effortQuantity"] ||
        native_field(data, "resourceQuantity")

    case quantity do
      quantity when is_map(quantity) ->
        value =
          quantity["hasNumericalValue"] || quantity["numericValue"] || quantity["value"]

        unit =
          first_text(
            [
              map_name(quantity["hasUnit"]),
              get_in(quantity, ["hasUnit", "symbol"]),
              quantity["unit"]
            ],
            80
          )

        if valid_number?(value), do: %{value: value, unit: unit}

      value when is_number(value) ->
        if valid_number?(value), do: %{value: value, unit: nil}

      _ ->
        nil
    end
  end

  defp valid_number?(value) when is_integer(value), do: value >= 0
  defp valid_number?(value) when is_float(value), do: value >= 0 and value < 1.0e100
  defp valid_number?(_value), do: false

  defp location(data) do
    value = data["eligibleLocation"] || data["location"]

    case value do
      location when is_map(location) ->
        first_text(
          [
            location["name"],
            location["description"],
            location["address"],
            location["locality"]
          ],
          300
        )

      location when is_binary(location) ->
        first_text(location, 300)

      _ ->
        nil
    end
  end

  defp participant_url(data, intents, key) do
    field = if key == "provider_url", do: "provider", else: "receiver"
    reference_url(data[field]) || first_intent_value(intents, String.to_existing_atom(key))
  end

  defp reference_url(value) when is_binary(value), do: secure_url(value)
  defp reference_url(%{"id" => value}), do: secure_url(value)
  defp reference_url([value | _]), do: reference_url(value)
  defp reference_url(_value), do: nil

  defp normalize_intents(value) do
    value
    |> intent_values()
    |> Enum.take(4)
    |> Enum.map(&normalize_intent/1)
    |> Enum.reject(&is_nil/1)
  end

  # ValueFlows publishers may inline intents directly or wrap them in an
  # ActivityStreams collection. Keep the collection envelope out of the UI and
  # preserve the actual terms it contains.
  defp intent_values(%{} = value) do
    case value["orderedItems"] || value["items"] do
      items when is_list(items) -> items
      _items -> [value]
    end
  end

  defp intent_values(value) when is_list(value), do: value
  defp intent_values(nil), do: []
  defp intent_values(value), do: [value]

  defp normalize_intent(intent) when is_map(intent) do
    resource_reference =
      intent["resource"] || intent["resourceConformsTo"] || intent["resourceClassifiedAs"]

    location_reference = intent["eligibleLocation"] || intent["location"]

    %{
      action: action_label(intent),
      role: intent_role(intent),
      title: first_text([intent["name"], intent["title"], intent["summary"]], 300),
      resource:
        first_text(
          [
            intent["resource"],
            intent["resourceClassifiedAs"],
            map_name(intent["resourceConformsTo"])
          ],
          300
        ),
      resource_url: reference_url(resource_reference),
      quantity: quantity(intent),
      location: location(intent),
      location_url: reference_url(location_reference),
      provider_url: reference_url(intent["provider"]),
      receiver_url: reference_url(intent["receiver"]),
      begins_at: timestamp(intent["hasBeginning"]),
      ends_at: timestamp(intent["hasEnd"] || intent["due"])
    }
  end

  defp normalize_intent(intent) when is_binary(intent) do
    case secure_url(intent) do
      nil -> nil
      activitypub_url -> %{activitypub_url: activitypub_url, role: "intent"}
    end
  end

  defp normalize_intent(_intent), do: nil

  defp intent_count(%{"totalItems" => count})
       when is_integer(count) and count >= 0 and count <= 100_000,
       do: count

  defp intent_count(value), do: value |> intent_values() |> Enum.take(100) |> length()

  defp intent_directions(value) do
    value
    |> List.wrap()
    |> Enum.map(fn
      intent when is_map(intent) -> participant_direction(intent)
      _intent -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp intent_role(intent) do
    case participant_direction(intent) do
      "offer" -> "offer"
      "need" -> "need"
      _direction -> "intent"
    end
  end

  defp participant_direction(data) do
    provider = reference_url(data["provider"])
    receiver = reference_url(data["receiver"])

    cond do
      provider && !receiver -> "offer"
      receiver && !provider -> "need"
      true -> nil
    end
  end

  defp first_intent_value(intents, key) do
    Enum.find_value(intents, &Map.get(&1, key))
  end

  defp coordination_availability(type, data, primary_intents) do
    state =
      first_text([data["state"], data["status"], native_field(data, "state")], 100)
      |> to_string()
      |> String.downcase()

    ends_at =
      timestamp(data["hasEnd"] || data["due"]) || first_intent_value(primary_intents, :ends_at)

    cond do
      String.downcase(type || "") |> String.contains?("event") -> "historical"
      state in ["closed", "completed", "fulfilled", "cancelled", "canceled", "expired"] -> state
      expired?(ends_at) -> "expired"
      state != "" -> state
      true -> "active"
    end
  end

  defp actionable?(role, availability) do
    role in ["offer", "need", "proposal", "intent"] and
      availability not in [
        "historical",
        "closed",
        "completed",
        "fulfilled",
        "cancelled",
        "canceled",
        "expired"
      ]
  end

  defp expired?(nil), do: false

  defp expired?(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date_time, _offset} -> DateTime.compare(date_time, DateTime.utc_now()) == :lt
      _error -> false
    end
  end

  defp tags(data) do
    data
    |> Map.get("tag", [])
    |> List.wrap()
    |> Enum.map(fn
      %{"name" => name} -> first_text(name, 80)
      name when is_binary(name) -> first_text(name, 80)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(8)
  end

  defp map_name(value) when is_map(value) do
    value["name"] || value["label"] || value["id"]
  end

  defp map_name(value) when is_binary(value), do: value
  defp map_name(_value), do: nil

  defp native_field(data, name), do: data[@namespace <> name]

  defp short_type([type | _]), do: short_type(type)

  defp short_type(type) when is_binary(type) do
    type
    |> String.split(~r{[/#:]}, trim: true)
    |> List.last()
    |> first_text(100)
  end

  defp short_type(_type), do: nil

  defp first_text(values, limit) when is_list(values) do
    Enum.find_value(values, &first_text(&1, limit))
  end

  defp first_text(value, limit) when is_binary(value) do
    text =
      case Floki.parse_fragment(value) do
        {:ok, fragment} -> Floki.text(fragment)
        _ -> value
      end

    text =
      text
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      |> String.slice(0, limit)

    if text == "", do: nil, else: text
  end

  defp first_text(_value, _limit), do: nil

  defp secure_url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil} = uri when is_binary(host) ->
        uri |> URI.to_string() |> String.slice(0, 2_000)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp secure_url(_value), do: nil

  defp timestamp(value) when is_binary(value), do: String.slice(value, 0, 40)
  defp timestamp(_value), do: nil
end

# end of coordination_discovery.ex
