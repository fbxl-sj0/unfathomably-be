# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.Cron.DatabaseCleanupLock do
  @moduledoc """
  Serializes database-heavy cleanup work without occupying a database connection.

  Oban state is useful for deciding whether another worker is already executing,
  but two jobs can observe each other before either state change is visible. This
  node-local runtime lock closes that race. Callers do not wait for the lock; they
  reschedule through their existing bounded continuation mechanism instead.
  """

  @lock_resource :unfathomably_database_cleanup

  @doc "Runs `function` while no other database cleanup owns the runtime lock."
  @spec run((-> result)) :: {:acquired, result} | :busy when result: var
  def run(function) when is_function(function, 0) do
    lock_id = {@lock_resource, self()}

    if :global.set_lock(lock_id, [node()], 0) do
      try do
        {:acquired, function.()}
      after
        :global.del_lock(lock_id, [node()])
      end
    else
      :busy
    end
  end
end

# end of database_cleanup_lock.ex
