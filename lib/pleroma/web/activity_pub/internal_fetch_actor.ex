# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.InternalFetchActor do
  alias Pleroma.Config
  alias Pleroma.User
  alias Pleroma.Web.Endpoint

  def init do
    # Wait for everything to settle.
    Process.sleep(1000 * 5)
    get_actor()
    get_actor(Endpoint.url())
  end

  def get_actor do
    (configured_origin() || Endpoint.url())
    |> get_actor()
  end

  def get_actor(origin) when is_binary(origin) do
    origin = String.trim_trailing(origin, "/")

    case URI.parse(origin) do
      %URI{host: host} when is_binary(host) ->
        nickname =
          if host == Endpoint.host() do
            "internal.fetch"
          else
            "internal.fetch@#{host}"
          end

        "#{origin}/internal/fetch"
        |> User.get_or_create_service_actor_by_ap_id(nickname)

      _ ->
        Endpoint.url()
        |> get_actor()
    end
  end

  def get_actor(_), do: get_actor(Endpoint.url())

  def configured_origin_for_host(host) when is_binary(host) do
    case configured_origin() do
      origin when is_binary(origin) ->
        case URI.parse(origin) do
          %URI{host: ^host} -> origin
          _ -> Endpoint.url()
        end

      _ ->
        Endpoint.url()
    end
  end

  def configured_origin_for_host(_), do: Endpoint.url()

  defp configured_origin do
    with origin when is_binary(origin) <- Config.get([:activitypub, :fetch_actor_origin]),
         origin <- String.trim_trailing(origin, "/"),
         %URI{scheme: scheme, host: host} when is_binary(host) <- URI.parse(origin),
         true <- allowed_origin_scheme?(scheme) do
      origin
    else
      _ -> nil
    end
  end

  defp allowed_origin_scheme?("https"), do: true

  defp allowed_origin_scheme?("http") do
    Config.get(:env) in [:dev, :test] &&
      Config.get([:activitypub, :allow_http_fetch_actor_origin], false)
  end

  defp allowed_origin_scheme?(_), do: false
end
