# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ManifestView do
  use Pleroma.Web, :view
  alias Pleroma.Config
  alias Pleroma.Web.Endpoint

  def render("manifest.json", _params) do
    %{
      name: Config.get([:instance, :name]),
      short_name: Config.get([:manifest, :short_name], Config.get([:instance, :name])),
      description: Config.get([:instance, :description]),
      protocol_handlers: [
        %{
          protocol: "web+ap",
          url: "/activitypub/externalInteraction?uri=%s"
        }
      ],
      icons: manifest_icons(),
      theme_color: Config.get([:manifest, :theme_color]),
      background_color: Config.get([:manifest, :background_color]),
      display: "standalone",
      scope: Endpoint.url(),
      start_url: "/",
      categories: [
        "social"
      ],
      serviceworker: %{
        src: "/sw.js"
      },
      share_target: %{
        action: "share",
        method: "GET",
        enctype: "application/x-www-form-urlencoded",
        params: %{
          title: "title",
          text: "text",
          url: "url"
        }
      },
      shortcuts: [
        %{
          name: "Search",
          url: "/search",
          icons: [
            %{
              src: "/images/shortcuts/search.png",
              sizes: "192x192"
            }
          ]
        },
        %{
          name: "Notifications",
          url: "/notifications",
          icons: [
            %{
              src: "/images/shortcuts/notifications.png",
              sizes: "192x192"
            }
          ]
        },
        %{
          name: "Chats",
          url: "/chats",
          icons: [
            %{
              src: "/images/shortcuts/chats.png",
              sizes: "192x192"
            }
          ]
        }
      ]
    }
  end

  defp manifest_icons do
    configured_icons =
      Config.get([:manifest, :icons], [])
      |> List.wrap()
      |> Enum.filter(fn
        %{src: src}
        when is_binary(src) and src != "" and src != "/images/unfathomably-logo.svg" ->
          true

        %{"src" => src}
        when is_binary(src) and src != "" and src != "/images/unfathomably-logo.svg" ->
          true

        _ ->
          false
      end)

    case configured_icons do
      [] -> [%{src: Config.get([:instance, :favicon], "/favicon.png") || "/favicon.png"}]
      icons -> icons
    end
  end
end
