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
    case Application.get_env(:web_push_encryption, :vapid_details, []) do
      config when is_list(config) -> config
      _ -> []
    end
  end

  def enabled, do: match?([subject: _, public_key: _, private_key: _], vapid_config())

  @spec send(Notification.t()) :: {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def send(notification) do
    WebPusherWorker.enqueue("web_push", %{"notification_id" => notification.id})
  end
end
