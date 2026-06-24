# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.EctoType.Config.BinaryValue do
  use Ecto.Type

  def type, do: :term

  # sobelow_skip ["Misc.BinToTerm"]
  def cast(value) when is_binary(value) do
    if String.valid?(value) do
      {:ok, value}
    else
      decode_binary(value)
    end
  end

  def cast(value), do: {:ok, value}

  # sobelow_skip ["Misc.BinToTerm"]
  def load(value) when is_binary(value) do
    decode_binary(value)
  end

  def dump(value) do
    {:ok, :erlang.term_to_binary(value)}
  end

  # sobelow_skip ["Misc.BinToTerm"]
  defp decode_binary(value) do
    {:ok, :erlang.binary_to_term(value, [:safe])}
  rescue
    ArgumentError ->
      # Older ConfigDB rows may contain module atoms from optional dependencies
      # that are not loaded yet. The config table is local admin-owned data, and
      # decoding it once lets BEAM register those atoms so later safe decodes
      # work normally.
      {:ok, :erlang.binary_to_term(value)}
  end
end
