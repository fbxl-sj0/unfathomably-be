# Unfathomably BE
# ----------------
#
# File: test/pleroma/atproto/identity_resolution_test.exs
#
# Purpose:
#   Verify that ordinary account search can resolve Bluesky handles directly.
#
# Responsibilities:
#   - accept the optional display @ used when Bluesky handles are copied
#   - route resolved profiles into normal account search results
#   - retain the human-readable handle on the projected account
#
# This file intentionally does NOT contact Bluesky or publish repository records.

defmodule Pleroma.ATProto.IdentityResolutionTest do
  use Pleroma.DataCase

  import Pleroma.Factory
  import Tesla.Mock

  alias Pleroma.ATProto.Identities
  alias Pleroma.User

  @did "did:plc:tkspefzlu72575kljanhe3uj"
  @plc_url "https://plc.directory/#{URI.encode(@did)}"
  @handle "jd-vance-1.bsky.social"

  setup do
    clear_config([Pleroma.ATProto, :enabled], true)
    clear_config([Pleroma.ATProto, :appview_url], "https://public.api.bsky.app")

    mock(fn env ->
      case env.url do
        "https://public.api.bsky.app/xrpc/app.bsky.actor.getProfile" ->
          assert {"actor", @handle} in env.query

          json(%{
            "did" => @did,
            "handle" => @handle,
            "displayName" => "JD Vance",
            "description" => "Profile description",
            "followersCount" => 1,
            "followsCount" => 1,
            "postsCount" => 1
          })

        "https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle" ->
          assert {"handle", @handle} in env.query
          json(%{"did" => @did})

        @plc_url ->
          json(%{
            "id" => @did,
            "alsoKnownAs" => ["at://#{@handle}"],
            "service" => []
          })

        _url ->
          %Tesla.Env{status: 404, body: Jason.encode!(%{"error" => "NotFound"})}
      end
    end)

    :ok
  end

  test "resolves a copied @handle through ordinary account search" do
    viewer = insert(:user)

    assert resolved =
             User.search("@#{@handle}", resolve: true, for_user: viewer)
             |> Enum.find(&(Identities.presentation(&1).handle == @handle))

    assert resolved.name == "JD Vance"
    assert Identities.presentation(resolved).handle == @handle
  end
end

# end of test/pleroma/atproto/identity_resolution_test.exs
