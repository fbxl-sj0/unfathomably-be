# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.Transmogrifier.CustomActivityHandlingTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Activity
  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.CustomObject
  alias Pleroma.Web.ActivityPub.Transmogrifier

  import Pleroma.Factory

  require Pleroma.Constants

  setup do
    repository =
      insert(:user,
        local: false,
        actor_type: "Repository",
        ap_id: "https://forge.example/repos/treesim",
        follower_address: "https://forge.example/repos/treesim/followers"
      )

    insert(:user,
      local: false,
      ap_id: "https://forge.example/users/aviva",
      follower_address: "https://forge.example/users/aviva/followers"
    )

    %{repository: repository}
  end

  test "stores and exports a ForgeFed Push as an inert activity", %{repository: repository} do
    push = File.read!("test/fixtures/forgefed-push.json") |> Jason.decode!()

    assert push["actor"] == repository.ap_id
    assert {:ok, %Activity{} = activity} = Transmogrifier.handle_incoming(push)

    assert activity.data["type"] == "Push"
    assert activity.data["hashBefore"] == push["hashBefore"]
    assert activity.data["hashAfter"] == push["hashAfter"]
    assert activity.data["object"]["orderedItems"] == push["object"]["orderedItems"]
    assert activity.data[CustomObject.internal_field()]["class"] == "process"
    assert Object.get_by_ap_id(push["id"]) == nil

    assert {:ok, exported} = Transmogrifier.prepare_outgoing(activity.data)
    assert exported["type"] == "Push"
    assert exported["object"] == push["object"]
    refute Map.has_key?(exported, CustomObject.internal_field())

    assert {:ok, ^activity} = Transmogrifier.handle_incoming(push)
  end

  test "rejects a Push whose activity ID is controlled by another origin" do
    push =
      File.read!("test/fixtures/forgefed-push.json")
      |> Jason.decode!()
      |> Map.put("id", "https://spoofed.example/outbox/push-1")

    assert {:error, _reason} = Transmogrifier.handle_incoming(push)
    assert Activity.get_by_ap_id(push["id"]) == nil
  end

  test "correlates a ForgeFed Ticket Offer and Accept without inventing local forge state" do
    {author, repository} = insert_offer_actors()
    offer = fixture("forgefed-ticket-offer.json")
    accept = fixture("forgefed-ticket-accept.json")

    assert offer["actor"] == author.ap_id
    refute Map.has_key?(offer["object"], "id")
    assert accept["actor"] == repository.ap_id
    assert accept["object"] == offer["id"]

    assert {:ok, %Activity{} = stored_offer} = Transmogrifier.handle_incoming(offer)
    assert stored_offer.data["object"] == offer["object"]
    assert stored_offer.data[CustomObject.internal_field()]["class"] == "process"

    assert {:ok, %Activity{} = stored_accept} = Transmogrifier.handle_incoming(accept)
    assert stored_accept.data["object"] == stored_offer.data["id"]
    assert stored_accept.data["result"] == accept["result"]
    assert Object.get_by_ap_id(accept["result"]) == nil

    assert {:ok, exported} = Transmogrifier.prepare_outgoing(stored_accept.data)
    assert exported["object"] == offer["id"]
    assert exported["result"] == accept["result"]
    refute is_map(exported["object"])

    assert {:ok, ^stored_offer} = Transmogrifier.handle_incoming(offer)
    assert {:ok, ^stored_accept} = Transmogrifier.handle_incoming(accept)
  end

  test "requires the ForgeFed Offer target to Accept or Reject" do
    {author, repository} = insert_offer_actors()
    offer = fixture("forgefed-ticket-offer.json")
    accept = fixture("forgefed-ticket-accept.json")

    assert {:ok, %Activity{}} = Transmogrifier.handle_incoming(offer)

    wrong_actor_accept =
      accept
      |> Map.put("id", "#{author.ap_id}/outbox/wrong-accept")
      |> Map.put("actor", author.ap_id)

    assert {:error, _reason} = Transmogrifier.handle_incoming(wrong_actor_accept)

    missing_result_accept =
      accept
      |> Map.put("id", "#{repository.ap_id}/outbox/missing-result")
      |> Map.delete("result")

    assert {:error, _reason} = Transmogrifier.handle_incoming(missing_result_accept)

    reject =
      accept
      |> Map.put("id", "#{repository.ap_id}/outbox/reject-1")
      |> Map.put("type", "Reject")
      |> Map.delete("result")

    assert {:ok, %Activity{} = stored_reject} = Transmogrifier.handle_incoming(reject)
    assert stored_reject.data["object"] == offer["id"]
    refute Map.has_key?(stored_reject.data, "result")

    assert {:ok, exported} = Transmogrifier.prepare_outgoing(stored_reject.data)
    assert exported["object"] == offer["id"]
    refute is_map(exported["object"])
  end

  test "unwraps an Ibis Group Announce around an Edit activity" do
    group =
      insert(:user,
        local: false,
        actor_type: "Group",
        ap_id: "https://ibis.example/",
        follower_address: nil
      )

    editor =
      insert(:user,
        local: false,
        ap_id: "https://ibis.example/user/editor",
        follower_address: nil
      )

    edit = %{
      "actor" => editor.ap_id,
      "cc" => [],
      "id" => "https://ibis.example/activity/edit-1",
      "object" => %{
        "attributedTo" => editor.ap_id,
        "content" => "--- original\n+++ modified\n",
        "id" => "https://ibis.example/article/Alien_Wiki/version-2",
        "object" => "https://ibis.example/article/Alien_Wiki",
        "type" => "Patch",
        "version" => "22222222-2222-4222-8222-222222222222"
      },
      "to" => [Pleroma.Constants.as_public(), group.ap_id],
      "type" => "Edit"
    }

    announce = %{
      "actor" => group.ap_id,
      "cc" => ["https://ibis.example/followers"],
      "id" => "https://ibis.example/activity/announce-edit-1",
      "object" => edit,
      "to" => [Pleroma.Constants.as_public()],
      "type" => "Announce"
    }

    assert {:ok, %Activity{} = stored_edit} = Transmogrifier.handle_incoming(announce)
    assert stored_edit.data["id"] == edit["id"]
    assert stored_edit.data["type"] == "Edit"
    assert stored_edit.data["object"]["type"] == "Patch"
    assert Activity.get_by_ap_id(announce["id"]) == nil
  end

  defp insert_offer_actors do
    author =
      insert(:user,
        local: false,
        ap_id: "https://forge.example/luke",
        follower_address: "https://forge.example/luke/followers"
      )

    repository =
      insert(:user,
        local: false,
        actor_type: "Repository",
        ap_id: "https://dev.example/aviva/game-of-life",
        follower_address: "https://dev.example/aviva/game-of-life/followers"
      )

    {author, repository}
  end

  defp fixture(name) do
    "test/fixtures/#{name}"
    |> File.read!()
    |> Jason.decode!()
  end
end

# end of test/pleroma/web/activity_pub/transmogrifier/custom_activity_handling_test.exs
