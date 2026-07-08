# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.ReleaseTaskTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.ReleaseTasks

  test "finding the module" do
    assert Mix.Tasks.Pleroma.Search.Meilisearch == ReleaseTasks.find_module("search.meilisearch")
    assert Mix.Tasks.Pleroma.User == ReleaseTasks.find_module("user")

    refute ReleaseTasks.find_module("doesnt.exist")
  end
end
