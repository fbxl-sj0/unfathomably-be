# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.CustomObjectValidatorTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Web.ActivityPub.CustomObject
  alias Pleroma.Web.ActivityPub.ObjectValidator

  import Pleroma.Factory

  require Pleroma.Constants

  setup do
    actor =
      insert(:user,
        local: false,
        ap_id: "https://bookwyrm.example/user/alice",
        follower_address: "https://bookwyrm.example/user/alice/followers"
      )

    %{actor: actor}
  end

  test "preserves a BookWyrm Review and its unknown JSON-LD fields", %{actor: actor} do
    review = review(actor)

    activity = %{
      "id" => "https://bookwyrm.example/user/alice/status/1/activity",
      "type" => "Create",
      "actor" => actor.ap_id,
      "to" => review["to"],
      "cc" => review["cc"],
      "context" => review["context"],
      "object" => review
    }

    assert {:ok, validated_activity, meta} = ObjectValidator.validate(activity, local: false)

    assert validated_activity["object"]["rating"] == 4.5
    assert meta[:object_data]["inReplyToBook"] == "https://bookwyrm.example/book/1"
    assert meta[:object_data]["bookwyrm:edition"]["isbn13"] == "9780123456789"

    assert %{
             "authority" => %{"write" => [authority]},
             "canonicalId" => "https://bookwyrm.example/user/alice/status/1",
             "class" => "status",
             "type" => "Review"
           } = meta[:object_data][CustomObject.internal_field()]

    assert authority == actor.ap_id
  end

  test "rejects a same-domain actor who is not an object authority", %{actor: actor} do
    intruder =
      insert(:user,
        local: false,
        ap_id: "https://bookwyrm.example/user/mallory",
        follower_address: "https://bookwyrm.example/user/mallory/followers"
      )

    review = review(actor)

    activity = %{
      "id" => "https://bookwyrm.example/user/mallory/status/1/activity",
      "type" => "Create",
      "actor" => intruder.ap_id,
      "to" => review["to"],
      "cc" => review["cc"],
      "object" => review
    }

    assert {:error, {:custom_object, :actor_not_authorized}} =
             ObjectValidator.validate(activity, local: false)
  end

  test "inherits Create addressing for an otherwise unaddressed Patch", %{actor: actor} do
    patch = %{
      "attributedTo" => actor.ap_id,
      "content" => "@@ -0,0 +1 @@\n+First wiki revision\n",
      "id" => "https://bookwyrm.example/patches/1",
      "object" => "https://bookwyrm.example/articles/1",
      "published" => "2026-07-17T12:00:00Z",
      "type" => "Patch",
      "version" => "11111111-1111-4111-8111-111111111111"
    }

    activity = %{
      "actor" => actor.ap_id,
      "cc" => [actor.follower_address],
      "id" => "https://bookwyrm.example/activities/create-patch-1",
      "object" => patch,
      "to" => [Pleroma.Constants.as_public()],
      "type" => "Create"
    }

    assert {:ok, validated_activity, meta} =
             ObjectValidator.validate(activity, local: false)

    assert validated_activity["to"] == activity["to"]
    assert validated_activity["cc"] == activity["cc"]
    assert meta[:object_data]["to"] == activity["to"]
    assert meta[:object_data]["cc"] == activity["cc"]
  end

  test "accepts an actorless Edition only from a contained canonical fetch" do
    edition = %{
      "id" => "https://bookwyrm.example/book/edition/1",
      "type" => "Edition",
      "title" => "A federated book",
      "work" => "https://bookwyrm.example/book/work/1",
      "isbn13" => "9780123456789",
      "bookwyrm:unknownField" => %{"preserved" => true}
    }

    assert {:ok, validated, _meta} =
             ObjectValidator.validate(edition,
               local: false,
               fetched_from: edition["id"]
             )

    assert validated["bookwyrm:unknownField"] == %{"preserved" => true}
    assert validated[CustomObject.internal_field()]["class"] == "resource"

    assert {:error, {:custom_object, :missing_provenance}} =
             ObjectValidator.validate(edition, local: false)
  end

  test "rejects structures deeper than the configured custom-object limit" do
    nested =
      Enum.reduce(1..40, %{"value" => "bottom"}, fn index, child ->
        %{Integer.to_string(index) => child}
      end)

    object = %{
      "id" => "https://forge.example/tickets/1",
      "type" => "Ticket",
      "payload" => nested
    }

    assert {:error, {:custom_object, :object_too_deep}} =
             ObjectValidator.validate(object,
               local: false,
               fetched_from: object["id"]
             )
  end

  test "rejects oversized inline collections without dereferencing anything" do
    object = %{
      "id" => "https://forge.example/tickets/1",
      "type" => "Ticket",
      "orderedItems" => Enum.map(1..501, &"https://forge.example/items/#{&1}")
    }

    assert {:error, {:custom_object, :too_many_collection_items}} =
             ObjectValidator.validate(object,
               local: false,
               fetched_from: object["id"]
             )
  end

  defp review(actor) do
    %{
      "id" => "https://bookwyrm.example/user/alice/status/1",
      "type" => "Review",
      "actor" => actor.ap_id,
      "attributedTo" => actor.ap_id,
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [actor.follower_address],
      "content" => "A review whose native fields must survive.",
      "context" => "https://bookwyrm.example/user/alice/status/1",
      "published" => "2026-07-17T12:00:00Z",
      "inReplyToBook" => "https://bookwyrm.example/book/1",
      "rating" => 4.5,
      "bookwyrm:edition" => %{
        "id" => "https://bookwyrm.example/book/edition/1",
        "isbn13" => "9780123456789"
      }
    }
  end
end

# end of test/pleroma/web/activity_pub/object_validators/custom_object_validator_test.exs
