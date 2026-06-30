# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.DeleteValidationTest do
  use Pleroma.DataCase, async: false

  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.Builder
  alias Pleroma.Web.ActivityPub.ObjectValidator
  alias Pleroma.Web.ActivityPub.Pipeline
  alias Pleroma.Web.CommonAPI

  import Pleroma.Factory

  describe "deletes" do
    setup do
      user = insert(:user)
      {:ok, post_activity} = CommonAPI.post(user, %{status: "cancel me daddy"})

      {:ok, valid_post_delete, _} = Builder.delete(user, post_activity.data["object"])
      {:ok, valid_user_delete, _} = Builder.delete(user, user.ap_id)

      %{user: user, valid_post_delete: valid_post_delete, valid_user_delete: valid_user_delete}
    end

    test "it is valid for a post deletion", %{valid_post_delete: valid_post_delete} do
      {:ok, valid_post_delete, _} = ObjectValidator.validate(valid_post_delete, [])

      assert valid_post_delete["deleted_activity_id"]
    end

    test "it is valid when the object was pruned but the Create activity remains", %{
      user: user,
      valid_post_delete: valid_post_delete
    } do
      object_id = valid_post_delete["object"]
      object = Object.get_by_ap_id(object_id)

      {:ok, _object} = Object.prune(object)
      {:ok, pruned_delete, _} = Builder.delete(user, object_id)

      assert {:ok, _delete, meta} = ObjectValidator.validate(pruned_delete, [])
      assert %{state: :pruned_object_with_create, object_id: ^object_id} = meta[:delete_target]
    end

    test "it marks a repeated delete for a tombstoned object as idempotent", %{
      valid_post_delete: valid_post_delete
    } do
      {:ok, first_delete, _meta} = Pipeline.common_pipeline(valid_post_delete, local: true)

      duplicate_delete =
        valid_post_delete
        |> Map.put("id", "#{valid_post_delete["id"]}/duplicate")

      assert {:ok, _delete, meta} = ObjectValidator.validate(duplicate_delete, [])

      assert %{state: :tombstone_duplicate, existing_delete: existing_delete} =
               meta[:delete_target]

      assert existing_delete.id == first_delete.id
    end

    test "it is invalid if the object isn't in a list of certain types", %{
      valid_post_delete: valid_post_delete
    } do
      object = Object.get_by_ap_id(valid_post_delete["object"])

      data =
        object.data
        |> Map.put("type", "Like")

      {:ok, _object} =
        object
        |> Ecto.Changeset.change(%{data: data})
        |> Object.update_and_set_cache()

      {:error, cng} = ObjectValidator.validate(valid_post_delete, [])
      assert {:object, {"object not in allowed types", []}} in cng.errors
    end

    test "it is valid for a user deletion", %{valid_user_delete: valid_user_delete} do
      assert match?({:ok, _, _}, ObjectValidator.validate(valid_user_delete, []))
    end

    test "it's invalid if the id is missing", %{valid_post_delete: valid_post_delete} do
      no_id =
        valid_post_delete
        |> Map.delete("id")

      {:error, cng} = ObjectValidator.validate(no_id, [])

      assert {:id, {"can't be blank", [validation: :required]}} in cng.errors
    end

    test "it's invalid if the object doesn't exist", %{valid_post_delete: valid_post_delete} do
      missing_object =
        valid_post_delete
        |> Map.put("object", "http://does.not/exist")

      {:error, cng} = ObjectValidator.validate(missing_object, [])

      assert {:object, {"can't find object", []}} in cng.errors
    end

    test "it accepts embedded remote tombstones as no-op deletes" do
      actor =
        insert(:user,
          local: false,
          ap_id: "https://remote-tombstone.example/users/alice",
          follower_address: "https://remote-tombstone.example/users/alice/followers"
        )

      delete = %{
        "id" => "https://remote-tombstone.example/activities/delete/1",
        "type" => "Delete",
        "actor" => actor.ap_id,
        "object" => %{
          "id" => "https://remote-tombstone.example/objects/already-gone",
          "type" => "Tombstone"
        },
        "to" => [actor.follower_address],
        "cc" => []
      }

      assert {:ok, _delete, meta} = ObjectValidator.validate(delete, [])
      assert %{state: :remote_tombstone} = meta[:delete_target]
    end

    test "it rejects malformed embedded tombstones without raising", %{
      valid_post_delete: valid_post_delete
    } do
      malformed_tombstone =
        valid_post_delete
        |> Map.put("object", %{"id" => ["not", "an", "id"], "type" => "Tombstone"})

      assert {:error, cng} = ObjectValidator.validate(malformed_tombstone, [])
      refute cng.valid?
    end

    test "it's invalid if the actor of the object and the actor of delete are from different domains",
         %{valid_post_delete: valid_post_delete} do
      valid_user = insert(:user)

      valid_other_actor =
        valid_post_delete
        |> Map.put("actor", valid_user.ap_id)

      assert match?({:ok, _, _}, ObjectValidator.validate(valid_other_actor, []))

      invalid_other_actor =
        valid_post_delete
        |> Map.put("actor", "https://gensokyo.2hu/users/raymoo")

      {:error, cng} = ObjectValidator.validate(invalid_other_actor, [])

      assert {:actor, {"is not allowed to modify object", []}} in cng.errors
    end

    test "it's only valid if the actor of the object is a privileged local user",
         %{valid_post_delete: valid_post_delete} do
      clear_config([:instance, :moderator_privileges], [:messages_delete])

      user =
        insert(:user, local: true, is_moderator: true, ap_id: "https://gensokyo.2hu/users/raymoo")

      post_delete_with_moderator_actor =
        valid_post_delete
        |> Map.put("actor", user.ap_id)

      {:ok, _, meta} = ObjectValidator.validate(post_delete_with_moderator_actor, [])

      assert meta[:do_not_federate]

      clear_config([:instance, :moderator_privileges], [])

      {:error, cng} = ObjectValidator.validate(post_delete_with_moderator_actor, [])

      assert {:actor, {"is not allowed to modify object", []}} in cng.errors
    end
  end
end
