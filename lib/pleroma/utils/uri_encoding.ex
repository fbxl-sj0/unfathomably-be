# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2025 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Utils.URIEncoding do
  @moduledoc """
  Utility functions for URI encoding paths and queries without corrupting
  already-escaped local upload and emoji paths.
  """

  @path_allowed_reserved_chars ~c"/:@!$&'()*+,;="

  @spec encode_url(String.t(), Keyword.t()) :: String.t() | {:error, :invalid_opts}
  def encode_url(url, opts \\ []) when is_binary(url) and is_list(opts) do
    bypass_parse = Keyword.get(opts, :bypass_parse, false)
    bypass_decode = Keyword.get(opts, :bypass_decode, false)

    with true <- is_boolean(bypass_parse),
         true <- is_boolean(bypass_decode) do
      if bypass_parse do
        encode_path(url, bypass_decode)
      else
        parsed = URI.parse(url)
        path = encode_path(parsed.path, bypass_decode)
        query = encode_query(parsed.query, parsed.host)

        parsed
        |> Map.put(:path, path)
        |> Map.put(:query, query)
        |> URI.to_string()
      end
    else
      _ -> {:error, :invalid_opts}
    end
  end

  defp encode_path(nil, _bypass_decode), do: nil

  defp encode_path(path, bypass_decode) when is_binary(path) do
    path =
      if bypass_decode do
        path
      else
        URI.decode(path)
      end

    URI.encode(path, fn byte ->
      URI.char_unreserved?(byte) || Enum.any?(@path_allowed_reserved_chars, &(&1 == byte))
    end)
  end

  defp encode_query(query, host) when is_binary(query) do
    query
    |> URI.query_decoder()
    |> Enum.to_list()
    |> do_encode_query(host)
  end

  defp encode_query(nil, _host), do: nil

  defp do_encode_query(enumerable, host) do
    Enum.map_join(enumerable, "&", &maybe_apply_query_quirk(&1, host))
  end

  defp maybe_apply_query_quirk({key, value}, "i.guim.co.uk") do
    case key do
      "precrop" -> query_encode_kv_pair({key, value}, ~c":,")
      _ -> query_encode_kv_pair({key, value})
    end
  end

  defp maybe_apply_query_quirk({key, value}, _host), do: query_encode_kv_pair({key, value})

  defp query_encode_kv_pair({key, value}, rules \\ []) when is_list(rules) do
    if rules == [] do
      URI.encode_www_form(Kernel.to_string(key)) <>
        "=" <> URI.encode_www_form(Kernel.to_string(value))
    else
      (URI.encode_www_form(Kernel.to_string(key)) <>
         "=" <>
         URI.encode(value, fn byte ->
           URI.char_unreserved?(byte) || Enum.any?(rules, &(&1 == byte))
         end))
      |> String.replace("%20", "+")
    end
  end
end
