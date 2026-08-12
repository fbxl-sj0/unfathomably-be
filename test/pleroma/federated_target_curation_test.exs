# Unfathomably Backend
#
# File: federated_target_curation_test.exs
#
# Purpose:
#   Protect duplicate-safe remote Group curation and reversible visibility.

defmodule Pleroma.FederatedTargetCurationTest do
  use Pleroma.DataCase

  import Pleroma.Factory

  alias Pleroma.FederatedTargetCuration
  alias Pleroma.Repo

  test "put/1 reuses one row and disabled rows leave the public catalog" do
    group =
      insert(:user,
        local: false,
        actor_type: "Group",
        ap_id: "https://groups.example/communities/elixir",
        is_active: true,
        invisible: false
      )

    assert {:ok, first} = FederatedTargetCuration.put(group)
    assert {:ok, second} = FederatedTargetCuration.put(group)
    assert first.id == second.id
    assert Repo.aggregate(FederatedTargetCuration, :count, :id) == 1
    assert FederatedTargetCuration.active_positions([group]) == %{group.id => first.position}

    assert {:ok, disabled} = FederatedTargetCuration.update(first, %{enabled: false})
    assert disabled.enabled == false
    assert FederatedTargetCuration.active_positions([group]) == %{}

    assert {:ok, reenabled} = FederatedTargetCuration.put(group)
    assert reenabled.id == first.id
    assert reenabled.enabled == true
    assert FederatedTargetCuration.active_positions([group]) == %{group.id => first.position}
  end
end

# end of test/pleroma/federated_target_curation_test.exs
