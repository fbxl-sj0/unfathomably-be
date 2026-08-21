# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.RichMedia.Parsers.OEmbed do
  @allowed_types ~w(link photo video rich)
  @text_limits %{
    "author_name" => 500,
    "author_url" => 4_096,
    "html" => 100_000,
    "provider_name" => 500,
    "provider_url" => 4_096,
    "thumbnail_url" => 4_096,
    "title" => 1_000,
    "url" => 4_096,
    "version" => 32
  }
  @maximum_dimension 100_000
  @maximum_cache_age 31_536_000

  def parse(html, _data) do
    with elements = [_ | _] <- get_discovery_data(html),
         oembed_url when is_binary(oembed_url) <- get_oembed_url(elements),
         {:ok, oembed_data = %{"html" => html}} <- get_oembed_data(oembed_url) do
      %{oembed_data | "html" => Pleroma.HTML.filter_tags(html)}
    else
      _e -> %{}
    end
  end

  defp get_discovery_data(html) do
    html |> Floki.find("link[type='application/json+oembed']")
  end

  defp get_oembed_url([{"link", attributes, _children} | _]) do
    Enum.find_value(attributes, fn {k, v} -> if k == "href", do: v end)
  end

  defp get_oembed_data(url) do
    with {:ok, json} <- Pleroma.Web.RichMedia.Helpers.rich_media_get(url),
         {:ok, data} <- Jason.decode(json) do
      normalize_data(data)
    end
  end

  @doc false
  def normalize_data(%{} = data) do
    normalized =
      Enum.reduce(@text_limits, %{}, fn {field, limit}, acc ->
        case bounded_text(data[field], limit) do
          nil -> acc
          value -> Map.put(acc, field, value)
        end
      end)
      |> put_type(data["type"])
      |> put_dimension("width", data["width"])
      |> put_dimension("height", data["height"])
      |> put_dimension("thumbnail_width", data["thumbnail_width"])
      |> put_dimension("thumbnail_height", data["thumbnail_height"])
      |> put_bounded_integer("cache_age", data["cache_age"], @maximum_cache_age)

    case normalized do
      %{"html" => html, "type" => type}
      when is_binary(html) and html != "" and type in @allowed_types ->
        {:ok, normalized}

      _ ->
        {:error, :invalid_oembed_metadata}
    end
  end

  def normalize_data(_), do: {:error, :invalid_oembed_metadata}

  defp put_type(data, type) when type in @allowed_types, do: Map.put(data, "type", type)
  defp put_type(data, _type), do: data

  defp put_dimension(data, field, value),
    do: put_bounded_integer(data, field, value, @maximum_dimension)

  defp put_bounded_integer(data, field, value, maximum)
       when is_integer(value) and value >= 0 and value <= maximum,
       do: Map.put(data, field, value)

  defp put_bounded_integer(data, field, value, maximum) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> put_bounded_integer(data, field, integer, maximum)
      _ -> data
    end
  end

  defp put_bounded_integer(data, _field, _value, _maximum), do: data

  defp bounded_text(value, limit) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      nil
    else
      String.slice(value, 0, limit)
    end
  end

  defp bounded_text(_value, _limit), do: nil
end
