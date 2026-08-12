# Unfathomably BE
# ----------------
#
# File: nostr/nip05.ex
#
# Purpose:
#   Validate human-readable Nostr identifiers before presenting them to users.
#
# Responsibilities:
#   - parse the constrained NIP-05 identifier form
#   - fetch the HTTPS well-known document without following redirects
#   - prove the document maps the claimed name to the signed event pubkey
#   - return bounded relay hints for subsequent Nostr discovery
#
# This file intentionally does NOT treat NIP-05 as proof of identity, retain
# private keys, or open external relay connections.

defmodule Pleroma.Nostr.NIP05 do
  alias Pleroma.HTTP
  alias Pleroma.Nostr.Protocol

  @maximum_document_bytes 65_536
  @maximum_relay_hints 8
  @local_part ~r/^[a-z0-9._-]{1,128}$/
  @domain ~r/^[a-z0-9.-]{1,253}$/

  def verify(identifier, pubkey)
      when is_binary(identifier) and is_binary(pubkey) do
    with {:ok, parsed} <- parse_identifier(identifier),
         {:ok, document} <- fetch_document(parsed),
         true <- mapped_pubkey(document, parsed.name) == String.downcase(pubkey) do
      {:ok,
       %{
         identifier: parsed.display,
         relays: relay_hints(document, pubkey)
       }}
    else
      _ -> {:error, :invalid_nip05}
    end
  rescue
    _ -> {:error, :invalid_nip05}
  catch
    _, _ -> {:error, :invalid_nip05}
  end

  def verify(_identifier, _pubkey), do: {:error, :invalid_nip05}

  def parse_identifier(identifier) when is_binary(identifier) do
    case identifier |> String.trim() |> String.downcase() |> String.split("@") do
      [name, domain] ->
        with true <- Regex.match?(@local_part, name),
             true <- valid_domain?(domain) do
          display = if name == "_", do: domain, else: "#{name}@#{domain}"
          {:ok, %{name: name, domain: domain, display: display}}
        else
          _ -> {:error, :invalid_nip05}
        end

      _ ->
        {:error, :invalid_nip05}
    end
  end

  def parse_identifier(_identifier), do: {:error, :invalid_nip05}

  defp fetch_document(%{name: name, domain: domain}) do
    url = "https://#{domain}/.well-known/nostr.json?" <> URI.encode_query(%{"name" => name})

    options = [
      pool: :federation,
      redirect_middleware: nil,
      adapter: [
        follow_redirect: false,
        force_redirect: false,
        recv_timeout: 5_000
      ]
    ]

    with {:ok, %Tesla.Env{status: 200, body: body}} <-
           HTTP.get(url, [{"accept", "application/json"}], options),
         true <- is_binary(body),
         true <- byte_size(body) <= @maximum_document_bytes,
         {:ok, %{} = document} <- Jason.decode(body) do
      {:ok, document}
    else
      _ -> {:error, :invalid_nip05}
    end
  end

  defp mapped_pubkey(%{"names" => %{} = names}, name) do
    case Map.get(names, name) do
      pubkey when is_binary(pubkey) -> String.downcase(pubkey)
      _ -> nil
    end
  end

  defp mapped_pubkey(_document, _name), do: nil

  defp relay_hints(%{"relays" => %{} = relays}, pubkey) do
    relays
    |> Map.get(String.downcase(pubkey), [])
    |> List.wrap()
    |> Enum.map(&Protocol.normalize_relay_url/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.take(@maximum_relay_hints)
  end

  defp relay_hints(_document, _pubkey), do: []

  defp valid_domain?(domain) do
    Regex.match?(@domain, domain) and
      not String.contains?(domain, "..") and
      domain not in ["localhost", "localhost.localdomain"] and
      not String.ends_with?(domain, [".local", ".localhost", ".internal"]) and
      valid_domain_labels?(domain) and
      not ip_address?(domain)
  end

  defp valid_domain_labels?(domain) do
    domain
    |> String.split(".")
    |> Enum.all?(fn label ->
      label != "" and byte_size(label) <= 63 and
        not String.starts_with?(label, "-") and
        not String.ends_with?(label, "-")
    end)
  end

  defp ip_address?(domain) do
    match?({:ok, _address}, :inet.parse_address(String.to_charlist(domain)))
  end
end

# end of nostr/nip05.ex
