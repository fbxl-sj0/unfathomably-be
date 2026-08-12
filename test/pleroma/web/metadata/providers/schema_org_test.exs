# Unfathomably BE
# ----------------
#
# File: metadata/providers/schema_org_test.exs
#
# Purpose:
#   Cover Schema.org JSON-LD generated from native ActivityPub objects.
#
# Responsibilities:
#   - prove object, author, and media fields retain useful semantics
#   - prove sensitive attachments are not exposed
#   - prove untrusted HTML cannot terminate the JSON-LD script element
#
# This file intentionally does NOT test OpenGraph or Twitter Card metadata.

defmodule Pleroma.Web.Metadata.Providers.SchemaOrgTest do
  use Pleroma.DataCase

  import Pleroma.Factory

  alias Pleroma.Web.Metadata.Providers.SchemaOrg

  setup do: clear_config([Pleroma.Web.Metadata, :unfurl_nsfw], false)

  test "renders native object semantics and media" do
    user = insert(:user, name: "Example author")

    note =
      insert(:note, %{
        data: %{
          "actor" => user.ap_id,
          "id" => "https://example.com/objects/1",
          "type" => "Article",
          "name" => "An article",
          "content" => "<p>Useful text</p>",
          "published" => "2026-08-08T12:00:00Z",
          "attachment" => [
            %{
              "name" => "Cover image",
              "summary" => "<p>A detailed description of the cover.</p>",
              "url" => [
                %{
                  "href" => "https://example.com/cover.png",
                  "mediaType" => "image/png",
                  "width" => 640,
                  "height" => 480
                }
              ]
            }
          ]
        }
      })

    schema =
      decode_schema(SchemaOrg.build_tags(%{object: note, user: user, url: note.data["id"]}))

    assert schema["@type"] == "Article"
    assert schema["url"] == note.data["id"]
    assert schema["text"] == "Useful text"
    assert schema["author"]["name"] == "Example author"

    assert [media] = schema["associatedMedia"]
    assert media["@type"] == "ImageObject"
    assert media["contentUrl"] == "https://example.com/cover.png"
    assert media["description"] == "A detailed description of the cover."
    assert media["width"] == 640
  end

  test "does not expose sensitive attachments or unsafe script delimiters" do
    user = insert(:user)

    note =
      insert(:note, %{
        data: %{
          "actor" => user.ap_id,
          "id" => "https://example.com/objects/2",
          "type" => "Note",
          "content" => "</script><script>alert(1)</script>",
          "summary" => "Sensitive media",
          "sensitive" => true,
          "attachment" => [
            %{
              "url" => [
                %{"href" => "https://example.com/private.png", "mediaType" => "image/png"}
              ]
            }
          ]
        }
      })

    [{:script, [type: "application/ld+json"], content}] =
      SchemaOrg.build_tags(%{object: note, user: user, url: note.data["id"]})

    encoded = Phoenix.HTML.safe_to_string(content)
    refute encoded =~ "</script>"

    schema = Jason.decode!(encoded)
    assert schema["text"] == "Sensitive media"
    refute Map.has_key?(schema, "associatedMedia")
  end

  test "renders native review ratings and reviewed books" do
    user = insert(:user, name: "Book reviewer")

    review =
      insert(:note, %{
        data: %{
          "actor" => user.ap_id,
          "id" => "https://bookwyrm.example/user/reviewer/status/1",
          "type" => "Review",
          "name" => "A useful review",
          "content" => "<p>The review body.</p>",
          "published" => "2026-08-08T13:00:00Z",
          "inReplyToBook" => "https://bookwyrm.example/book/edition/1",
          "rating" => 4.5,
          "ratingBest" => 5,
          "bookwyrm:edition" => %{
            "id" => "https://bookwyrm.example/book/edition/1",
            "type" => "Edition",
            "name" => "Example Book"
          }
        }
      })

    schema =
      decode_schema(SchemaOrg.build_tags(%{object: review, user: user, url: review.data["id"]}))

    assert schema["@type"] == "Review"
    assert schema["reviewBody"] == "The review body."
    assert schema["reviewRating"]["ratingValue"] == 4.5
    assert schema["reviewRating"]["bestRating"] == 5
    assert schema["itemReviewed"]["@type"] == "Book"
    assert schema["itemReviewed"]["name"] == "Example Book"
    assert schema["itemReviewed"]["url"] == "https://bookwyrm.example/book/edition/1"
  end

  defp decode_schema([{:script, [type: "application/ld+json"], content}]) do
    content
    |> Phoenix.HTML.safe_to_string()
    |> Jason.decode!()
  end
end

# end of metadata/providers/schema_org_test.exs
