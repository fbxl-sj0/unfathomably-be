# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.FederatedSourceTimelineControllerTest do
  use Pleroma.Web.ConnCase

  alias Pleroma.User

  import Pleroma.Factory

  require Pleroma.Constants

  describe "GET /api/v1/timelines/feeds" do
    setup do: oauth_access(["read:statuses"])

    test "returns root posts authored by followed feeds", %{conn: conn, user: user} do
      source =
        insert(:user,
          actor_type: "Application",
          local: false,
          nickname: "library@audio.example",
          ap_id: "https://audio.example/federation/music/libraries/everyone",
          name: "Everyone's Music"
        )

      unfollowed_source =
        insert(:user,
          actor_type: "Application",
          local: false,
          nickname: "other@audio.example",
          ap_id: "https://audio.example/federation/music/libraries/other"
        )

      {:ok, _, _} = User.follow(user, source)

      context = "https://audio.example/tracks/1"

      root =
        insert(:note,
          user: source,
          data: %{
            "content" => "<p>A followed feed root.</p>",
            "context" => context,
            "to" => [Pleroma.Constants.as_public()]
          }
        )

      followed_activity =
        insert(:note_activity,
          user: source,
          note: root,
          local: false,
          data_attrs: %{
            "context" => context,
            "to" => [Pleroma.Constants.as_public()]
          }
        )

      reply =
        insert(:note,
          user: source,
          data: %{
            "content" => "<p>A followed feed reply.</p>",
            "context" => context,
            "inReplyTo" => root.data["id"],
            "to" => [Pleroma.Constants.as_public()]
          }
        )

      insert(:note_activity,
        user: source,
        note: reply,
        local: false,
        data_attrs: %{
          "context" => context,
          "to" => [Pleroma.Constants.as_public()]
        }
      )

      other_root =
        insert(:note,
          user: unfollowed_source,
          data: %{
            "content" => "<p>An unfollowed feed root.</p>",
            "to" => [Pleroma.Constants.as_public()]
          }
        )

      insert(:note_activity,
        user: unfollowed_source,
        note: other_root,
        local: false,
        data_attrs: %{"to" => [Pleroma.Constants.as_public()]}
      )

      assert [%{"id" => followed_activity_id, "content" => content}] =
               conn
               |> get("/api/v1/timelines/feeds")
               |> json_response(200)

      assert followed_activity_id == to_string(followed_activity.id)
      assert content =~ "A followed feed root"
    end
  end
end
