# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Federation do
  @moduledoc """
  Owns the runtime switch for ActivityPub network activity.

  The instance setting is deliberately checked at runtime. Administrators can
  therefore stop routes, discovery, fetches, and queued delivery work without
  rebuilding the release. Cached remote records remain available to local API
  callers, and non-ActivityPub connectors enforce their own independent gates.
  """

  alias Pleroma.Config

  @spec enabled?() :: boolean()
  def enabled? do
    Config.get([:instance, :federating], true) == true
  end

  @spec ensure_enabled() :: :ok | {:error, :federation_disabled}
  def ensure_enabled do
    if enabled?(), do: :ok, else: {:error, :federation_disabled}
  end
end

# end of lib/pleroma/federation.ex
