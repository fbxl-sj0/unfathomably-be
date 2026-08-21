# Unfathomably BE
# ----------------
#
# File: nostr/semantics_test.exs
#
# Purpose:
#   Cover bounded Nostr semantic mappings shared by relay and bridge paths.
#
# Responsibilities:
#   - verify expiration and protected-event handling
#   - verify content-warning and external-identifier projection
#   - verify outbound NIP-92 attachment metadata
#
# This file intentionally does NOT open relay connections or create users.

defmodule Pleroma.Nostr.SemanticsTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Nostr.Media
  alias Pleroma.Nostr.Semantics

  test "recognizes expired and protected events" do
    event = %{"tags" => [["expiration", "100"], ["-"]]}

    assert Semantics.expired?(event, 100)
    assert Semantics.protected?(event)
    assert {:error, "restricted", _reason} = Semantics.bridgeable?(event)
  end

  test "maps content warnings and bounded external identifiers" do
    event = %{
      "tags" => [
        ["content-warning", "Spoilers"],
        ["i", "isbn:9780765382030", "https://books.example/items/9780765382030"],
        ["k", "isbn"]
      ]
    }

    assert %{sensitive: true, spoiler_text: "Spoilers"} =
             Semantics.put_inbound_params(%{}, event)

    assert [%{"id" => "isbn:9780765382030", "kind" => "isbn"}] =
             event
             |> Semantics.external_content_ids()
             |> Enum.map(&Map.delete(&1, "url"))
  end

  test "emits NIP-92 imeta from ActivityPub attachments" do
    object = %{
      "attachment" => [
        %{
          "type" => "Document",
          "mediaType" => "image/png",
          "name" => "Example image",
          "url" => [
            %{"href" => "https://media.example/image.png", "width" => 640, "height" => 480}
          ]
        }
      ]
    }

    assert {"A post with media\n\nhttps://media.example/image.png",
            [
              [
                "imeta",
                "url https://media.example/image.png",
                "m image/png",
                "dim 640x480",
                "alt Example image"
              ]
            ]} = Media.outbound("A post with media", object)
  end

  test "does not duplicate a media URL already present in content" do
    object = %{
      "attachment" => [
        %{
          "type" => "Document",
          "mediaType" => "image/png",
          "url" => [%{"href" => "https://media.example/image.png"}]
        }
      ]
    }

    content = "Already linked https://media.example/image.png"

    assert {^content, [["imeta", "url https://media.example/image.png", "m image/png"]]} =
             Media.outbound(content, object)
  end
end

# end of nostr/semantics_test.exs
