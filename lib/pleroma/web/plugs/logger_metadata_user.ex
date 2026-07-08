# Pleroma: A lightweight social networking server
# Copyright © 2017-2024 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.LoggerMetadataUser do
  @moduledoc """
  Adds the authenticated user's nickname to Logger metadata after authentication.
  """

  alias Pleroma.User

  def init(opts), do: opts

  def call(%{assigns: %{user: %User{} = user}} = conn, _) do
    Logger.metadata(user: user.nickname)
    conn
  end

  def call(conn, _), do: conn
end
