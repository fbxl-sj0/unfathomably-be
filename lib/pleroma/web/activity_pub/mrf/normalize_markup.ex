# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.MRF.NormalizeMarkup do
  @moduledoc "Scrub configured hypertext markup"
  alias Pleroma.HTML

  @behaviour Pleroma.Web.ActivityPub.MRF.Policy

  @impl true
  def history_awareness, do: :auto

  @impl true
  def filter(%{"type" => type, "object" => object} = activity)
      when type in ["Create", "Update"] do
    scrub_policy = Pleroma.Config.get([:mrf_normalize_markup, :scrub_policy])

    object = scrub_object(object, scrub_policy)
    activity = Map.put(activity, "object", object)

    {:ok, activity}
  end

  def filter(activity), do: {:ok, activity}

  defp scrub_object(%{"content" => content} = object, scrub_policy) do
    object
    |> Map.put("content", HTML.filter_tags(content, scrub_policy))
    |> scrub_history(scrub_policy)
  end

  defp scrub_object(object, scrub_policy) do
    scrub_history(object, scrub_policy)
  end

  defp scrub_history(
         %{"formerRepresentations" => %{"orderedItems" => items} = history} = object,
         scrub_policy
       )
       when is_list(items) do
    history = Map.put(history, "orderedItems", Enum.map(items, &scrub_object(&1, scrub_policy)))
    Map.put(object, "formerRepresentations", history)
  end

  defp scrub_history(object, _scrub_policy), do: object

  @impl true
  def describe, do: {:ok, %{}}

  @impl true
  def config_description do
    %{
      key: :mrf_normalize_markup,
      related_policy: "Pleroma.Web.ActivityPub.MRF.NormalizeMarkup",
      label: "MRF Normalize Markup",
      description: "MRF NormalizeMarkup settings. Scrub configured hypertext markup.",
      children: [
        %{
          key: :scrub_policy,
          type: :module,
          suggestions: [Pleroma.HTML.Scrubber.Default]
        }
      ]
    }
  end
end
