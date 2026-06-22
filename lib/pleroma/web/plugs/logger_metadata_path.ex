# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.LoggerMetadataPath do
  @moduledoc """
  Adds the request path to Logger metadata for downstream log formatting.
  """

  def init(opts), do: opts

  def call(conn, _opts) do
    Logger.metadata(path: conn.request_path)
    conn
  end
end
