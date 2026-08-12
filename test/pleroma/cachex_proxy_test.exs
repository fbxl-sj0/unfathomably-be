# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.CachexProxyTest do
  use ExUnit.Case, async: false

  alias Pleroma.CachexProxy
  alias Pleroma.NullCache

  @cache :cachex_proxy_test

  setup do
    start_supervised!({Cachex, name: @cache})
    :ok
  end

  test "normalizes Cachex commit tuples carrying per-entry options" do
    assert {:commit, [:value]} =
             CachexProxy.fetch(@cache, :safe_fetch, fn _key ->
               {:commit, [:value], expire: 1_000}
             end)

    assert [:value] =
             CachexProxy.fetch!(@cache, :safe_fetch_bang, fn _key ->
               {:commit, [:value], expire: 1_000}
             end)
  end

  test "keeps the null provider compatible with both fallback arities" do
    assert {:commit, :zero_arity} =
             NullCache.fetch(@cache, :unused, fn ->
               {:commit, :zero_arity, expire: 1_000}
             end)

    assert :one_arity =
             NullCache.fetch!(@cache, :one_arity, fn key ->
               {:commit, key, expire: 1_000}
             end)
  end
end

# end of cachex_proxy_test.exs
