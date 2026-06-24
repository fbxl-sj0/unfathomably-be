# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.StaticFE.StaticFEViewTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Web.StaticFE.StaticFEView

  test "format_date tolerates missing or malformed remote dates" do
    assert is_binary(StaticFEView.format_date(nil))
    assert is_binary(StaticFEView.format_date("not a date"))
  end
end
