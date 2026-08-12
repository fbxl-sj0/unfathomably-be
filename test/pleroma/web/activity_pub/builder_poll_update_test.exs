# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.BuilderPollUpdateTest do
  use ExUnit.Case, async: true

  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Builder

  test "Question Updates blind-copy known voters and participants" do
    actor = %User{
      ap_id: "https://local.example/users/author",
      follower_address: "https://local.example/users/author/followers"
    }

    question = %{
      "id" => "https://local.example/questions/1",
      "type" => "Question",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "participations" => ["https://remote.example/users/participant"],
      "voters" => [
        "https://remote.example/users/voter",
        "https://remote.example/users/voter",
        nil
      ]
    }

    assert {:ok, activity, []} = Builder.update(actor, question)

    assert MapSet.new(activity["bcc"]) ==
             MapSet.new([
               "https://remote.example/users/participant",
               "https://remote.example/users/voter"
             ])
  end

  test "Update IDs are stable for one object revision and distinct between objects" do
    actor = %User{
      ap_id: "https://local.example/users/author",
      follower_address: "https://local.example/users/author/followers"
    }

    updated = "2026-08-08T12:34:56.123456Z"

    question = %{
      "id" => "https://local.example/questions/1",
      "type" => "Question",
      "updated" => updated,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => []
    }

    other_question = Map.put(question, "id", "https://local.example/questions/2")

    assert {:ok, first, []} = Builder.update(actor, question)
    assert {:ok, repeated, []} = Builder.update(actor, question)
    assert {:ok, other, []} = Builder.update(actor, other_question)

    assert first["id"] == repeated["id"]
    refute first["id"] == other["id"]
  end
end

# end of builder_poll_update_test.exs
