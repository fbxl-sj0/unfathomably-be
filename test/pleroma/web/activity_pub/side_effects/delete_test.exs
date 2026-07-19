# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.SideEffects.DeleteTest do
  use Oban.Testing, repo: Pleroma.Repo
  use Pleroma.DataCase, async: true

  alias Pleroma.Activity
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.Tests.ObanHelpers
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.ActivityPub.Builder
  alias Pleroma.Web.ActivityPub.SideEffects
  alias Pleroma.Web.CommonAPI

  alias Pleroma.LoggerMock
  alias Pleroma.Web.ActivityPub.ActivityPubMock

  import Mox
  import Pleroma.Factory

  describe "user deletion" do
    setup do
      user = insert(:user)

      {:ok, delete_user_data, _meta} = Builder.delete(user, user.ap_id)
      {:ok, delete_user, _meta} = ActivityPub.persist(delete_user_data, local: true)

      %{
        user: user,
        delete_user: delete_user
      }
    end

    test "it handles user deletions", %{delete_user: delete, user: user} do
      {:ok, _delete, _} = SideEffects.handle(delete)
      ObanHelpers.perform_all()

      refute User.get_cached_by_ap_id(user.ap_id).is_active
    end

    test "a Manyfold model deletion removes its same-origin compatibility Note" do
      resource_url = "https://manyfold.example/models/model-1"

      model =
        insert(:user,
          local: false,
          ap_id: "https://manyfold.example/federation/actors/model-1",
          uri: resource_url,
          actor_type: "Service",
          actor_extensions: %{"f3di:concreteType" => "3DModel"}
        )

      creator =
        insert(:user,
          local: false,
          ap_id: "https://manyfold.example/federation/actors/creator-1"
        )

      compatibility_note =
        insert(:note,
          user: creator,
          data: %{
            "id" => "https://manyfold.example/federation/published/comments/model-1",
            "actor" => creator.ap_id,
            "attributedTo" => creator.ap_id,
            "context" => resource_url,
            "url" => resource_url
          }
        )

      cross_origin_note =
        insert(:note,
          user: insert(:user, local: false, ap_id: "https://other.example/users/creator"),
          data: %{
            "id" => "https://other.example/notes/model-1",
            "actor" => "https://other.example/users/creator",
            "attributedTo" => "https://other.example/users/creator",
            "context" => resource_url,
            "url" => resource_url
          }
        )

      {:ok, delete_data, _meta} = Builder.delete(model, model.ap_id)
      {:ok, delete, _meta} = ActivityPub.persist(delete_data, local: false)

      ActivityPubMock
      |> expect(:stream_out, fn ^delete -> nil end)
      |> expect(:stream_out_participations, fn %Object{id: id}, %User{id: creator_id} ->
        assert id == compatibility_note.id
        assert creator_id == creator.id
      end)

      assert {:ok, ^delete, _meta} = SideEffects.handle(delete)
      assert Object.get_by_id(compatibility_note.id).data["type"] == "Tombstone"
      assert Object.get_by_id(cross_origin_note.id).data["type"] == "Note"
      refute User.get_cached_by_ap_id(model.ap_id).is_active
    end
  end

  describe "object deletion" do
    setup do
      user = insert(:user)
      other_user = insert(:user)

      {:ok, op} = CommonAPI.post(other_user, %{status: "big oof"})
      {:ok, post} = CommonAPI.post(user, %{status: "hey", in_reply_to_id: op})
      {:ok, favorite} = CommonAPI.favorite(user, post.id)
      object = Object.normalize(post, fetch: false)
      {:ok, delete_data, _meta} = Builder.delete(user, object.data["id"])
      {:ok, delete, _meta} = ActivityPub.persist(delete_data, local: true)

      %{
        user: user,
        delete: delete,
        post: post,
        object: object,
        op: op,
        favorite: favorite
      }
    end

    test "it handles object deletions", %{
      delete: delete,
      post: post,
      object: object,
      user: user,
      op: op,
      favorite: favorite
    } do
      object_id = object.id
      user_id = user.id

      ActivityPubMock
      |> expect(:stream_out, fn ^delete -> nil end)
      |> expect(:stream_out_participations, fn %Object{id: ^object_id}, %User{id: ^user_id} ->
        nil
      end)

      {:ok, _delete, _} = SideEffects.handle(delete)
      user = User.get_cached_by_ap_id(object.data["actor"])

      object = Object.get_by_id(object.id)
      assert object.data["type"] == "Tombstone"
      refute Activity.get_by_id(post.id)
      refute Activity.get_by_id(favorite.id)

      user = User.get_by_id(user.id)
      assert user.note_count == 0

      object = Object.normalize(op.data["object"], fetch: false)

      assert object.data["repliesCount"] == 0
    end

    test "it handles object deletions when the object itself has been pruned", %{
      delete: delete,
      post: post,
      object: object,
      user: user,
      op: op
    } do
      object_id = object.id
      user_id = user.id

      ActivityPubMock
      |> expect(:stream_out, fn ^delete -> nil end)
      |> expect(:stream_out_participations, fn %Object{id: ^object_id}, %User{id: ^user_id} ->
        nil
      end)

      {:ok, _delete, _} = SideEffects.handle(delete)
      user = User.get_cached_by_ap_id(object.data["actor"])

      object = Object.get_by_id(object.id)
      assert object.data["type"] == "Tombstone"
      refute Activity.get_by_id(post.id)

      user = User.get_by_id(user.id)
      assert user.note_count == 0

      object = Object.normalize(op.data["object"], fetch: false)

      assert object.data["repliesCount"] == 0
    end

    test "it treats deletion of an existing Tombstone as idempotent", %{
      delete: delete,
      object: object
    } do
      assert {:ok, tombstone, _activity} = Object.delete(object)
      assert tombstone.data["type"] == "Tombstone"

      assert {:ok, ^delete, _meta} = SideEffects.handle(delete)
    end

    test "it logs issues with objects deletion", %{
      delete: delete,
      object: object
    } do
      {:ok, _object} =
        object
        |> Object.change(%{data: Map.delete(object.data, "actor")})
        |> Repo.update()

      LoggerMock
      |> expect(:error, fn str -> assert str =~ "The object doesn't have an actor" end)

      {:error, :no_object_actor} = SideEffects.handle(delete)
    end
  end
end
