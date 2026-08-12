# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.AdminAPI.AccountViewTest do
  use Pleroma.DataCase, async: true
  import Pleroma.Factory
  alias Pleroma.Web.AdminAPI.AccountView

  describe "show.json" do
    test "renders the user's email" do
      user = insert(:user, email: "yolo@yolofam.tld")
      assert %{"email" => "yolo@yolofam.tld"} = AccountView.render("show.json", %{user: user})
    end

    test "renders account migration state" do
      user =
        insert(:user,
          also_known_as: ["https://old.example/users/alice"],
          last_move_at: ~N[2025-08-08 12:34:56]
        )

      assert %{
               "also_known_as" => ["https://old.example/users/alice"],
               "last_move_at" => "2025-08-08T12:34:56.000Z"
             } = AccountView.render("show.json", %{user: user})
    end
  end
end
