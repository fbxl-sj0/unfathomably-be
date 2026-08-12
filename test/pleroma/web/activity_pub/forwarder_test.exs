# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ForwarderTest do
  use Pleroma.DataCase

  import Pleroma.Factory

  alias Pleroma.Activity
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ForwardedActivityVerifier
  alias Pleroma.Web.ActivityPub.Forwarder

  @public "https://www.w3.org/ns/activitystreams#Public"
  @object_id "https://origin.example/objects/quoted"

  test "plans one forwarded delivery per affected remote inbox" do
    quoter = insert(:user)
    quote = insert(:note, user: quoter, data: %{"quoteUrl" => @object_id})
    insert(:note_activity, user: quoter, note: quote)

    follower =
      insert(:user,
        local: false,
        ap_id: "https://follower.example/users/alice",
        inbox: "https://follower.example/users/alice/inbox",
        shared_inbox: "https://follower.example/inbox"
      )

    assert {:ok, _follower, _quoter} = User.follow(follower, quoter)

    data = forwarded_delete()

    activity = %Activity{
      actor: data["actor"],
      data: data,
      recipients: [@public]
    }

    assert ForwardedActivityVerifier.forwardable?(data)

    quoter_id = quoter.id

    assert [%{actor: %{id: ^quoter_id}, inbox: "https://follower.example/inbox"}] =
             Forwarder.delivery_plan(data, activity)
  end

  test "does not recognize a malformed embedded proof as forwardable" do
    data = put_in(forwarded_delete()["signature"]["signatureValue"], "not-base64")

    refute ForwardedActivityVerifier.forwardable?(data)
  end

  test "does not forward for an unpublished local quote object" do
    quoter = insert(:user)
    insert(:note, user: quoter, data: %{"quoteUrl" => @object_id})

    follower =
      insert(:user,
        local: false,
        ap_id: "https://follower.example/users/unpublished",
        inbox: "https://follower.example/users/unpublished/inbox"
      )

    assert {:ok, _follower, _quoter} = User.follow(follower, quoter)

    data = forwarded_delete()

    activity = %Activity{
      actor: data["actor"],
      data: data,
      recipients: [@public]
    }

    assert Forwarder.delivery_plan(data, activity) == []
  end

  defp forwarded_delete do
    %{
      "actor" => "https://origin.example/users/author",
      "cc" => [],
      "id" => "https://origin.example/activities/delete-quoted",
      "object" => @object_id,
      "signature" => %{
        "created" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "creator" => "https://origin.example/users/author#main-key",
        "signatureValue" => Base.encode64(:crypto.strong_rand_bytes(256)),
        "type" => "RsaSignature2017"
      },
      "to" => [@public],
      "type" => "Delete"
    }
  end
end

# end of web/activity_pub/forwarder_test.exs
