# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.MRF.NoPlaceholderTextPolicy do
  @moduledoc "Ensure no content placeholder is present (such as the dot from mastodon)"
  @behaviour Pleroma.Web.ActivityPub.MRF.Policy

  @impl true
  def history_awareness, do: :auto

  @impl true
  def filter(%{"type" => type, "object" => object} = activity)
      when type in ["Create", "Update"] do
    {:ok, Map.put(activity, "object", scrub_object(object))}
  end

  @impl true
  def filter(activity), do: {:ok, activity}

  defp scrub_object(%{"content" => content, "attachment" => _} = object)
       when content in [".", "<p>.</p>"] do
    object
    |> Map.put("content", "")
    |> scrub_history()
  end

  defp scrub_object(object), do: scrub_history(object)

  defp scrub_history(%{"formerRepresentations" => %{"orderedItems" => items} = history} = object)
       when is_list(items) do
    history = Map.put(history, "orderedItems", Enum.map(items, &scrub_object/1))
    Map.put(object, "formerRepresentations", history)
  end

  defp scrub_history(object), do: object

  @impl true
  def describe, do: {:ok, %{}}
end
