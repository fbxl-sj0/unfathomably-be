# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2023 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.MRF.QuietReply do
  @moduledoc """
  QuietReply alters the scope of local replies by making them unlisted.

  The activity is still delivered to the expected recipients and instances, and
  it remains visible to anyone opening the thread. It is not published into the
  federated timeline as a top-level public reply.
  """
  require Pleroma.Constants

  alias Pleroma.User

  @behaviour Pleroma.Web.ActivityPub.MRF.Policy

  @impl true
  def history_awareness, do: :auto

  @impl true
  def filter(
        %{
          "type" => "Create",
          "to" => to,
          "cc" => cc,
          "object" => %{
            "actor" => actor,
            "type" => "Note",
            "inReplyTo" => in_reply_to
          }
        } = activity
      ) do
    with true <- is_binary(in_reply_to),
         true <- Pleroma.Constants.as_public() in to,
         %User{follower_address: followers_collection, local: true} <-
           User.get_by_ap_id(actor) do
      updated_to =
        [followers_collection | to]
        |> Kernel.--([Pleroma.Constants.as_public()])

      updated_cc =
        [Pleroma.Constants.as_public() | cc]
        |> Kernel.--([followers_collection])

      updated_activity =
        activity
        |> Map.put("to", updated_to)
        |> Map.put("cc", updated_cc)
        |> put_in(["object", "to"], updated_to)
        |> put_in(["object", "cc"], updated_cc)

      {:ok, updated_activity}
    else
      _ -> {:ok, activity}
    end
  end

  @impl true
  def filter(activity), do: {:ok, activity}

  @impl true
  def describe, do: {:ok, %{}}
end
