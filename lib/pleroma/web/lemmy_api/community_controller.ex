# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.LemmyAPI.CommunityController do
  use Pleroma.Web, :controller

  import Ecto.Query

  alias Pleroma.Repo
  alias Pleroma.User

  def list(conn, params) do
    communities =
      case Map.get(params, "type_", Map.get(params, :type_)) do
        "Subscribed" -> []
        _ -> public_communities()
      end

    json(conn, %{"communities" => Enum.map(communities, &render_community/1)})
  end

  defp public_communities do
    User
    |> where([u], u.local == true)
    |> where([u], u.actor_type == "Group")
    |> where([u], u.is_active == true)
    |> where([u], u.invisible == false)
    |> where([u], u.is_discoverable == true)
    |> order_by([u], asc: u.nickname)
    |> limit(50)
    |> Repo.all()
  end

  defp render_community(%User{} = group) do
    %{
      "community" => %{
        "id" => group.id,
        "name" => group.nickname,
        "title" => group.name || group.nickname,
        "actor_id" => group.ap_id,
        "local" => true,
        "deleted" => false,
        "removed" => false,
        "nsfw" => false,
        "hidden" => false,
        "posting_restricted_to_mods" => group.posting_restricted_to_mods || false
      },
      "subscribed" => "NotSubscribed"
    }
  end
end
