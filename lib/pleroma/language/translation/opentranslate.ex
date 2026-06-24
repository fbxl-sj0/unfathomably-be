# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Language.Translation.Opentranslate do
  import Pleroma.Web.Utils.Guards, only: [not_empty_string: 1]

  alias Pleroma.Language.Translation.Provider

  use Provider

  @behaviour Provider

  @name "OpenTranslate"

  @impl Provider
  def configured?, do: not_empty_string(base_url())

  @impl Provider
  def translate(content, source_language, target_language) do
    if normalize_language(target_language) == "en" do
      case Pleroma.HTTP.post(
             endpoint("/translate"),
             request_body(content, source_language, target_language),
             [{"Content-Type", "application/json"}]
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
    case Pleroma.HTTP.get(endpoint("/languages")) do
      {:ok, %{status: 200} = res} ->
        decode_languages(res.body)

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

  defp request_body(content, source_language, target_language) do
    %{
      q: content,
      source: normalize_source_language(content, source_language),
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
      {:ok, %{"translatedText" => translated_content}} when is_binary(translated_content) ->
        {:ok,
         %{
           content: translated_content,
           detected_source_language: detected_source_language(body, source_language),
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

  defp normalize_language(language) do
    language
    |> to_string()
    |> String.downcase()
  end

  defp normalize_source_language(_content, language) when is_binary(language) do
    case normalize_language(language) do
      "" -> "auto"
      language -> language
    end
  end

  defp normalize_source_language(content, _) do
    infer_source_language(content) || "auto"
  end

  defp infer_source_language(content) when is_binary(content) do
    cond do
      String.match?(content, ~r/[\x{3040}-\x{30FF}\x{FF66}-\x{FF9F}]/u) -> "ja"
      String.match?(content, ~r/[\x{AC00}-\x{D7AF}\x{1100}-\x{11FF}]/u) -> "ko"
      String.match?(content, ~r/[\x{0600}-\x{06FF}]/u) -> "ar"
      String.match?(content, ~r/[\x{0900}-\x{097F}]/u) -> "hi"
      String.match?(content, ~r/[\x{0400}-\x{04FF}]/u) -> "ru"
      String.match?(content, ~r/[\x{4E00}-\x{9FFF}]/u) -> "zh-Hans"
      true -> nil
    end
  end

  defp infer_source_language(_), do: nil

  defp detected_source_language(body, fallback_language) do
    with {:ok, data} <- Jason.decode(body),
         language when is_binary(language) and language != "" <- detected_language(data) do
      normalize_language(language)
    else
      _ -> normalize_source_language(nil, fallback_language)
    end
  end

  defp detected_language(%{"detectedLanguage" => %{"language" => language}}), do: language
  defp detected_language(%{"detectedLanguage" => language}), do: language
  defp detected_language(%{"detected_source_language" => language}), do: language
  defp detected_language(_), do: nil

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
