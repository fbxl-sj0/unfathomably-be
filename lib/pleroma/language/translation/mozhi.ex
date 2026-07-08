# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Language.Translation.Mozhi do
  import Pleroma.Web.Utils.Guards, only: [not_empty_string: 1]

  alias Pleroma.Language.Translation.Provider

  use Provider

  @behaviour Provider

  @name "Mozhi"

  @impl Provider
  def configured?, do: not_empty_string(base_url()) and not_empty_string(engine())

  @impl Provider
  def translate(content, source_language, target_language) do
    params = %{
      engine: engine(),
      text: content,
      from: source_language,
      to: target_language
    }

    case Pleroma.HTTP.get(endpoint("/api/translate", params)) do
      {:ok, %{status: 429}} ->
        {:error, :too_many_requests}

      {:ok, %{status: 403}} ->
        {:error, :quota_exceeded}

      {:ok, %{status: 200} = res} ->
        with {:ok, %{"translated-text" => translated_content}} when is_binary(translated_content) <-
               Jason.decode(res.body) do
          {:ok,
           %{
             content: translated_content,
             detected_source_language: source_language,
             provider: @name
           }}
        else
          _ -> {:error, :internal_server_error}
        end

      _ ->
        {:error, :internal_server_error}
    end
  end

  @impl Provider
  def supported_languages(:source), do: language_list("/api/source_languages")
  def supported_languages(:target), do: language_list("/api/target_languages")

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

  defp language_list(path) do
    case Pleroma.HTTP.get(endpoint(path, %{engine: engine()})) do
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

  defp language_code(%{"Id" => code}) when is_binary(code), do: [code]
  defp language_code(%{"id" => code}) when is_binary(code), do: [code]
  defp language_code(_), do: []

  defp endpoint(path, params) do
    base_url() <> path <> "?" <> URI.encode_query(params)
  end

  defp base_url do
    Pleroma.Config.get([__MODULE__, :base_url])
  end

  defp engine do
    Pleroma.Config.get([__MODULE__, :engine])
  end
end
