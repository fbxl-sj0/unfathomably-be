defmodule Pleroma.Web.LemmyAPI.CommunityControllerTest do
  use Pleroma.Web.ConnCase, async: true

  alias Pleroma.Web.FederatedTarget

  import Pleroma.Factory

  describe "GET /api/v3/community/list" do
    test "lists only discoverable local groups", %{conn: conn} do
      owner = insert(:user)

      {:ok, listed_group} =
        FederatedTarget.create_local_group(owner, %{
          "display_name" => "Listed Group",
          "group_visibility" => "everyone",
          "discoverable" => "true"
        })

      {:ok, hidden_group} =
        FederatedTarget.create_local_group(owner, %{
          "display_name" => "Hidden Group",
          "group_visibility" => "everyone",
          "discoverable" => "false"
        })

      conn = get(conn, "/api/v3/community/list")

      names =
        conn
        |> json_response(200)
        |> Map.fetch!("communities")
        |> Enum.map(&get_in(&1, ["community", "name"]))

      assert listed_group.nickname in names
      refute hidden_group.nickname in names
    end

    test "returns no subscribed groups for unauthenticated Lemmy clients", %{conn: conn} do
      owner = insert(:user)

      {:ok, _group} =
        FederatedTarget.create_local_group(owner, %{
          "display_name" => "Listed Group",
          "group_visibility" => "everyone",
          "discoverable" => "true"
        })

      conn = get(conn, "/api/v3/community/list", %{"type_" => "Subscribed"})

      assert %{"communities" => []} = json_response(conn, 200)
    end
  end
end
