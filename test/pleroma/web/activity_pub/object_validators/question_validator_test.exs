# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.QuestionValidatorTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Web.ActivityPub.ObjectValidators.QuestionValidator

  import Pleroma.Factory

  require Pleroma.Constants

  test "it accepts Mastodon-style interaction collections on poll updates" do
    actor =
      insert(:user,
        local: false,
        ap_id: "https://social.coop/users/cwebber",
        follower_address: "https://social.coop/users/cwebber/followers"
      )

    data = %{
      "id" => "https://social.coop/users/cwebber/statuses/116850393571642206",
      "type" => "Question",
      "actor" => actor.ap_id,
      "attributedTo" => actor.ap_id,
      "context" => "https://social.coop/contexts/113482993316443450-116850393571642206",
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [actor.follower_address],
      "content" => "<p>how old are you</p>",
      "published" => "2026-07-02T12:31:47Z",
      "endTime" => "2026-07-03T12:31:47Z",
      "oneOf" => [
        %{"name" => "a little baby", "replies" => %{"type" => "Collection", "totalItems" => 23}},
        %{
          "name" => "a sassy whippersnapper",
          "replies" => %{"type" => "Collection", "totalItems" => 80}
        }
      ],
      "likes" => %{
        "id" => "https://social.coop/users/cwebber/statuses/116850393571642206/likes",
        "type" => "Collection",
        "totalItems" => 30
      },
      "shares" => %{
        "id" => "https://social.coop/users/cwebber/statuses/116850393571642206/shares",
        "type" => "Collection",
        "totalItems" => 87
      }
    }

    assert {:ok, question} =
             data
             |> QuestionValidator.cast_and_validate()
             |> Ecto.Changeset.apply_action(:insert)

    assert question.likes == []
    assert question.like_count == 30
    assert question.announcements == []
    assert question.announcement_count == 87
    assert question.closed == "2026-07-03T12:31:47Z"
  end
end
