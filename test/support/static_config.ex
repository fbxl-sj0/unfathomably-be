# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Test.StaticConfig do
  @behaviour Pleroma.Config.Getting

  @impl true
  def get(key), do: Pleroma.Config.get(key)

  @impl true
  def get(key, default), do: Pleroma.Config.get(key, default)
end
