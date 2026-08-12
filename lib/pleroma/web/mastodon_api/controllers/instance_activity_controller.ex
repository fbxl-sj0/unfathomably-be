# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.InstanceActivityController do
  @moduledoc """
  Serves the legacy Mastodon weekly instance activity response.

  This controller intentionally contains no reporting history or write-side
  behavior. It only projects the local aggregates retained by Unfathomably.
  """

  use Pleroma.Web, :controller

  plug(:skip_auth)

  def show(conn, _params) do
    json(conn, Pleroma.Stats.get_weekly_activity())
  end
end

# end of instance_activity_controller.ex
