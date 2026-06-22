# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.MappedSignatureToIdentityPlug do
  alias Pleroma.Helpers.AuthHelper
  alias Pleroma.Signature
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Utils

  import Plug.Conn
  require Logger

  def init(options), do: options

  def call(%{assigns: %{user: %User{}}} = conn, _opts), do: conn

  # if this has payload make sure it is signed by the same actor that made it
  def call(%{assigns: %{valid_signature: true}, params: %{"actor" => actor}} = conn, _opts) do
    with key_actor_id when is_binary(key_actor_id) <- key_actor_id_from_conn(conn),
         actor_id <- Utils.get_ap_id(actor),
         {:user, %User{} = user} <- {:user, user_from_key_actor_id(key_actor_id)},
         {:user_match, true} <- {:user_match, user.ap_id == actor_id} do
      conn
      |> assign(:user, user)
      |> AuthHelper.skip_oauth()
    else
      :missing ->
        conn

      :invalid ->
        Logger.debug("Failed to map identity from signature (invalid key id)")
        Logger.debug("key_id=#{inspect(key_id_from_conn(conn))}, actor=#{inspect(actor)}")
        assign(conn, :valid_signature, false)

      {:user_match, false} ->
        Logger.debug("Failed to map identity from signature (payload actor mismatch)")
        Logger.debug("key_id=#{inspect(key_id_from_conn(conn))}, actor=#{inspect(actor)}")
        assign(conn, :valid_signature, false)

      # remove me once testsuite uses mapped capabilities instead of what we do now
      {:user, nil} ->
        Logger.debug("Failed to map identity from signature (lookup failure)")
        Logger.debug("key_id=#{inspect(key_id_from_conn(conn))}, actor=#{inspect(actor)}")
        assign(conn, :valid_signature, false)
    end
  end

  # no payload, probably a signed fetch
  def call(%{assigns: %{valid_signature: true}} = conn, _opts) do
    with key_actor_id when is_binary(key_actor_id) <- key_actor_id_from_conn(conn),
         %User{} = user <- user_from_key_actor_id(key_actor_id) do
      conn
      |> assign(:user, user)
      |> AuthHelper.skip_oauth()
    else
      :missing ->
        conn

      _ ->
        Logger.debug("Failed to map identity from signature (no payload actor mismatch)")
        Logger.debug("key_id=#{inspect(key_id_from_conn(conn))}")
        assign(conn, :valid_signature, false)
    end
  end

  # no signature at all
  def call(conn, _opts), do: conn

  defp key_actor_id_from_conn(conn) do
    case HTTPSignatures.signature_for_conn(conn) do
      %{"keyId" => key_id} when is_binary(key_id) ->
        case Signature.key_id_to_actor_id(key_id) do
          {:ok, ap_id} -> ap_id
          _ -> :invalid
        end

      _ ->
        :missing
    end
  end

  defp key_id_from_conn(conn) do
    case key_actor_id_from_conn(conn) do
      key_actor_id when is_binary(key_actor_id) -> key_actor_id
      _ -> nil
    end
  end

  defp user_from_key_actor_id(key_actor_id) do
    with {:ok, %User{} = user} <- User.get_or_fetch_by_ap_id(key_actor_id) do
      user
    else
      _ ->
        nil
    end
  end
end
