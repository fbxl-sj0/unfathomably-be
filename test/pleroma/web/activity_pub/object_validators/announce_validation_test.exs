# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.AnnounceValidationTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Constants
  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.Builder
  alias Pleroma.Web.ActivityPub.ObjectValidator
  alias Pleroma.Web.CommonAPI

  import Pleroma.Factory

  require Pleroma.Constants

  describe "announces" do
    setup do
      user = insert(:user)
      announcer = insert(:user)
      {:ok, post_activity} = CommonAPI.post(user, %{status: "uguu"})

      object = Object.normalize(post_activity, fetch: false)
      {:ok, valid_announce, []} = Builder.announce(announcer, object)

      %{
        valid_announce: valid_announce,
        user: user,
        post_activity: post_activity,
        announcer: announcer
      }
    end

    test "returns ok for a valid announce", %{valid_announce: valid_announce} do
      assert {:ok, _object, _meta} = ObjectValidator.validate(valid_announce, [])
    end

    test "keeps announced object context", %{valid_announce: valid_announce} do
      assert %Object{data: %{"context" => object_context}} =
               Object.get_cached_by_ap_id(valid_announce["object"])

      {:ok, %{"context" => context}, _} =
        valid_announce
        |> Map.put("context", "https://example.org/invalid_context_id")
        |> ObjectValidator.validate([])

      assert context == object_context
    end

    test "returns an error if the object can't be found", %{valid_announce: valid_announce} do
      without_object =
        valid_announce
        |> Map.delete("object")

      {:error, cng} = ObjectValidator.validate(without_object, [])

      assert {:object, {"can't be blank", [validation: :required]}} in cng.errors

      nonexisting_object =
        valid_announce
        |> Map.put("object", "https://gensokyo.2hu/objects/99999999")

      {:error, cng} = ObjectValidator.validate(nonexisting_object, [])

      assert {:object, {"can't find object", []}} in cng.errors
    end

    test "rejects malformed object references without raising", %{
      valid_announce: valid_announce
    } do
      malformed_object =
        valid_announce
        |> Map.put("object", ["not", "an", "object"])

      assert {:error, cng} = ObjectValidator.validate(malformed_object, [])
      refute cng.valid?
    end

    test "accepts embedded relay activity objects as no-op announces" do
      group = insert(:user, actor_type: "Group", local: false)

      for type <- ~w[Add Block Dislike Like Remove] do
        announce = %{
          "id" => "https://relay.example/activities/#{String.downcase(type)}",
          "type" => "Announce",
          "actor" => group.ap_id,
          "object" => %{
            "id" => "https://relay.example/activities/embedded-#{String.downcase(type)}",
            "type" => type,
            "actor" => "https://relay.example/users/alice",
            "object" => "https://relay.example/objects/1"
          },
          "to" => [Constants.as_public()],
          "cc" => []
        }

        assert {:ok, validated, _meta} = ObjectValidator.validate(announce, [])
        assert validated["object"]["type"] == type
      end
    end

    test "returns an error if the actor already announced the object", %{
      valid_announce: valid_announce,
      announcer: announcer,
      post_activity: post_activity
    } do
      _announce = CommonAPI.repeat(post_activity.id, announcer)

      {:error, cng} = ObjectValidator.validate(valid_announce, [])

      assert {:actor, {"already announced this object", []}} in cng.errors
      assert {:object, {"already announced by this actor", []}} in cng.errors
    end

    test "returns an error if the actor can't announce the object", %{
      announcer: announcer,
      user: user
    } do
      {:ok, post_activity} =
        CommonAPI.post(user, %{status: "a secret post", visibility: "private"})

      object = Object.normalize(post_activity, fetch: false)

      # Another user can't announce it
      {:ok, announce, []} = Builder.announce(announcer, object, public: false)

      {:error, cng} = ObjectValidator.validate(announce, [])

      assert {:actor, {"can not announce this object", []}} in cng.errors

      # The actor of the object can announce it
      {:ok, announce, []} = Builder.announce(user, object, public: false)

      assert {:ok, _, _} = ObjectValidator.validate(announce, [])

      # The actor of the object can not announce it publicly
      {:ok, announce, []} = Builder.announce(user, object, public: true)

      {:error, cng} = ObjectValidator.validate(announce, [])

      assert {:actor, {"can not announce this object publicly", []}} in cng.errors
    end

    test "addresses public group announces to public plus group followers", %{user: user} do
      group =
        insert(:user,
          actor_type: "Group",
          follower_address: "https://example.com/c/smoke/followers"
        )

      {:ok, post_activity} = CommonAPI.post(user, %{status: "group announce target"})
      object = Object.normalize(post_activity, fetch: false)

      {:ok, announce, []} = Builder.announce(group, object, public: true)

      assert announce["to"] == [Constants.as_public()]
      assert announce["cc"] == [group.follower_address]
      refute user.ap_id in (announce["to"] ++ announce["cc"])

      assert {:ok, validated_announce, []} = ObjectValidator.validate(announce, [])
      assert validated_announce["to"] == [Constants.as_public()]
      assert validated_announce["cc"] == [group.follower_address]
      refute user.ap_id in (validated_announce["to"] ++ validated_announce["cc"])
    end

    test "refreshes stale group actors before addressing public group announces", %{user: user} do
      group =
        insert(:user,
          actor_type: "Group",
          follower_address: "https://example.com/c/stale/followers"
        )

      stale_group = %{group | actor_type: "Person"}

      {:ok, post_activity} = CommonAPI.post(user, %{status: "stale group announce target"})
      object = Object.normalize(post_activity, fetch: false)

      {:ok, announce, []} = Builder.announce(stale_group, object, public: true)

      assert announce["actor"] == group.ap_id
      assert announce["to"] == [Constants.as_public()]
      assert announce["cc"] == [group.follower_address]
      refute user.ap_id in (announce["to"] ++ announce["cc"])

      assert {:ok, validated_announce, []} = ObjectValidator.validate(announce, [])
      assert validated_announce["to"] == [Constants.as_public()]
      assert validated_announce["cc"] == [group.follower_address]
      refute user.ap_id in (validated_announce["to"] ++ validated_announce["cc"])
    end

    test "rejects missing recipients during private announce checks without raising", %{
      user: user
    } do
      {:ok, post_activity} =
        CommonAPI.post(user, %{status: "private announce target", visibility: "private"})

      object = Object.normalize(post_activity, fetch: false)
      {:ok, announce, []} = Builder.announce(user, object, public: false)

      malformed_recipients =
        announce
        |> Map.delete("to")
        |> Map.delete("cc")

      assert {:error, cng} = ObjectValidator.validate(malformed_recipients, [])
      refute cng.valid?
    end
  end
end
