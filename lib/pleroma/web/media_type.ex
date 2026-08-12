# Unfathomably HTTP media negotiation
# ------------------------------------
#
# File: media_type.ex
#
# Purpose:
#   Parse bounded HTTP Accept and Content-Type values consistently.
#
# Responsibilities:
#   - split comma-separated media alternatives from one or more header lines
#   - parse media parameters through Plug's standards-aware parser
#   - reject malformed or explicitly unacceptable quality values
#   - select only media families explicitly allowed by a caller
#
# This file intentionally does NOT choose controller formats, decode response
# bodies, or broaden the media types accepted by federation subsystems.

defmodule Pleroma.Web.MediaType do
  @max_header_bytes 8_192
  @max_media_ranges 32

  @type media_match :: {String.t(), String.t(), map()}

  @spec match(String.t() | [String.t()], [{String.t(), String.t()}]) ::
          media_match() | nil
  def match(header_values, allowed_types) when is_list(allowed_types) do
    allowed_types = MapSet.new(allowed_types)

    header_values
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(&split_header/1)
    |> Enum.take(@max_media_ranges)
    |> Enum.find_value(fn value ->
      case Plug.Conn.Utils.media_type(value) do
        {:ok, type, subtype, params} ->
          if MapSet.member?(allowed_types, {type, subtype}) and acceptable_quality?(params) do
            {type, subtype, params}
          end

        :error ->
          nil
      end
    end)
  end

  def match(_header_values, _allowed_types), do: nil

  defp split_header(value) when byte_size(value) <= @max_header_bytes do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split_header(_value), do: []

  defp acceptable_quality?(params) do
    case Map.get(params, "q") do
      nil ->
        true

      quality when is_binary(quality) ->
        case Float.parse(quality) do
          {value, ""} when value > 0.0 and value <= 1.0 -> true
          _ -> false
        end

      _ ->
        false
    end
  end
end

# end of media_type.ex
