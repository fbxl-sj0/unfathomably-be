# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.OAuth.AppTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Repo
  alias Pleroma.Web.OAuth.App
  import Pleroma.Factory

  describe "get_or_make/2" do
    test "gets exist app" do
      attrs = %{client_name: "Mastodon-Local", redirect_uris: "."}
      app = insert(:oauth_app, Map.merge(attrs, %{scopes: ["read", "write"]}))
      {:ok, %App{} = exist_app} = App.get_or_make(attrs, [])
      assert exist_app == app
    end

    test "make app" do
      attrs = %{client_name: "Mastodon-Local", redirect_uris: "."}
      {:ok, %App{} = app} = App.get_or_make(attrs, ["write"])
      assert app.scopes == ["write"]
    end

    test "gets exist app and updates scopes" do
      attrs = %{client_name: "Mastodon-Local", redirect_uris: "."}
      app = insert(:oauth_app, Map.merge(attrs, %{scopes: ["read", "write"]}))
      {:ok, %App{} = exist_app} = App.get_or_make(attrs, ["read", "write", "follow", "push"])
      assert exist_app.id == app.id
      assert exist_app.scopes == ["read", "write", "follow", "push"]
    end

    test "has unique client_id" do
      insert(:oauth_app, client_name: "", redirect_uris: "", client_id: "boop")

      error =
        catch_error(insert(:oauth_app, client_name: "", redirect_uris: "", client_id: "boop"))

      assert %Ecto.ConstraintError{} = error
      assert error.constraint == "apps_client_id_index"
      assert error.type == :unique
    end
  end

  test "get_user_apps/1" do
    user = insert(:user)

    apps = [
      insert(:oauth_app, user_id: user.id),
      insert(:oauth_app, user_id: user.id),
      insert(:oauth_app, user_id: user.id)
    ]

    assert Enum.sort(App.get_user_apps(user)) == Enum.sort(apps)
  end

  describe "maybe_update_owner/1" do
    test "assigns an app used by one account to that account" do
      user = insert(:user)
      app = insert(:oauth_app, user_id: nil)
      token = insert(:oauth_token, app: app, user: user)

      assert :ok = App.maybe_update_owner(token)
      assert Repo.get(App, app.id).user_id == user.id
    end

    test "removes the owner when an app is shared by multiple accounts" do
      first_user = insert(:user)
      second_user = insert(:user)
      app = insert(:oauth_app, user_id: nil)
      first_token = insert(:oauth_token, app: app, user: first_user)
      second_token = insert(:oauth_token, app: app, user: second_user)

      assert :ok = App.maybe_update_owner(first_token)
      assert Repo.get(App, app.id).user_id == nil

      assert :ok = App.maybe_update_owner(second_token)
      assert Repo.get(App, app.id).user_id == nil
    end
  end

  test "removes orphaned apps" do
    attrs = %{client_name: "Mastodon-Local", redirect_uris: "."}
    {:ok, %App{} = old_app} = App.get_or_make(attrs, ["write"])

    # backdate the old app so it's within the threshold for being cleaned up
    one_hour_ago = DateTime.add(DateTime.utc_now(), -3600)

    {:ok, _} =
      "UPDATE apps SET inserted_at = $1, updated_at = $1 WHERE id = $2"
      |> Pleroma.Repo.query([one_hour_ago, old_app.id])

    # Create the new app after backdating the old one
    attrs = %{client_name: "PleromaFE", redirect_uris: "."}
    {:ok, %App{} = app} = App.get_or_make(attrs, ["write"])

    App.remove_orphans()

    assert [app] == Pleroma.Repo.all(App)
  end
end
