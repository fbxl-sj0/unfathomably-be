# Pleroma: A lightweight social networking server
# Copyright 2017-2024 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Signature.HTTPSignatures do
  @callback validate_conn(Plug.Conn.t()) :: any()
end
