# Project: Unfathomably
# File: marketplace_object_discovery.ex
# Purpose: Search verified public marketplace listings already received.
#
# Responsibilities:
# - preselect stock Flohmarkt and FEP-0837 listing-shaped Notes
# - reuse CustomObject's canonical listing verifier and presentation metadata
# - expose price, currency identity, seller, location, and resolution actions
# - hydrate locally known seller identity in one bounded query
#
# This file intentionally does not send user coordinates, query marketplace
# peers, infer listings from hostnames, or open seller conversations.

defmodule Pleroma.Web.ActivityPub.MarketplaceObjectDiscovery do
  @moduledoc """
  Local-first discovery for verified Flohmarkt-compatible listings.

  Stock Flohmarkt embeds a controlled `flohmarkt:data` record. Newer peers may
  use a FEP-0837 Proposal attachment. `CustomObject.presentation/1` already
  validates both shapes, including ownership and canonical identifier checks,
  so discovery uses that result as its final classification boundary.
  """

  import Ecto.Query

  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.CustomObject
  alias Pleroma.Web.MediaProxy

  @public "https://www.w3.org/ns/activitystreams#Public"
  @default_limit 12
  @maximum_limit 20
  @maximum_offset 5_000
  @maximum_query_length 200
  @terminal_states ~w[deleted expired sold unavailable withdrawn]

  @spec search(map()) :: map()
  def search(params) when is_map(params) do
    query =
      params
      |> Map.get("q", "")
      |> string_value()
      |> String.trim()
      |> String.slice(0, @maximum_query_length)

    limit = bounded_integer(Map.get(params, "limit"), @default_limit, 1, @maximum_limit)
    offset = bounded_integer(Map.get(params, "offset"), 0, 0, @maximum_offset)

    normalized =
      if String.length(query) == 1 do
        []
      else
        query
        |> search_query(limit + 1, offset)
        |> Repo.all(timeout: 30_000)
        |> Enum.map(&normalize_result/1)
        |> Enum.reject(&is_nil/1)
        |> hydrate_sellers()
      end

    has_more = length(normalized) > limit

    %{
      "items" => Enum.take(normalized, limit),
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
    |> from(as: :activity)
    |> join(:inner, [activity: activity], object in Object,
      as: :object,
      on:
        fragment(
          "(?->>'id') = associated_object_id(?)",
          object.data,
          activity.data
        )
    )
    |> where(
      [activity: activity],
      activity.local == false and fragment("?->>'type' = 'Create'", activity.data)
    )
    |> where(
      [object: object],
      fragment("unfathomably_native_discoverable(?)", object.data) and
        fragment("unfathomably_native_family(?) = 'marketplace'", object.data)
    )
    |> where(
      [object: object],
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
    |> maybe_search(query)
    |> order_by([object: object], desc: object.id)
    |> limit(^limit)
    |> offset(^offset)
    |> select([activity: activity, object: object], {activity, object})
  end

  defp maybe_search(query, ""), do: query

  defp maybe_search(query, search) do
    where(
      query,
      [object: object],
      fragment(
        "unfathomably_marketplace_search_document(?) @@ websearch_to_tsquery('simple', ?)",
        object.data,
        ^search
      )
    )
  end

  defp normalize_result({activity, object}) do
    data = object.data || %{}
    proposal = proposal_attachment(data["attachment"])

    with %{fields: fields} <- CustomObject.presentation(data),
         "flohmarkt" <- fields[:platform],
         true <- current_listing?(data, fields, proposal),
         title when is_binary(title) <- scalar(fields[:listing_name]),
         activitypub_url when is_binary(activitypub_url) <- reference_url(data["id"]) do
      source_url = reference_url(data["url"]) || activitypub_url
      actor = data["attributedTo"] || data["actor"] || activity.data["actor"]
      actor_url = reference_url(actor)
      expiry = listing_expiry(data, proposal)
      state = listing_state(data, fields)

      currency =
        currency_metadata(fields[:currency]) ||
          currency_metadata(proposal_currency(proposal))

      %{
        "id" => activity.id,
        "family" => "market",
        "kind" => "classified",
        "title" => title,
        "summary" =>
          data |> first_present(["summary", "content"]) |> plain_text() |> truncate(800),
        "url" => source_url,
        "activitypub_url" => activitypub_url,
        "image_url" => data |> image_url() |> proxied_image_url(),
        "price" => scalar_string(fields[:price]) || proposal_price(proposal),
        "currency" => currency && currency.label,
        "currency_url" => currency && currency.url,
        "purpose" => listing_purpose(fields, proposal),
        "availability" => state,
        "published_at" => scalar_string(data["published"]),
        "expires_at" => expiry,
        "location" => scalar(fields[:listing_location]),
        "latitude" => numeric_value(fields[:latitude]),
        "longitude" => numeric_value(fields[:longitude]),
        "condition" => scalar(fields[:condition]),
        "delivery" => scalar(fields[:delivery]),
        "category" => scalar(fields[:category]),
        "tags" => hashtag_names(data["tag"]),
        "seller_url" => actor_url,
        "seller_label" => actor_label(actor, actor_url),
        "source_host" => source_host(source_url),
        "local_action" => "resolve"
      }
    else
      _ -> nil
    end
  end

  defp normalize_result(_), do: nil

  defp hydrate_sellers(items) do
    seller_urls =
      items
      |> Enum.map(& &1["seller_url"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.take(100)

    sellers =
      if seller_urls == [] do
        %{}
      else
        from(user in User,
          where: user.local == false,
          where: user.is_active == true,
          where: user.ap_id in ^seller_urls
        )
        |> Repo.all(timeout: 30_000)
        |> Map.new(fn user ->
          label = clean_text(user.name, 300) || clean_text(user.nickname, 300)

          {user.ap_id,
           %{
             id: to_string(user.id),
             label: label,
             handle: seller_handle(user.nickname)
           }}
        end)
      end

    Enum.map(items, fn item ->
      case Map.get(sellers, item["seller_url"]) do
        %{id: id, label: label, handle: handle} ->
          item
          |> Map.put("seller_id", id)
          |> Map.put("seller_label", label || item["seller_label"])
          |> Map.put("seller_handle", handle)

        _ ->
          item
      end
    end)
  end

  defp seller_handle(nickname) when is_binary(nickname) do
    nickname = String.trim(nickname)

    cond do
      nickname == "" -> nil
      String.starts_with?(nickname, "@") -> clean_text(nickname, 300)
      String.contains?(nickname, "@") -> clean_text("@" <> nickname, 300)
      true -> nil
    end
  end

  defp seller_handle(_), do: nil

  defp current_listing?(data, fields, proposal) do
    listing_state(data, fields) not in @terminal_states and
      not expired?(listing_expiry(data, proposal))
  end

  defp listing_state(data, fields) do
    (scalar(fields[:state]) ||
       scalar(data["state"]) ||
       scalar(data["availability"]) ||
       scalar(data["status"]))
    |> case do
      nil -> nil
      state -> String.downcase(state)
    end
  end

  defp listing_expiry(data, proposal) do
    Enum.find_value(
      [
        data["endTime"],
        data["expires"],
        data["validThrough"],
        proposal && proposal["endTime"],
        proposal && proposal["expires"],
        proposal && proposal["validThrough"]
      ],
      &scalar_string/1
    )
  end

  defp expired?(nil), do: false

  defp expired?(value) do
    case DateTime.from_iso8601(value) do
      {:ok, expires_at, _offset} -> DateTime.compare(expires_at, DateTime.utc_now()) == :lt
      _value -> false
    end
  end

  defp listing_purpose(fields, proposal) do
    scalar(fields[:listing_type]) ||
      (proposal && scalar(proposal["purpose"])) ||
      "offer"
  end

  defp proposal_attachment(attachments) do
    attachments
    |> List.wrap()
    |> Enum.find(fn
      %{"type" => "Proposal"} ->
        true

      %{"type" => type} when is_binary(type) ->
        String.ends_with?(type, ["#Proposal", "/Proposal"])

      _attachment ->
        false
    end)
  end

  defp proposal_price(%{} = proposal) do
    proposal
    |> get_in(["reciprocal", "resourceQuantity", "hasNumericalValue"])
    |> scalar_string()
  end

  defp proposal_price(_proposal), do: nil

  defp proposal_currency(%{} = proposal) do
    get_in(proposal, ["reciprocal", "resourceQuantity", "hasUnit"])
  end

  defp proposal_currency(_proposal), do: nil

  defp currency_metadata(%{} = value) do
    label =
      value
      |> first_present(["name", "label", "symbol", "code"])
      |> clean_text(100)

    url = reference_url(value)

    if label || url do
      %{label: label || currency_url_label(url), url: url}
    end
  end

  defp currency_metadata(value) when is_binary(value) do
    case reference_url(value) do
      url when is_binary(url) -> %{label: currency_url_label(url), url: url}
      _ -> %{label: clean_text(value, 100), url: nil}
    end
  end

  defp currency_metadata(_), do: nil

  defp currency_url_label(url) when is_binary(url) do
    url
    |> URI.parse()
    |> Map.get(:path, "")
    |> String.split("/", trim: true)
    |> List.last()
    |> case do
      nil -> source_host(url)
      value -> value |> URI.decode() |> clean_text(100)
    end
  rescue
    _ -> source_host(url)
  end

  defp currency_url_label(_), do: nil

  defp image_url(data) do
    reference_url(data["image"]) ||
      reference_url(data["icon"]) ||
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

  defp proxied_image_url(nil), do: nil
  defp proxied_image_url(url), do: MediaProxy.browser_url(url)

  defp actor_label(actor, actor_url) when is_map(actor) do
    first_present(actor, ["name", "preferredUsername"]) || source_host(actor_url)
  end

  defp actor_label(_actor, actor_url), do: source_host(actor_url)

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

  defp scalar(value) when is_binary(value), do: clean_text(value, 500)
  defp scalar(_), do: nil

  defp scalar_string(value) when is_binary(value), do: clean_text(value, 100)
  defp scalar_string(value) when is_integer(value), do: Integer.to_string(value)
  defp scalar_string(value) when is_float(value), do: Float.to_string(value)
  defp scalar_string(_), do: nil

  defp numeric_value(value) when is_integer(value) or is_float(value), do: value

  defp numeric_value(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp numeric_value(_), do: nil

  defp first_present(map, keys) do
    if is_map(map) do
      Enum.find_value(keys, fn key ->
        case map[key] do
          value when is_binary(value) -> clean_text(value, 500)
          _ -> nil
        end
      end)
    end
  end

  defp reference_url(value) when is_binary(value) do
    value = String.trim(value)

    case URI.parse(value) do
      %URI{scheme: scheme, host: host, userinfo: nil} = uri
      when scheme in ["http", "https"] and is_binary(host) and byte_size(value) <= 2_048 ->
        URI.to_string(uri)

      _ ->
        nil
    end
  end

  defp reference_url(%{"url" => value}), do: reference_url(value)
  defp reference_url(%{"href" => value}), do: reference_url(value)
  defp reference_url(%{"id" => value}), do: reference_url(value)
  defp reference_url(%{"@id" => value}), do: reference_url(value)

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

  defp local_host do
    Config.get([Pleroma.Web.Endpoint, :url, :host], "local")
  end
end

# end of marketplace_object_discovery.ex
