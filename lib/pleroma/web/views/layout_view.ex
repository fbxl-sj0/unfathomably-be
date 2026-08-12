# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.LayoutView do
  use Pleroma.Web, :view

  alias Pleroma.Config

  def instance_meta_tags do
    instance_name = escaped_config([:instance, :name])
    theme_color = escaped_config([:manifest, :theme_color], "#282c37")
    favicon = escaped_config([:instance, :favicon], "/favicon.png")

    Phoenix.HTML.raw(
      ~s(<meta name="application-name" content="#{instance_name}">) <>
        ~s(<meta name="theme-color" content="#{theme_color}">) <>
        ~s(<link rel="icon" href="#{favicon}">) <>
        ~s(<link rel="manifest" href="/manifest.json">)
    )
  end

  defp escaped_config(path, fallback \\ "") do
    path
    |> Config.get(fallback)
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end
end
