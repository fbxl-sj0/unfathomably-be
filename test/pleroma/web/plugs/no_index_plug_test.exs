# Pleroma: A lightweight social networking server
# Copyright 2017-2026 Pleroma Authors and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.NoIndexPlugTest do
  use ExUnit.Case, async: true

  import Plug.Conn, only: [get_resp_header: 2]
  import Plug.Test, only: [conn: 2]

  alias Pleroma.Web.Plugs.NoIndexPlug

  test "marks machine-facing responses as non-indexable" do
    conn =
      :get
      |> conn("/api/v1/instance")
      |> NoIndexPlug.call([])

    assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
  end
end

# end of no_index_plug_test.exs
