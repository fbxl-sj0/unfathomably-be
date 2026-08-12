# Unfathomably FASP cryptography
# ------------------------------
#
# File: crypto.ex
#
# Purpose:
#   Manage the per-provider Ed25519 identity required by the FASP protocol.
#
# Responsibilities:
#   - generate Ed25519 keypairs with OTP crypto
#   - encrypt private keys with secrets derived from the instance secret
#   - validate decrypted key material before use
#   - calculate the protocol fingerprint shown to administrators
#
# This file intentionally does not parse HTTP Message Signatures or decide
# whether a provider is trusted.

defmodule Pleroma.FASP.Crypto do
  alias Pleroma.Config
  alias Pleroma.Web.Endpoint
  alias Plug.Crypto.KeyGenerator
  alias Plug.Crypto.MessageEncryptor

  @encryption_salt "unfathomably-fasp-private-key-v1"
  @signing_salt "unfathomably-fasp-private-key-sign-v1"

  def generate_keypair do
    case :crypto.generate_key(:eddsa, :ed25519) do
      {public_key, private_key}
      when is_binary(public_key) and byte_size(public_key) == 32 and is_binary(private_key) ->
        {:ok, public_key, private_key}

      _ ->
        {:error, :key_generation_failed}
    end
  rescue
    _ -> {:error, :key_generation_failed}
  catch
    _, _ -> {:error, :key_generation_failed}
  end

  def encrypt_private_key(private_key) when is_binary(private_key) do
    {encryption_secret, signing_secret} = secret_pair()
    {:ok, MessageEncryptor.encrypt(private_key, encryption_secret, signing_secret)}
  rescue
    _ -> {:error, :key_encryption_failed}
  catch
    _, _ -> {:error, :key_encryption_failed}
  end

  def encrypt_private_key(_), do: {:error, :key_encryption_failed}

  def decrypt_private_key(ciphertext) when is_binary(ciphertext) do
    {encryption_secret, signing_secret} = secret_pair()

    with {:ok, private_key} <-
           MessageEncryptor.decrypt(ciphertext, encryption_secret, signing_secret),
         true <- byte_size(private_key) in [32, 64] do
      {:ok, private_key}
    else
      _ -> {:error, :invalid_private_key}
    end
  rescue
    _ -> {:error, :invalid_private_key}
  catch
    _, _ -> {:error, :invalid_private_key}
  end

  def decrypt_private_key(_), do: {:error, :invalid_private_key}

  def fingerprint(public_key) when is_binary(public_key) and byte_size(public_key) == 32 do
    public_key
    |> :crypto.hash(:sha256)
    |> Base.encode64()
  end

  def fingerprint(_), do: nil

  defp secret_pair do
    secret_key_base = Config.get!([Endpoint, :secret_key_base])

    {
      KeyGenerator.generate(secret_key_base, @encryption_salt),
      KeyGenerator.generate(secret_key_base, @signing_salt)
    }
  end
end

# end of crypto.ex
