# Unfathomably Backend Test Suite
# --------------------------------
#
# File: test/pleroma/web/activity_pub/custom_object_controls_test.exs
#
# Purpose:
#
#   Prove that specialized presentation controls come from validated object
#   structure rather than hostnames or arbitrary display text.
#
# Responsibilities:
#
#   * cover review, contact, response, discussion, download, and listen controls
#   * preserve the open-only fallback for ordinary objects
#
# This file intentionally does NOT contain:
#
#   * controller authorization tests
#   * frontend labels
#   * remote network requests

defmodule Pleroma.Web.ActivityPub.CustomObjectControlsTest do
  use ExUnit.Case, async: true

  alias Pleroma.Web.ActivityPub.CustomObject

  @namespace "https://unfathomably.social/ns#"
  @public "https://www.w3.org/ns/activitystreams#Public"

  test "books and cultural records expose review creation" do
    assert controls("books", "book_review") == ["open", "review"]
    assert controls("culture", "catalog_review") == ["open", "review"]
  end

  test "market, coordination, and software records expose contextual replies" do
    assert controls("markets", "classified") == ["open", "contact"]
    assert controls("coordination", "offer") == ["open", "respond"]
    assert controls("software", "issue") == ["open", "discuss"]
  end

  test "downloadable routes expose a download control" do
    object = native_object("routes", "trail", %{"gpxUrl" => "https://local.test/trail.gpx"})

    assert CustomObject.presentation(object).controls == ["open", "download", "discuss"]
  end

  test "Audio objects expose repeatable listening activity" do
    object =
      %{
        "actor" => "https://audio.test/actors/library",
        "id" => "https://audio.test/tracks/1",
        "name" => "A track",
        "published" => "2026-07-22T12:00:00Z",
        "to" => [@public],
        "type" => "Audio"
      }
      |> CustomObject.put_internal_metadata()

    assert CustomObject.presentation(object).controls == ["open", "listen"]
  end

  test "ordinary Notes retain the open-only fallback" do
    object =
      %{
        "actor" => "https://remote.test/users/alice",
        "content" => "An ordinary status",
        "id" => "https://remote.test/objects/1",
        "published" => "2026-07-22T12:00:00Z",
        "to" => [@public],
        "type" => "Note"
      }
      |> CustomObject.put_internal_metadata()

    assert CustomObject.presentation(object).controls == ["open"]
  end

  defp controls(family, kind) do
    family
    |> native_object(kind)
    |> CustomObject.presentation()
    |> Map.fetch!(:controls)
  end

  defp native_object(family, kind, extra \\ %{}) do
    Map.merge(
      %{
        "actor" => "https://local.test/users/alice",
        "content" => "Specialized activity",
        "id" => "https://local.test/objects/#{family}-#{kind}",
        "published" => "2026-07-22T12:00:00Z",
        "to" => [@public],
        "type" => "Note",
        (@namespace <> "family") => family,
        (@namespace <> "kind") => kind
      },
      extra
    )
    |> CustomObject.put_internal_metadata(local: true)
  end
end

# end of test/pleroma/web/activity_pub/custom_object_controls_test.exs
