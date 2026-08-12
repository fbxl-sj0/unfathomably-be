# Unfathomably BE
# ----------------
#
# File: test/pleroma/diaspora/identity_resolution_test.exs
#
# Purpose:
#   Verify that ordinary account search resolves diaspora* identifiers.
#
# Responsibilities:
#   - follow the diaspora* WebFinger and hCard discovery chain
#   - accept the legacy external HTML 4 DOCTYPE emitted by current pods
#   - route the projected identity into normal account search results
#
# This file intentionally does NOT contact a live pod or publish federation
# envelopes.

defmodule Pleroma.Diaspora.IdentityResolutionTest do
  use Pleroma.DataCase

  import Pleroma.Factory
  import Tesla.Mock

  alias Pleroma.Diaspora.Identities
  alias Pleroma.Keys
  alias Pleroma.User

  @diaspora_id "hq@diaspora.example"
  @guid "7bca7c80311b01332d046c626dd55703"
  @hcard_url "https://diaspora.example/hcard/users/#{@guid}"

  setup do
    clear_config([Pleroma.ATProto, :enabled], false)
    clear_config([Pleroma.Diaspora, :enabled], true)
    clear_config([Pleroma.Nostr, :enabled], false)

    {:ok, keys} = Keys.generate_rsa_pem()
    public_key = public_key_pem(keys)

    webfinger =
      Jason.encode!(%{
        "subject" => "acct:#{@diaspora_id}",
        "links" => [
          %{
            "rel" => "http://microformats.org/profile/hcard",
            "type" => "text/html",
            "href" => @hcard_url
          },
          %{
            "rel" => "http://joindiaspora.com/seed_location",
            "href" => "https://diaspora.example/"
          },
          %{
            "rel" => "http://webfinger.net/rel/profile-page",
            "href" => "https://diaspora.example/u/hq"
          },
          %{
            "rel" => "salmon",
            "href" => "https://diaspora.example/receive/users/#{@guid}"
          }
        ]
      })

    hcard = """
    <!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.0 Transitional//EN" "http://www.w3.org/TR/REC-html40/loose.dtd">
    <html>
      <body>
        <div class="entity_profile vcard author">
          <span class="uid">#{@guid}</span>
          <span class="nickname">hq</span>
          <span class="fn">diaspora* HQ</span>
          <pre class="key">#{public_key}</pre>
          <img class="photo avatar" src="https://diaspora.example/avatar.png" />
        </div>
      </body>
    </html>
    """

    mock(fn env ->
      cond do
        String.starts_with?(
          env.url,
          "https://diaspora.example/.well-known/webfinger?resource="
        ) ->
          %Tesla.Env{status: 200, body: webfinger}

        env.url == @hcard_url ->
          %Tesla.Env{status: 200, body: hcard}

        true ->
          %Tesla.Env{status: 404, body: ""}
      end
    end)

    :ok
  end

  test "resolves a diaspora* identifier through ordinary account search" do
    viewer = insert(:user)

    assert [resolved] = User.search(@diaspora_id, resolve: true, for_user: viewer)
    assert resolved.name == "diaspora* HQ"

    assert %{id: @diaspora_id, profile_url: "https://diaspora.example/u/hq"} =
             Identities.presentation(resolved)

    assert Identities.get_by_user(resolved).receive_url ==
             "https://diaspora.example/receive/users/#{@guid}"
  end

  defp public_key_pem(keys) do
    {:ok, _private_key, public_key} = Keys.keys_from_pem(keys)
    entry = :public_key.pem_entry_encode(:RSAPublicKey, public_key)
    entry |> then(&:public_key.pem_encode([&1])) |> IO.iodata_to_binary()
  end
end

# end of test/pleroma/diaspora/identity_resolution_test.exs
