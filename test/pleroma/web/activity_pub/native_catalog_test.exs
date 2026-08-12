# Unfathomably BE Test Suite
# --------------------------
#
# File: native_catalog_test.exs
#
# Purpose:
#   Verify bounded metadata catalog normalization for Worlds authoring.
#
# Responsibilities:
#   - prove MusicBrainz recording results become editable audio drafts
#   - retain provider provenance without downloading remote media
#
# This file intentionally does not contact live metadata providers.

defmodule Pleroma.Web.ActivityPub.NativeCatalogTest do
  use Pleroma.DataCase, async: false

  import Tesla.Mock

  alias Pleroma.Web.ActivityPub.NativeCatalog

  test "maps MusicBrainz recordings into bounded audio draft candidates" do
    mock(fn %{method: :get, url: url} ->
      assert String.starts_with?(url, "https://musicbrainz.org/ws/2/recording?")

      %Tesla.Env{
        status: 200,
        body:
          Jason.encode!(%{
            "recordings" => [
              %{
                "artist-credit" => [%{"name" => "Alice Example"}],
                "first-release-date" => "2026-07-21",
                "genres" => [%{"name" => "ambient"}],
                "id" => "11111111-2222-4333-8444-555555555555",
                "releases" => [%{"title" => "Signals"}],
                "title" => "Antenna Song"
              }
            ]
          })
      }
    end)

    assert {:ok, [candidate]} = NativeCatalog.search("audio", "antenna unique 20260721")
    assert candidate.provider == "musicbrainz"
    assert candidate.title == "Antenna Song"

    assert candidate.source_url ==
             "https://musicbrainz.org/recording/11111111-2222-4333-8444-555555555555"

    assert candidate.fields["artist"] == "Alice Example"
    assert candidate.fields["album"] == "Signals"
    assert candidate.fields["release_date"] == "2026-07-21"
    assert candidate.fields["genres"] == "ambient"
  end

  test "maps configured NeoDB results into federatable culture draft candidates" do
    clear_config([:native_discovery, :neodb_indexes], ["https://culture.example"])

    mock(fn %{method: :get, url: url} ->
      assert String.starts_with?(url, "https://culture.example/api/catalog/search?")

      %Tesla.Env{
        status: 200,
        body:
          Jason.encode!(%{
            "count" => 1,
            "data" => [
              %{
                "brief" => "A film from the configured cultural catalog.",
                "category" => "movie",
                "credits" => [%{"name" => "Alice Director"}],
                "display_title" => "Signal Fire",
                "url" => "/movie/signal-fire",
                "uuid" => "11111111-2222-4333-8444-555555555555"
              }
            ]
          })
      }
    end)

    assert {:ok, [candidate]} =
             NativeCatalog.search("culture", "signal fire unique 20260803", "film")

    assert candidate.provider == "neodb"
    assert candidate.title == "Signal Fire"
    assert candidate.reference_url == "https://culture.example/movie/signal-fire"
    assert candidate.fields == %{"category" => "film"}
  end

  test "keeps only checksum-valid ISBN values from Open Library" do
    mock(fn %{method: :get, url: url} ->
      assert String.starts_with?(url, "https://openlibrary.org/search.json?")

      %Tesla.Env{
        status: 200,
        body:
          Jason.encode!(%{
            "docs" => [
              %{
                "isbn" => ["0-306-40615-3", "0-306-40615-2"],
                "key" => "/works/OL1000001W",
                "title" => "Checksum Fallback"
              },
              %{
                "isbn" => ["979-10-90636-07-1"],
                "key" => "/works/OL1000002W",
                "title" => "Assigned 979 Range"
              }
            ]
          })
      }
    end)

    assert {:ok, [fallback, assigned_979]} =
             NativeCatalog.search("books", "isbn checksum unique 20260808")

    assert fallback.fields["isbn"] == "0306406152"
    assert assigned_979.fields["isbn"] == "9791090636071"
  end

  test "rejects unknown NeoDB catalog categories" do
    assert {:error, :invalid_category} =
             NativeCatalog.search("culture", "signal fire", "unknown")
  end

  test "rejects unsupported catalog workflows without making a request" do
    assert {:error, :unsupported_template} = NativeCatalog.search("markets", "radio")
  end
end

# end of test/pleroma/web/activity_pub/native_catalog_test.exs
