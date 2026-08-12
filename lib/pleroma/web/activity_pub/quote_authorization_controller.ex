# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.QuoteAuthorizationController do
  use Pleroma.Web, :controller

  alias Pleroma.Object
  alias Pleroma.QuoteAuthorization

  def show(conn, %{"id" => id}) do
    with %Object{} = object <- Object.get_by_id(id),
         {:ok, document} <-
           QuoteAuthorization.authorization_document_for_requester(
             object,
             conn.assigns[:user]
           ) do
      conn
      |> maybe_put_cache_header(id)
      |> put_resp_content_type("application/activity+json")
      |> json(document)
    else
      _ -> send_resp(conn, :not_found, "Not found")
    end
  end

  defp maybe_put_cache_header(conn, id) do
    if QuoteAuthorization.cacheable_document?(id) do
      put_resp_header(conn, "cache-control", "public, max-age=30")
    else
      put_resp_header(conn, "cache-control", "private, no-store")
    end
  end
end

# end of quote_authorization_controller.ex
