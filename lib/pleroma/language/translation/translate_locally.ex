# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2024 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Language.Translation.TranslateLocally do
  alias Pleroma.Language.Translation.Provider

  use Provider

  @behaviour Provider

  @name "translateLocally"

  @impl Provider
  def missing_dependencies do
    if Pleroma.Utils.command_available?("translateLocally") do
      []
    else
      ["translateLocally"]
    end
  end

  @impl Provider
  def configured? do
    models = models()

    is_map(models) and map_size(models) > 0
  end

  @impl Provider
  def translate(content, source_language, target_language) do
    with {:ok, route} <- translation_route(source_language, target_language),
         {:ok, translated_content} <- translate_route(content, route) do
      {:ok,
       %{
         content: translated_content,
         detected_source_language: source_language,
         provider: @name
       }}
    end
  end

  @impl Provider
  def supported_languages(:source) do
    with {:ok, matrix} <- languages_matrix() do
      {:ok, Map.keys(matrix)}
    end
  end

  @impl Provider
  def supported_languages(:target) do
    with {:ok, matrix} <- languages_matrix() do
      languages =
        matrix
        |> Map.values()
        |> List.flatten()
        |> Enum.uniq()

      {:ok, languages}
    end
  end

  @impl Provider
  def languages_matrix do
    models = models()

    if is_map(models) do
      languages =
        models
        |> Enum.map(fn {source_language, targets} ->
          {source_language, target_languages(targets)}
        end)
        |> Enum.into(%{})
        |> maybe_add_intermediary_languages()

      {:ok, languages}
    else
      {:error, :not_found}
    end
  end

  @impl Provider
  def name, do: @name

  defp translation_route(source_language, target_language) do
    cond do
      direct_model = get_model(source_language, target_language) ->
        {:ok, [direct_model]}

      route = intermediary_route(source_language, target_language) ->
        {:ok, route}

      true ->
        {:error, :unsupported_language}
    end
  end

  defp intermediary_route(source_language, target_language) do
    intermediary_language = intermediary_language()

    with true <- is_binary(intermediary_language),
         first_model when is_binary(first_model) <-
           get_model(source_language, intermediary_language),
         second_model when is_binary(second_model) <-
           get_model(intermediary_language, target_language) do
      [first_model, second_model]
    else
      _ -> nil
    end
  end

  defp translate_route(content, route) do
    Enum.reduce_while(route, {:ok, content}, fn model, {:ok, current_content} ->
      case translate_with_model(current_content, model) do
        {:ok, translated_content} -> {:cont, {:ok, translated_content}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp translate_with_model(content, model) do
    text_path = Path.join(System.tmp_dir!(), "translateLocally-#{Ecto.UUID.generate()}")

    try do
      with :ok <- File.write(text_path, content),
           {translated_content, 0} <-
             System.cmd("translateLocally", ["-m", model, "-i", text_path, "--html"]) do
        {:ok, translated_content}
      else
        _ -> {:error, :internal_server_error}
      end
    after
      File.rm(text_path)
    end
  end

  defp target_languages(targets) when is_map(targets), do: Map.keys(targets)
  defp target_languages(_), do: []

  defp maybe_add_intermediary_languages(languages) do
    intermediary_language = intermediary_language()
    intermediary_targets = Map.get(languages, intermediary_language)

    if is_binary(intermediary_language) and is_list(intermediary_targets) do
      languages
      |> Enum.map(fn {source_language, target_languages} ->
        expanded_targets =
          if source_language == intermediary_language do
            target_languages
          else
            target_languages
            |> Kernel.++(intermediary_targets)
            |> Enum.uniq()
            |> Kernel.--([source_language])
          end

        {source_language, expanded_targets}
      end)
      |> Enum.into(%{})
    else
      languages
    end
  end

  defp get_model(source_language, target_language) do
    models()
    |> Map.get(source_language, %{})
    |> Map.get(target_language)
  end

  defp models, do: Pleroma.Config.get([__MODULE__, :models])

  defp intermediary_language, do: Pleroma.Config.get([__MODULE__, :intermediary_language])
end
