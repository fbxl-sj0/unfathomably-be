# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ReplyPolicyTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.GroupMembership
  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.ObjectValidators.ArticleNotePageValidator
  alias Pleroma.Web.ActivityPub.ReplyPolicy
  alias Pleroma.Web.CommonAPI

  import Pleroma.Factory

  require Pleroma.Constants

  test "a root lock closes descendants and rejects local and incoming replies" do
    author = insert(:user)
    first_replier = insert(:user)
    blocked_replier = insert(:user)

    {:ok, root} = CommonAPI.post(author, %{status: "Root"})
    {:ok, child} = CommonAPI.post(first_replier, %{status: "Child", in_reply_to_id: root.id})

    root_object = Object.normalize(root, fetch: false)
    child_object = Object.normalize(child, fetch: false)
    {:ok, _root_object} = Object.update_data(root_object, %{"commentsEnabled" => false})

    refute ReplyPolicy.open?(child_object)

    assert {:error, errors} =
             CommonAPI.post(blocked_replier, %{
               status: "Local bypass attempt",
               in_reply_to_id: child.id
             })

    assert Enum.any?(errors, &String.contains?(&1, "discussion is locked"))

    remote_replier =
      insert(:user,
        local: false,
        ap_id: "https://remote.example/users/replier",
        follower_address: "https://remote.example/users/replier/followers"
      )

    remote_reply = %{
      "id" => "https://remote.example/statuses/reply",
      "type" => "Note",
      "actor" => remote_replier.ap_id,
      "attributedTo" => remote_replier.ap_id,
      "inReplyTo" => child_object.data["id"],
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [],
      "content" => "Remote bypass attempt",
      "context" => child_object.data["context"]
    }

    changeset = ArticleNotePageValidator.cast_and_validate(remote_reply)
    refute changeset.valid?
    assert {"reply thread is locked", []} = changeset.errors[:inReplyTo]
  end

  test "a local group manager retains authority below a locked group thread" do
    owner = insert(:user)
    author = insert(:user)
    group = insert(:user, local: true, actor_type: "Group")
    {:ok, _membership} = GroupMembership.ensure_owner(group, owner)

    {:ok, root} = CommonAPI.post(author, %{status: "Group root"})
    {:ok, child} = CommonAPI.post(author, %{status: "Group child", in_reply_to_id: root.id})

    root_object = Object.normalize(root, fetch: false)

    {:ok, _root_object} =
      Object.update_data(root_object, %{
        "commentsEnabled" => false,
        "audience" => group.ap_id
      })

    assert :ok = ReplyPolicy.allowed?(child, owner)

    assert {:ok, _reply} =
             CommonAPI.post(owner, %{status: "Moderator reply", in_reply_to_id: child.id})
  end
end

# end of test/pleroma/web/activity_pub/reply_policy_test.exs
