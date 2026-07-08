# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Push do
  alias Pleroma.Notification
  alias Pleroma.Workers.WebPusherWorker

  require Logger

  def init do
    unless enabled() do
      Logger.warning("""
      VAPID key pair is not found. If you wish to enabled web push, please run

          mix web_push.gen.keypair

      and add the resulting output to your configuration file.
      """)
    end
  end

  def vapid_config do
    Application.get_env(:web_push_encryption, :vapid_details, [])
  end

  def enabled do
    config = vapid_config()

    Enum.all?([:subject, :public_key, :private_key], &present_config_value?(config, &1))
  end

  defp present_config_value?(config, key) when is_list(config) do
    config
    |> Keyword.get(key)
    |> present_config_value?()
  end

  defp present_config_value?(config, key) when is_map(config) do
    value = Map.get(config, key) || Map.get(config, Atom.to_string(key))

    present_config_value?(value)
  end

  defp present_config_value?(_config, _key), do: false

  defp present_config_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_config_value?(_value), do: false

  @spec send(Notification.t()) :: {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def send(notification) do
    WebPusherWorker.enqueue("web_push", %{"notification_id" => notification.id})
  end
end
