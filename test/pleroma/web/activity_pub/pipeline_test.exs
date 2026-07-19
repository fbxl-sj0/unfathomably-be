# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.PipelineTest do
  use Pleroma.DataCase, async: true

  import Mox
  import Pleroma.Factory

  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.ConfigMock
  alias Pleroma.Web.ActivityPub.ActivityPubMock
  alias Pleroma.Web.ActivityPub.MRFMock
  alias Pleroma.Web.ActivityPub.ObjectValidatorMock
  alias Pleroma.Web.ActivityPub.SideEffectsMock
  alias Pleroma.Web.FederatorMock

  setup :verify_on_exit!

  describe "common_pipeline/2" do
    setup do
      ObjectValidatorMock
      |> expect(:validate, fn o, m -> {:ok, o, m} end)

      MRFMock
      |> expect(:pipeline_filter, fn o, m -> {:ok, o, m} end)

      SideEffectsMock
      |> expect(:handle, fn o, m -> {:ok, o, m} end)
      |> expect(:handle_after_transaction, fn m -> m end)

      :ok
    end

    test "when given an `object_data` in meta, Federation will receive a the original activity with the `object` field set to this embedded object" do
      activity = insert(:note_activity)
      object = %{"id" => "1", "type" => "Love"}
      meta = [local: true, object_data: object]

      activity_with_object = %{activity | data: Map.put(activity.data, "object", object)}

      ActivityPubMock
      |> expect(:persist, fn _, m -> {:ok, activity, m} end)

      FederatorMock
      |> expect(:publish, fn ^activity_with_object -> :ok end)

      ConfigMock
      |> expect(:get, fn [:instance, :federating] -> true end)

      assert {:ok, ^activity, ^meta} =
               Pleroma.Web.ActivityPub.Pipeline.common_pipeline(
                 activity.data,
                 meta
               )
    end

    test "it goes through validation, filtering, persisting, side effects and federation for local activities" do
      activity = insert(:note_activity)
      meta = [local: true]

      ActivityPubMock
      |> expect(:persist, fn _, m -> {:ok, activity, m} end)

      FederatorMock
      |> expect(:publish, fn ^activity -> :ok end)

      ConfigMock
      |> expect(:get, fn [:instance, :federating] -> true end)

      assert {:ok, ^activity, ^meta} =
               Pleroma.Web.ActivityPub.Pipeline.common_pipeline(activity.data, meta)
    end

    test "it goes through validation, filtering, persisting, side effects without federation for remote activities" do
      activity = insert(:note_activity)
      meta = [local: false]

      ActivityPubMock
      |> expect(:persist, fn _, m -> {:ok, activity, m} end)

      ConfigMock
      |> expect(:get, fn [:instance, :federating] -> true end)

      assert {:ok, ^activity, ^meta} =
               Pleroma.Web.ActivityPub.Pipeline.common_pipeline(activity.data, meta)
    end

    test "a native compatibility form upgrades the object returned by nested persistence" do
      actor = "https://bookwyrm.example/user/alice"
      object_id = "https://bookwyrm.example/user/alice/review/raced"
      recipients = ["https://www.w3.org/ns/activitystreams#Public"]

      fallback = %{
        "id" => object_id,
        "type" => "Article",
        "attributedTo" => actor,
        "content" => "A compatibility review.",
        "to" => recipients
      }

      native = %{
        "id" => object_id,
        "type" => "Review",
        "attributedTo" => actor,
        "content" => "A native review.",
        "rating" => 4.5,
        "inReplyToBook" => "https://bookwyrm.example/book/edition/1",
        "to" => recipients
      }

      assert {:ok, _object} = Object.create(fallback)

      stored_object = Object.get_by_ap_id(object_id)
      meta = [local: false, object_data: native, activity_actor: actor]

      ActivityPubMock
      |> expect(:persist, fn ^native, m -> {:ok, stored_object, m} end)

      assert {:ok, %Object{} = returned_object, ^meta} =
               Pleroma.Web.ActivityPub.Pipeline.common_pipeline(native, meta)

      upgraded = Object.get_by_ap_id(object_id)
      assert returned_object.data["type"] == "Review"
      assert upgraded.data["type"] == "Review"
      assert upgraded.data["rating"] == 4.5
    end

    test "it goes through validation, filtering, persisting, side effects without federation for local activities if federation is deactivated" do
      activity = insert(:note_activity)
      meta = [local: true]

      ActivityPubMock
      |> expect(:persist, fn _, m -> {:ok, activity, m} end)

      ConfigMock
      |> expect(:get, fn [:instance, :federating] -> false end)

      assert {:ok, ^activity, ^meta} =
               Pleroma.Web.ActivityPub.Pipeline.common_pipeline(activity.data, meta)
    end
  end

  describe "persisted Create conflicts" do
    test "activity persistence reports whether it inserted or returned a conflict winner" do
      activity = build(:note_activity)
      meta = [local: false]

      assert {:ok, inserted, inserted_meta} = ActivityPub.persist(activity.data, meta)
      assert inserted_meta[:activity_inserted] == true

      assert {:ok, returned, returned_meta} = ActivityPub.persist(activity.data, meta)
      assert returned.id == inserted.id
      assert returned_meta[:activity_inserted] == false
    end

    test "a conflict loser does not replay Create side effects" do
      actor = "https://bookwyrm.example/user/alice"
      object_id = "https://bookwyrm.example/user/alice/review/raced"
      recipients = ["https://www.w3.org/ns/activitystreams#Public"]

      fallback = %{
        "id" => object_id,
        "type" => "Article",
        "attributedTo" => actor,
        "content" => "A compatibility review.",
        "to" => recipients
      }

      native = %{
        "id" => object_id,
        "type" => "Review",
        "attributedTo" => actor,
        "content" => "A native review.",
        "rating" => 4.5,
        "to" => recipients
      }

      assert {:ok, _object} = Object.create(fallback)

      activity =
        build(:note_activity,
          data: %{
            "id" => object_id <> "/activity",
            "type" => "Create",
            "actor" => actor,
            "object" => object_id,
            "to" => recipients
          }
        )

      meta = [local: false, object_data: native, activity_inserted: false]

      ObjectValidatorMock
      |> expect(:validate, fn o, m -> {:ok, o, m} end)

      MRFMock
      |> expect(:pipeline_filter, fn o, m -> {:ok, o, m} end)

      ActivityPubMock
      |> expect(:persist, fn _, m -> {:ok, activity, m} end)

      SideEffectsMock
      |> expect(:handle_after_transaction, fn m -> m end)

      assert {:ok, ^activity, returned_meta} =
               Pleroma.Web.ActivityPub.Pipeline.common_pipeline(activity.data, meta)

      refute Keyword.has_key?(returned_meta, :activity_inserted)
      assert Object.get_by_ap_id(object_id).data["type"] == "Review"
    end
  end
end
