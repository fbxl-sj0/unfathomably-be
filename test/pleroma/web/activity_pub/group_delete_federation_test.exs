# Unfathomably group federation
# ----------------------------
#
# File: group_delete_federation_test.exs
#
# Purpose:
#
#   Prove that deletes for local group-addressed content are forwarded by
#   the group actor for Threadiverse receivers.
#
# Responsibilities:
#
#   * build a public Delete activity with local group context
#   * run the group delete forwarding helper
#   * assert that the group actor creates the expected Announce
#
# This file intentionally does NOT contain:
#
#   * end-to-end remote Lemmy assertions
#   * browser or frontend smoke coverage
#

defmodule Pleroma.Web.ActivityPub.GroupDeleteFederationTest do
  use Pleroma.DataCase, async: true

  import Ecto.Query
  import Pleroma.Factory

  alias Pleroma.Activity
  alias Pleroma.Repo
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.ActivityPub.Utils

  require Pleroma.Constants

  test "announces local group-addressed deletes from the group actor" do
    actor = insert(:user)
    group = insert(:user, actor_type: "Group", local: true)

    {:ok, delete} =
      ActivityPub.insert(
        %{
          "id" => "https://local.example/activities/delete-group-comment",
          "type" => "Delete",
          "actor" => actor.ap_id,
          "object" => "https://local.example/objects/group-comment",
          "to" => [Pleroma.Constants.as_public()],
          "cc" => [group.ap_id],
          "audience" => group.ap_id
        },
        true
      )

    assert :ok = Utils.maybe_handle_group_deletes(delete)

    assert %Activity{} = announce = announced_activity(delete)
    assert announce.data["type"] == "Announce"
    assert announce.data["actor"] == group.ap_id
    assert announce.data["object"] == delete.data["id"]
    assert announce.data["audience"] == group.ap_id
    assert announce.data["to"] == [Pleroma.Constants.as_public()]
    assert group.follower_address in announce.data["cc"]
  end

  defp announced_activity(activity) do
    Repo.one(
      from(a in Activity,
        where:
          fragment("?->>'type' = 'Announce'", a.data) and
            fragment("?->>'object' = ?", a.data, ^activity.data["id"])
      )
    )
  end
end

# end of group_delete_federation_test.exs
