# Project: Unfathomably BE
# File: article_note_page_markdown_test.exs
# Purpose: Protect direct Markdown ActivityPub object normalization.
# Responsibilities: Verify source preservation, HTML conversion, and sanitization.
# This file intentionally does not test HTTP fetching or federation delivery.

defmodule Pleroma.Web.ActivityPub.ObjectValidators.ArticleNotePageMarkdownTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Web.ActivityPub.ObjectValidators.ArticleNotePageValidator

  test "formats direct Markdown content and preserves its source" do
    source = "# Heading\n\n[Example](https://example.com)<script>alert('x')</script>"

    fixed =
      ArticleNotePageValidator.fix(%{
        "type" => "Article",
        "mediaType" => "text/markdown",
        "content" => source
      })

    assert fixed["source"] == %{"content" => source, "mediaType" => "text/markdown"}
    assert fixed["content"] =~ "Heading"
    assert fixed["content"] =~ "href=\"https://example.com\""
    refute fixed["content"] =~ "<h1>"
    refute fixed["content"] =~ "<script"
  end

  test "resolves relative links in Markdown source and rendered HTML" do
    source = "[Guide](../guide) ![Cover](/media/cover.png)"

    fixed =
      ArticleNotePageValidator.fix(%{
        "id" => "https://forum.example/topic/42",
        "type" => "Article",
        "mediaType" => "text/markdown",
        "content" => source
      })

    assert fixed["source"]["content"] =~ "https://forum.example/guide"
    assert fixed["source"]["content"] =~ "https://forum.example/media/cover.png"
    assert fixed["content"] =~ ~s(href="https://forum.example/guide")
    assert fixed["content"] =~ ~s(src="https://forum.example/media/cover.png")
  end

  test "renders source-only Markdown delivered as a private object" do
    source = "Private **source text**"

    fixed =
      ArticleNotePageValidator.fix(%{
        "type" => "Note",
        "to" => ["https://local.example/users/recipient"],
        "content" => "",
        "source" => %{"content" => source, "mediaType" => "text/markdown; charset=utf-8"}
      })

    assert fixed["content"] =~ "<strong>source text</strong>"
    assert fixed["source"]["content"] == source
    assert fixed["to"] == ["https://local.example/users/recipient"]
  end

  test "sanitizes source-only HTML before promoting it to rendered content" do
    fixed =
      ArticleNotePageValidator.fix(%{
        "type" => "Note",
        "content" => nil,
        "source" => %{
          "content" => "<p>Readable</p><script>alert('x')</script>",
          "mediaType" => "text/html"
        }
      })

    assert fixed["content"] =~ "<p>Readable</p>"
    refute fixed["content"] =~ "<script"
  end

  test "does not replace existing rendered content with source text" do
    fixed =
      ArticleNotePageValidator.fix(%{
        "type" => "Note",
        "content" => "<p>Rendered representation</p>",
        "source" => %{"content" => "Different source", "mediaType" => "text/plain"}
      })

    assert fixed["content"] == "<p>Rendered representation</p>"
  end
end

# end of article_note_page_markdown_test.exs
