# Unfathomably BE
# ----------------
#
# File: test/pleroma/atproto/links_test.exs
#
# Purpose:
#   Verify local AT Protocol account provisioning and managed-link behavior.
#
# Responsibilities:
#   - map local usernames onto valid service handles
#   - authenticate account creation with the local PDS administrator secret
#   - retain encrypted sessions without retaining generated passwords
#   - prevent managed repositories from being orphaned through disconnect
#
# This file intentionally does NOT contact a live PDS or publish records.

defmodule Pleroma.ATProto.LinksTest do
  use Pleroma.DataCase

  import Pleroma.Factory
  import Tesla.Mock

  alias Pleroma.ATProto.Link
  alias Pleroma.ATProto.Links
  alias Pleroma.Repo

  @did "did:plc:managedexample"
  @handle "sj-zero.social.fbxl.net"
  @pds_url "https://pds.fbxl.net"
  @admin_password "test-admin-password"

  setup do
    clear_config([Pleroma.ATProto, :local_pds_enabled], true)
    clear_config([Pleroma.ATProto, :local_pds_url], @pds_url)
    clear_config([Pleroma.ATProto, :local_handle_domain], "social.fbxl.net")
    clear_config([Pleroma.ATProto, :local_pds_admin_password], @admin_password)

    mock(fn env ->
      case {env.method, env.url} do
        {:post, "#{@pds_url}/xrpc/com.atproto.server.createInviteCode"} ->
          expected = "Basic " <> Base.encode64("admin:#{@admin_password}")
          assert {"authorization", expected} in env.headers
          assert Jason.decode!(env.body) == %{"useCount" => 1}
          json(%{"code" => "invite-code"})

        {:post, "#{@pds_url}/xrpc/com.atproto.server.createAccount"} ->
          body = Jason.decode!(env.body)

          assert body["handle"] == @handle
          assert body["email"] == "sj-zero@example.com"
          assert body["inviteCode"] == "invite-code"
          assert is_binary(body["password"])
          assert byte_size(body["password"]) >= 24

          json(%{
            "did" => @did,
            "handle" => @handle,
            "accessJwt" => "access-token",
            "refreshJwt" => "refresh-token"
          })

        _request ->
          %Tesla.Env{status: 404, body: Jason.encode!(%{"error" => "NotFound"})}
      end
    end)

    :ok
  end

  test "provisions a managed PDS identity and translates underscores in the handle" do
    user = insert(:user, nickname: "sj_zero", email: "sj-zero@example.com")

    assert {:ok, state} = Links.provision_local(user)
    assert state.connected
    assert state.managed
    assert state.did == @did
    assert state.handle == @handle
    assert state.pds == @pds_url
    assert state.password_shown_once
    assert is_binary(state.account_password)

    assert %Link{managed: true, handle: @handle, did: @did} =
             Repo.get_by(Link, user_id: user.id)

    assert {:ok, existing_state} = Links.provision_local(user)
    refute Map.has_key?(existing_state, :account_password)
    assert {:error, :managed_identity} = Links.disconnect(user)
  end

  test "advertises the deterministic handle before the user opts in" do
    user = insert(:user, nickname: "sj_zero", email: "sj-zero@example.com")

    assert %{
             connected: false,
             provisioning_available: true,
             suggested_handle: @handle
           } = Links.state(user)
  end
end

# end of test/pleroma/atproto/links_test.exs
