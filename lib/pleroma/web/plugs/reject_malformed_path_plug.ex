# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.RejectMalformedPathPlug do
  @moduledoc """
  Rejects request paths whose percent-decoded form is not valid UTF-8.

  Plug and URI decoding expect text paths to contain valid UTF-8. Rejecting a
  malformed path before routing keeps scanner traffic from becoming an
  endpoint exception and an HTTP 500 response.
  """

  import Plug.Conn

  def init(options), do: options

  def call(%Plug.Conn{request_path: request_path} = conn, _options) do
    if valid_path?(request_path) do
      conn
    else
      conn
      |> send_resp(:bad_request, "Malformed request path")
      |> halt()
    end
  end

  defp valid_path?(request_path) do
    request_path
    |> URI.decode()
    |> String.valid?()
  rescue
    ArgumentError -> false
  end
end

# end of reject_malformed_path_plug.ex
