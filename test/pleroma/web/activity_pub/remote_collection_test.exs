# Project: Unfathomably ActivityPub Test Suite
# --------------------------------------------
#
# File: remote_collection_test.exs
#
# Purpose:
#
#     Prove remote collection traversal stays bounded, cycle-safe, and
#     tolerant of mixed collection member representations.
#
# Responsibilities:
#
#     * cover mixed inline and URL entries
#     * cover same-origin pagination and cycles
#     * cover exact and bounded fallback counts
#
# This file intentionally does NOT contain:
#
#     * live network requests
#     * object ingestion assertions
#     * actor authorization tests

defmodule Pleroma.Web.ActivityPub.RemoteCollectionTest do
  use Pleroma.DataCase, async: false

  import Mock

  alias Pleroma.Object.Fetcher
  alias Pleroma.Web.ActivityPub.RemoteCollection

  @root "https://forum.example/groups/books/moderators"
  @page "https://forum.example/groups/books/moderators?page=1"
  @first "https://forum.example/users/alice"
  @second "https://remote.example/users/bob"
  @third "https://forum.example/users/carol"

  test "collects mixed entries across same-origin pages without nulls or cycles" do
    with_mock Fetcher,
      fetch_and_contain_remote_collection_from_id: fn
        @root ->
          {:ok,
           %{
             "id" => @root,
             "type" => "OrderedCollection",
             "orderedItems" => [@first, %{"id" => @second}, nil, false],
             "first" => @page
           }}

        @page ->
          {:ok,
           %{
             "id" => @page,
             "type" => "OrderedCollectionPage",
             "items" => [@first, @third],
             "next" => @root
           }}
      end do
      assert {:ok, [@first, %{"id" => @second}, @third]} =
               RemoteCollection.fetch(@root, max_items: 10, max_pages: 4)

      assert {:ok, 3} = RemoteCollection.count(@root, max_items: 10, max_pages: 4)
    end
  end

  test "uses an exact advertised count without traversing a cross-origin page" do
    with_mock Fetcher,
      fetch_and_contain_remote_collection_from_id: fn
        @root ->
          {:ok,
           %{
             "id" => @root,
             "type" => "OrderedCollection",
             "totalItems" => "27",
             "first" => "https://attacker.example/collection"
           }}
      end do
      assert {:ok, 27} = RemoteCollection.count(@root)
    end
  end

  test "does not report a page-limited traversal as an exact count" do
    with_mock Fetcher,
      fetch_and_contain_remote_collection_from_id: fn
        @root ->
          {:ok,
           %{
             "id" => @root,
             "type" => "OrderedCollection",
             "first" => @page
           }}
      end do
      assert {:error, :collection_too_large} =
               RemoteCollection.count(@root, max_items: 10, max_pages: 1)
    end
  end
end

# end of remote_collection_test.exs
