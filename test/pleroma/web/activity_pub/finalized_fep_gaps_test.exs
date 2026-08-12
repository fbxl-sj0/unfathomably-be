# Unfathomably finalized FEP regression tests
#
# File: finalized_fep_gaps_test.exs
#
# Purpose:
#   Cover structural Object Links, actor Multikeys, synchronization digests,
#   and owner-confirmed appendable collections.

defmodule Pleroma.Web.ActivityPub.FinalizedFEPGapsTest do
  use Pleroma.Web.ConnCase

  import Pleroma.Factory

  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.AppendableCollection
  alias Pleroma.Web.ActivityPub.FollowersSynchronization
  alias Pleroma.Web.ActivityPub.MRF.QuoteToLinkTagPolicy
  alias Pleroma.Web.ActivityPub.UserView

  require Pleroma.Constants

  test "quoted objects carry a structural Link while ordinary objects are unchanged" do
    ordinary = %{"type" => "Create", "object" => %{"type" => "Note"}}
    assert QuoteToLinkTagPolicy.add_object_link_tag(ordinary) == ordinary

    activity = %{
      "type" => "Create",
      "object" => %{"type" => "Note", "quoteUrl" => "https://remote.example/objects/1"}
    }

    result = QuoteToLinkTagPolicy.add_object_link_tag(activity)

    assert Enum.any?(result["object"]["tag"], fn tag ->
             tag["type"] == "Link" and tag["href"] == "https://remote.example/objects/1"
           end)
  end

  test "local actors publish their existing key as a Multikey assertion method" do
    user = insert(:user)
    actor = UserView.render("user.json", %{user: user})

    assert [method] = actor["assertionMethod"]
    assert method["id"] == user.ap_id <> "#main-key"
    assert method["controller"] == user.ap_id
    assert method["type"] == "Multikey"
    assert String.starts_with?(method["publicKeyMultibase"], "z")
  end

  test "follower synchronization digest is order independent and bounded" do
    first = "https://local.example/users/first"
    second = "https://local.example/users/second"

    assert FollowersSynchronization.digest([first, second]) ==
             FollowersSynchronization.digest([second, first])

    assert FollowersSynchronization.digest([]) == String.duplicate("0", 64)
  end

  test "an appendable wall exposes only owner-confirmed memberships" do
    owner = insert(:user)
    creator = insert(:user, local: false, ap_id: "https://remote.example/users/creator")
    object_id = "https://remote.example/objects/appendable"
    target = AppendableCollection.collection(owner)

    {:ok, _object} =
      Object.create(%{
        "id" => object_id,
        "type" => "Note",
        "actor" => creator.ap_id,
        "attributedTo" => creator.ap_id,
        "target" => target,
        "to" => [Pleroma.Constants.as_public()],
        "cc" => []
      })

    refute object_id in AppendableCollection.items(owner)
    assert AppendableCollection.authorized?(target["id"], owner, object_id)

    assert {:ok, _object} =
             AppendableCollection.apply_change("Add", target["id"], owner, object_id)

    assert object_id in AppendableCollection.items(owner)

    assert {:ok, _object} =
             AppendableCollection.apply_change("Remove", target["id"], owner, object_id)

    refute object_id in AppendableCollection.items(owner)
  end

  test "unsigned follower synchronization requests return a client response", %{conn: conn} do
    user = insert(:user)

    conn =
      conn
      |> put_req_header("accept", "application/activity+json")
      |> get("/users/#{user.nickname}/followers_synchronization")

    assert json_response(conn, 404) == %{"error" => "Not found"}
  end
end

# end of finalized_fep_gaps_test.exs
