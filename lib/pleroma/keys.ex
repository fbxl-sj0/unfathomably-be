# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Keys do
  @base58btc_alphabet "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  @ed25519_multicodec <<0xED, 0x01>>
  @ed25519_spki_prefix <<0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00>>
  @maximum_actor_key_methods 16
  @maximum_multibase_bytes 128

  # Native generation of RSA keys is only available since OTP 20+ and in default build conditions
  # We try at compile time to generate natively an RSA key otherwise we fallback on the old way.
  try do
    _ = :public_key.generate_key({:rsa, 2048, 65_537})

    def generate_rsa_pem do
      key = :public_key.generate_key({:rsa, 2048, 65_537})
      entry = :public_key.pem_entry_encode(:RSAPrivateKey, key)
      pem = :public_key.pem_encode([entry]) |> String.trim_trailing()
      {:ok, pem}
    end
  rescue
    _ ->
      def generate_rsa_pem do
        port = Port.open({:spawn, "openssl genrsa"}, [:binary])

        {:ok, pem} =
          receive do
            {^port, {:data, pem}} -> {:ok, pem}
          end

        Port.close(port)

        if Regex.match?(~r/RSA PRIVATE KEY/, pem) do
          {:ok, pem}
        else
          :error
        end
      end
  end

  def keys_from_pem(pem) do
    with [private_key_code] <- :public_key.pem_decode(pem),
         private_key <- :public_key.pem_entry_decode(private_key_code),
         {:RSAPrivateKey, _, modulus, exponent, _, _, _, _, _, _, _} <- private_key do
      {:ok, private_key, {:RSAPublicKey, modulus, exponent}}
    else
      error -> {:error, error}
    end
  end

  @doc "Decodes every supported public key in a PEM bundle."
  def public_keys_from_pem(pem) when is_binary(pem) do
    pem
    |> :public_key.pem_decode()
    |> Enum.flat_map(fn entry ->
      case public_key_from_pem_entry(entry) do
        {:ok, public_key} -> [public_key]
        _ -> []
      end
    end)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  def public_keys_from_pem(_), do: []

  @doc "Encodes a raw Ed25519 public key as SubjectPublicKeyInfo PEM."
  def ed25519_public_key_to_pem(public_key)
      when is_binary(public_key) and byte_size(public_key) == 32 do
    encoded = Base.encode64(@ed25519_spki_prefix <> public_key)
    "-----BEGIN PUBLIC KEY-----\n#{encoded}\n-----END PUBLIC KEY-----"
  end

  @doc "Extracts bounded, actor-controlled Ed25519 verification methods."
  def ed25519_public_key_pems(%{"id" => actor_id} = actor) when is_binary(actor_id) do
    actor
    |> actor_key_methods(actor_id)
    |> Enum.flat_map(fn method ->
      case ed25519_public_key_from_method(method) do
        {:ok, public_key} -> [ed25519_public_key_to_pem(public_key)]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  def ed25519_public_key_pems(_), do: []

  @doc "Decodes an Ed25519 did:key identifier into its raw 32-byte public key."
  @spec ed25519_public_key_from_did_key(String.t()) ::
          {:ok, binary()} | {:error, :invalid_ed25519_did_key}
  def ed25519_public_key_from_did_key("did:key:z" <> encoded)
      when byte_size(encoded) > 0 and byte_size(encoded) <= @maximum_multibase_bytes do
    with {:ok, decoded} <- decode_base58btc(encoded),
         <<@ed25519_multicodec::binary, public_key::binary-size(32)>> <- decoded do
      {:ok, public_key}
    else
      _ -> {:error, :invalid_ed25519_did_key}
    end
  end

  def ed25519_public_key_from_did_key(_did_key),
    do: {:error, :invalid_ed25519_did_key}

  @doc "Decodes a bounded base58-btc Multibase value."
  @spec decode_multibase_base58btc(String.t(), pos_integer()) ::
          {:ok, binary()} | {:error, :invalid_base58btc_multibase}
  def decode_multibase_base58btc("z" <> encoded, maximum_decoded_bytes)
      when byte_size(encoded) > 0 and byte_size(encoded) <= @maximum_multibase_bytes and
             is_integer(maximum_decoded_bytes) and maximum_decoded_bytes > 0 and
             maximum_decoded_bytes <= 4_096 do
    with {:ok, decoded} <- decode_base58btc(encoded),
         true <- byte_size(decoded) <= maximum_decoded_bytes do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_base58btc_multibase}
    end
  end

  def decode_multibase_base58btc(_value, _maximum_decoded_bytes),
    do: {:error, :invalid_base58btc_multibase}

  defp public_key_from_pem_entry(
         {:SubjectPublicKeyInfo, <<@ed25519_spki_prefix::binary, public_key::binary-size(32)>>,
          :not_encrypted}
       ) do
    {:ok, {:ed25519, public_key}}
  end

  defp public_key_from_pem_entry(entry) do
    {:ok, :public_key.pem_entry_decode(entry)}
  rescue
    _ -> {:error, :invalid_public_key}
  catch
    _, _ -> {:error, :invalid_public_key}
  end

  defp actor_key_methods(actor, actor_id) do
    assertions = actor |> Map.get("assertionMethod", []) |> List.wrap()

    assertion_ids =
      assertions
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    inline_assertions = Enum.filter(assertions, &is_map/1)
    verification_methods = actor |> Map.get("verificationMethod", []) |> List.wrap()

    referenced_methods =
      if MapSet.size(assertion_ids) == 0 do
        verification_methods
      else
        Enum.filter(verification_methods, fn
          %{"id" => id} when is_binary(id) -> MapSet.member?(assertion_ids, id)
          _ -> false
        end)
      end

    actor
    |> Map.get("publicKey", [])
    |> List.wrap()
    |> Kernel.++(inline_assertions)
    |> Kernel.++(referenced_methods)
    |> Enum.filter(&actor_controls_key_method?(&1, actor_id))
    |> Enum.take(@maximum_actor_key_methods)
  end

  defp actor_controls_key_method?(method, actor_id) when is_map(method) do
    controller = method["controller"] || method["owner"]
    controller == actor_id
  end

  defp actor_controls_key_method?(_method, _actor_id), do: false

  defp ed25519_public_key_from_method(%{
         "publicKeyJwk" => %{"kty" => "OKP", "crv" => "Ed25519", "x" => encoded}
       })
       when is_binary(encoded) do
    encoded = String.trim_trailing(encoded, "=")

    case Base.url_decode64(encoded, padding: false) do
      {:ok, public_key} when byte_size(public_key) == 32 -> {:ok, public_key}
      _ -> {:error, :invalid_ed25519_jwk}
    end
  end

  defp ed25519_public_key_from_method(%{"publicKeyMultibase" => "z" <> encoded})
       when byte_size(encoded) > 0 and byte_size(encoded) <= @maximum_multibase_bytes do
    with {:ok, decoded} <- decode_base58btc(encoded),
         <<@ed25519_multicodec::binary, public_key::binary-size(32)>> <- decoded do
      {:ok, public_key}
    else
      _ -> {:error, :invalid_ed25519_multikey}
    end
  end

  defp ed25519_public_key_from_method(_method), do: {:error, :unsupported_public_key}

  defp decode_base58btc(encoded) do
    characters = :binary.bin_to_list(encoded)
    leading_zeroes = Enum.count(Enum.take_while(characters, &(&1 == ?1)))

    with {:ok, integer} <- decode_base58btc_integer(characters) do
      decoded = if integer == 0, do: <<>>, else: :binary.encode_unsigned(integer)
      {:ok, :binary.copy(<<0>>, leading_zeroes) <> decoded}
    end
  end

  defp decode_base58btc_integer(characters) do
    Enum.reduce_while(characters, {:ok, 0}, fn character, {:ok, accumulator} ->
      case :binary.match(@base58btc_alphabet, <<character>>) do
        {value, 1} -> {:cont, {:ok, accumulator * 58 + value}}
        :nomatch -> {:halt, {:error, :invalid_base58btc}}
      end
    end)
  end
end
