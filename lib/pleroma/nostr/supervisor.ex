# Unfathomably BE
# ----------------
#
# File: nostr/supervisor.ex
#
# Purpose:
#   Own the optional Nostr relay and external synchronization process tree.
#
# Responsibilities:
#   - start relay registries with the required key semantics
#   - supervise external relay connections independently
#   - keep the whole subsystem inert when Nostr is disabled
#
# This file intentionally does NOT connect to relays directly or perform
# protocol translation.

defmodule Pleroma.Nostr.Supervisor do
  use Supervisor

  alias Pleroma.Nostr.RelayHub

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    local_group_reconciler =
      Supervisor.child_spec(
        {Task, &Pleroma.Nostr.Community.reconcile_local_groups/0},
        id: Pleroma.Nostr.LocalGroupReconciler
      )

    children =
      if Pleroma.Nostr.enabled?() do
        RelayHub.child_specs() ++
          [
            {DynamicSupervisor,
             strategy: :one_for_one, name: Pleroma.Nostr.RelayConnectionSupervisor},
            Pleroma.Nostr.RelayManager,
            local_group_reconciler
          ]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end

# end of nostr/supervisor.ex
