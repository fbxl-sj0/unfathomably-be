# Pleroma: A lightweight social networking server
# Copyright Â© 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.PleromaAPI.ScrobbleView do
  use Pleroma.Web, :view

  alias Pleroma.Activity
  alias Pleroma.HTML
  alias Pleroma.Object
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Web.CommonAPI.Utils
  alias Pleroma.Web.MastodonAPI.AccountView

  def render("show.json", %{activity: %Activity{data: %{"type" => "Listen"}} = activity} = opts) do
    object = Object.normalize(activity, fetch: false)

    user = CommonAPI.get_user(activity.data["actor"])
    created_at = Utils.to_masto_date(activity.data["published"])

    external_link = object.data["externalLink"] || object.data["url"] || object.data["id"]
    title = object.data["title"] || object.data["name"]
    artist = object.data["artist"] || funkwhale_artist(object.data)

    %{
      id: activity.id,
      account: AccountView.render("show.json", %{user: user, for: opts[:for]}),
      created_at: created_at,
      title: scrub_text(title),
      artist: scrub_text(artist),
      album: scrub_text(object.data["album"]),
      externalLink: external_link,
      url: external_link,
      length: object.data["length"]
    }
  end

  def render("index.json", opts) do
    safe_render_many(opts.activities, __MODULE__, "show.json", opts)
  end

  defp funkwhale_artist(%{"artist_credit" => credit}) when is_list(credit) do
    credit
    |> Enum.map(fn
      %{"name" => name} when is_binary(name) -> name
      %{"artist" => %{"name" => name}} when is_binary(name) -> name
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
  end

  defp funkwhale_artist(_), do: nil

  # Funkwhale embeds an Album object in Track and Listen payloads.  The
  # Pleroma scrobble extension uses plain strings, so keep its response shape
  # while accepting the native object without handing a map to FastSanitize.
  defp scrub_text(text) when is_binary(text), do: HTML.strip_tags(text)
  defp scrub_text(%{"name" => name}) when is_binary(name), do: HTML.strip_tags(name)
  defp scrub_text(_), do: ""
end
