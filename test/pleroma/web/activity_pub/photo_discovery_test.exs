# Project: Unfathomably BE
# File: photo_discovery_test.exs
# Purpose: Protect photo discovery interaction-permission normalization.
# Responsibilities: Verify fail-closed defaults and explicit remote policy handling.
# This file intentionally does not query discovery indexes or fetch remote media.

defmodule Pleroma.Web.ActivityPub.PhotoDiscoveryTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Web.ActivityPub.PhotoDiscovery

  @public "https://www.w3.org/ns/activitystreams#Public"

  test "missing remote capabilities fail closed without claiming a declaration" do
    assert PhotoDiscovery.interaction_permissions(nil, nil) == %{
             allowed: %{announce: false, like: false, reply: false},
             declared: %{announce: false, like: false, reply: false}
           }
  end

  test "public capability declarations enable their matching actions" do
    capabilities = %{
      "announce" => @public,
      "like" => %{"id" => @public},
      "reply" => %{"items" => [@public]}
    }

    assert PhotoDiscovery.interaction_permissions(capabilities, nil) == %{
             allowed: %{announce: true, like: true, reply: true},
             declared: %{announce: true, like: true, reply: true}
           }
  end

  test "comments disabled closes replies even when a capability says public" do
    permissions = PhotoDiscovery.interaction_permissions(%{"reply" => @public}, false)

    refute permissions.allowed.reply
    assert permissions.declared.reply
  end

  test "comments enabled is an explicit reply permission when no capability exists" do
    permissions = PhotoDiscovery.interaction_permissions(%{}, true)

    assert permissions.allowed.reply
    assert permissions.declared.reply
  end
end

# end of photo_discovery_test.exs
