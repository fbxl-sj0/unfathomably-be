# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.HTTPSignaturePlug do
  alias Pleroma.Helpers.InetHelper

  import Plug.Conn
  import Phoenix.Controller, only: [get_format: 1, text: 2]

  alias Pleroma.Config
  alias Pleroma.Signature
  alias Pleroma.Web.ActivityPub.MRF

  require Logger

  def init(options) do
    options
  end

  def call(%{assigns: %{valid_signature: true}} = conn, _opts) do
    conn
    |> maybe_assign_actor_id()
    |> maybe_filter_requests()
  end

  def call(conn, _opts) do
    if get_format(conn) in ["json", "activity+json"] do
      conn
      |> maybe_assign_valid_signature()
      |> maybe_reject_signature_error()
      |> maybe_assign_actor_id()
      |> maybe_require_signature()
      |> maybe_filter_requests()
    else
      conn
    end
  end

  defp maybe_assign_valid_signature(conn) do
    if has_signature_header?(conn) do
      # Replace wire digest values only after DigestPlug proved they describe
      # the parsed body. This gives both signature formats the same body view.
      conn = put_computed_digests(conn)

      case Signature.validate_signature_result(conn) do
        :ok ->
          conn
          |> assign(:valid_signature, true)
          |> assign(:signature_error, nil)

        {:error, reason} ->
          conn
          |> assign(:valid_signature, false)
          |> assign(:signature_error, reason)
      end
    else
      Logger.debug("No signature header!")
      conn
    end
  end

  defp maybe_assign_actor_id(%{assigns: %{valid_signature: true, actor_id: actor_id}} = conn)
       when is_binary(actor_id) do
    conn
  end

  defp maybe_assign_actor_id(%{assigns: %{valid_signature: true}} = conn) do
    adapter = Application.get_env(:http_signatures, :adapter)

    case adapter.get_actor_id(conn) do
      {:ok, actor_id} when is_binary(actor_id) -> assign(conn, :actor_id, actor_id)
      _ -> conn
    end
  end

  defp maybe_assign_actor_id(conn), do: conn

  defp maybe_reject_signature_error(%{halted: true} = conn), do: conn

  defp maybe_reject_signature_error(%{assigns: %{signature_error: :key_unavailable}} = conn) do
    conn
    |> put_status(:service_unavailable)
    |> text("Signing key temporarily unavailable")
    |> halt()
  end

  defp maybe_reject_signature_error(
         %{assigns: %{signature_error: reason}} = conn
       )
       when reason not in [nil, :invalid_signature] do
    conn
    |> put_status(:bad_request)
    |> text("Malformed HTTP Signature")
    |> halt()
  end

  defp maybe_reject_signature_error(conn), do: conn

  defp has_signature_header?(conn) do
    conn |> get_req_header("signature") |> Enum.at(0, false)
  end

  defp put_computed_digests(conn) do
    conn =
      case conn do
        %{assigns: %{digest: digest}} -> put_req_header(conn, "digest", digest)
        _ -> conn
      end

    case conn do
      %{assigns: %{content_digest: digest, content_digest_valid: true}} ->
        put_req_header(conn, "content-digest", digest)

      _ ->
        conn
    end
  end

  defp maybe_require_signature(%{assigns: %{valid_signature: true}} = conn), do: conn
  defp maybe_require_signature(%{halted: true} = conn), do: conn

  defp maybe_require_signature(%{remote_ip: remote_ip} = conn) do
    if Pleroma.Config.get([:activitypub, :authorized_fetch_mode], false) do
      if authorized_fetch_exception?(remote_ip) do
        conn
      else
        conn
        |> put_status(:unauthorized)
        |> text("Request not signed")
        |> halt()
      end
    else
      conn
    end
  end

  defp authorized_fetch_exception?(remote_ip) do
    Config.get([:activitypub, :authorized_fetch_mode_exceptions], [])
    |> Enum.map(&InetHelper.parse_cidr/1)
    |> Enum.any?(&InetCidr.contains?(&1, remote_ip))
  end

  defp maybe_filter_requests(%{halted: true} = conn), do: conn

  defp maybe_filter_requests(%{assigns: %{actor_id: actor_id}} = conn) when is_binary(actor_id) do
    if Config.get([:activitypub, :authorized_fetch_mode], false) do
      host = uri_host(actor_id)

      if is_binary(host) and MRF.subdomain_match?(rejected_domains(), host) do
        conn
        |> put_status(:unauthorized)
        |> text("Request rejected")
        |> halt()
      else
        conn
      end
    else
      conn
    end
  end

  defp maybe_filter_requests(conn), do: conn

  defp rejected_domains do
    Config.get([:instance, :rejected_instances])
    |> MRF.instance_list_from_tuples()
    |> MRF.subdomains_regex()
  end

  defp uri_host(uri) when is_binary(uri) do
    uri
    |> URI.parse()
    |> Map.get(:host)
  rescue
    URI.Error -> nil
  end
end
