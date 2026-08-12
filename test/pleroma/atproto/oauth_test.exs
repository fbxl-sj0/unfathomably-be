# Unfathomably BE
# ----------------
#
# File: test/pleroma/atproto/oauth_test.exs
#
# Purpose:
#   Verify the public AT Protocol OAuth client contract.
#
# Responsibilities:
#   - require authorization-code and refresh-token grants
#   - require DPoP-bound access tokens
#   - keep permissions limited to supported repository and blob operations
#
# This file intentionally does NOT perform browser redirects or contact a PDS.

defmodule Pleroma.ATProto.OAuthTest do
  use ExUnit.Case, async: true

  alias Pleroma.ATProto.OAuth

  test "publishes bounded public-client metadata without firehose permissions" do
    metadata = OAuth.client_metadata()

    assert metadata["token_endpoint_auth_method"] == "none"
    assert metadata["dpop_bound_access_tokens"] == true
    assert metadata["grant_types"] == ["authorization_code", "refresh_token"]
    assert metadata["response_types"] == ["code"]
    assert metadata["client_id"] =~ "/api/v1/atproto/oauth/client-metadata.json"

    assert metadata["redirect_uris"] == [
             String.replace(metadata["client_id"], "client-metadata.json", "callback")
           ]

    scope = String.split(metadata["scope"])
    assert "atproto" in scope
    assert "repo:app.bsky.feed.post" in scope
    assert "blob:image/*" in scope
    refute "transition:chat.bsky" in scope
    refute Enum.any?(scope, &String.contains?(&1, "subscribeRepos"))
  end
end

# end of test/pleroma/atproto/oauth_test.exs
