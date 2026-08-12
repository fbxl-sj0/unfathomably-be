# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.OAuth.AuthorizationTest do
  use Pleroma.DataCase, async: true
  alias Pleroma.Web.OAuth.App
  alias Pleroma.Web.OAuth.Authorization
  import Pleroma.Factory

  setup do
    {:ok, app} =
      Repo.insert(
        App.register_changeset(%App{}, %{
          client_name: "client",
          scopes: ["read", "write"],
          redirect_uris: "url"
        })
      )

    %{app: app}
  end

  test "create an authorization token for a valid app", %{app: app} do
    user = insert(:user)

    {:ok, auth1} = Authorization.create_authorization(app, user)
    assert auth1.scopes == app.scopes

    {:ok, auth2} = Authorization.create_authorization(app, user, ["read"])
    assert auth2.scopes == ["read"]

    for auth <- [auth1, auth2] do
      assert auth.user_id == user.id
      assert auth.app_id == app.id
      assert String.length(auth.token) > 10
      assert auth.used == false
    end
  end

  test "stores and validates an S256 PKCE challenge", %{app: app} do
    user = insert(:user)
    verifier = String.duplicate("a", 43)

    challenge =
      :crypto.hash(:sha256, verifier)
      |> Base.url_encode64(padding: false)

    {:ok, auth} =
      Authorization.create_authorization(app, user, ["read"], %{
        redirect_uri: "url",
        code_challenge: challenge,
        code_challenge_method: "S256"
      })

    assert :ok ==
             Authorization.validate_exchange(auth, %{
               "redirect_uri" => "url",
               "code_verifier" => verifier
             })

    assert {:error, :invalid_code_verifier} ==
             Authorization.validate_exchange(auth, %{
               "redirect_uri" => "url",
               "code_verifier" => String.duplicate("b", 43)
             })

    assert {:error, :redirect_uri_mismatch} ==
             Authorization.validate_exchange(auth, %{
               "redirect_uri" => "different",
               "code_verifier" => verifier
             })
  end

  test "rejects malformed PKCE authorization values", %{app: app} do
    user = insert(:user)

    assert {:error, changeset} =
             Authorization.create_authorization(app, user, nil, %{
               code_challenge: "short",
               code_challenge_method: "S256"
             })

    assert "must be a valid RFC 7636 challenge" in errors_on(changeset).code_challenge
  end

  test "use up a token", %{app: app} do
    user = insert(:user)

    {:ok, auth} = Authorization.create_authorization(app, user)

    {:ok, auth} = Authorization.use_token(auth)

    assert auth.used == true

    assert {:error, "already used"} == Authorization.use_token(auth)

    expired_auth = %Authorization{
      user_id: user.id,
      app_id: app.id,
      valid_until: NaiveDateTime.add(NaiveDateTime.utc_now(), -10),
      token: "mytoken",
      used: false
    }

    {:ok, expired_auth} = Repo.insert(expired_auth)

    assert {:error, "token expired"} == Authorization.use_token(expired_auth)
  end

  test "delete authorizations", %{app: app} do
    user = insert(:user)

    {:ok, auth} = Authorization.create_authorization(app, user)
    {:ok, auth} = Authorization.use_token(auth)

    Authorization.delete_user_authorizations(user)

    {_, invalid} = Authorization.use_token(auth)

    assert auth != invalid
  end
end
