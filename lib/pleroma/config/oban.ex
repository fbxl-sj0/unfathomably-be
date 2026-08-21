# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Config.Oban do
  alias Pleroma.Config

  require Logger

  @required_nostr_crontab [
    {"*/10 * * * *", Pleroma.Workers.NostrProfileSweepWorker},
    {"*/30 * * * *", Pleroma.Workers.NostrCommunityDiscoveryWorker}
  ]

  def warn do
    oban_config = Config.get(Oban)

    crontab =
      oban_config[:crontab]
      |> remove_retired_workers()
      |> ensure_required_nostr_workers()

    Config.put(Oban, Keyword.put(oban_config, :crontab, crontab))
  end

  defp remove_retired_workers(crontab) do
    retired_workers = [
      Pleroma.Workers.Cron.StatsWorker,
      Pleroma.Workers.Cron.PurgeExpiredActivitiesWorker,
      Pleroma.Workers.Cron.ClearOauthTokenWorker
    ]

    Enum.reduce(retired_workers, crontab, fn removed_worker, acc ->
      with acc when is_list(acc) <- acc,
           setting when not is_nil(setting) <-
             Enum.find(acc, &(configured_worker(&1) == removed_worker)) do
        """
        !!!OBAN CONFIG WARNING!!!
        You are using old workers in Oban crontab settings, which were removed.
        Please, remove setting from crontab in your config file (prod.secret.exs): #{inspect(setting)}
        """
        |> Logger.warning()

        List.delete(acc, setting)
      else
        _ -> acc
      end
    end)
  end

  defp ensure_required_nostr_workers(crontab) when is_list(crontab) do
    if Config.get([Pleroma.Nostr, :enabled], false) do
      Enum.reduce(@required_nostr_crontab, crontab, fn {schedule, worker} = setting, acc ->
        if Enum.any?(acc, &(configured_worker(&1) == worker)) do
          acc
        else
          Logger.info(
            "Restored required Nostr Oban crontab worker #{inspect(worker)} at #{schedule}"
          )

          acc ++ [setting]
        end
      end)
    else
      crontab
    end
  end

  defp ensure_required_nostr_workers(crontab), do: crontab

  defp configured_worker({_schedule, worker}), do: worker
  defp configured_worker({_schedule, worker, _options}), do: worker
  defp configured_worker(_setting), do: nil
end
