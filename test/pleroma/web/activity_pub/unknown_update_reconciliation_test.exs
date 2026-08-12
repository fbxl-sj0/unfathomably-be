# Unfathomably: concurrent Create and Update reconciliation tests
#
# File: unknown_update_reconciliation_test.exs
#
# Purpose:
#   Prove that the insert-or-existing boundary applies a newer Update body when
#   a concurrent Create wins object insertion, without allowing an older Update
#   to replace a newer stored representation.
#
# This file intentionally does not depend on scheduler timing to create a race.

defmodule Pleroma.Web.ActivityPub.UnknownUpdateReconciliationTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.SideEffects

  test "applies a newer Update after a Create wins object insertion" do
    {:ok, original} = Object.create(object_data("original", "2026-08-10T10:00:00Z"))

    update =
      object_data("edited", "2026-08-10T10:00:00Z")
      |> Map.put("updated", "2026-08-10T10:05:00Z")

    assert {:ok, reconciled, true} = SideEffects.reconcile_unknown_update(original, update)
    assert reconciled.data["content"] == "edited"
    assert reconciled.data["updated"] == "2026-08-10T10:05:00Z"
  end

  test "does not replace a newer stored representation with an older Update" do
    original =
      object_data("current", "2026-08-10T10:00:00Z")
      |> Map.put("updated", "2026-08-10T10:10:00Z")

    {:ok, original} = Object.create(original)

    older_update =
      object_data("stale", "2026-08-10T10:00:00Z")
      |> Map.put("updated", "2026-08-10T10:05:00Z")

    assert {:ok, reconciled, false} =
             SideEffects.reconcile_unknown_update(original, older_update)

    assert reconciled.data["content"] == "current"
    assert reconciled.data["updated"] == "2026-08-10T10:10:00Z"
  end

  defp object_data(content, published) do
    %{
      "actor" => "https://remote.example/users/alice",
      "attributedTo" => "https://remote.example/users/alice",
      "cc" => [],
      "content" => content,
      "context" => "https://remote.example/contexts/thread",
      "id" => "https://remote.example/objects/racing-status",
      "published" => published,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "type" => "Note"
    }
  end
end

# end of unknown_update_reconciliation_test.exs
