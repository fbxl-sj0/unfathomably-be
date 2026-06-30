# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

# credo:disable-for-this-file Credo.Check.Readability.PredicateFunctionNames

defmodule Pleroma.Web.ActivityPub.MRF.NoEmptyPolicy do
  @moduledoc "Filter local activities which have no content"
  @behaviour Pleroma.Web.ActivityPub.MRF.Policy

  alias Pleroma.Web.Endpoint

  @impl true
  def filter(%{"actor" => actor} = activity) do
    with true <- is_local?(actor),
         true <- is_eligible_type?(activity),
         true <- is_note?(activity),
         false <- has_attachment?(activity),
         true <- only_mentions?(activity) do
      {:reject, "[NoEmptyPolicy]"}
    else
      _ ->
        {:ok, activity}
    end
  end

  def filter(activity), do: {:ok, activity}

  defp is_local?(actor) when is_binary(actor), do: String.starts_with?(actor, "#{Endpoint.url()}")
  defp is_local?(_actor), do: false

  defp has_attachment?(%{
         "object" => %{"type" => "Note", "attachment" => attachments}
       })
       when attachments != [],
       do: true

  defp has_attachment?(_), do: false

  defp only_mentions?(%{"object" => %{"type" => "Note", "source" => source}}) do
    source =
      case source do
        %{"content" => text} when is_binary(text) -> text
        text when is_binary(text) -> text
        _ -> source
      end

    source_is_only_mentions?(source)
  end

  defp only_mentions?(_), do: false

  defp source_is_only_mentions?(source) when is_binary(source) do
    non_mentions =
      source
      |> String.split()
      |> Enum.filter(&(not String.starts_with?(&1, "@")))
      |> length()

    non_mentions == 0
  end

  defp source_is_only_mentions?(_source), do: false

  defp is_note?(%{"object" => %{"type" => "Note"}}), do: true
  defp is_note?(_), do: false

  defp is_eligible_type?(%{"type" => type}) when type in ["Create", "Update"], do: true
  defp is_eligible_type?(_), do: false

  @impl true
  def describe, do: {:ok, %{}}
end
