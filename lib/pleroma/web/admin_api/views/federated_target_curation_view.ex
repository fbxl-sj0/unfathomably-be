# Unfathomably Backend
#
# File: federated_target_curation_view.ex
#
# Purpose:
#   Render staff curation state alongside ordinary remote Group presentations.
#
# This file intentionally does not expose local actor internals or perform
# curation mutations.

defmodule Pleroma.Web.AdminAPI.FederatedTargetCurationView do
  use Pleroma.Web, :view

  alias Pleroma.FederatedTargetCuration
  alias Pleroma.Web.MastodonAPI.FederatedTargetView

  def render("index.json", %{curations: curations} = opts) do
    groups = Enum.map(curations, & &1.target)

    rendered_groups =
      FederatedTargetView.render("groups.json", %{
        groups: groups,
        for: opts[:for],
        include_interaction_score: false,
        refresh_counts: false
      })

    curations
    |> Enum.zip(rendered_groups)
    |> Enum.map(fn {%FederatedTargetCuration{} = curation, group} ->
      %{
        id: to_string(curation.id),
        enabled: curation.enabled,
        position: curation.position,
        target: Map.put(group, :remote, true)
      }
    end)
  end

  def render("show.json", %{curation: %FederatedTargetCuration{} = curation} = opts) do
    [rendered] = render("index.json", Map.put(opts, :curations, [curation]))
    rendered
  end
end

# end of lib/pleroma/web/admin_api/views/federated_target_curation_view.ex
