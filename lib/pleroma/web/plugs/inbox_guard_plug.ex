# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.InboxGuardPlug do
  import Plug.Conn
  import Pleroma.Constants, only: [activity_types: 0, allowed_activity_types_from_strangers: 0]

  alias Pleroma.User

  require Logger

  def init(options), do: options

  def call(%{assigns: %{valid_signature: true}} = conn, _opts) do
    if Pleroma.Federation.enabled?() do
      conn
      |> maybe_assign_implicit_actor()
      |> require_actor()
      |> filter_activity_types(:acknowledge)
    else
      json(conn, 403, "Not federating")
    end
  end

  def call(conn, _opts) do
    if Pleroma.Federation.enabled?() do
      conn = require_actor(conn)

      cond do
        conn.halted -> conn
        known_actor?(conn) -> filter_activity_types(conn, :acknowledge)
        unknown_actor_self_delete?(conn) -> acknowledge_unknown_actor_self_delete(conn)
        true -> filter_unknown_actor(conn)
      end
    else
      json(conn, 403, "Not federating")
    end
  end

  defp filter_activity_types(%{body_params: %{"type" => type}} = conn, mode)
       when is_binary(type) do
    if type in activity_types() do
      conn
    else
      handle_unsupported_activity(conn, mode)
    end
  end

  defp filter_activity_types(conn, _mode) do
    json(conn, 400, "Invalid activity type")
  end

  # FEP-7aa9 FeatureRequest intentionally permits an omitted actor. For direct
  # delivery, the verified HTTP Signature identifies the requester. Do not
  # apply this fallback to unsigned or relayed requests: those need a separately
  # authenticated origin proof before the relay may differ from the requester.
  defp maybe_assign_implicit_actor(
         %{
           assigns: %{user: %User{is_active: true} = signer},
           body_params: %{"type" => "FeatureRequest"} = body_params
         } = conn
       ) do
    if Map.get(body_params, "actor") in [nil, ""] do
      body_params = Map.put(body_params, "actor", signer.ap_id)

      params =
        if is_map(conn.params),
          do: Map.put(conn.params, "actor", signer.ap_id),
          else: body_params

      %{conn | body_params: body_params, params: params}
    else
      conn
    end
  end

  defp maybe_assign_implicit_actor(conn), do: conn

  defp handle_unsupported_activity(conn, :acknowledge) do
    Logger.info(
      "Acknowledging unsupported activity at inbox guard " <>
        "actor=#{inspect(log_value(body_value(conn, "actor")))} " <>
        "activity_id=#{inspect(log_value(body_value(conn, "id")))} " <>
        "type=#{inspect(log_value(body_value(conn, "type")))} " <>
        "request_path=#{inspect(conn.request_path)}"
    )

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(202, "Unsupported activity acknowledged")
    |> halt()
  end

  defp handle_unsupported_activity(conn, :reject) do
    json(conn, 400, "Invalid activity type")
  end

  defp require_actor(%Plug.Conn{halted: true} = conn), do: conn

  defp require_actor(%{body_params: data} = conn) when is_map(data) do
    case Pleroma.Object.Containment.get_actor(data) do
      actor when is_binary(actor) and actor != "" -> conn
      _ -> json(conn, 400, "Activity actor is required")
    end
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

  defp filter_unknown_actor(conn) do
    conn = filter_activity_types(conn, :reject)

    if conn.halted do
      conn
    else
      filter_from_strangers(conn)
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

  # A remote account can disappear before its final Delete reaches this
  # server. When the actor has never existed locally, acknowledging the exact
  # actor-deletes-itself shape has no state-changing side effect. Doing so at
  # first contact also prevents the sender from retrying a harmless tombstone.
  defp unknown_actor_self_delete?(conn) do
    actor = body_value(conn, "actor")

    conn.method == "POST" and
      String.ends_with?(conn.request_path, "/inbox") and
      body_value(conn, "type") == "Delete" and
      body_value(conn, "object") == actor and
      is_binary(actor) and
      is_nil(User.get_cached_by_ap_id(actor))
  end

  defp acknowledge_unknown_actor_self_delete(conn) do
    Logger.info(
      "Acknowledging self-delete for unknown actor at inbox guard " <>
        "actor=#{inspect(log_value(body_value(conn, "actor")))} " <>
        "activity_id=#{inspect(log_value(body_value(conn, "id")))} " <>
        "request_path=#{inspect(conn.request_path)}"
    )

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(202, "Delete acknowledged for unknown actor")
    |> halt()
  end

  defp json(conn, status, resp) do
    Logger.info(
      "Inbox guard rejected request " <>
        "status=#{status} reason=#{inspect(resp)} " <>
        "actor=#{inspect(log_value(body_value(conn, "actor")))} " <>
        "activity_id=#{inspect(log_value(body_value(conn, "id")))} " <>
        "type=#{inspect(log_value(body_value(conn, "type")))} " <>
        "request_path=#{inspect(conn.request_path)}"
    )

    json_resp = Jason.encode!(resp)

    conn
    |> put_resp_content_type("application/json")
    |> resp(status, json_resp)
    |> halt()
  end

  defp body_value(%{body_params: params}, key) when is_map(params) do
    case Map.get(params, key) do
      %{"id" => value} -> value
      value -> value
    end
  end

  defp body_value(_conn, _key), do: nil

  defp log_value(value) when is_binary(value), do: String.slice(value, 0, 500)
  defp log_value(_value), do: nil
end
