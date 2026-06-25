# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Instances do
  @moduledoc "Instances context."

  alias Pleroma.Instances.Instance

  @default_dormant_instance_timeout_days 183

  def filter_reachable(urls_or_hosts), do: Instance.filter_reachable(urls_or_hosts)

  def reachable?(url_or_host), do: Instance.reachable?(url_or_host)

  def dormant?(url_or_host), do: Instance.dormant?(url_or_host)

  def any_dormant?, do: Instance.any_dormant?()

  def set_reachable(url_or_host), do: Instance.set_reachable(url_or_host)

  def set_unreachable(url_or_host, unreachable_since \\ nil),
    do: Instance.set_unreachable(url_or_host, unreachable_since)

  def record_success(url_or_host, opts \\ []), do: Instance.record_success(url_or_host, opts)

  def record_failure(url_or_host, reason \\ :failure, opts \\ []),
    do: Instance.record_failure(url_or_host, reason, opts)

  def record_redirect(url_or_host, target, opts \\ []),
    do: Instance.record_redirect(url_or_host, target, opts)

  def record_gone(url_or_host, opts \\ []), do: Instance.record_gone(url_or_host, opts)

  def get_consistently_unreachable, do: Instance.get_consistently_unreachable()

  def set_consistently_unreachable(url_or_host),
    do: set_unreachable(url_or_host, reachability_datetime_threshold())

  def reachability_datetime_threshold do
    federation_reachability_timeout_days =
      Pleroma.Config.get([:instance, :federation_reachability_timeout_days], 0)

    if federation_reachability_timeout_days > 0 do
      NaiveDateTime.add(
        NaiveDateTime.utc_now(),
        -federation_reachability_timeout_days * 24 * 3600,
        :second
      )
    else
      ~N[0000-01-01 00:00:00]
    end
  end

  def dormant_datetime_threshold do
    dormant_instance_timeout_days =
      Pleroma.Config.get(
        [:instance, :dormant_instance_timeout_days],
        @default_dormant_instance_timeout_days
      )

    if dormant_instance_timeout_days > 0 do
      NaiveDateTime.add(
        NaiveDateTime.utc_now(),
        -dormant_instance_timeout_days * 24 * 3600,
        :second
      )
    else
      ~N[0000-01-01 00:00:00]
    end
  end

  def host(url_or_host) when is_binary(url_or_host) do
    if url_or_host =~ ~r/^http/i do
      URI.parse(url_or_host).host
    else
      url_or_host
    end
  end
end
