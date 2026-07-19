# Pleroma: federation status tests
# --------------------------------
#
# File: federation_status_test.exs
#
# Purpose:
#
#     Prove that local federation policy is exposed as a stable status object
#     for clients before they try search, follow, or group interactions.
#
# Responsibilities:
#
#     * cover rejected hosts
#     * cover accept-list misses
#     * cover neutral hosts
#
# This file intentionally does NOT contain:
#
#     * remote HTTP probing
#     * ActivityPub delivery tests
#     * frontend rendering assertions

defmodule Pleroma.FederationStatusTest do
  use Pleroma.DataCase, async: false

  alias Pleroma.FederationStatus

  setup do
    clear_config([:mrf_simple, :reject], [])
    clear_config([:mrf_simple, :accept], [])
    clear_config([:instance, :quarantined_instances], [])

    :ok
  end

  test "reports locally rejected hosts with the configured reason" do
    clear_config([:mrf_simple, :reject], [{"blocked.example", "Federation paused"}])

    assert %{
             host: "blocked.example",
             known: true,
             defederated: true,
             direction: "local_policy",
             severity: "reject",
             reason: "Federation paused",
             message: "Federation paused"
           } = FederationStatus.for_identifier("@alice@blocked.example")
  end

  test "reports hosts outside a non-empty accept list" do
    clear_config([:mrf_simple, :accept], [{"allowed.example", ""}])

    assert %{
             host: "blocked.example",
             known: true,
             defederated: true,
             direction: "local_policy",
             severity: "accept_list",
             reason: "Host is not in the local federation accept list"
           } = FederationStatus.for_identifier("https://blocked.example/users/alice")
  end

  test "reports ordinary hosts as neutral" do
    assert %{
             host: "open.example",
             known: false,
             defederated: false,
             direction: nil,
             severity: "none",
             reason: nil,
             message: nil
           } = FederationStatus.for_identifier("open.example")
  end
end

# end of test/pleroma/federation_status_test.exs
