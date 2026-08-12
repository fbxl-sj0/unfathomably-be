# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.HTTP.AdapterHelper.Finch do
  @behaviour Pleroma.HTTP.AdapterHelper

  alias Pleroma.Config
  alias Pleroma.HTTP.AdapterHelper

  @spec options(keyword(), URI.t()) :: keyword()
  def options(incoming_opts \\ [], %URI{} = _uri) do
    proxy =
      [:http, :proxy_url]
      |> Config.get()
      |> AdapterHelper.format_proxy()

    config_opts = Config.get([:http, :adapter], [])

    config_opts
    |> Keyword.merge(incoming_opts)
    |> AdapterHelper.maybe_add_proxy(proxy)
    |> normalize_receive_timeout()
    |> maybe_stream()
  end

  # Pleroma's adapter-neutral HTTP options call this value recv_timeout.
  # Finch calls the same per-chunk deadline receive_timeout. Translate it here
  # so every Finch request observes the timeout selected by its caller instead
  # of silently falling back to Tesla's longer adapter default.
  defp normalize_receive_timeout(opts) do
    {recv_timeout, opts} = Keyword.pop(opts, :recv_timeout)

    if is_integer(recv_timeout) and recv_timeout > 0 do
      Keyword.put_new(opts, :receive_timeout, recv_timeout)
    else
      opts
    end
  end

  # Tesla Finch adapter uses response: :stream.
  defp maybe_stream(opts) do
    case Keyword.pop(opts, :stream, nil) do
      {true, opts} -> Keyword.put(opts, :response, :stream)
      {_, opts} -> opts
    end
  end
end
