# Unfathomably BE
# ----------------
#
# File: 20260810120001_track_successful_activity_federation.exs
#
# Purpose:
#   Distinguish activities accepted by a remote peer from activities that
#   never left the local server.
#
# Responsibilities:
#   - preserve conservative behavior for historical activity rows
#   - give newly inserted activities an explicit undelivered state
#
# This file intentionally does NOT infer historical delivery from visibility
# or queued jobs because neither proves that a peer accepted an activity.

defmodule Pleroma.Repo.Migrations.TrackSuccessfulActivityFederation do
  use Ecto.Migration

  def up do
    alter table(:activities) do
      add(:federated, :boolean, null: false, default: true)
    end
  end

  def down do
    alter table(:activities) do
      remove(:federated)
    end
  end
end

# end of 20260810120001_track_successful_activity_federation.exs
