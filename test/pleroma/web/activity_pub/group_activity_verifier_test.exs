# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.GroupActivityVerifierTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Web.ActivityPub.GroupActivityVerifier

  @group "https://group.example/c/testing"
  @announce_id "https://group.example/activities/announce/1"

  test "trusts an embedded activity owned by the wrapper origin" do
    activity = embedded_activity("https://group.example/activities/create/1", @group)

    assert {:ok, ^activity} =
             GroupActivityVerifier.canonicalize(group_announce(activity), activity, fn _id ->
               flunk("same-origin activities must not be fetched")
             end)
  end

  test "fetches a cross-origin embedded activity from its canonical identifier" do
    activity_id = "https://author.example/activities/create/1"
    actor = "https://author.example/users/alice"
    forwarded = embedded_activity(activity_id, actor) |> put_in(["object", "name"], "changed")
    canonical = embedded_activity(activity_id, actor)

    assert {:ok, ^canonical} =
             GroupActivityVerifier.canonicalize(group_announce(forwarded), forwarded, fn
               ^activity_id -> {:ok, canonical}
             end)
  end

  test "rejects a fetched activity whose identifier or type changed" do
    activity_id = "https://author.example/activities/create/1"
    activity = embedded_activity(activity_id, "https://author.example/users/alice")
    mismatched = %{activity | "id" => activity_id <> "/other"}

    assert {:error, {:reject, :group_activity_origin_mismatch}} =
             GroupActivityVerifier.canonicalize(group_announce(activity), activity, fn
               ^activity_id -> {:ok, mismatched}
             end)
  end

  test "accepts an idless embedded activity only for an actor on the wrapper origin" do
    local_activity = embedded_activity(nil, @group)
    remote_activity = embedded_activity(nil, "https://author.example/users/alice")

    assert {:ok, ^local_activity} =
             GroupActivityVerifier.canonicalize(
               group_announce(local_activity),
               local_activity,
               fn _id -> flunk("idless activities cannot be fetched") end
             )

    assert {:error, {:reject, :invalid_group_activity}} =
             GroupActivityVerifier.canonicalize(
               group_announce(remote_activity),
               remote_activity,
               fn _id -> flunk("idless activities cannot be fetched") end
             )
  end

  defp group_announce(activity) do
    %{
      "id" => @announce_id,
      "type" => "Announce",
      "actor" => @group,
      "object" => activity
    }
  end

  defp embedded_activity(id, actor) do
    %{
      "id" => id,
      "type" => "Create",
      "actor" => actor,
      "object" => %{
        "id" => "https://group.example/post/1",
        "type" => "Page",
        "attributedTo" => actor
      }
    }
  end
end

# end of group_activity_verifier_test.exs
