# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Upload.Filter.AnalyzeMetadata do
  @moduledoc """
  Extracts metadata about the upload, such as width/height
  """
  require Logger

  @behaviour Pleroma.Upload.Filter

  @spec filter(Pleroma.Upload.t()) ::
          {:ok, :filtered, Pleroma.Upload.t()} | {:ok, :noop} | {:error, String.t()}
  def filter(%Pleroma.Upload{tempfile: file, content_type: "image" <> _} = upload) do
    try do
      image =
        file
        |> Mogrify.open()
        |> Mogrify.verbose()

      upload =
        upload
        |> Map.put(:width, image.width)
        |> Map.put(:height, image.height)
        |> Map.put(:blurhash, get_blurhash(file))

      {:ok, :filtered, upload}
    rescue
      e in ErlangError ->
        Logger.warning("#{__MODULE__}: #{inspect(e)}")
        {:ok, :noop}
    end
  end

  def filter(%Pleroma.Upload{tempfile: file, content_type: "video" <> _} = upload) do
    try do
      result = media_dimensions(file)

      upload =
        upload
        |> Map.put(:width, result.width)
        |> Map.put(:height, result.height)

      {:ok, :filtered, upload}
    rescue
      e in ErlangError ->
        Logger.warning("#{__MODULE__}: #{inspect(e)}")
        {:ok, :noop}
    end
  end

  def filter(_), do: {:ok, :noop}

  defp get_blurhash(file) do
    try do
      with {:ok, blurhash} <- :eblurhash.magick(file) do
        blurhash
      else
        _ -> get_blurhash_with_commands(file)
      end
    rescue
      e in ErlangError ->
        Logger.warning("#{__MODULE__}: blurhash metadata failed: #{inspect(e)}")
        nil
    catch
      kind, reason ->
        Logger.warning("#{__MODULE__}: blurhash metadata failed: #{inspect({kind, reason})}")
        nil
    end
  end

  # eblurhash shells out with POSIX single-quote escaping. That is correct on
  # Unix, but cmd.exe treats those quotes as filename characters. System.cmd/3
  # keeps each filename as a separate argument and also handles paths with
  # spaces on Windows.
  defp get_blurhash_with_commands(file) do
    with convert when is_binary(convert) <-
           System.find_executable("magick") || System.find_executable("convert"),
         identify when is_binary(identify) <- System.find_executable("identify"),
         encoder when is_binary(encoder) <- blurhash_executable() do
      thumbnail =
        Path.join(
          System.tmp_dir!(),
          "unfathomably-blurhash-#{System.unique_integer([:positive])}.gif"
        )

      try do
        with {_output, 0} <-
               System.cmd(convert, [
                 file,
                 "-quantize",
                 "YUV",
                 "+dither",
                 "-colors",
                 "256",
                 "-thumbnail",
                 "20x20",
                 thumbnail
               ]),
             {dimensions, 0} <- System.cmd(identify, ["-format", "%w %h", thumbnail]),
             [width, height] <-
               dimensions |> String.split() |> Enum.map(&String.to_integer/1),
             maximum when maximum > 0 <- max(width, height),
             x_components <- max(round(width * 5 / maximum), 1),
             y_components <- max(round(height * 5 / maximum), 1),
             {blurhash, 0} <-
               System.cmd(encoder, [
                 Integer.to_string(x_components),
                 Integer.to_string(y_components),
                 thumbnail
               ]),
             blurhash when blurhash != "" <- String.trim(blurhash) do
          blurhash
        else
          _ -> nil
        end
      after
        File.rm(thumbnail)
      end
    else
      _ -> nil
    end
  end

  defp blurhash_executable do
    base = :eblurhash |> :code.priv_dir() |> List.to_string() |> Path.join("blurhash")

    [base, base <> ".exe"]
    |> Enum.find(&File.regular?/1)
  end

  defp media_dimensions(file) do
    with executable when is_binary(executable) <- System.find_executable("ffprobe"),
         args = [
           "-v",
           "error",
           "-show_entries",
           "stream=width,height",
           "-of",
           "csv=p=0:s=x",
           file
         ],
         {result, 0} <- System.cmd(executable, args),
         [width, height] <-
           String.split(String.trim(result), "x") |> Enum.map(&String.to_integer(&1)) do
      %{width: width, height: height}
    else
      nil -> {:error, {:ffprobe, :command_not_found}}
      {:error, _} = error -> error
    end
  end
end
