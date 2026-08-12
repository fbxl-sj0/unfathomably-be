# Unfathomably BE
# ----------------
#
# File: nostr/relay_info.ex
#
# Purpose:
#   Read bounded NIP-11 relay capability documents for approved relays.
#
# Responsibilities:
#   - convert approved WebSocket relay URLs to their HTTP information endpoint
#   - fetch without redirects through the federation HTTP pool
#   - retain only bounded capability and limitation fields
#   - cache successful documents so user searches do not repeatedly probe relays
#
# This file intentionally does NOT approve relay URLs, open WebSockets, or
# interpret capabilities a relay does not explicitly advertise.

defmodule Pleroma.Nostr.RelayInfo do
  alias Pleroma.Config
  alias Pleroma.HTTP
  alias Pleroma.Nostr
  alias Pleroma.Nostr.Protocol

  @cache :nostr_relay_info_cache
  @cachex Config.get([:cachex, :provider], Cachex)
  @maximum_document_bytes 65_536
  @maximum_supported_nips 256

  def get(relay_url) do
    relay_url = Protocol.normalize_relay_url(relay_url)

    with true <- Nostr.allowed_relay?(relay_url) do
      case @cachex.get(@cache, relay_url) do
        {:ok, %{} = information} -> {:ok, information}
        _ -> fetch_and_cache(relay_url)
      end
    else
      _ -> {:error, :relay_not_approved}
    end
  rescue
    _ -> {:error, :relay_information_unavailable}
  catch
    _, _ -> {:error, :relay_information_unavailable}
  end

  def supports?(relay_url, nip) when is_integer(nip) and nip >= 0 do
    case get(relay_url) do
      {:ok, %{"supported_nips" => supported_nips}} -> nip in supported_nips
      _ -> false
    end
  end

  def supports?(_relay_url, _nip), do: false

  def filter_limit(information, requested) when is_integer(requested) and requested > 0 do
    case get_in(information, ["limitation", "max_limit"]) do
      value when is_integer(value) and value > 0 -> min(value, requested)
      _ -> requested
    end
  end

  def filter_limit(_information, requested), do: requested

  defp fetch_and_cache(relay_url) do
    with {:ok, url} <- information_url(relay_url),
         {:ok, %Tesla.Env{status: 200, body: body}} <-
           HTTP.get(url, [{"accept", "application/nostr+json"}], request_options()),
         true <- is_binary(body) and byte_size(body) <= @maximum_document_bytes,
         {:ok, %{} = document} <- Jason.decode(body),
         {:ok, information} <- normalize(document) do
      _ = @cachex.put(@cache, relay_url, information)
      {:ok, information}
    else
      _ -> {:error, :relay_information_unavailable}
    end
  end

  defp information_url(relay_url) do
    case URI.parse(relay_url) do
      %URI{scheme: "wss"} = uri -> {:ok, uri |> Map.put(:scheme, "https") |> URI.to_string()}
      %URI{scheme: "ws"} = uri -> {:ok, uri |> Map.put(:scheme, "http") |> URI.to_string()}
      _ -> {:error, :invalid_relay_url}
    end
  rescue
    URI.Error -> {:error, :invalid_relay_url}
  end

  defp normalize(document) do
    supported_nips =
      document
      |> Map.get("supported_nips", [])
      |> List.wrap()
      |> Enum.filter(&(is_integer(&1) and &1 >= 0 and &1 <= 65_535))
      |> Enum.uniq()
      |> Enum.take(@maximum_supported_nips)

    if supported_nips == [] do
      {:error, :missing_supported_nips}
    else
      {:ok,
       %{
         "name" => bounded_string(document["name"], 256),
         "software" => bounded_string(document["software"], 2_048),
         "version" => bounded_string(document["version"], 256),
         "supported_nips" => supported_nips,
         "limitation" => normalize_limitations(document["limitation"])
       }}
    end
  end

  defp normalize_limitations(%{} = limitations) do
    %{
      "max_limit" => positive_integer(limitations["max_limit"]),
      "default_limit" => positive_integer(limitations["default_limit"]),
      "max_subid_length" => positive_integer(limitations["max_subid_length"]),
      "payment_required" => limitations["payment_required"] == true,
      "auth_required" => limitations["auth_required"] == true,
      "restricted_writes" => limitations["restricted_writes"] == true
    }
  end

  defp normalize_limitations(_limitations), do: %{}

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp bounded_string(value, maximum) when is_binary(value),
    do: binary_part(value, 0, min(byte_size(value), maximum))

  defp bounded_string(_value, _maximum), do: nil

  defp request_options do
    timeout = Config.get([Nostr, :relay_info_timeout_ms], 3_000)
    timeout = if is_integer(timeout) and timeout in 250..10_000, do: timeout, else: 3_000

    [
      pool: :federation,
      redirect_middleware: nil,
      adapter: [follow_redirect: false, force_redirect: false, recv_timeout: timeout]
    ]
  end
end

# end of nostr/relay_info.ex
