# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.MRF.AntiLinkSpamPolicy do
  alias Pleroma.User

  @behaviour Pleroma.Web.ActivityPub.MRF.Policy

  @impl true
  def history_awareness, do: :auto

  # has the user successfully posted before?
  defp old_user?(%User{} = u) do
    u.note_count > 0 || u.follower_count > 0
  end

  defp content_contains_links?(content) when is_binary(content) do
    content
    |> Floki.parse_fragment!()
    |> Floki.filter_out("a.mention,a.hashtag,a[rel~=\"tag\"],a.zrl")
    |> Floki.attribute("a", "href")
    |> length() > 0
  end

  defp content_contains_links?(_), do: false

  defp history_items(%{"formerRepresentations" => %{"orderedItems" => items}})
       when is_list(items) do
    items
  end

  defp history_items(_object), do: []

  # does the post contain links?
  defp contains_links?(%{"content" => content} = object) do
    content_contains_links?(content) or Enum.any?(history_items(object), &contains_links?/1)
  end

  defp contains_links?(object) when is_map(object) do
    Enum.any?(history_items(object), &contains_links?/1)
  end

  defp contains_links?(_), do: false

  @impl true
  def filter(%{"type" => "Create", "actor" => actor, "object" => object} = activity) do
    with {:ok, %User{local: false} = u} <- User.get_or_fetch_by_ap_id(actor),
         {:contains_links, true} <- {:contains_links, contains_links?(object)},
         {:old_user, true} <- {:old_user, old_user?(u)} do
      {:ok, activity}
    else
      {:ok, %User{local: true}} ->
        {:ok, activity}

      {:contains_links, false} ->
        {:ok, activity}

      {:old_user, false} ->
        {:reject, "[AntiLinkSpamPolicy] User has no posts nor followers"}

      {:error, _} ->
        {:reject, "[AntiLinkSpamPolicy] Failed to get or fetch user by ap_id"}

      e ->
        {:reject, "[AntiLinkSpamPolicy] Unhandled error #{inspect(e)}"}
    end
  end

  # in all other cases, pass through
  def filter(activity), do: {:ok, activity}

  @impl true
  def describe, do: {:ok, %{}}
end
