# Unfathomably: Canonical ActivityPub actor identity tests
#
# File: actor_identity_test.exs
#
# Purpose:
#   Ensure nickname collisions cannot transfer actor authority without a
#   verified WebFinger result.

defmodule Pleroma.Web.ActivityPub.ActorIdentityTest do
  use Pleroma.DataCase, async: false

  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ActivityPub

  import Pleroma.Factory

  test "an inferred handle cannot displace an existing canonical actor" do
    old_user =
      insert(:user,
        local: false,
        nickname: "alice@example.com",
        ap_id: "https://example.com/actors/old-alice"
      )

    assert {:ok, resolved} =
             ActivityPub.maybe_handle_clashing_nickname(%{
               nickname: old_user.nickname,
               nickname_authoritative: false,
               ap_id: "https://example.com/actors/new-alice"
             })

    assert User.get_by_id(old_user.id).nickname == "alice@example.com"
    assert resolved.nickname != old_user.nickname
    assert String.ends_with?(resolved.nickname, "@example.com")
  end

  test "a verified WebFinger handle can release the previous remote nickname" do
    old_user =
      insert(:user,
        local: false,
        nickname: "alice@example.com",
        ap_id: "https://example.com/actors/old-alice"
      )

    assert {:ok, resolved} =
             ActivityPub.maybe_handle_clashing_nickname(%{
               nickname: old_user.nickname,
               nickname_authoritative: true,
               ap_id: "https://example.com/actors/new-alice"
             })

    assert resolved.nickname == "alice@example.com"
    assert User.get_by_id(old_user.id).nickname != "alice@example.com"
  end
end

# end of actor_identity_test.exs
