# Project: Unfathomably BE
# File: lib/pleroma/crypto/random.ex
# Purpose: Generate cryptographically secure URL-safe identifiers.
# Responsibilities: Centralize entropy policy and bound requested allocations.
# This file intentionally does not generate human-entered recovery or OTP codes.

# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Crypto.Random do
  @moduledoc """
  Generates URL-safe random values for security-sensitive identifiers.

  Named levels keep entropy decisions visible at call sites. The byte-oriented
  helper preserves compatibility for APIs whose callers already supply a size.
  Both paths reject invalid or unexpectedly large allocations.
  """

  @entropy_bytes %{
    low: 16,
    medium: 24,
    high: 32
  }

  @max_bytes 1024

  @type security_level :: :low | :medium | :high

  @spec urlsafe(security_level()) :: String.t()
  def urlsafe(level \\ :high) do
    case Map.fetch(@entropy_bytes, level) do
      {:ok, bytes} -> urlsafe_bytes(bytes)
      :error -> raise ArgumentError, "unknown random security level: #{inspect(level)}"
    end
  end

  @spec urlsafe_bytes(pos_integer()) :: String.t()
  def urlsafe_bytes(bytes) when is_integer(bytes) and bytes > 0 and bytes <= @max_bytes do
    bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  def urlsafe_bytes(bytes) do
    raise ArgumentError,
          "random byte count must be between 1 and #{@max_bytes}, got: #{inspect(bytes)}"
  end
end

# end of lib/pleroma/crypto/random.ex
