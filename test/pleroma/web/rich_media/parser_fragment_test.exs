# Project: Unfathomably BE
# File: parser_fragment_test.exs
# Purpose: Protect fragment-aware RichMedia card enrichment.
# Responsibilities: Verify exact ID lookup, bounded context, and safe fallback.
# This file intentionally does not perform HTTP requests or populate the card cache.

defmodule Pleroma.Web.RichMedia.ParserFragmentTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Web.RichMedia.Parser

  test "adds heading and section text for an exact fragment target" do
    {:ok, html} =
      Floki.parse_document("""
      <html><body>
        <section id="installation">
          <h2>Installation</h2>
          <p>Install the package, then restart the service.</p>
        </section>
      </body></html>
      """)

    card =
      Parser.enrich_fragment_context(
        %{"title" => "Operator guide", "description" => "General documentation"},
        "https://docs.example/guide#installation",
        html
      )

    assert card["title"] == "Operator guide: Installation"
    assert card["description"] == "Installation Install the package, then restart the service."
  end

  test "uses a heading fragment without requiring section body text" do
    {:ok, html} = Floki.parse_document("<h2 id=\"limits\">Limits</h2>")

    assert Parser.enrich_fragment_context(%{}, "https://docs.example/#limits", html) == %{
             "title" => "Limits"
           }
  end

  test "missing and selector-shaped fragments leave the ordinary card unchanged" do
    {:ok, html} = Floki.parse_document("<h2 id=\"safe\">Safe heading</h2>")
    card = %{"title" => "Original", "description" => "Original description"}

    assert Parser.enrich_fragment_context(card, "https://docs.example/#missing", html) == card

    assert Parser.enrich_fragment_context(
             card,
             "https://docs.example/#%5Bid%3Dsafe%5D%2Cscript",
             html
           ) == card
  end

  test "non-printable and oversized fragments fail closed" do
    {:ok, html} = Floki.parse_document("<section id=\"safe\">Safe</section>")
    card = %{"title" => "Original"}

    assert Parser.enrich_fragment_context(card, "https://docs.example/#%00safe", html) == card

    assert Parser.enrich_fragment_context(
             card,
             "https://docs.example/##{String.duplicate("x", 201)}",
             html
           ) == card
  end
end

# end of parser_fragment_test.exs
