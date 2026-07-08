# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.PleromaAPI.FollowRequestControllerTest do
  use Pleroma.Web.ConnCase, async: true

  alias Pleroma.User
  alias Pleroma.Web.CommonAPI

  import Pleroma.Factory

  defp extract_next_link_header(header) do
    [_, next_link] = Regex.run(~r{<(?<next_link>.*)>; rel="next"}, header)
    next_link
  end

  describe "outgoing follow requests" do
    setup do
      user = insert(:user)
      %{conn: conn} = oauth_access(["follow"], user: user)
      %{user: user, conn: conn}
    end

    test "/api/v1/pleroma/outgoing_follow_requests paginates", %{user: user, conn: conn} do
      for _ <- 1..21 do
        other_user = insert(:user, is_locked: true)
        {:ok, _, _, _activity} = CommonAPI.follow(user, other_user)
        {:ok, _user, _other_user} = User.follow(user, other_user, :follow_pending)
      end

      conn = get(conn, "/api/v1/pleroma/outgoing_follow_requests")

      assert length(json_response_and_validate_schema(conn, 200)) == 20
      assert [link_header] = get_resp_header(conn, "link")
      assert link_header =~ "rel=\"next\""

      next_link = extract_next_link_header(link_header)
      assert next_link =~ "/api/v1/pleroma/outgoing_follow_requests"

      conn = get(conn, next_link)
      assert length(json_response_and_validate_schema(conn, 200)) == 1
    end
  end
end
