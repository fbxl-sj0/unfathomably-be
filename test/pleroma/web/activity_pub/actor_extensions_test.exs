# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ActorExtensionsTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Web.ActivityPub.ActorExtensions

  setup do
    actor =
      "test/fixtures/manyfold-model-actor.json"
      |> File.read!()
      |> Jason.decode!()

    %{actor: actor}
  end

  test "preserves Manyfold vocabulary without retaining normalized identity fields", %{
    actor: actor
  } do
    extensions = ActorExtensions.extract(actor)

    assert extensions["f3di:concreteType"] == "3DModel"
    assert extensions["content"] == "Print at 0.2 mm layer height."
    assert extensions["spdx:license"]["spdx:licenseId"] == "MIT"
    assert [%{"type" => "Link"}] = extensions["attachment"]
    refute Map.has_key?(extensions, "id")
    refute Map.has_key?(extensions, "publicKey")
    refute Map.has_key?(extensions, "inbox")
  end

  test "merges extension collections while normalized actor fields remain authoritative", %{
    actor: source_actor
  } do
    extensions = ActorExtensions.extract(source_actor)

    normalized = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => source_actor["id"],
      "type" => "Service",
      "name" => "Normalized name",
      "attachment" => [%{"type" => "PropertyValue", "name" => "Site", "value" => "Local"}]
    }

    merged = ActorExtensions.merge_into_actor(normalized, extensions)

    assert merged["name"] == "Normalized name"
    assert merged["f3di:concreteType"] == "3DModel"
    assert Enum.any?(merged["attachment"], &(&1["type"] == "PropertyValue"))
    assert Enum.any?(merged["attachment"], &(&1["type"] == "Link"))
    assert "https://www.w3.org/ns/activitystreams" in List.wrap(merged["@context"])
  end

  test "builds a bounded native presentation for the frontend", %{actor: actor} do
    presentation =
      actor
      |> ActorExtensions.extract()
      |> ActorExtensions.presentation(actor["id"])

    assert presentation.type == "3DModel"
    assert presentation.class == "resource"
    assert presentation.controls == ["open"]
    assert presentation.fields.license == "MIT"

    assert presentation.fields.attributed_to == [
             "https://manyfold.example/creators/example-maker"
           ]

    assert presentation.fields.collections == [
             "https://manyfold.example/collections/calibration"
           ]
  end

  test "rejects extension maps outside the configured JSON safety boundary" do
    clear_config([:activitypub, :custom_object_max_bytes], 64)

    refute ActorExtensions.valid?(%{"f3di:concreteType" => String.duplicate("x", 128)})
  end
end

# end of test/pleroma/web/activity_pub/actor_extensions_test.exs
