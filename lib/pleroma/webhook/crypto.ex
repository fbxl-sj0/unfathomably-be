# Unfathomably BE
# ----------------
#
# File: webhook/crypto.ex
#
# Purpose:
#   Encrypt webhook signing secrets before they are stored in PostgreSQL.
#
# Responsibilities:
#   - derive a separate authenticated-encryption key for each webhook row
#   - version ciphertext so future key formats can coexist safely
#   - reject malformed, copied, or oversized ciphertext
#
# This file intentionally does NOT generate webhook secrets, send webhooks, or
# expose decrypted secrets to API callers.

defmodule Pleroma.Webhook.Crypto do
  alias Pleroma.Config
  alias Pleroma.Web.Endpoint
  alias Plug.Crypto.KeyGenerator
  alias Plug.Crypto.MessageEncryptor

  @ciphertext_prefix "v1:"
  @encryption_salt "unfathomably-webhook-secret-v1"
  @signing_salt "unfathomably-webhook-secret-sign-v1"
  @max_secret_bytes 512

  def encrypt(secret, webhook_id)
      when is_binary(secret) and byte_size(secret) in 1..@max_secret_bytes and
             is_integer(webhook_id) and webhook_id > 0 do
    {encryption_secret, signing_secret} = secret_pair(webhook_id)

    ciphertext = MessageEncryptor.encrypt(secret, encryption_secret, signing_secret)
    {:ok, @ciphertext_prefix <> ciphertext}
  rescue
    _ -> {:error, :webhook_secret_encryption_failed}
  catch
    _, _ -> {:error, :webhook_secret_encryption_failed}
  end

  def encrypt(_secret, _webhook_id), do: {:error, :webhook_secret_encryption_failed}

  def decrypt(@ciphertext_prefix <> ciphertext, webhook_id)
      when is_binary(ciphertext) and is_integer(webhook_id) and webhook_id > 0 do
    {encryption_secret, signing_secret} = secret_pair(webhook_id)

    with {:ok, secret} <-
           MessageEncryptor.decrypt(ciphertext, encryption_secret, signing_secret),
         true <- byte_size(secret) in 1..@max_secret_bytes do
      {:ok, secret}
    else
      _ -> {:error, :invalid_webhook_secret_ciphertext}
    end
  rescue
    _ -> {:error, :invalid_webhook_secret_ciphertext}
  catch
    _, _ -> {:error, :invalid_webhook_secret_ciphertext}
  end

  # This compatibility branch keeps an interrupted deployment operational if
  # application code starts before the data migration has encrypted every row.
  # New writes always use the versioned ciphertext form above.
  def decrypt(secret, webhook_id)
      when is_binary(secret) and byte_size(secret) in 1..@max_secret_bytes and
             is_integer(webhook_id) and webhook_id > 0 do
    {:ok, secret}
  end

  def decrypt(_ciphertext, _webhook_id), do: {:error, :invalid_webhook_secret_ciphertext}

  def encrypted?(@ciphertext_prefix <> _ciphertext), do: true
  def encrypted?(_secret), do: false

  defp secret_pair(webhook_id) do
    secret_key_base = Config.get!([Endpoint, :secret_key_base])
    row_salt = Integer.to_string(webhook_id)

    {
      KeyGenerator.generate(secret_key_base, @encryption_salt <> ":" <> row_salt),
      KeyGenerator.generate(secret_key_base, @signing_salt <> ":" <> row_salt)
    }
  end
end

# end of webhook/crypto.ex
