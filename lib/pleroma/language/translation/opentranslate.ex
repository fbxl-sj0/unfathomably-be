# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Language.Translation.Opentranslate do
  import Pleroma.Web.Utils.Guards, only: [not_empty_string: 1]

  alias Pleroma.Language.Translation.Provider

  use Provider

  @behaviour Provider

  @name "OpenTranslate"
  @default_request_timeout_ms :timer.seconds(180)
  @default_language_timeout_ms :timer.seconds(15)

  @impl Provider
  def configured?, do: not_empty_string(base_url())

  @impl Provider
  def translate(content, source_language, target_language) do
    source_language = normalize_source_language(content, source_language)
    target_language = normalize_language(target_language)

    if target_language == "en" do
      case Pleroma.HTTP.post(
             endpoint("/translate"),
             request_body(content, source_language, target_language),
             [{"Content-Type", "application/json"}],
             recv_timeout: request_timeout_ms()
           ) do
        {:ok, %{status: 429}} ->
          {:error, :too_many_requests}

        {:ok, %{status: 403}} ->
          {:error, :quota_exceeded}

        {:ok, %{status: 200} = res} ->
          decode_translation(res.body, source_language)

        _ ->
          {:error, :internal_server_error}
      end
    else
      {:error, :unsupported_language}
    end
  end

  @impl Provider
  def supported_languages(:target), do: {:ok, ["en"]}

  def supported_languages(:source) do
    case Pleroma.HTTP.get(endpoint("/languages"), [], recv_timeout: language_timeout_ms()) do
      {:ok, %{status: 200} = res} ->
        with {:ok, languages} <- decode_languages(res.body) do
          {:ok, add_auto_language(languages)}
        end

      _ ->
        {:error, :internal_server_error}
    end
  end

  @impl Provider
  def languages_matrix do
    with {:ok, source_languages} <- supported_languages(:source) do
      {:ok, Map.new(source_languages, fn language -> {language, target_languages(language)} end)}
    else
      {:error, error} -> {:error, error}
    end
  end

  @impl Provider
  def name, do: @name

  defp endpoint(path) do
    base_url() <> path
  end

  defp request_timeout_ms do
    configured_timeout_ms(:request_timeout_ms, @default_request_timeout_ms)
  end

  defp language_timeout_ms do
    configured_timeout_ms(:language_timeout_ms, @default_language_timeout_ms)
  end

  defp configured_timeout_ms(key, default) do
    case Pleroma.Config.get([__MODULE__, key], default) do
      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp request_body(content, source_language, target_language) do
    %{
      q: content,
      source: normalize_language(source_language),
      target: normalize_language(target_language),
      format: "html"
    }
    |> maybe_put_api_key(api_key())
    |> Jason.encode!()
  end

  defp maybe_put_api_key(body, api_key) when is_binary(api_key) and api_key != "" do
    Map.put(body, :api_key, api_key)
  end

  defp maybe_put_api_key(body, _), do: body

  defp target_languages("en"), do: []
  defp target_languages(_), do: ["en"]

  defp decode_translation(body, source_language) do
    case Jason.decode(body) do
      {:ok, %{"translatedText" => translated_content} = decoded}
      when is_binary(translated_content) ->
        {:ok,
         %{
           content: translated_content,
           detected_source_language: detected_source_language(decoded, source_language),
           provider: @name
         }}

      _ ->
        {:error, :internal_server_error}
    end
  end

  defp decode_languages(body) do
    case Jason.decode(body) do
      {:ok, languages} when is_list(languages) ->
        languages =
          languages
          |> Enum.reduce([], fn
            %{"code" => code}, acc when is_binary(code) -> [code | acc]
            _, acc -> acc
          end)
          |> Enum.reverse()

        {:ok, languages}

      _ ->
        {:error, :internal_server_error}
    end
  end

  defp add_auto_language(["auto" | _] = languages), do: languages
  defp add_auto_language(languages), do: ["auto" | languages]

  defp detected_source_language(decoded, fallback) do
    with language when is_binary(language) <- detected_source_language_from_response(decoded),
         language <- String.trim(language),
         true <- language != "" do
      language
    else
      _ -> fallback
    end
  end

  defp detected_source_language_from_response(%{"detectedLanguage" => %{"language" => language}}),
    do: language

  defp detected_source_language_from_response(%{"detectedLanguage" => language}), do: language

  defp detected_source_language_from_response(%{"detected_source_language" => language}),
    do: language

  defp detected_source_language_from_response(_), do: nil

  defp normalize_source_language(content, language) do
    case normalize_language(language) do
      "" -> infer_source_language(content) || "auto"
      language -> language
    end
  end

  defp infer_source_language(content) do
    content
    |> visible_text()
    |> script_language()
  end

  defp visible_text(content) when is_binary(content) do
    content
    |> Floki.parse_fragment!()
    |> Floki.text()
  rescue
    _ -> content
  end

  defp visible_text(_), do: ""

  defp script_language(text) do
    cond do
      Regex.match?(~r/[\x{3040}-\x{30ff}]/u, text) -> "ja"
      Regex.match?(~r/[\x{ac00}-\x{d7af}]/u, text) -> "ko"
      Regex.match?(~r/[\x{0600}-\x{06ff}]/u, text) -> "ar"
      Regex.match?(~r/[\x{0900}-\x{097f}]/u, text) -> "hi"
      Regex.match?(~r/[\x{4e00}-\x{9fff}]/u, text) -> "zh-Hans"
      true -> nil
    end
  end

  defp normalize_language(language) do
    language
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp base_url do
    case Pleroma.Config.get([__MODULE__, :base_url]) do
      url when is_binary(url) -> String.trim_trailing(url, "/")
      value -> value
    end
  end

  defp api_key do
    Pleroma.Config.get([__MODULE__, :api_key])
  end
end
