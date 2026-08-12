# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.RichMedia.Parser do
  alias Pleroma.Web.RichMedia.Helpers
  import Pleroma.Web.Metadata.Utils, only: [scrub_html_and_truncate: 2]

  @config_impl Application.compile_env(:pleroma, [__MODULE__, :config_impl], Pleroma.Config)
  @fragment_headings ~w[h1 h2 h3 h4 h5 h6]
  @maximum_fragment_length 200
  @maximum_fragment_nodes 5_000

  defp parsers do
    Pleroma.Config.get([:rich_media, :parsers])
  end

  @type parse_errors :: {:error, :rich_media_disabled | :validate}

  @spec parse(String.t()) ::
          {:ok, map()} | parse_errors() | Helpers.get_errors()
  def parse(url) when is_binary(url) do
    with {_, true} <- {:config, @config_impl.get([:rich_media, :enabled])},
         {_, :ok} <- {:validate, validate_page_url(url)},
         {_, {:ok, data}} <- {:parse, parse_url(url)} do
      data = Map.put(data, "url", url)
      {:ok, data}
    else
      {:config, _} -> {:error, :rich_media_disabled}
      {:validate, _} -> {:error, :validate}
      {:parse, error} -> error
    end
  end

  defp parse_url(url) do
    with {:ok, body} <- Helpers.rich_media_get(url),
         {:ok, html} <- Floki.parse_document(body) do
      html
      |> maybe_parse()
      |> enrich_fragment_context(url, html)
      |> clean_parsed_data()
      |> check_parsed_data()
    end
  end

  @doc false
  @spec enrich_fragment_context(map(), String.t(), Floki.html_tree()) :: map()
  def enrich_fragment_context(data, url, html)
      when is_map(data) and is_binary(url) and is_list(html) do
    with fragment when is_binary(fragment) <- safe_fragment(url),
         node when not is_nil(node) <- fragment_node(html, fragment),
         context when is_map(context) <- fragment_context(node) do
      data
      |> put_fragment_title(context.title)
      |> put_fragment_description(context.description)
    else
      _ -> data
    end
  rescue
    _ -> data
  end

  def enrich_fragment_context(data, _url, _html), do: data

  defp safe_fragment(url) do
    case URI.parse(url).fragment do
      fragment when is_binary(fragment) and byte_size(fragment) <= @maximum_fragment_length * 3 ->
        fragment = URI.decode(fragment)

        if fragment != "" and String.length(fragment) <= @maximum_fragment_length and
             String.printable?(fragment) do
          fragment
        end

      _ ->
        nil
    end
  rescue
    URI.Error -> nil
    ArgumentError -> nil
  end

  # The selector is constant. The untrusted fragment is compared as an
  # attribute value and is never interpolated into CSS or XPath syntax.
  defp fragment_node(html, fragment) do
    html
    |> Floki.find("[id]")
    |> Enum.take(@maximum_fragment_nodes)
    |> Enum.find(fn
      {_tag, attributes, _children} ->
        Enum.any?(attributes, fn
          {"id", ^fragment} -> true
          _ -> false
        end)

      _ ->
        false
    end)
  end

  defp fragment_context({tag, _attributes, _children} = node) do
    title =
      if tag in @fragment_headings do
        node_text(node, 200)
      else
        node
        |> Floki.find(Enum.join(@fragment_headings, ","))
        |> List.first()
        |> node_text(200)
      end

    text = node_text(node, 600)

    %{
      title: title || text,
      description: if(text && text != title, do: text, else: nil)
    }
  end

  defp fragment_context(_node), do: nil

  defp node_text(nil, _maximum), do: nil

  defp node_text(node, maximum) do
    node
    |> Floki.text(sep: " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, maximum)
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp put_fragment_title(data, nil), do: data

  defp put_fragment_title(%{"title" => title} = data, fragment_title)
       when is_binary(title) and title != "" do
    if same_text?(title, fragment_title) or contains_text?(title, fragment_title) do
      data
    else
      Map.put(data, "title", title <> ": " <> fragment_title)
    end
  end

  defp put_fragment_title(data, fragment_title), do: Map.put(data, "title", fragment_title)

  defp put_fragment_description(data, nil), do: data

  defp put_fragment_description(%{"description" => description} = data, fragment_description)
       when is_binary(description) and description != "" do
    if same_text?(description, fragment_description) or
         contains_text?(description, fragment_description) do
      data
    else
      Map.put(data, "description", fragment_description)
    end
  end

  defp put_fragment_description(data, fragment_description),
    do: Map.put(data, "description", fragment_description)

  defp same_text?(left, right), do: normalized_text(left) == normalized_text(right)

  defp contains_text?(container, value) do
    String.contains?(normalized_text(container), normalized_text(value))
  end

  defp normalized_text(value) do
    value
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp maybe_parse(html) do
    Enum.reduce_while(parsers(), %{}, fn parser, acc ->
      case parser.parse(html, acc) do
        data when data != %{} -> {:halt, data}
        _ -> {:cont, acc}
      end
    end)
  end

  defp check_parsed_data(%{"title" => title} = data)
       when is_binary(title) and title != "" do
    {:ok, data}
  end

  defp check_parsed_data(_data) do
    {:error, :invalid_metadata}
  end

  defp clean_parsed_data(data) do
    data
    |> Enum.reject(fn {key, val} ->
      not match?({:ok, _}, Jason.encode(%{key => val}))
    end)
    |> Map.new()
    |> truncate_title()
    |> truncate_desc()
  end

  defp truncate_title(%{"title" => title} = data) when is_binary(title),
    do: %{data | "title" => scrub_html_and_truncate(title, 120)}

  defp truncate_title(data), do: data

  defp truncate_desc(%{"description" => desc} = data) when is_binary(desc),
    do: %{data | "description" => scrub_html_and_truncate(desc, 200)}

  defp truncate_desc(data), do: data

  @spec validate_page_url(URI.t() | binary()) :: :ok | :error
  defp validate_page_url(page_url) when is_binary(page_url) do
    validate_tld = @config_impl.get([Pleroma.Formatter, :validate_tld])

    page_url
    |> Linkify.Parser.url?(validate_tld: validate_tld)
    |> parse_uri(page_url)
  end

  defp validate_page_url(%URI{host: host, scheme: "https"}) do
    cond do
      Linkify.Parser.ip?(host) ->
        :error

      host in @config_impl.get([:rich_media, :ignore_hosts], []) ->
        :error

      get_tld(host) in @config_impl.get([:rich_media, :ignore_tld], []) ->
        :error

      true ->
        :ok
    end
  end

  defp validate_page_url(_), do: :error

  defp parse_uri(true, url) do
    url
    |> URI.parse()
    |> validate_page_url
  end

  defp parse_uri(_, _), do: :error

  defp get_tld(host) do
    host
    |> String.split(".")
    |> Enum.reverse()
    |> hd
  end
end
