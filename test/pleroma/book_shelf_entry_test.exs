# Unfathomably native book library tests
# --------------------------------------
#
# File: book_shelf_entry_test.exs
#
# Purpose:
#
#   Protect personal shelf metadata and reading lifecycle transitions.
#
# This file intentionally does NOT test HTTP rendering or remote delivery.

defmodule Pleroma.BookShelfEntryTest do
  use Pleroma.DataCase, async: false

  import Pleroma.Factory

  alias Pleroma.BookShelfEntry

  test "partial shelf moves preserve presentation and record reading dates" do
    user = insert(:user)
    book_uri = "https://books.example/editions/the-left-hand-of-darkness"

    assert {:ok, wanted} =
             BookShelfEntry.put(user, %{
               "book_uri" => book_uri,
               "shelf" => "to-read",
               "presentation" => %{
                 "title" => "The Left Hand of Darkness",
                 "author" => "Ursula K. Le Guin"
               }
             })

    assert is_nil(wanted.started_at)
    assert is_nil(wanted.finished_at)

    assert {:ok, reading} =
             BookShelfEntry.put(user, %{
               "book_uri" => book_uri,
               "shelf" => "reading",
               "progress" => 25,
               "progress_mode" => "percent"
             })

    assert reading.presentation == wanted.presentation
    assert %DateTime{} = reading.started_at
    assert is_nil(reading.finished_at)

    assert {:ok, finished} =
             BookShelfEntry.put(user, %{
               "book_uri" => book_uri,
               "shelf" => "read"
             })

    assert finished.presentation == wanted.presentation
    assert finished.progress == 25
    assert finished.progress_mode == "percent"
    assert finished.started_at == reading.started_at
    assert %DateTime{} = finished.finished_at
    assert DateTime.compare(finished.finished_at, finished.started_at) in [:eq, :gt]
  end
end

# end of book_shelf_entry_test.exs
