# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Helpers.UriHelper do
  @max_log_url_bytes 16_384
  @max_log_path_length 1_024
  @max_log_text_bytes 65_536
  @loggable_schemes ~w[
    elasticsearch http https meilisearch postgres postgresql redis rediss
  ]
  @credential_url_regex ~r{\b(?:elasticsearch|https?|meilisearch|postgres(?:ql)?|rediss?)://[^\s<>"']+}iu

  @doc """
  Returns a URL representation that is safe to include in diagnostic logs.

  Userinfo, fragments, and query values can contain credentials or signed
  download tokens. Logs retain the origin and a bounded path for operational
  diagnosis, while recording only that a query was present.
  """
  @spec log_safe_url(term()) :: String.t()
  def log_safe_url(value)

  def log_safe_url(value)
      when is_binary(value) and byte_size(value) > 0 and
             byte_size(value) <= @max_log_url_bytes do
    with true <- String.valid?(value),
         {:ok, %URI{scheme: scheme, host: host} = uri} <- URI.new(value),
         true <- scheme in @loggable_schemes,
         true <- is_binary(host) and host != "" do
      uri
      |> Map.put(:userinfo, nil)
      |> Map.put(:fragment, nil)
      |> Map.put(:query, if(is_binary(uri.query), do: "redacted", else: nil))
      |> Map.put(:path, safe_log_path(uri.path))
      |> URI.to_string()
    else
      _ -> "[invalid URL]"
    end
  rescue
    _ -> "[invalid URL]"
  end

  def log_safe_url(_value), do: "[invalid URL]"

  @doc """
  Redacts credential-bearing URLs embedded in bounded diagnostic text.

  Exception and adapter messages sometimes repeat a request URL even when the
  caller logged its own URL safely. This helper retains the surrounding error
  text while applying the same URL policy to every recognized service URL.
  """
  @spec log_safe_text(term()) :: String.t()
  def log_safe_text(value)

  def log_safe_text(value)
      when is_binary(value) and byte_size(value) <= @max_log_text_bytes do
    if String.valid?(value) do
      Regex.replace(@credential_url_regex, value, fn url -> log_safe_url(url) end)
    else
      "[invalid diagnostic text]"
    end
  rescue
    _ -> "[invalid diagnostic text]"
  end

  def log_safe_text(value) when is_binary(value), do: "[diagnostic text too large]"
  def log_safe_text(value), do: value |> inspect(limit: 50) |> log_safe_text()

  @spec equivalent?(String.t(), String.t()) :: boolean()
  def equivalent?(left, right) when is_binary(left) and is_binary(right) do
    case {uri_identity(left), uri_identity(right)} do
      {{:ok, identity}, {:ok, identity}} -> true
      _ -> false
    end
  end

  def equivalent?(_, _), do: false

  def modify_uri_params(uri, overridden_params, deleted_params \\ []) do
    uri = URI.parse(uri)

    existing_params = URI.query_decoder(uri.query || "") |> Map.new()
    overridden_params = Map.new(overridden_params, fn {k, v} -> {to_string(k), v} end)
    deleted_params = Enum.map(deleted_params, &to_string/1)

    updated_params =
      existing_params
      |> Map.merge(overridden_params)
      |> Map.drop(deleted_params)

    uri
    |> Map.put(:query, URI.encode_query(updated_params))
    |> URI.to_string()
    |> String.replace_suffix("?", "")
  end

  def maybe_add_base("/" <> uri, base), do: Path.join([base, uri])
  def maybe_add_base(uri, _base), do: uri

  defp safe_log_path(nil), do: nil

  defp safe_log_path(path) when is_binary(path) do
    path
    |> String.replace(~r/[\x00-\x1F\x7F]/u, "")
    |> String.slice(0, @max_log_path_length)
  end

  defp uri_identity(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} = uri
      when is_binary(scheme) and is_binary(host) ->
        scheme = String.downcase(scheme)

        if scheme in ["http", "https"] do
          {:ok,
           {
             scheme,
             String.downcase(host),
             uri.port || URI.default_port(scheme),
             uri.userinfo,
             uri.path || "",
             uri.query,
             uri.fragment
           }}
        else
          :error
        end

      _ ->
        :error
    end
  rescue
    URI.Error -> :error
  end
end
