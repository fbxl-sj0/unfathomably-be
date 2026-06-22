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
      {:ok, :erlang.binary_to_term(value, [:safe])}
    end
  end

  def cast(value), do: {:ok, value}

  # sobelow_skip ["Misc.BinToTerm"]
  def load(value) when is_binary(value) do
    {:ok, :erlang.binary_to_term(value, [:safe])}
  end

  def dump(value) do
    {:ok, :erlang.term_to_binary(value)}
  end
end
