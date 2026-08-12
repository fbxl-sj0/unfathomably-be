# Unfathomably BE
# ----------------
#
# File: text_boundary.ex
#
# Purpose:
#   Bound untrusted UTF-8 text without splitting a codepoint or traversing an
#   arbitrarily large grapheme cluster.
#
# Responsibilities:
#   - stop at both a codepoint count and a byte count
#   - return valid UTF-8
#   - keep work proportional to the accepted prefix
#
# This file intentionally does not sanitize HTML, normalize Unicode, or decide
# product-specific text limits.

defmodule Pleroma.TextBoundary do
  @moduledoc false

  @spec truncate_utf8(binary(), non_neg_integer(), non_neg_integer()) :: binary()
  def truncate_utf8(value, maximum_codepoints, maximum_bytes)
      when is_binary(value) and is_integer(maximum_codepoints) and maximum_codepoints >= 0 and
             is_integer(maximum_bytes) and maximum_bytes >= 0 do
    truncate_utf8(value, maximum_codepoints, maximum_bytes, [])
  end

  def truncate_utf8(_value, _maximum_codepoints, _maximum_bytes), do: ""

  defp truncate_utf8(_value, 0, _remaining_bytes, accepted),
    do: accepted |> Enum.reverse() |> IO.iodata_to_binary()

  defp truncate_utf8(_value, _remaining_codepoints, 0, accepted),
    do: accepted |> Enum.reverse() |> IO.iodata_to_binary()

  defp truncate_utf8(value, remaining_codepoints, remaining_bytes, accepted) do
    case String.next_codepoint(value) do
      {codepoint, rest} when byte_size(codepoint) <= remaining_bytes ->
        truncate_utf8(
          rest,
          remaining_codepoints - 1,
          remaining_bytes - byte_size(codepoint),
          [codepoint | accepted]
        )

      _finished_or_too_large ->
        accepted |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end
end

# end of text_boundary.ex
