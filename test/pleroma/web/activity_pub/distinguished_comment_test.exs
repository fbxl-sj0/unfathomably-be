# Unfathomably Backend
#
# File: distinguished_comment_test.exs
#
# Purpose:
#   Cover authority-backed preservation of moderator-comment metadata.

defmodule Pleroma.Web.ActivityPub.DistinguishedCommentTest do
  use Pleroma.DataCase, async: true

  import Pleroma.Factory

  alias Pleroma.GroupMembership
  alias Pleroma.Web.ActivityPub.DistinguishedComment

  test "preserves distinction for a known group moderator" do
    group =
      insert(:user,
        local: true,
        actor_type: "Group",
        ap_id: "https://local.example/groups/engineering"
      )

    moderator = insert(:user, local: false, ap_id: "https://remote.example/users/mod")

    assert {:ok, _membership} =
             GroupMembership.sync_directory_member(group, moderator, "moderator")

    data = %{
      "type" => "Note",
      "actor" => moderator.ap_id,
      "inReplyTo" => "https://local.example/objects/topic",
      "audience" => group.ap_id,
      "distinguished" => true
    }

    assert DistinguishedComment.normalize(data)["distinguished"] == true
  end

  test "downgrades an unproven distinction without rejecting the reply" do
    group =
      insert(:user,
        local: true,
        actor_type: "Group",
        ap_id: "https://local.example/groups/engineering"
      )

    member = insert(:user, local: false, ap_id: "https://remote.example/users/member")
    assert {:ok, _membership} = GroupMembership.sync_directory_member(group, member, "user")

    data = %{
      "type" => "Note",
      "actor" => member.ap_id,
      "inReplyTo" => "https://local.example/objects/topic",
      "audience" => group.ap_id,
      "distinguished" => true
    }

    assert DistinguishedComment.normalize(data)["distinguished"] == false
  end
end

# end of test/pleroma/web/activity_pub/distinguished_comment_test.exs
