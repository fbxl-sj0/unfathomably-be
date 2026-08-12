# Project: Unfathomably BE
# File: test/pleroma/crypto/random_test.exs
# Purpose: Verify the centralized random identifier policy.
# Responsibilities: Check entropy sizes, URL safety, and allocation bounds.
# This file intentionally does not test Erlang's cryptographic implementation.

# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Crypto.RandomTest do
  use ExUnit.Case, async: true

  alias Pleroma.Crypto.Random

  test "named security levels produce the documented entropy sizes" do
    assert decoded_size(Random.urlsafe(:low)) == 16
    assert decoded_size(Random.urlsafe(:medium)) == 24
    assert decoded_size(Random.urlsafe(:high)) == 32
  end

  test "byte-oriented generation remains bounded" do
    assert decoded_size(Random.urlsafe_bytes(48)) == 48

    assert_raise ArgumentError, fn -> Random.urlsafe_bytes(0) end
    assert_raise ArgumentError, fn -> Random.urlsafe_bytes(1025) end
    assert_raise ArgumentError, fn -> Random.urlsafe(:unknown) end
  end

  defp decoded_size(value) do
    value
    |> Base.url_decode64!(padding: false)
    |> byte_size()
  end
end

# end of test/pleroma/crypto/random_test.exs
