# Unfathomably BE
# ----------------
#
# File: atproto/crypto.ex
#
# Purpose:
#   Encrypt AT Protocol PDS session tokens at rest.
#
# Responsibilities:
#   - derive bridge-specific encryption and signing keys
#   - encrypt opaque access and refresh token values
#   - authenticate ciphertext before returning plaintext
#
# This file intentionally does NOT log tokens, store user passwords, or manage
# PDS session refresh policy.

defmodule Pleroma.ATProto.Crypto do
  alias Pleroma.Config
  alias Pleroma.Web.Endpoint
  alias Plug.Crypto.KeyGenerator
  alias Plug.Crypto.MessageEncryptor

  @encryption_salt "unfathomably-atproto-session-v1"
  @signing_salt "unfathomably-atproto-session-sign-v1"
  @max_token_bytes 16_384

  def encrypt(token) when is_binary(token) and byte_size(token) in 1..@max_token_bytes do
    {encryption_secret, signing_secret} = secret_pair()
    {:ok, MessageEncryptor.encrypt(token, encryption_secret, signing_secret)}
  rescue
    _ -> {:error, :token_encryption_failed}
  catch
    _, _ -> {:error, :token_encryption_failed}
  end

  def encrypt(_token), do: {:error, :token_encryption_failed}

  def decrypt(ciphertext) when is_binary(ciphertext) do
    {encryption_secret, signing_secret} = secret_pair()

    with {:ok, token} <- MessageEncryptor.decrypt(ciphertext, encryption_secret, signing_secret),
         true <- byte_size(token) in 1..@max_token_bytes do
      {:ok, token}
    else
      _ -> {:error, :invalid_token_ciphertext}
    end
  rescue
    _ -> {:error, :invalid_token_ciphertext}
  catch
    _, _ -> {:error, :invalid_token_ciphertext}
  end

  def decrypt(_ciphertext), do: {:error, :invalid_token_ciphertext}

  defp secret_pair do
    secret_key_base = Config.get!([Endpoint, :secret_key_base])

    {
      KeyGenerator.generate(secret_key_base, @encryption_salt),
      KeyGenerator.generate(secret_key_base, @signing_salt)
    }
  end
end

# end of atproto/crypto.ex
