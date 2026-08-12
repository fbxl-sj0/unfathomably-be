# Project: Unfathomably BE
# File: batched_announce_test.exs
# Purpose: Protect safe expansion of PieFed multi-object Announce activities.
# Responsibilities: Verify bounds, audience containment, and deterministic IDs.
# This file intentionally does not run the federation pipeline or verify signatures.

defmodule Pleroma.Web.ActivityPub.BatchedAnnounceTest do
  use ExUnit.Case, async: true

  alias Pleroma.Web.ActivityPub.BatchedAnnounce

  @actor "https://forum.example/c/news"
  @activity_id "https://forum.example/activities/announce/batch"

  test "expands same-group items into deterministic single-object activities" do
    first = item("https://forum.example/activities/like/1", "Like")
    second = item("https://forum.example/activities/undo/2", "Undo")
    activity = announce([first, second])

    assert {:ok, expanded} = BatchedAnnounce.expand(activity)
    assert Enum.map(expanded, & &1["object"]) == [first, second]
    assert Enum.all?(expanded, &String.starts_with?(&1["id"], @activity_id <> "#batch-"))
    assert expanded == elem(BatchedAnnounce.expand(activity), 1)
    assert length(Enum.uniq_by(expanded, & &1["id"])) == 2
  end

  test "rejects an item that is not addressed to the announcing group" do
    item =
      "https://forum.example/activities/like/1"
      |> item("Like")
      |> Map.put("audience", "https://forum.example/c/other")

    assert {:error, :invalid_batched_announce} = BatchedAnnounce.expand(announce([item]))
  end

  test "rejects batches above the processing bound" do
    items =
      Enum.map(1..101, fn index ->
        item("https://forum.example/activities/like/#{index}", "Like")
      end)

    assert {:error, :invalid_batched_announce} = BatchedAnnounce.expand(announce(items))
  end

  defp announce(items) do
    %{
      "type" => "Announce",
      "id" => @activity_id,
      "actor" => @actor,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "object" => items
    }
  end

  defp item(id, type), do: %{"id" => id, "type" => type, "audience" => @actor}
end

# end of batched_announce_test.exs
