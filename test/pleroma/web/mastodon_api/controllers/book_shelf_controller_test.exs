# Unfathomably native book library tests
# --------------------------------------
#
# File: book_shelf_controller_test.exs
#
# Purpose:
#
#   Protect the local reading-library API and its public Shelf serialization.
#
# Responsibilities:
#
#   * verify duplicate-safe shelf moves and progress validation
#   * verify personal library listing and removal
#   * verify BookWyrm-compatible actor-owned Shelf collection output
#
# This file intentionally does NOT exercise remote delivery workers.

defmodule Pleroma.Web.MastodonAPI.BookShelfControllerTest do
  use Pleroma.Web.ConnCase, async: true

  alias Pleroma.Activity
  alias Pleroma.BookShelfEntry
  alias Pleroma.FollowingRelationship
  alias Pleroma.Instances.Instance
  alias Pleroma.Notification
  alias Pleroma.Repo

  import Pleroma.Factory

  test "adds, moves, lists, and removes a book" do
    %{user: user, conn: conn} = oauth_access(["read:statuses", "write:statuses"])
    book_uri = "https://books.example/book/edition-1"

    assert %{"book_uri" => ^book_uri, "shelf" => "to-read"} =
             conn
             |> put_req_header("content-type", "application/json")
             |> post("/api/v1/book_shelves", %{
               "book_uri" => book_uri,
               "shelf" => "to-read",
               "presentation" => %{"title" => "A Useful Book", "ignored" => "not retained"}
             })
             |> json_response(:ok)

    assert %{"shelf" => "reading", "progress" => 35, "progress_mode" => "percent"} =
             conn
             |> put_req_header("content-type", "application/json")
             |> post("/api/v1/book_shelves", %{
               "book_uri" => book_uri,
               "shelf" => "reading",
               "progress" => 35,
               "progress_mode" => "percent"
             })
             |> json_response(:ok)

    assert [%{"id" => "reading", "items" => [%{"book_uri" => ^book_uri}]}] =
             conn
             |> get("/api/v1/book_shelves?shelf=reading")
             |> json_response(:ok)
             |> Map.fetch!("shelves")
             |> Enum.filter(&(&1["items"] != []))

    assert %{} =
             conn
             |> put_req_header("content-type", "application/json")
             |> delete("/api/v1/book_shelves", %{"book_uri" => book_uri})
             |> json_response(:ok)

    assert BookShelfEntry.list(user) == []
  end

  test "rejects percentage progress outside its bounded range" do
    user = insert(:user)

    assert {:error, changeset} =
             BookShelfEntry.put(user, %{
               "book_uri" => "https://books.example/book/edition-2",
               "shelf" => "reading",
               "progress" => 101,
               "progress_mode" => "percent"
             })

    assert changeset.errors
           |> Keyword.get_values(:progress)
           |> Enum.any?(fn
             {"must be at most 100 when measured as percent", _options} -> true
             _ -> false
           end)
  end

  test "distinguishes federated BookWyrm books from local metadata URLs" do
    clear_config([:native_discovery, :bookwyrm_indexes], ["https://books.example"])

    assert BookShelfEntry.federatable_book_uri?("https://books.example/book/edition-2")
    refute BookShelfEntry.federatable_book_uri?("https://openlibrary.org/books/OL1M")
    refute BookShelfEntry.federatable_book_uri?("https://books.example/search?q=edition")
  end

  test "library changes do not create timeline activities or notifications" do
    clear_config([:native_discovery, :bookwyrm_indexes], ["https://bookwyrm.example"])

    %{user: user, conn: conn} = oauth_access(["read:statuses", "write:statuses"])

    follower =
      insert(:user,
        local: false,
        ap_id: "https://bookwyrm.example/user/quiet-reader",
        follower_address: "https://bookwyrm.example/user/quiet-reader/followers"
      )

    assert {:ok, _, _} = FollowingRelationship.follow(follower, user, :follow_accept)

    assert {:ok, _instance} =
             %Instance{}
             |> Instance.changeset(%{
               host: "bookwyrm.example",
               metadata: %{software_name: "bookwyrm"}
             })
             |> Repo.insert()

    activity_count = Repo.aggregate(Activity, :count, :id)
    notification_count = Repo.aggregate(Notification, :count, :id)
    book_uri = "https://bookwyrm.example/book/quiet-edition"

    assert %{"shelf" => "to-read"} =
             conn
             |> put_req_header("content-type", "application/json")
             |> post("/api/v1/book_shelves", %{
               "book_uri" => book_uri,
               "shelf" => "to-read"
             })
             |> json_response(:ok)

    assert %{"shelf" => "reading", "progress" => 20} =
             conn
             |> put_req_header("content-type", "application/json")
             |> post("/api/v1/book_shelves", %{
               "book_uri" => book_uri,
               "shelf" => "reading",
               "progress" => 20,
               "progress_mode" => "percent"
             })
             |> json_response(:ok)

    assert %{} =
             conn
             |> put_req_header("content-type", "application/json")
             |> delete("/api/v1/book_shelves", %{"book_uri" => book_uri})
             |> json_response(:ok)

    assert Repo.aggregate(Activity, :count, :id) == activity_count
    assert Repo.aggregate(Notification, :count, :id) == notification_count
  end

  test "renders an actor-owned BookWyrm Shelf and its items" do
    user = insert(:user)

    assert {:ok, _entry} =
             BookShelfEntry.put(user, %{
               "book_uri" => "https://books.example/book/edition-3",
               "shelf" => "read"
             })

    assert %{
             "type" => "Shelf",
             "owner" => owner,
             "totalItems" => 1,
             "first" => first
           } =
             build_conn()
             |> get("/users/#{user.nickname}/books/read")
             |> json_response(:ok)

    assert owner == user.ap_id
    assert first == "#{user.ap_id}/books/read?page=1"

    assert %{"type" => "OrderedCollectionPage", "orderedItems" => [item]} =
             build_conn()
             |> get("/users/#{user.nickname}/books/read?page=1")
             |> json_response(:ok)

    assert item["type"] == "ShelfItem"
    assert item["book"] == "https://books.example/book/edition-3"
  end
end

# end of book_shelf_controller_test.exs
