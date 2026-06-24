# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Language.Translation.Libretranslate do
  import Pleroma.Web.Utils.Guards, only: [not_empty_string: 1]

  alias Pleroma.Language.Translation.Provider

  use Provider

  @behaviour Provider

  @name "LibreTranslate"

  @impl Provider
  def configured?, do: not_empty_string(base_url()) and not_empty_string(api_key())

  @impl Provider
  def translate(content, source_language, target_language) do
    case Pleroma.HTTP.post(
           base_url() <> "/translate",
           Jason.encode!(%{
             q: content,
             source: normalize_source_language(content, source_language),
             target: target_language,
             format: "html",
             api_key: api_key()
           }),
           [
             {"Content-Type", "application/json"}
           ]
         ) do
      {:ok, %{status: 429}} ->
        {:error, :too_many_requests}

      {:ok, %{status: 403}} ->
        {:error, :quota_exceeded}

      {:ok, %{status: 200} = res} ->
        with {:ok, %{"translatedText" => content} = data} <- Jason.decode(res.body) do
          {:ok,
           %{
             content: content,
             detected_source_language: detected_source_language(data, source_language),
             provider: "LibreTranslate"
           }}
        else
          _ -> {:error, :internal_server_error}
        end

      _ ->
        {:error, :internal_server_error}
    end
  end

  @impl Provider
  def supported_languages(_) do
    case Pleroma.HTTP.get(base_url() <> "/languages") do
      {:ok, %{status: 200} = res} ->
        with {:ok, languages} when is_list(languages) <- Jason.decode(res.body) do
          {:ok, Enum.flat_map(languages, &language_code/1)}
        else
          _ -> {:error, :internal_server_error}
        end

      _ ->
        {:error, :internal_server_error}
    end
  end

  @impl Provider
  def languages_matrix do
    with {:ok, source_languages} <- supported_languages(:source),
         {:ok, target_languages} <- supported_languages(:target) do
      {:ok,
       Map.new(source_languages, fn language -> {language, target_languages -- [language]} end)}
    else
      {:error, error} -> {:error, error}
    end
  end

  @impl Provider
  def name, do: @name

  defp base_url do
    Pleroma.Config.get([__MODULE__, :base_url])
  end

  defp api_key do
    Pleroma.Config.get([__MODULE__, :api_key], "")
  end

  defp language_code(%{"code" => code}) when is_binary(code), do: [code]
  defp language_code(_), do: []

  defp normalize_source_language(_content, language) when is_binary(language) do
    case String.trim(language) do
      "" -> "auto"
      language -> String.upcase(language)
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

  defp detected_source_language(data, fallback_language) do
    case detected_language(data) do
      language when is_binary(language) and language != "" -> String.downcase(language)
      _ -> normalize_fallback_language(fallback_language)
    end
  end

  defp detected_language(%{"detectedLanguage" => %{"language" => language}}), do: language
  defp detected_language(%{"detectedLanguage" => language}), do: language
  defp detected_language(%{"detected_source_language" => language}), do: language
  defp detected_language(_), do: nil

  defp normalize_fallback_language(language) when is_binary(language) do
    case String.trim(language) do
      "" -> "auto"
      language -> String.downcase(language)
    end
  end

  defp normalize_fallback_language(_), do: "auto"
end
