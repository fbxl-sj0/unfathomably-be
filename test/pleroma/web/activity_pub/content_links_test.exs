# Project: Unfathomably ActivityPub Test Suite
# --------------------------------------------
#
# File: content_links_test.exs
#
# Purpose:
#
#     Prove canonical URL normalization changes link destinations without
#     rewriting unrelated authored content.
#
# Responsibilities:
#
#     * cover parsed HTML attributes
#     * cover Markdown link and image AST nodes
#     * preserve absolute external links and code literals
#
# This file intentionally does NOT contain:
#
#     * network requests
#     * sanitizer policy definitions
#     * ActivityPub object validation

defmodule Pleroma.Web.ActivityPub.ContentLinksTest do
  use ExUnit.Case, async: true

  alias Pleroma.Web.ActivityPub.ContentLinks

  @base "https://forum.example/topic/42"

  test "resolves relative HTML attributes and preserves absolute links" do
    html =
      ~s(<p><a href="../guide">Guide</a><img src="/media/cover.png"><a href="https://outside.example/page">Outside</a></p>)

    normalized = ContentLinks.absolutize_html(html, @base)

    assert normalized =~ ~s(href="https://forum.example/guide")
    assert normalized =~ ~s(src="https://forum.example/media/cover.png")
    assert normalized =~ ~s(href="https://outside.example/page")
  end

  test "resolves Markdown links structurally without changing code literals" do
    markdown =
      "[Guide](../guide) ![Cover](/media/cover.png) `![literal](../not-a-link)`"

    normalized = ContentLinks.absolutize_markdown(markdown, @base)

    assert normalized =~ "https://forum.example/guide"
    assert normalized =~ "https://forum.example/media/cover.png"
    assert normalized =~ "`![literal](../not-a-link)`"
  end

  test "selects a browser URL before the canonical object identifier" do
    assert ContentLinks.canonical_base(%{
             "id" => "https://forum.example/ap/object/42",
             "url" => %{"href" => "https://forum.example/topic/42"}
           }) == "https://forum.example/topic/42"
  end
end

# end of content_links_test.exs
