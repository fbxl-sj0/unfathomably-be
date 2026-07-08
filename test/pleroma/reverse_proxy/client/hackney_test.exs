# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.ReverseProxy.Client.HackneyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Pleroma.ReverseProxy.Client.Hackney

  setup do
    :ok = :meck.new(:hackney, [:passthrough, :no_link])

    on_exit(fn ->
      :meck.validate(:hackney)
      :meck.unload(:hackney)
    end)
  end

  describe "request/5 redirects" do
    test "follows nested relative redirects without asking Hackney to handle redirects" do
      :meck.expect(:hackney, :request, fn
        :get, "https://example.test/start", [], "", opts ->
          assert opts[:follow_redirect] == false
          assert is_function(opts[:path_encode_fun], 1)

          {:ok, 302, [{"location", "/middle"}], :start}

        :get, "https://example.test/middle", [], "", opts ->
          assert opts[:follow_redirect] == false

          {:ok, 301, [{"Location", "/final"}], :middle}

        :get, "https://example.test/final", [], "", opts ->
          assert opts[:follow_redirect] == false

          {:ok, 200, [{"content-type", "text/plain"}], :final}
      end)

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, 200, [{"content-type", "text/plain"}], :final} =
                   Hackney.request(:get, "https://example.test/start", [], "",
                     follow_redirect: true
                   )
        end)

      assert log =~ "handling redirect https://example.test/start -> https://example.test/middle"
      assert log =~ "handling redirect https://example.test/middle -> https://example.test/final"
    end

    test "returns the final redirect response when the redirect limit is reached" do
      counter = :counters.new(1, [])

      :meck.expect(:hackney, :request, fn :get, "https://example.test/loop", [], "", _opts ->
        :counters.add(counter, 1, 1)
        {:ok, 302, [{"Location", "/loop"}], :loop}
      end)

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, 302, [{"Location", "/loop"}], :loop} =
                   Hackney.request(:get, "https://example.test/loop", [], "",
                     follow_redirect: true
                   )
        end)

      assert :counters.get(counter, 1) == 7
      assert log =~ "redirect limit was reached"
    end
  end
end
