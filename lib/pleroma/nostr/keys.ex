# Unfathomably BE
# ----------------
#
# File: nostr/keys.ex
#
# Purpose:
#   Derive stable bridge-only Nostr keys without storing private key material.
#
# Responsibilities:
#   - validate the operator-provided bridge secret
#   - derive domain-separated secp256k1 private keys
#   - reject the negligible invalid-scalar cases instead of assuming success
#
# This file intentionally does NOT import user-owned keys, expose private keys
# through an API, or make Nostr the canonical identity store.

defmodule Pleroma.Nostr.Keys do
  alias Pleroma.Config

  @max_scalar_attempts 16

  def private_key(scope) when is_binary(scope) and byte_size(scope) > 0 do
    with {:ok, secret} <- bridge_secret() do
      derive_valid_key(secret, scope, 0)
    end
  end

  def private_key(_scope), do: {:error, :invalid_scope}

  def public_key(scope) do
    with {:ok, private_key} <- private_key(scope) do
      {:ok, Nostr.Crypto.pubkey(private_key)}
    end
  rescue
    _ -> {:error, :invalid_private_key}
  end

  defp bridge_secret do
    case Config.get([Pleroma.Nostr, :bridge_secret]) do
      value when is_binary(value) and byte_size(value) >= 32 -> {:ok, value}
      _ -> {:error, :missing_bridge_secret}
    end
  end

  defp derive_valid_key(_secret, _scope, attempt) when attempt >= @max_scalar_attempts,
    do: {:error, :could_not_derive_key}

  defp derive_valid_key(secret, scope, attempt) do
    private_key =
      :crypto.mac(:hmac, :sha256, secret, "unfathomably-nostr-v1:" <> scope <> ":#{attempt}")
      |> Base.encode16(case: :lower)

    try do
      _pubkey = Nostr.Crypto.pubkey(private_key)
      {:ok, private_key}
    rescue
      _ -> derive_valid_key(secret, scope, attempt + 1)
    end
  end
end

# end of nostr/keys.ex
