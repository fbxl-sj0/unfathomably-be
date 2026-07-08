# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Helpers.QtFastStart do
  @moduledoc """
  (WIP) Converts a "slow start" (data before metadatas) mov/mp4 file to a "fast start" one (metadatas before data).
  """

  # Inspirations: https://www.ffmpeg.org/doxygen/3.4/qt-faststart_8c_source.html
  #               https://github.com/danielgtaylor/qtfaststart/blob/master/qtfaststart/processor.py
  #               ISO/IEC 14496-12:2015, ISO/IEC 15444-12:2015
  #               Paracetamol

  def fix(<<0x00, 0x00, 0x00, _, 0x66, 0x74, 0x79, 0x70, _::bits>> = binary) do
    index = fix(binary, 0, nil, nil, [])

    case index do
      :abort -> binary
      [{"ftyp", _, _, _, _}, {"mdat", _, _, _, _} | _] -> faststart(index)
      [{"ftyp", _, _, _, _}, {"free", _, _, _, _}, {"mdat", _, _, _, _} | _] -> faststart(index)
      _ -> binary
    end
  end

  def fix(binary) do
    binary
  end

  # MOOV have been seen before MDAT- abort
  defp fix(<<_::bits>>, _, true, false, _) do
    :abort
  end

  defp fix(
         <<size::integer-big-size(32), fourcc::bits-size(32), rest::bits>>,
         pos,
         got_moov,
         got_mdat,
         acc
       )
       when size >= 8 and bit_size(rest) >= (size - 8) * 8 do
    try do
      full_size = (size - 8) * 8
      <<data::bits-size(^full_size), rest::bits>> = rest

      acc = [
        {fourcc, pos, pos + size, size,
         <<size::integer-big-size(32), fourcc::bits-size(32), data::bits>>}
        | acc
      ]

      fix(rest, pos + size, got_moov || fourcc == "moov", got_mdat || fourcc == "mdat", acc)
    rescue
      _ ->
        :abort
    end
  end

  defp fix(<<>>, _pos, _, _, acc) do
    :lists.reverse(acc)
  end

  defp fix(_malformed, _pos, _got_moov, _got_mdat, _acc), do: :abort

  defp faststart(index) do
    original = box_data(index)

    with {{_ftyp, _, _, _, ftyp}, index} <- List.keytake(index, "ftyp", 0),
         {free_size, index} <- take_free(index),
         {{_moov, _, _, moov_size, moov}, index} <- List.keytake(index, "moov", 0),
         offset <- -free_size + moov_size,
         rest <- box_data(index),
         <<moov_head::bits-size(64), moov_data::bits>> <- moov,
         fixed_moov when fixed_moov != :abort <- fix_moov(moov_data, offset, []) do
      [ftyp, moov_head, fixed_moov, rest]
    else
      _ -> original
    end
  end

  defp box_data(index), do: for({_, _, _, _, data} <- index, do: data, into: [])

  # Skip re-writing the free fourcc as it's kind of useless.
  # Why stream useless bytes when you can do without?
  defp take_free(index) do
    case List.keytake(index, "free", 0) do
      {{_, _, _, size, _}, index} -> {size, index}
      _ -> {0, index}
    end
  end

  defp fix_moov(
         <<size::integer-big-size(32), fourcc::bits-size(32), rest::bits>>,
         offset,
         acc
       )
       when size >= 8 and bit_size(rest) >= (size - 8) * 8 do
    full_size = (size - 8) * 8
    <<data::bits-size(^full_size), rest::bits>> = rest

    data =
      cond do
        fourcc in ["trak", "mdia", "minf", "stbl"] ->
          # Theses contains sto or co64 part
          with fixed_moov when fixed_moov != :abort <- fix_moov(data, offset, []) do
            [<<size::integer-big-size(32), fourcc::bits-size(32)>>, fixed_moov]
          end

        fourcc in ["stco", "co64"] ->
          # fix the damn thing
          case data do
            <<version::integer-big-size(32), count::integer-big-size(32), rest::bits>> ->
              entry_size =
                case fourcc do
                  "stco" -> 32
                  "co64" -> 64
                end

              with entries when entries != :abort <-
                     rewrite_entries(entry_size, offset, rest, []) do
                [
                  <<size::integer-big-size(32), fourcc::bits-size(32),
                    version::integer-big-size(32), count::integer-big-size(32)>>,
                  entries
                ]
              end

            _ ->
              :abort
          end

        true ->
          [<<size::integer-big-size(32), fourcc::bits-size(32)>>, data]
      end

    case data do
      :abort ->
        :abort

      data ->
        acc = [acc | data]
        fix_moov(rest, offset, acc)
    end
  end

  defp fix_moov(<<>>, _, acc), do: acc
  defp fix_moov(_malformed, _, _), do: :abort

  for size <- [32, 64] do
    defp rewrite_entries(
           unquote(size),
           offset,
           <<pos::integer-big-size(unquote(size)), rest::bits>>,
           acc
         ) do
      rewrite_entries(unquote(size), offset, rest, [
        acc | <<pos + offset::integer-big-size(unquote(size))>>
      ])
    end
  end

  defp rewrite_entries(_, _, <<>>, acc), do: acc
  defp rewrite_entries(_, _, _malformed, _acc), do: :abort
end
