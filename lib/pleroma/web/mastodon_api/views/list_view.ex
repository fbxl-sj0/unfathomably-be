# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.ListView do
  use Pleroma.Web, :view
  alias Pleroma.Web.MastodonAPI.ListView

  def render("index.json", %{lists: lists} = opts) do
    render_many(lists, ListView, "show.json", opts)
  end

  def render("show.json", %{list: list}) do
    %{
      id: to_string(list.id),
      title: list.title,
      exclusive: list.exclusive,
      pleroma: %{
        emoji: list.emoji,
        emoji_url: emoji_url(list.emoji)
      }
    }
  end

  defp emoji_url(nil), do: nil

  defp emoji_url(emoji) do
    if Pleroma.Emoji.is_unicode_emoji?(emoji) do
      nil
    else
      case Pleroma.Emoji.get(emoji) do
        %{file: relative_url} -> Pleroma.Emoji.local_url(relative_url)
        _ -> nil
      end
    end
  end
end
