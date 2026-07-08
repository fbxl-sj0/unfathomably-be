# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.InboxGuardPlug do
  import Plug.Conn
  import Pleroma.Constants, only: [activity_types: 0, allowed_activity_types_from_strangers: 0]

  alias Pleroma.Config
  alias Pleroma.User

  def init(options), do: options

  def call(%{assigns: %{valid_signature: true}} = conn, _opts) do
    if Config.get!([:instance, :federating]) do
      filter_activity_types(conn)
    else
      json(conn, 403, "Not federating")
    end
  end

  def call(conn, _opts) do
    if Config.get!([:instance, :federating]) do
      conn = filter_activity_types(conn)

      cond do
        conn.halted -> conn
        known_actor?(conn) -> conn
        true -> filter_from_strangers(conn)
      end
    else
      json(conn, 403, "Not federating")
    end
  end

  defp filter_activity_types(%{body_params: %{"type" => type}} = conn) when is_binary(type) do
    if type in activity_types() do
      conn
    else
      json(conn, 400, "Invalid activity type")
    end
  end

  defp filter_activity_types(conn) do
    json(conn, 400, "Invalid activity type")
  end

  # If the actor is already known, accept the request into the normal receiver
  # path even when the signature did not verify. The worker may only need to
  # refresh a rotated remote key before validating the activity.
  defp known_actor?(%{body_params: data}) do
    case Pleroma.Object.Containment.get_actor(data) |> User.get_cached_by_ap_id() do
      %User{} -> true
      _ -> false
    end
  end

  # Unsigned first contact is useful for broad federation, but it must stay
  # narrow. Moderator-only group operations such as Add, Remove, and Lock remain
  # accepted when they are properly signed by a known actor.
  defp filter_from_strangers(%{body_params: %{"type" => type}} = conn) when is_binary(type) do
    if type in allowed_activity_types_from_strangers() do
      conn
    else
      json(conn, 400, "Invalid activity type for an unknown actor")
    end
  end

  defp filter_from_strangers(conn) do
    json(conn, 400, "Invalid activity type for an unknown actor")
  end

  defp json(conn, status, resp) do
    json_resp = Jason.encode!(resp)

    conn
    |> put_resp_content_type("application/json")
    |> resp(status, json_resp)
    |> halt()
  end
end
