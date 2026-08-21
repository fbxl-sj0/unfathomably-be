# Unfathomably BE
# ----------------
#
# File: web/diaspora/fetch_controller.ex
#
# Purpose:
#   Serve locally retained diaspora* entity XML by native type and GUID.
#
# Responsibilities:
#   - return only locally authored or previously verified stored entities
#   - require the requested type to match the retained record
#
# This file intentionally does NOT synthesize missing remote entities.

defmodule Pleroma.Web.Diaspora.FetchController do
  use Pleroma.Web, :controller

  alias Pleroma.Activity
  alias Pleroma.Diaspora.Protocol
  alias Pleroma.Diaspora.Record
  alias Pleroma.Diaspora.Store
  alias Pleroma.User

  def show(conn, %{"type" => type, "guid" => guid}) do
    case Store.get(guid) do
      %Record{type: ^type, raw_xml: xml, local: true, ap_activity_id: activity_id} ->
        with %Activity{} = activity <- Activity.get_by_id(activity_id),
             %User{} = actor <- User.get_cached_by_ap_id(activity.data["actor"]),
             {:ok, envelope} <- Protocol.build_public_envelope(actor, xml) do
          conn
          |> put_resp_content_type("application/magic-envelope+xml")
          |> send_resp(200, envelope)
        else
          _ -> send_resp(conn, 404, "Not found")
        end

      _ ->
        send_resp(conn, 404, "Not found")
    end
  end
end

# end of web/diaspora/fetch_controller.ex
