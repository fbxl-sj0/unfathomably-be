# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.MastodonAPIControllerTest do
  use Pleroma.Web.ConnCase, async: true

  import Pleroma.Factory

  describe "compatibility endpoints" do
    test "GET /api/v1/accounts/:id/identity_proofs" do
      proof = %{
        "type" => "VerifiableIdentityStatement",
        "subject" => "did:key:z6Mktest",
        "alsoKnownAs" => "https://remote.example/users/alice",
        "proof" => %{"type" => "DataIntegrityProof", "cryptosuite" => "eddsa-jcs-2022"}
      }

      target = insert(:user, identity_proofs: [proof])
      %{conn: conn} = oauth_access(["read:accounts"])

      assert [proof] ==
               conn
               |> get("/api/v1/accounts/#{target.id}/identity_proofs")
               |> json_response(200)
    end

    test "GET /api/v1/endorsements" do
      %{conn: conn} = oauth_access(["read:accounts"])

      assert [] ==
               conn
               |> get("/api/v1/endorsements")
               |> json_response(200)
    end

    test "GET /api/v1/trends", %{conn: conn} do
      assert [] ==
               conn
               |> get("/api/v1/trends")
               |> json_response(200)
    end

    test "GET /api/v1/trends/statuses", %{conn: conn} do
      assert [] ==
               conn
               |> get("/api/v1/trends/statuses")
               |> json_response(200)
    end
  end
end
