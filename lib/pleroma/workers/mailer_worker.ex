# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.MailerWorker do
  use Pleroma.Workers.WorkerHelper, queue: "mailer"

  @impl Oban.Worker
  # sobelow_skip ["Misc.BinToTerm"]
  def perform(%Job{
        args: %{"op" => "email", "encoded_email" => encoded_email, "config" => config}
      })
      when is_binary(encoded_email) do
    with {:ok, email} <- decode_email(encoded_email) do
      Pleroma.Emails.Mailer.deliver(email, config)
    else
      {:error, reason} -> {:cancel, reason}
    end
  end

  def perform(%Job{}), do: :discard

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(5)

  defp decode_email(encoded_email) do
    case Base.decode64(encoded_email) do
      {:ok, email} -> {:ok, :erlang.binary_to_term(email, [:safe])}
      :error -> {:error, :invalid_email_payload}
    end
  rescue
    _ -> {:error, :invalid_email_payload}
  end
end
