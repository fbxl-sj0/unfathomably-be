# Pleroma: A lightweight social networking server
# Copyright © 2017-2023 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.MRF.QuoteToLinkTagPolicy do
  @moduledoc "Force a Link tag for posts quoting another post. (may break outgoing federation of quote posts with older Pleroma versions)"
  @behaviour Pleroma.Web.ActivityPub.MRF.Policy

  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonFixes

  require Pleroma.Constants

  @impl true
  def filter(%{"object" => %{"quoteUrl" => _} = object} = activity) do
    {:ok, Map.put(activity, "object", filter_object(object))}
  end

  @impl true
  def filter(activity), do: {:ok, activity}

  @impl true
  def describe, do: {:ok, %{}}

  @impl true
  def history_awareness, do: :auto

  defp filter_object(%{"quoteUrl" => quote_url} = object) do
    tags = tag_list(object["tag"])

    if Enum.any?(tags, fn tag ->
         CommonFixes.is_object_link_tag(tag) and tag["href"] == quote_url
       end) do
      object
    else
      object
      |> Map.put(
        "tag",
        tags ++
          [
            %{
              "type" => "Link",
              "mediaType" => Pleroma.Constants.activity_json_canonical_mime_type(),
              "href" => quote_url
            }
          ]
      )
    end
  end

  defp tag_list(values) when is_list(values), do: Enum.filter(values, &valid_tag?/1)
  defp tag_list(value) when is_map(value), do: [value]
  defp tag_list(value) when is_binary(value), do: [value]
  defp tag_list(_), do: []

  defp valid_tag?(value) when is_map(value), do: true
  defp valid_tag?(value) when is_binary(value), do: true
  defp valid_tag?(_), do: false
end
