# Unfathomably ActivityPub error responses
# -----------------------------------------
#
# File: activity_pub_problem_details_plug.ex
#
# Purpose:
#   Render failed ActivityPub controller responses as FEP-c180 Problem Details.
#
# Responsibilities:
#   - format ActivityPub HTTP errors without changing successful responses
#   - retain bounded, already-public structured error metadata
#   - preserve ActivityStreams Tombstones served with HTTP 410
#
# This file intentionally does not handle Mastodon API errors, rescue internal
# exceptions, or expose unstructured response bodies.

defmodule Pleroma.Web.Plugs.ActivityPubProblemDetailsPlug do
  @moduledoc """
  Formats ActivityPub controller errors as bounded Problem Details documents.

  A `410 Gone` response containing an ActivityStreams Tombstone is an object
  representation, not an error document. Those responses retain their original
  body and content type so remote object deletion remains interoperable.
  """

  import Plug.Conn

  @maximum_metadata_body_bytes 16_384

  def init(options), do: options

  def call(conn, _options) do
    register_before_send(conn, &format_error/1)
  end

  defp format_error(%Plug.Conn{status: status} = conn)
       when is_integer(status) and status >= 400 do
    metadata = decode_metadata(conn.resp_body)

    if problem_details?(conn) or tombstone?(status, metadata) do
      conn
    else
      problem =
        %{
          "type" => "about:blank",
          "title" => problem_title(metadata, status),
          "status" => status,
          "detail" => problem_detail(metadata, status),
          "instance" => conn.request_path
        }
        |> maybe_put_metadata(metadata)

      conn
      |> put_resp_content_type("application/problem+json")
      |> Map.put(:resp_body, Jason.encode!(problem))
    end
  end

  defp format_error(conn), do: conn

  defp decode_metadata(body) do
    with {:ok, body} <- body_binary(body),
         true <- byte_size(body) <= @maximum_metadata_body_bytes,
         {:ok, decoded} when is_map(decoded) or is_list(decoded) <- Jason.decode(body) do
      decoded
    else
      _ -> nil
    end
  end

  defp body_binary(body) when is_binary(body), do: {:ok, body}

  defp body_binary(body) when is_list(body) do
    {:ok, IO.iodata_to_binary(body)}
  rescue
    ArgumentError -> :error
  end

  defp body_binary(_body), do: :error

  defp problem_details?(conn) do
    conn
    |> get_resp_header("content-type")
    |> Enum.any?(&String.starts_with?(String.downcase(&1), "application/problem+json"))
  end

  defp tombstone?(410, %{"type" => "Tombstone"}), do: true
  defp tombstone?(_status, _metadata), do: false

  defp problem_title(%{} = metadata, status) do
    string_value(metadata, ["title", "code"]) || Plug.Conn.Status.reason_phrase(status)
  end

  defp problem_title(_metadata, status), do: Plug.Conn.Status.reason_phrase(status)

  defp problem_detail(%{} = metadata, status) do
    string_value(metadata, ["detail", "message", "error"]) ||
      Plug.Conn.Status.reason_phrase(status)
  end

  defp problem_detail(_metadata, status), do: Plug.Conn.Status.reason_phrase(status)

  defp string_value(metadata, keys) do
    Enum.find_value(keys, fn key ->
      case metadata[key] do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp maybe_put_metadata(problem, nil), do: problem
  defp maybe_put_metadata(problem, metadata), do: Map.put(problem, "metadata", metadata)
end

# end of activity_pub_problem_details_plug.ex
