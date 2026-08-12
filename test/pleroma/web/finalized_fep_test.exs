# Unfathomably BE
#
# File: finalized_fep_test.exs
# Purpose: Protect finalized FEP discovery and shared relay behavior.
# Responsibilities: Exercise FEP-d556 server discovery and /relay negotiation.
# This file intentionally does not test the full relay delivery workflow.

defmodule Pleroma.Web.FinalizedFEPTest do
  use Pleroma.Web.ConnCase, async: false

  alias Pleroma.Web.ActivityPub.Marketplace

  setup do
    clear_config([:instance, :federating], true)
    clear_config([Pleroma.Nostr, :enabled], true)
    clear_config([Pleroma.Nostr, :relay_path], "/relay")
  end

  test "discovers the server actor with the FEP-d556 WebFinger resource", %{conn: conn} do
    server_prefix = String.trim_trailing(Pleroma.Web.Endpoint.url(), "/") <> "/"

    response =
      conn
      |> put_req_header("accept", "application/jrd+json")
      |> get("/.well-known/webfinger", %{"resource" => server_prefix})
      |> json_response(200)

    assert response["subject"] == server_prefix

    assert response["links"] == [
             %{
               "rel" => "https://www.w3.org/ns/activitystreams#Service",
               "type" => "application/activity+json",
               "href" => Marketplace.service_actor_ap_id()
             }
           ]
  end

  test "passes ActivityPub relay actor requests through the Nostr relay plug", %{conn: conn} do
    response =
      conn
      |> put_req_header("accept", "application/activity+json")
      |> get("/relay")
      |> json_response(200)

    assert response["id"] == Pleroma.Web.Endpoint.url() <> "/relay"
    assert response["type"] == "Application"
  end

  test "continues to serve NIP-11 information from the shared relay path", %{conn: conn} do
    response =
      conn
      |> put_req_header("accept", "application/nostr+json")
      |> get("/relay")

    assert response.status == 200
    assert [content_type] = get_resp_header(response, "content-type")
    assert String.starts_with?(content_type, "application/nostr+json")
  end
end

# end of finalized_fep_test.exs
