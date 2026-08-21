# Unfathomably: frontend asset path compatibility
#
# File: frontend_asset_path_plug.ex
#
# Purpose:
#   Recover static asset requests from older Vite preload helpers that resolve
#   an output-relative dependency from an already nested chunk directory.
#
# Responsibilities:
#   - normalize duplicated JavaScript and asset bundle prefixes
#   - leave every non-matching request untouched
#
# This file intentionally does not serve files or redirect arbitrary paths.

defmodule Pleroma.Web.Plugs.FrontendAssetPathPlug do
  @moduledoc false

  @behaviour Plug

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(
        %Plug.Conn{path_info: ["packs", "js", "packs", asset_kind | rest]} = conn,
        _options
      )
      when asset_kind in ["assets", "js"] and rest != [] do
    path_info = ["packs", asset_kind | rest]
    request_path = "/" <> Enum.join(path_info, "/")

    %{conn | path_info: path_info, request_path: request_path}
  end

  def call(conn, _options), do: conn
end

# end of frontend_asset_path_plug.ex
