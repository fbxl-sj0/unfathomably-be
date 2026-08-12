# Unfathomably BE
# ----------------
#
# File: metadata/providers/schema_org.ex
#
# Purpose:
#   Describe public ActivityPub profiles and objects as Schema.org JSON-LD.
#
# Responsibilities:
#   - map native ActivityPub object families to useful Schema.org types
#   - expose bounded text, authorship, dates, and media to external consumers
#   - preserve the server's sensitive-media unfurl policy
#   - encode script content so untrusted remote HTML cannot terminate the tag
#
# This file intentionally does NOT fetch remote resources, alter stored
# ActivityPub data, or make private objects discoverable.

defmodule Pleroma.Web.Metadata.Providers.SchemaOrg do
  @behaviour Pleroma.Web.Metadata.Providers.Provider

  alias Pleroma.Web.Metadata
  alias Pleroma.Web.Metadata.Utils

  @schema_context "https://schema.org"
  @max_text_length 1_000

  @impl true
  def build_tags(%{object: %{data: data} = object, user: user} = params) when is_map(data) do
    sensitive? = Metadata.activity_nsfw?(object)

    text_source =
      if sensitive? do
        data["summary"]
      else
        data["content"] || data["summary"]
      end

    schema =
      %{
        "@context" => @schema_context,
        "@type" => schema_type(data),
        "url" => public_url(params[:url], data["id"]),
        "name" => scrub(data["name"]),
        "text" => scrub(text_source),
        "datePublished" => valid_date(data["published"]),
        "dateModified" => valid_date(data["updated"]),
        "author" => actor_schema(user),
        "associatedMedia" => if(sensitive?, do: nil, else: media_schemas(data["attachment"]))
      }
      |> Map.merge(review_schema(data, sensitive?))
      |> compact_map()

    json_ld_tag(schema)
  end

  def build_tags(%{user: user}) when is_map(user) do
    schema =
      %{
        "@context" => @schema_context,
        "@type" => actor_schema_type(Map.get(user, :actor_type)),
        "url" => public_url(Map.get(user, :uri), Map.get(user, :ap_id)),
        "name" => scrub(Map.get(user, :name) || Map.get(user, :nickname)),
        "alternateName" => scrub(Map.get(user, :nickname)),
        "description" => scrub(Map.get(user, :bio))
      }
      |> compact_map()

    json_ld_tag(schema)
  end

  def build_tags(_params), do: []

  defp json_ld_tag(schema) do
    json = Jason.encode!(schema, escape: :html_safe)
    [{:script, [type: "application/ld+json"], Phoenix.HTML.raw(json)}]
  end

  defp actor_schema(user) when is_map(user) do
    %{
      "@type" => actor_schema_type(Map.get(user, :actor_type)),
      "url" => public_url(Map.get(user, :uri), Map.get(user, :ap_id)),
      "name" => scrub(Map.get(user, :name) || Map.get(user, :nickname)),
      "alternateName" => scrub(Map.get(user, :nickname))
    }
    |> compact_map()
  end

  defp actor_schema(_user), do: nil

  defp actor_schema_type(actor_type) when actor_type in ["Group", "Organization"],
    do: "Organization"

  defp actor_schema_type(_actor_type), do: "Person"

  defp schema_type(%{"type" => "Article", "rating" => rating}) when is_number(rating),
    do: "Review"

  defp schema_type(%{"type" => "Event"}), do: "Event"
  defp schema_type(%{"type" => "Video"}), do: "VideoObject"
  defp schema_type(%{"type" => "Audio"}), do: "AudioObject"
  defp schema_type(%{"type" => "Image"}), do: "ImageObject"
  defp schema_type(%{"type" => "Book"}), do: "Book"
  defp schema_type(%{"type" => "Review"}), do: "Review"

  defp schema_type(%{"type" => type}) when type in ["Article", "Page", "Document"],
    do: "Article"

  defp schema_type(_data), do: "SocialMediaPosting"

  defp review_schema(data, sensitive?) when is_map(data) do
    if schema_type(data) == "Review" do
      body_source = if(sensitive?, do: data["summary"], else: data["content"] || data["summary"])

      %{
        "reviewBody" => scrub(body_source),
        "reviewRating" => rating_schema(data),
        "itemReviewed" => reviewed_item_schema(data)
      }
      |> compact_map()
    else
      %{}
    end
  end

  defp rating_schema(data) do
    rating = positive_number(data["rating"])
    best = positive_number(data["ratingBest"] || data["rating_best"]) || 5

    if rating && rating <= best do
      %{
        "@type" => "Rating",
        "ratingValue" => rating,
        "bestRating" => best
      }
    end
  end

  defp reviewed_item_schema(data) do
    embedded = normalize_reference(data["bookwyrm:edition"])
    tagged = catalog_reference(data["tag"])

    reference =
      public_url(
        data["inReplyToBook"] || data["withRegardTo"],
        public_url(reference_url(embedded), reference_url(tagged))
      )

    if reference do
      %{
        "@type" => reviewed_item_type(embedded || tagged),
        "url" => reference,
        "name" => scrub(reference_name(embedded) || reference_name(tagged))
      }
      |> compact_map()
    end
  end

  defp catalog_reference(references) when is_list(references) do
    Enum.find_value(references, &catalog_reference/1)
  end

  defp catalog_reference(%{} = reference) do
    if reference["type"] not in ["Hashtag", "Mention"] && reference_url(reference) do
      reference
    end
  end

  defp catalog_reference(_reference), do: nil

  defp normalize_reference(%{} = reference), do: reference
  defp normalize_reference(reference) when is_binary(reference), do: %{"id" => reference}
  defp normalize_reference(_reference), do: nil

  defp reference_url(%{} = reference), do: public_url(reference["id"], reference["href"])
  defp reference_url(_reference), do: nil

  defp reference_name(%{} = reference), do: reference["name"]
  defp reference_name(_reference), do: nil

  defp reviewed_item_type(%{"type" => type})
       when type in ["Book", "Edition", "Work"],
       do: "Book"

  defp reviewed_item_type(%{"type" => type}) when is_binary(type), do: type
  defp reviewed_item_type(_reference), do: "CreativeWork"

  defp positive_number(value) when is_integer(value) and value > 0, do: value
  defp positive_number(value) when is_float(value) and value > 0, do: value
  defp positive_number(_value), do: nil

  defp media_schemas(attachments) when is_list(attachments) do
    attachments
    |> Enum.map(&media_schema/1)
    |> Enum.reject(&is_nil/1)
    |> empty_to_nil()
  end

  defp media_schemas(_attachments), do: nil

  defp media_schema(attachment) when is_map(attachment) do
    with url_data when is_map(url_data) <- normalize_url(attachment["url"]),
         href when is_binary(href) <- public_url(url_data["href"], url_data["url"]) do
      media_type = url_data["mediaType"] || attachment["mediaType"]

      description =
        [attachment["summary"], attachment["name"]]
        |> Enum.find(fn value -> is_binary(value) and String.trim(value) != "" end)

      %{
        "@type" => media_schema_type(media_type),
        "contentUrl" => href,
        "encodingFormat" => media_type,
        "description" => scrub(description),
        "width" => positive_dimension(url_data["width"] || attachment["width"]),
        "height" => positive_dimension(url_data["height"] || attachment["height"])
      }
      |> compact_map()
    else
      _ -> nil
    end
  end

  defp media_schema(_attachment), do: nil

  defp media_schema_type("image/" <> _subtype), do: "ImageObject"
  defp media_schema_type("video/" <> _subtype), do: "VideoObject"
  defp media_schema_type("audio/" <> _subtype), do: "AudioObject"
  defp media_schema_type(_media_type), do: "MediaObject"

  defp normalize_url(urls) when is_list(urls) do
    Enum.find_value(urls, fn
      url when is_binary(url) -> %{"href" => url}
      %{} = url -> if(public_url(url["href"], url["url"]), do: url)
      _ -> nil
    end)
  end

  defp normalize_url(%{} = url), do: url
  defp normalize_url(url) when is_binary(url), do: %{"href" => url}
  defp normalize_url(_url), do: nil

  defp public_url(primary, _fallback) when is_binary(primary) and primary != "", do: primary
  defp public_url(_primary, fallback) when is_binary(fallback) and fallback != "", do: fallback
  defp public_url(_primary, _fallback), do: nil

  defp valid_date(value) when is_binary(value) and value != "", do: value
  defp valid_date(_value), do: nil

  defp positive_dimension(value) when is_integer(value) and value > 0, do: value
  defp positive_dimension(_value), do: nil

  defp scrub(value) when is_binary(value) and value != "" do
    value
    |> Utils.scrub_html_and_truncate(@max_text_length)
    |> empty_to_nil()
  end

  defp scrub(_value), do: nil

  defp compact_map(map) do
    Map.reject(map, fn {_key, value} -> value in [nil, "", [], %{}] end)
  end

  defp empty_to_nil(value) when value in [nil, "", [], %{}], do: nil
  defp empty_to_nil(value), do: value
end

# end of metadata/providers/schema_org.ex
