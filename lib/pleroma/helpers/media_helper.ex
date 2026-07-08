# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Helpers.MediaHelper do
  @moduledoc """
  Handles common media-related operations.
  """

  alias Pleroma.HTTP

  @cachex Pleroma.Config.get([:cachex, :provider], Cachex)

  def missing_dependencies do
    Enum.reduce([imagemagick: "convert", ffmpeg: "ffmpeg"], [], fn {sym, executable}, acc ->
      if Pleroma.Utils.command_available?(executable) do
        acc
      else
        [sym | acc]
      end
    end)
  end

  def image_resize(url, options) do
    with executable when is_binary(executable) <- System.find_executable("convert"),
         {:ok, args} <- prepare_image_resize_args(options),
         {:ok, env} <- HTTP.get(url, [], http_client_opts()) do
      run_with_input(env, executable, fn input ->
        List.flatten([input, args])
      end)
    else
      nil -> {:error, {:convert, :command_not_found}}
      {:error, _} = error -> error
    end
  end

  defp prepare_image_resize_args(
         %{max_width: max_width, max_height: max_height, format: "png"} = options
       ) do
    quality = options[:quality] || 85
    resize = Enum.join([max_width, "x", max_height, ">"])

    args = [
      "-resize",
      resize,
      "-quality",
      to_string(quality),
      "png:-"
    ]

    {:ok, args}
  end

  defp prepare_image_resize_args(%{max_width: max_width, max_height: max_height} = options) do
    quality = options[:quality] || 85
    resize = Enum.join([max_width, "x", max_height, ">"])

    args = [
      "-interlace",
      "Plane",
      "-resize",
      resize,
      "-quality",
      to_string(quality),
      "jpg:-"
    ]

    {:ok, args}
  end

  defp prepare_image_resize_args(_), do: {:error, :missing_options}

  # Note: video thumbnail is intentionally not resized (always has original dimensions)
  def video_framegrab(url) do
    with {:ok, false} <- @cachex.exists?(:failed_media_helper_cache, url),
         executable when is_binary(executable) <- System.find_executable("ffmpeg"),
         {:ok, env} <- HTTP.get(url, [], http_client_opts()),
         {:ok, output} <-
           run_with_input(env, executable, fn input ->
             [
               "-y",
               "-i",
               input,
               "-vframes",
               "1",
               "-f",
               "mjpeg",
               "-loglevel",
               "error",
               "-"
             ]
           end) do
      {:ok, output}
    else
      {:ok, true} -> {:error, :cached_failure}
      nil -> cache_media_helper_failure(url, {:error, {:ffmpeg, :command_not_found}})
      {:error, _} = error -> cache_media_helper_failure(url, error)
    end
  end

  defp cache_media_helper_failure(url, error) do
    @cachex.put(:failed_media_helper_cache, url, true)
    error
  end

  defp http_client_opts, do: Pleroma.Config.get([:media_proxy, :proxy_opts, :http], pool: :media)

  defp run_with_input(env, executable, args_fun) do
    if match?({:win32, _}, :os.type()) do
      run_tempfile(env, executable, args_fun)
    else
      with {:ok, fifo_path} <- mkfifo() do
        run_fifo(fifo_path, env, executable, args_fun.(fifo_path))
      end
    end
  end

  defp run_tempfile(env, executable, args_fun) do
    path = Path.join(System.tmp_dir!(), "pleroma-media-preview-input-#{Ecto.UUID.generate()}")
    input = Pleroma.Helpers.QtFastStart.fix(env.body)

    try do
      File.write!(path, input)

      case System.cmd(executable, args_fun.(path), stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {_output, status} -> {:error, status}
      end
    after
      File.rm(path)
    end
  end

  defp run_fifo(fifo_path, env, executable, args) do
    pid =
      Port.open({:spawn_executable, executable}, [
        :use_stdio,
        :stream,
        :exit_status,
        :binary,
        :stderr_to_stdout,
        args: args
      ])

    fix = Pleroma.Helpers.QtFastStart.fix(env.body)

    case write_fifo(fifo_path, fix) do
      :ok ->
        loop_recv(pid)

      {:error, reason} ->
        close_port(pid)
        {:error, reason}
    end
  after
    File.rm(fifo_path)
  end

  defp write_fifo(fifo_path, input) do
    case File.open(fifo_path, [:write, :binary]) do
      {:ok, fifo} ->
        try do
          case :file.write(fifo, input) do
            :ok -> :ok
            {:error, reason} -> {:error, reason}
          end
        rescue
          error in ErlangError ->
            case error.original do
              :epipe -> {:error, :epipe}
              _ -> reraise(error, __STACKTRACE__)
            end
        after
          File.close(fifo)
        end

      {:error, reason} ->
        {:error, {:fifo_open_failed, reason}}
    end
  end

  defp close_port(pid) do
    try do
      :erlang.port_close(pid)
    catch
      :error, :badarg -> :ok
    end
  end

  defp mkfifo do
    path = Path.join(System.tmp_dir!(), "pleroma-media-preview-pipe-#{Ecto.UUID.generate()}")

    case System.cmd("mkfifo", [path]) do
      {_, 0} ->
        spawn(fifo_guard(path))
        {:ok, path}

      {_, err} ->
        {:error, {:fifo_failed, err}}
    end
  end

  defp fifo_guard(path) do
    pid = self()

    fn ->
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} ->
          File.rm(path)
      end
    end
  end

  defp loop_recv(pid) do
    loop_recv(pid, <<>>)
  end

  defp loop_recv(pid, acc) do
    receive do
      {^pid, {:data, data}} ->
        loop_recv(pid, acc <> data)

      {^pid, {:exit_status, 0}} ->
        {:ok, acc}

      {^pid, {:exit_status, status}} ->
        {:error, status}
    after
      5000 ->
        :erlang.port_close(pid)
        {:error, :timeout}
    end
  end
end
