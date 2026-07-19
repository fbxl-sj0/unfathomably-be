# Pleroma: Mastodon API federation status controller tests
# --------------------------------------------------------
#
# File: federation_status_controller_test.exs
#
# Purpose:
#
#     Prove clients can ask the API whether local federation policy already
#     knows a remote host is blocked before search or follow attempts.
#
# Responsibilities:
#
#     * cover acct-style lookup values
#     * cover host normalization
#     * keep the response shape stable for frontend search controls
#
# This file intentionally does NOT contain:
#
#     * ActivityPub fetches
#     * remote server probing
#     * admin policy mutation

defmodule Pleroma.Web.MastodonAPI.FederationStatusControllerTest do
  use Pleroma.Web.ConnCase, async: false

  test "reports known local federation policy for a remote acct", %{conn: conn} do
    clear_config([:mrf_simple, :reject], [{"blocked.example", "Federation paused"}])

    assert %{
             "host" => "blocked.example",
             "known" => true,
             "defederated" => true,
             "direction" => "local_policy",
             "severity" => "reject",
             "reason" => "Federation paused",
             "message" => "Federation paused"
           } =
             conn
             |> get(
               "/api/v1/federation/status?q=#{URI.encode_www_form("@alice@blocked.example")}"
             )
             |> json_response(200)
  end
end

# end of test/pleroma/web/mastodon_api/controllers/federation_status_controller_test.exs
