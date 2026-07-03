# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Telemetry.LoggerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Pleroma.Telemetry.Logger

  test "logs routine connection pool client shutdowns below warning level" do
    assert capture_log([level: :warning], fn ->
             Logger.handle_event(
               [:pleroma, :connection_pool, :client, :dead],
               %{client_pid: self(), reason: :shutdown},
               %{key: "https:remote.example:443"},
               []
             )
           end) == ""
  end

  test "keeps abnormal connection pool client exits visible as warnings" do
    log =
      capture_log([level: :warning], fn ->
        Logger.handle_event(
          [:pleroma, :connection_pool, :client, :dead],
          %{client_pid: self(), reason: :killed},
          %{key: "https:remote.example:443"},
          []
        )
      end)

    assert log =~ "died before releasing the connection with :killed"
  end
end

# end of logger_test.exs
