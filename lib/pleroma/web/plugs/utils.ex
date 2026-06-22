# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.Utils do
  @moduledoc """
  Small helper functions shared across request plugs.
  """

  def get_safe_mime_type(%{allowed_mime_types: allowed_mime_types}, mime)
      when is_list(allowed_mime_types) and is_binary(mime) do
    [main_type | _] = String.split(mime, "/", parts: 2)

    if main_type in allowed_mime_types do
      mime
    else
      "application/octet-stream"
    end
  end

  def get_safe_mime_type(_, _), do: "application/octet-stream"
end
