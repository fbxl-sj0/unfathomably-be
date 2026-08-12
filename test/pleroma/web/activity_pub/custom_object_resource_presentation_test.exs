# Project: Unfathomably ActivityPub compatibility
#
# File: custom_object_resource_presentation_test.exs
#
# Purpose: Prove that bounded route and model attachments become useful API presentation fields.
#
# Responsibilities:
#   * cover common Wanderer GPX media-type variants
#   * cover Manyfold-style 3D model attachment metadata
#
# This file intentionally does not fetch remote files or test frontend rendering.

defmodule Pleroma.Web.ActivityPub.CustomObjectResourcePresentationTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Web.ActivityPub.CustomObject

  @public "https://www.w3.org/ns/activitystreams#Public"

  test "presents a Wanderer GPX attachment and route coordinates" do
    object =
      public_object(%{
        "id" => "https://routes.example/api/v1/trail/lake-loop",
        "type" => "Note",
        "attachment" => %{
          "type" => "Document",
          "mediaType" => "application/gpx+xml",
          "url" => "https://routes.example/trails/lake-loop.gpx"
        },
        "location" => %{
          "type" => "Place",
          "name" => "Lake loop",
          "latitude" => 44.5,
          "longitude" => -79.3
        }
      })

    fields =
      object
      |> CustomObject.put_internal_metadata()
      |> CustomObject.presentation()
      |> Map.fetch!(:fields)

    assert fields.gpx_url == "https://routes.example/trails/lake-loop.gpx"
    assert fields.latitude == 44.5
    assert fields.longitude == -79.3
  end

  test "presents a Manyfold model without downloading its file" do
    object =
      public_object(%{
        "type" => "Service",
        "f3di:concreteType" => "f3di:3DModel",
        "attachment" => %{
          "type" => "Document",
          "mediaType" => "model/stl",
          "name" => "replacement-knob.stl",
          "url" => "https://models.example/files/replacement-knob.stl"
        }
      })

    fields =
      object
      |> CustomObject.put_internal_metadata()
      |> CustomObject.presentation()
      |> Map.fetch!(:fields)

    assert fields.family == "models"
    assert fields.kind == "3d_model"
    assert fields.platform == "manyfold"
    assert fields.file_format == "model/stl"
    assert fields.file_name == "replacement-knob.stl"
    assert fields.resource_url == "https://models.example/files/replacement-knob.stl"
  end

  test "presents explicit scheduled live video metadata" do
    object =
      public_object(%{
        "type" => "Video",
        "embedUrl" => "https://video.example/videos/embed/live-show",
        "isLiveBroadcast" => true,
        "schedules" => [%{"startDate" => "2026-08-01T18:00:00Z"}]
      })

    fields =
      object
      |> CustomObject.put_internal_metadata()
      |> CustomObject.presentation()
      |> Map.fetch!(:fields)

    assert fields.family == "video"
    assert fields.kind == "scheduled_live_video"
    assert fields.is_live_broadcast
    assert fields.live_start == "2026-08-01T18:00:00Z"
    assert fields.embed_url == "https://video.example/videos/embed/live-show"
  end

  test "presents a FEP-0837 listing without the legacy Flohmarkt extension" do
    object =
      public_object(%{
        "@context" => [
          "https://www.w3.org/ns/activitystreams",
          %{"vf" => "https://w3id.org/valueflows/ont/vf#"}
        ],
        "type" => "Note",
        "attachment" => [
          %{
            "type" => "Proposal",
            "id" => "https://market.example/proposals/lamp-1",
            "attributedTo" => "https://remote.example/users/alice",
            "name" => "Reading lamp",
            "purpose" => "offer",
            "location" => %{"type" => "Place", "name" => "Downtown"},
            "publishes" => %{
              "type" => "Intent",
              "action" => "vf:transfer",
              "resourceQuantity" => %{"hasNumericalValue" => "1", "hasUnit" => "one"}
            },
            "reciprocal" => %{
              "type" => "Intent",
              "action" => "vf:transfer",
              "resourceQuantity" => %{"hasNumericalValue" => "25", "hasUnit" => "EUR"}
            }
          }
        ]
      })

    presentation = object |> CustomObject.put_internal_metadata() |> CustomObject.presentation()

    assert presentation.fields.platform == "flohmarkt"
    assert presentation.fields.family == "markets"
    assert presentation.fields.listing_name == "Reading lamp"
    assert presentation.fields.price == "25"
    assert presentation.fields.currency == "EUR"
    assert presentation.fields.listing_location == "Downtown"
    assert "contact" in presentation.controls
  end

  test "presents a context-qualified ValueFlows proposal as coordination" do
    object =
      public_object(%{
        "@context" => [
          "https://www.w3.org/ns/activitystreams",
          %{"vf" => "https://w3id.org/valueflows/ont/vf#"}
        ],
        "type" => "Proposal",
        "vf:action" => "vf:transfer",
        "https://w3id.org/valueflows/ont/vf#provider" => "https://aid.example/users/alice",
        "resourceQuantity" => %{
          "hasNumericalValue" => "3",
          "hasUnit" => "https://qudt.org/vocab/unit/KiloGM"
        }
      })

    presentation = object |> CustomObject.put_internal_metadata() |> CustomObject.presentation()

    assert presentation.class == "status"
    assert presentation.fields.platform == "bonfire_valueflows"
    assert presentation.fields.valueflows_type == "Proposal"
    assert presentation.fields.action == "transfer"
    assert presentation.fields.provider == "https://aid.example/users/alice"
    assert presentation.fields.resource_quantity == "3"
    assert presentation.fields.resource_quantity_unit == "https://qudt.org/vocab/unit/KiloGM"
    assert "respond" in presentation.controls
  end

  defp public_object(extra) do
    Map.merge(
      %{
        "id" => "https://remote.example/objects/#{System.unique_integer([:positive])}",
        "actor" => "https://remote.example/users/alice",
        "attributedTo" => "https://remote.example/users/alice",
        "to" => [@public]
      },
      extra
    )
  end
end

# end of custom_object_resource_presentation_test.exs
