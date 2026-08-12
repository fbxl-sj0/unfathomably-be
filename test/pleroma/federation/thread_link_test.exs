# Unfathomably BE
# ----------------
#
# File: test/pleroma/federation/thread_link_test.exs
#
# Purpose:
#   Verify the common late-parent repair used by native protocol bridges.
#
# Responsibilities:
#   - persist ActivityPub inReplyTo and context fields together
#   - replace stale cached object data after repair
#   - expose the repaired parent through Mastodon-compatible status rendering
#
# This file intentionally does NOT resolve Nostr, ATProto, or diaspora* IDs.

defmodule Pleroma.Federation.ThreadLinkTest do
  use Pleroma.DataCase, async: false

  import Pleroma.Factory

  alias Pleroma.Activity
  alias Pleroma.Federation.ThreadLink
  alias Pleroma.Object
  alias Pleroma.Web.MastodonAPI.StatusView

  test "makes a repaired native projection render as a reply" do
    parent_context = "https://social.example/contexts/native-thread"
    parent_object = insert(:note, data: %{"context" => parent_context})

    parent_activity =
      insert(:note_activity,
        note: parent_object,
        data_attrs: %{"context" => parent_context}
      )

    reply_object = insert(:note, data: %{"context" => nil, "inReplyTo" => nil})
    reply_activity = insert(:note_activity, note: reply_object, data_attrs: %{"context" => nil})

    assert %Object{data: %{"inReplyTo" => nil}} =
             Object.normalize(reply_activity, fetch: false)

    assert {:ok, %Activity{} = repaired_activity} =
             ThreadLink.repair(reply_activity, parent_activity)

    repaired_object = Object.normalize(repaired_activity, fetch: false)

    assert repaired_activity.data["context"] == parent_context
    assert repaired_object.data["context"] == parent_context
    assert repaired_object.data["inReplyTo"] == parent_object.data["id"]

    rendered = StatusView.render("show.json", activity: repaired_activity)

    assert rendered.in_reply_to_id == to_string(parent_activity.id)
    assert rendered.in_reply_to_account_id
  end
end

# end of test/pleroma/federation/thread_link_test.exs
