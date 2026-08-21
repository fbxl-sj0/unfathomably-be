# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2024 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Metadata.Providers.ActivityPubTest do
  use Pleroma.DataCase
  import Pleroma.Factory

  alias Pleroma.Web.CommonAPI
  alias Pleroma.Web.Metadata.Providers.ActivityPub

  test "it renders a link for user info" do
    user = insert(:user)
    res = ActivityPub.build_tags(%{user: user})

    assert res == [
             {:link, [rel: "alternate", type: "application/activity+json", href: user.ap_id], []},
             {:link,
              [
                rel: "alternate",
                type: "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\"",
                href: user.ap_id
              ], []}
           ]
  end

  test "it renders a link for a post" do
    user = insert(:user)
    {:ok, %{id: activity_id, object: object}} = CommonAPI.post(user, %{status: "hi"})

    result = ActivityPub.build_tags(%{object: object, user: user, activity_id: activity_id})

    assert [
             {:link,
              [rel: "alternate", type: "application/activity+json", href: object.data["id"]], []},
             {:link,
              [
                rel: "alternate",
                type: "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\"",
                href: object.data["id"]
              ], []},
             {:meta, [name: "fediverse:creator", content: "@#{Pleroma.User.full_nickname(user)}"],
              []}
           ] == result
  end

  test "it does not attribute a locally rendered remote post to an unverified creator" do
    user = insert(:user, local: false, nickname: "remote@example.com")

    result =
      ActivityPub.build_tags(%{
        object: %{data: %{"id" => "https://example.com/objects/1"}},
        user: user
      })

    assert result == [
             {:link,
              [
                rel: "alternate",
                type: "application/activity+json",
                href: "https://example.com/objects/1"
              ], []},
             {:link,
              [
                rel: "alternate",
                type: "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\"",
                href: "https://example.com/objects/1"
              ], []}
           ]
  end

  test "it returns no tags without a usable ActivityPub id" do
    assert ActivityPub.build_tags(%{}) == []
  end
end
