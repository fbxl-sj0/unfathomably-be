# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.FeatureAuthorizationTest do
  use Pleroma.DataCase, async: true

  import Pleroma.Factory

  alias Pleroma.Activity
  alias Pleroma.FeatureAuthorization
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Pipeline

  test "a discoverable local actor accepts and publishes reusable collection consent" do
    featured = insert(:user, is_discoverable: true)
    requester = insert(:user, local: false)
    collection_uri = requester.ap_id <> "/collections/starter-pack"

    data = request_data(requester, featured, collection_uri)

    assert {:ok, %Activity{}, _meta} = Pipeline.common_pipeline(data, local: false)

    authorization = Repo.get_by!(FeatureAuthorization, user_id: featured.id)
    assert authorization.collection_uri == collection_uri

    assert {:ok, document} = FeatureAuthorization.authorization_document(authorization.id)

    assert document["interactingObject"] == collection_uri
    assert document["interactionTarget"] == featured.ap_id

    accept = response_activity("Accept", data["id"])
    assert accept.data["result"] == FeatureAuthorization.authorization_uri(authorization)
  end

  test "a non-discoverable local actor rejects collection consent without storing it" do
    featured = insert(:user, is_discoverable: false)
    requester = insert(:user, local: false)
    data = request_data(requester, featured, requester.ap_id <> "/collections/private")

    assert {:ok, %Activity{}, _meta} = Pipeline.common_pipeline(data, local: false)
    assert Repo.aggregate(FeatureAuthorization, :count, :id) == 0
    assert response_activity("Reject", data["id"])
  end

  test "withdrawing discoverability immediately withdraws the authorization document" do
    featured = insert(:user, is_discoverable: true)

    authorization =
      Repo.insert!(
        FeatureAuthorization.changeset(%FeatureAuthorization{}, %{
          user_id: featured.id,
          requester_actor: "https://remote.example/users/alice",
          collection_uri: "https://remote.example/collections/pack",
          request_ap_id: "https://remote.example/feature-requests/1"
        })
      )

    assert {:ok, _document} = FeatureAuthorization.authorization_document(authorization.id)

    assert {:ok, _user} =
             featured
             |> Ecto.Changeset.change(is_discoverable: false)
             |> User.update_and_set_cache()

    assert {:error, :not_found} = FeatureAuthorization.authorization_document(authorization.id)
  end

  defp request_data(requester, featured, collection_uri) do
    %{
      "actor" => requester.ap_id,
      "id" => requester.ap_id <> "/feature-requests/" <> Ecto.UUID.generate(),
      "instrument" => collection_uri,
      "object" => featured.ap_id,
      "to" => [featured.ap_id],
      "type" => "FeatureRequest"
    }
  end

  defp response_activity(type, request_id) do
    type
    |> Activity.Queries.by_type()
    |> Repo.all()
    |> Enum.find(&(&1.data["object"] == request_id))
  end
end

# end of feature_authorization_test.exs
