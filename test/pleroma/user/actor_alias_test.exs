# Unfathomably: Verified remote actor alias tests
#
# File: actor_alias_test.exs
#
# Purpose:
#   Cover canonical actor binding and safe reassignment of verified WebFinger
#   aliases.

defmodule Pleroma.User.ActorAliasTest do
  use Pleroma.DataCase, async: false

  alias Pleroma.User.ActorAlias

  import Pleroma.Factory

  test "a newly verified handle is bound to its canonical actor" do
    user = insert(:user, local: false)

    assert {:ok, _binding} = ActorAlias.bind_verified(user, "Alice@Example.COM")
    assert %{id: user_id} = ActorAlias.get_fresh_user("@Alice@example.com")
    assert user_id == user.id
  end

  test "a new WebFinger proof atomically reassigns an alias without duplicating it" do
    old_user = insert(:user, local: false)
    new_user = insert(:user, local: false)

    assert {:ok, _binding} = ActorAlias.bind_verified(old_user, "alice@example.com")
    assert {:ok, _binding} = ActorAlias.bind_verified(new_user, "alice@example.com")

    assert %{id: user_id} = ActorAlias.get_fresh_user("alice@example.com")
    assert user_id == new_user.id
  end
end

# end of actor_alias_test.exs
