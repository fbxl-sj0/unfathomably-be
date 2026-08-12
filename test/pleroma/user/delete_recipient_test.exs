# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.User.DeleteRecipientTest do
  use Pleroma.DataCase

  import Pleroma.Factory

  alias Pleroma.Object
  alias Pleroma.User

  test "finds remote actors that interacted with a locally cached public object" do
    author = insert(:user)
    parent_activity = insert(:note_activity, user: author)
    parent = Object.normalize(parent_activity, fetch: false)

    reply_actor = insert(:user, local: false)

    reply =
      insert(:note,
        user: reply_actor,
        data: %{"inReplyTo" => parent.data["id"]}
      )

    insert(:note_activity, user: reply_actor, note: reply)

    boost_actor = insert(:user, local: false)

    insert(:activity,
      user: boost_actor,
      data: %{"type" => "Announce", "object" => parent.data["id"]}
    )

    reaction_actor = insert(:user, local: false)

    insert(:activity,
      user: reaction_actor,
      data: %{"type" => "EmojiReact", "object" => parent.data["id"]}
    )

    quote_actor = insert(:user, local: false)
    quote = insert(:note, user: quote_actor, data: %{"quoteUrl" => parent.data["id"]})
    insert(:note_activity, user: quote_actor, note: quote)

    local_actor = insert(:user)

    insert(:activity,
      user: local_actor,
      data: %{"type" => "Like", "object" => parent.data["id"]}
    )

    actor_ids =
      parent.data["id"]
      |> User.get_remote_interactors_by_object_ap_id()
      |> Enum.map(& &1.id)
      |> MapSet.new()

    assert actor_ids ==
             MapSet.new([reply_actor.id, boost_actor.id, reaction_actor.id, quote_actor.id])
  end

  test "rejects malformed object identifiers without querying" do
    assert User.get_remote_interactors_by_object_ap_id(nil) == []
  end
end
