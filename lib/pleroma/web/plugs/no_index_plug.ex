# Pleroma: A lightweight social networking server
# Copyright 2017-2026 Pleroma Authors and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.NoIndexPlug do
  @moduledoc """
  Keeps machine-facing API and ActivityPub responses out of search indexes.

  Human-facing profile and status pages remain indexable according to the
  instance metadata policy. This plug is intentionally attached only to
  machine-response router pipelines so crawlers do not index duplicate JSON
  representations of those pages.
  """

  @behaviour Plug

  import Plug.Conn, only: [put_resp_header: 3]

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, _options), do: put_resp_header(conn, "x-robots-tag", "noindex")
end

# end of no_index_plug.ex
