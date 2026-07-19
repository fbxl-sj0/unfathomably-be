# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.PleromaAPI.ScrobbleViewTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Object
  alias Pleroma.Web.PleromaAPI.ScrobbleView

  import Pleroma.Factory

  test "successfully renders a Listen activity (pleroma extension)" do
    listen_activity = insert(:listen)

    status = ScrobbleView.render("show.json", activity: listen_activity)

    assert status.length == listen_activity.data["object"]["length"]
    assert status.title == listen_activity.data["object"]["title"]
  end

  test "renders native Funkwhale artist credits and Album objects" do
    listen_activity = insert(:listen)
    object = Object.normalize(listen_activity, fetch: false)

    object_data =
      object.data
      |> Map.delete("artist")
      |> Map.put("artist_credit", [
        %{
          "artist" => %{"name" => "Funkwhale <b>Artist</b>"},
          "name" => "Funkwhale <b>Artist</b>"
        }
      ])
      |> Map.put("album", %{"name" => "Funkwhale <i>Album</i>"})

    listen_activity = %{listen_activity | object: %{object | data: object_data}}
    status = ScrobbleView.render("show.json", activity: listen_activity)

    assert status.artist == "Funkwhale Artist"
    assert status.album == "Funkwhale Album"
  end
end
