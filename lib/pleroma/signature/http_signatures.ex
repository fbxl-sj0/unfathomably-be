# Pleroma: A lightweight social networking server
# Copyright 2017-2024 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Signature.HTTPSignatures do
  require Logger

  @callback validate_conn(Plug.Conn.t()) :: any()

  @spec validate_conn(Plug.Conn.t()) :: boolean()
  def validate_conn(conn) do
    adapter = Application.get_env(:http_signatures, :adapter)

    with {:ok, public_key} <- adapter.fetch_public_key(conn) do
      case validate_conn(conn, public_key) do
        true ->
          true

        false ->
          maybe_refetch_key_and_retry(conn, adapter)
      end
    else
      e ->
        Logger.debug("Could not validate against known public keys: #{inspect(e)}")
        false
    end
  end

  @spec validate_conn(Plug.Conn.t(), any()) :: boolean()
  def validate_conn(conn, {:ed25519_public_key, public_key})
      when is_binary(public_key) and byte_size(public_key) == 32 do
    validate_ed25519_conn(conn, public_key)
  end

  def validate_conn(conn, public_key), do: HTTPSignatures.validate_conn(conn, public_key)

  defp validate_ed25519_conn(conn, public_key) do
    with {:ok, headers} <- request_headers(conn),
         {:ok, signature} <- signature_from_headers(headers),
         :ok <- validate_signature_params(signature),
         :ok <- validate_required_headers(headers, signature["headers"]),
         {:ok, signature_bytes} <- decode_signature(signature),
         :ok <- validate_signature_bytes(signature_bytes),
         signing_string <- signing_string(headers, signature) do
      :crypto.verify(:eddsa, :none, signing_string, signature_bytes, [public_key, :ed25519])
    else
      {:error, reason} ->
        Logger.error("#{__MODULE__}: invalid Ed25519 signature #{inspect(reason)}")
        false
    end
  end

  defp request_headers(conn) do
    {:ok,
     Map.new(conn.req_headers, fn {key, value} -> {String.downcase(to_string(key)), value} end)}
  rescue
    _ -> {:error, :invalid_headers}
  end

  defp signature_from_headers(%{"signature" => signature}) when is_binary(signature) do
    {:ok, HTTPSignatures.split_signature(signature)}
  rescue
    _ -> {:error, :invalid_signature_header}
  end

  defp signature_from_headers(_), do: {:error, :missing_signature_header}

  defp signing_string(headers, signature) do
    headers =
      headers
      |> Map.put("(created)", signature["created"])
      |> Map.put("(expires)", signature["expires"])

    HTTPSignatures.build_signing_string(headers, signature["headers"] || [])
  end

  defp decode_signature(%{"signature" => encoded}) when is_binary(encoded) do
    Base.decode64(encoded)
  end

  defp decode_signature(_), do: {:error, :missing_signature}

  defp validate_signature_bytes(signature_bytes) when byte_size(signature_bytes) == 64, do: :ok
  defp validate_signature_bytes(_), do: {:error, :invalid_signature_size}

  defp validate_signature_params(signature) do
    sig_headers = signature["headers"] || []

    with :ok <- validate_algorithm(signature["algorithm"]),
         :ok <- validate_created_param(signature, sig_headers) do
      validate_expires_param(signature, sig_headers)
    end
  end

  defp validate_algorithm(nil), do: :ok
  defp validate_algorithm(""), do: :ok

  defp validate_algorithm(algorithm) when is_binary(algorithm) do
    case String.downcase(algorithm) do
      "ed25519" -> :ok
      "hs2019" -> :ok
      _ -> {:error, :unsupported_algorithm}
    end
  end

  defp validate_algorithm(_), do: {:error, :unsupported_algorithm}

  defp validate_created_param(signature, sig_headers) do
    if "(created)" in sig_headers do
      signature["created"]
      |> parse_integer_timestamp()
      |> validate_created_timestamp()
    else
      :ok
    end
  end

  defp validate_expires_param(signature, sig_headers) do
    if "(expires)" in sig_headers do
      signature["expires"]
      |> parse_timestamp()
      |> validate_expires_timestamp()
    else
      :ok
    end
  end

  defp parse_integer_timestamp(value) when is_integer(value), do: {:ok, value}

  defp parse_integer_timestamp(value) when is_binary(value) do
    case Integer.parse(value) do
      {timestamp, ""} -> {:ok, timestamp}
      _ -> :error
    end
  end

  defp parse_integer_timestamp(_), do: :error

  defp parse_timestamp(value) when is_integer(value), do: {:ok, value}
  defp parse_timestamp(value) when is_float(value), do: {:ok, value}

  defp parse_timestamp(value) when is_binary(value) do
    case Float.parse(value) do
      {timestamp, ""} -> {:ok, timestamp}
      _ -> :error
    end
  end

  defp parse_timestamp(_), do: :error

  defp validate_created_timestamp({:ok, timestamp}) do
    if timestamp <= System.system_time(:second), do: :ok, else: {:error, :created_in_future}
  end

  defp validate_created_timestamp(:error), do: {:error, :created_param}

  defp validate_expires_timestamp({:ok, timestamp}) do
    if timestamp >= System.system_time(:second), do: :ok, else: {:error, :expires_in_past}
  end

  defp validate_expires_timestamp(:error), do: {:error, :expires_param}

  defp validate_required_headers(req_headers, sig_headers) do
    sig_headers = sig_headers || []

    cond do
      not has_header?("host", req_headers, sig_headers) -> {:error, :host_header}
      not has_request_target?(req_headers, sig_headers) -> {:error, :request_target_header}
      true -> :ok
    end
  end

  defp has_header?(header_name, req_headers, sig_headers),
    do: header_name in sig_headers && not empty?(req_headers[header_name])

  defp has_request_target?(req_headers, sig_headers) do
    has_header?("(request-target)", req_headers, sig_headers) ||
      has_header?("@request-target", req_headers, sig_headers)
  end

  defp empty?(nil), do: true
  defp empty?(""), do: true
  defp empty?(_), do: false

  defp maybe_refetch_key_and_retry(conn, adapter) do
    if retryable_signature_failure?(conn) do
      refetch_key_and_retry(conn, adapter)
    else
      false
    end
  end

  defp retryable_signature_failure?(conn) do
    with {:ok, headers} <- request_headers(conn),
         {:ok, signature} <- signature_from_headers(headers) do
      validate_required_headers(headers, signature["headers"]) == :ok
    else
      _ -> false
    end
  end

  defp refetch_key_and_retry(conn, adapter) do
    Logger.debug("Could not validate, trying to refetch any relevant keys")

    with {:ok, public_key} <- adapter.refetch_public_key(conn) do
      validate_conn(conn, public_key)
    else
      e ->
        Logger.debug("Failed to refetch public key: #{inspect(e)}")
        false
    end
  end
end
