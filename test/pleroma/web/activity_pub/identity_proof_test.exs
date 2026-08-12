# Unfathomably ActivityPub identity-proof tests
# ----------------------------------------------
#
# File: identity_proof_test.exs
#
# Purpose:
#   Prove FEP-c390 binding and W3C eddsa-jcs-2022 signature verification.

defmodule Pleroma.Web.ActivityPub.IdentityProofTest do
  use ExUnit.Case, async: true

  alias Pleroma.Web.ActivityPub.IdentityProof

  @actor "https://social.example/users/alice"
  @base58btc_alphabet "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  @ed25519_multicodec <<0xED, 0x01>>

  test "accepts a valid FEP-c390 eddsa-jcs-2022 statement" do
    statement = signed_statement(@actor)

    assert {:ok, ^statement} = IdentityProof.verify(statement, @actor)

    assert [^statement] =
             IdentityProof.extract(%{"id" => @actor, "attachment" => [statement]})
  end

  test "rejects a statement after protected content changes" do
    statement = signed_statement(@actor) |> Map.put("alsoKnownAs", @actor <> "/other")

    assert {:error, :invalid_identity_proof} = IdentityProof.verify(statement, @actor)
  end

  test "discards a valid signature that names a different actor" do
    statement = signed_statement(@actor)

    assert [] =
             IdentityProof.extract(%{
               "id" => "https://social.example/users/mallory",
               "attachment" => [statement]
             })
  end

  defp signed_statement(actor_id) do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    subject = "did:key:" <> multibase(@ed25519_multicodec <> public_key)

    proof_config = %{
      "type" => "DataIntegrityProof",
      "cryptosuite" => "eddsa-jcs-2022",
      "created" => "2026-08-10T12:00:00Z",
      "verificationMethod" => subject,
      "proofPurpose" => "assertionMethod"
    }

    unsecured_statement = %{
      "type" => "VerifiableIdentityStatement",
      "subject" => subject,
      "alsoKnownAs" => actor_id
    }

    hash_data =
      :crypto.hash(:sha256, Jcs.encode(proof_config)) <>
        :crypto.hash(:sha256, Jcs.encode(unsecured_statement))

    signature = :crypto.sign(:eddsa, :none, hash_data, [private_key, :ed25519])

    Map.put(
      unsecured_statement,
      "proof",
      Map.put(proof_config, "proofValue", multibase(signature))
    )
  end

  defp multibase(binary), do: "z" <> encode_base58btc(binary)

  defp encode_base58btc(binary) do
    leading_zeroes = binary |> :binary.bin_to_list() |> Enum.take_while(&(&1 == 0)) |> length()
    integer = :binary.decode_unsigned(binary)

    encoded =
      if integer == 0 do
        ""
      else
        encode_base58btc_integer(integer, [])
      end

    String.duplicate("1", leading_zeroes) <> encoded
  end

  defp encode_base58btc_integer(0, characters), do: IO.iodata_to_binary(characters)

  defp encode_base58btc_integer(integer, characters) do
    character = binary_part(@base58btc_alphabet, rem(integer, 58), 1)
    encode_base58btc_integer(div(integer, 58), [character | characters])
  end
end

# end of test/pleroma/web/activity_pub/identity_proof_test.exs
