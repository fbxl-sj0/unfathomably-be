# Unfathomably ActivityPub key publication
#
# File: multikey.ex
#
# Purpose:
#   Encode the existing ActivityPub RSA public key as a FEP-521a Multikey.
#
# This file intentionally does not generate keys or persist private material.

defmodule Pleroma.Keys.Multikey do
  alias Pleroma.Keys

  @base58btc_alphabet "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  @rsa_public_multicodec <<0x85, 0x24>>

  def rsa_public_key_multibase(pem) when is_binary(pem) do
    with {:ok, _private_key, public_key} <- Keys.keys_from_pem(pem) do
      der = :public_key.der_encode(:RSAPublicKey, public_key)
      {:ok, "z" <> encode_base58(@rsa_public_multicodec <> der)}
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  def rsa_public_key_multibase(_pem), do: {:error, :invalid_key}

  defp encode_base58(binary) do
    leading_zeroes = binary |> :binary.bin_to_list() |> Enum.take_while(&(&1 == 0)) |> length()
    encoded = binary |> :binary.decode_unsigned() |> encode_integer([]) |> IO.iodata_to_binary()
    String.duplicate("1", leading_zeroes) <> encoded
  end

  defp encode_integer(0, digits), do: digits

  defp encode_integer(integer, digits) when integer > 0 do
    quotient = div(integer, 58)
    remainder = rem(integer, 58)
    digit = binary_part(@base58btc_alphabet, remainder, 1)
    encode_integer(quotient, [digit | digits])
  end
end

# end of multikey.ex
