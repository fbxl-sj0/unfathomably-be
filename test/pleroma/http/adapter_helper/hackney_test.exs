# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.HTTP.AdapterHelper.HackneyTest do
  use ExUnit.Case, async: true
  use Pleroma.Tests.Helpers

  alias Pleroma.HTTP.AdapterHelper.Hackney

  setup_all do
    uri = URI.parse("http://domain.com")
    {:ok, uri: uri}
  end

  describe "options/2" do
    setup do
      adapter_config = [a: 1, b: 2]

      clear_config([:http, :adapter], adapter_config)
    end

    test "add proxy and opts from config", %{uri: uri} do
      opts = Hackney.options([proxy: "localhost:8123"], uri)

      assert opts[:a] == 1
      assert opts[:b] == 2
      assert opts[:proxy] == "localhost:8123"
    end

    test "respect connection opts and no proxy", %{uri: uri} do
      opts = Hackney.options([a: 2, b: 1], uri)

      assert opts[:a] == 2
      assert opts[:b] == 1
      refute Keyword.has_key?(opts, :proxy)
    end
  end
end
