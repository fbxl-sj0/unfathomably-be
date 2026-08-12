# Unfathomably BE
# ----------------
#
# File: object_validators/update_validator_test.exs
#
# Purpose:
#   Exercise ownership checks for incoming ActivityPub Update activities.
#
# Responsibilities:
#   - accept updates from an actor present in stored and incoming ownership sets
#   - reject updates that add a new actor only in the incoming representation
#
# This file intentionally does NOT exercise object persistence or Update side
# effects; those are covered by the ActivityPub pipeline tests.

defmodule Pleroma.Web.ActivityPub.ObjectValidators.UpdateValidatorTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Web.ActivityPub.ObjectValidators.UpdateValidator

  import Pleroma.Factory

  require Pleroma.Constants

  test "accepts a PeerTube-style update from one member of a stable attributedTo list" do
    account = insert(:user, local: false)
    channel = insert(:user, local: false, actor_type: "Group")

    object =
      insert(:note,
        user: account,
        data: %{
          "actor" => channel.ap_id,
          "attributedTo" => [
            %{"id" => account.ap_id, "type" => "Person"},
            %{"id" => channel.ap_id, "type" => "Group"}
          ]
        }
      )

    update = update_data(object.data, account.ap_id)

    assert %{valid?: true} = UpdateValidator.cast_and_validate(update)
  end

  test "rejects an actor added only to the incoming ownership list" do
    stored_account = insert(:user, local: false)
    injected_account = insert(:user, local: false)

    object = insert(:note, user: stored_account)

    incoming_object =
      Map.put(object.data, "attributedTo", [stored_account.ap_id, injected_account.ap_id])

    update = update_data(incoming_object, injected_account.ap_id)

    assert %{valid?: false, errors: errors} = UpdateValidator.cast_and_validate(update)
    assert {:object, {"Can't be updated by this actor", []}} in errors
  end

  test "rejects updates that would resurrect a Tombstone" do
    actor = insert(:user, local: false)

    tombstone =
      insert(:note,
        user: actor,
        data: %{
          "type" => "Tombstone",
          "formerType" => "Video",
          "deleted" => "2025-01-27T09:06:05Z"
        }
      )

    incoming_object =
      tombstone.data
      |> Map.put("type", "Video")
      |> Map.put("actor", actor.ap_id)
      |> Map.put("attributedTo", actor.ap_id)

    update = update_data(incoming_object, actor.ap_id)

    assert %{valid?: false, errors: errors} = UpdateValidator.cast_and_validate(update)
    assert {:object, {"Deleted object can't be updated", []}} in errors
  end

  defp update_data(object, actor) do
    %{
      "id" => "#{object["id"]}/updates/1",
      "type" => "Update",
      "actor" => actor,
      "object" => object,
      "to" => [Pleroma.Constants.as_public()],
      "cc" => []
    }
  end
end

# end of object_validators/update_validator_test.exs
