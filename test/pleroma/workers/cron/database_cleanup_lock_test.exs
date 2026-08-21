# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.Cron.DatabaseCleanupLockTest do
  use ExUnit.Case, async: false

  alias Pleroma.Workers.Cron.DatabaseCleanupLock

  test "returns busy instead of waiting while another cleanup owns the lock" do
    parent = self()

    holder =
      Task.async(fn ->
        DatabaseCleanupLock.run(fn ->
          send(parent, :cleanup_lock_acquired)

          receive do
            :release_cleanup_lock -> :released
          end
        end)
      end)

    assert_receive :cleanup_lock_acquired
    assert :busy = DatabaseCleanupLock.run(fn -> :unexpected end)

    send(holder.pid, :release_cleanup_lock)
    assert {:acquired, :released} = Task.await(holder)
    assert {:acquired, :available} = DatabaseCleanupLock.run(fn -> :available end)
  end
end

# end of database_cleanup_lock_test.exs
