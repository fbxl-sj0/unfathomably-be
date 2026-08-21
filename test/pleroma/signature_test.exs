# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.SignatureTest do
  use Pleroma.DataCase

  import ExUnit.CaptureLog
  import Pleroma.Factory
  import Tesla.Mock
  import Mock

  alias Pleroma.Keys
  alias Pleroma.Signature
  alias Pleroma.StubbedHTTPSignaturesMock, as: HTTPSignaturesMock
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ActivityPub

  @base58btc_alphabet "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

  setup do
    clear_config([:instance, :federating], true)
    mock(fn env -> apply(HttpRequestMock, :request, [env]) end)
    :ok
  end

  @private_key "-----BEGIN RSA PRIVATE KEY-----\nMIIEpQIBAAKCAQEA48qb4v6kqigZutO9Ot0wkp27GIF2LiVaADgxQORZozZR63jH\nTaoOrS3Xhngbgc8SSOhfXET3omzeCLqaLNfXnZ8OXmuhJfJSU6mPUvmZ9QdT332j\nfN/g3iWGhYMf/M9ftCKh96nvFVO/tMruzS9xx7tkrfJjehdxh/3LlJMMImPtwcD7\nkFXwyt1qZTAU6Si4oQAJxRDQXHp1ttLl3Ob829VM7IKkrVmY8TD+JSlV0jtVJPj6\n1J19ytKTx/7UaucYvb9HIiBpkuiy5n/irDqKLVf5QEdZoNCdojOZlKJmTLqHhzKP\n3E9TxsUjhrf4/EqegNc/j982RvOxeu4i40zMQwIDAQABAoIBAQDH5DXjfh21i7b4\ncXJuw0cqget617CDUhemdakTDs9yH+rHPZd3mbGDWuT0hVVuFe4vuGpmJ8c+61X0\nRvugOlBlavxK8xvYlsqTzAmPgKUPljyNtEzQ+gz0I+3mH2jkin2rL3D+SksZZgKm\nfiYMPIQWB2WUF04gB46DDb2mRVuymGHyBOQjIx3WC0KW2mzfoFUFRlZEF+Nt8Ilw\nT+g/u0aZ1IWoszbsVFOEdghgZET0HEarum0B2Je/ozcPYtwmU10iBANGMKdLqaP/\nj954BPunrUf6gmlnLZKIKklJj0advx0NA+cL79+zeVB3zexRYSA5o9q0WPhiuTwR\n/aedWHnBAoGBAP0sDWBAM1Y4TRAf8ZI9PcztwLyHPzfEIqzbObJJnx1icUMt7BWi\n+/RMOnhrlPGE1kMhOqSxvXYN3u+eSmWTqai2sSH5Hdw2EqnrISSTnwNUPINX7fHH\njEkgmXQ6ixE48SuBZnb4w1EjdB/BA6/sjL+FNhggOc87tizLTkMXmMtTAoGBAOZV\n+wPuAMBDBXmbmxCuDIjoVmgSlgeRunB1SA8RCPAFAiUo3+/zEgzW2Oz8kgI+xVwM\n33XkLKrWG1Orhpp6Hm57MjIc5MG+zF4/YRDpE/KNG9qU1tiz0UD5hOpIU9pP4bR/\ngxgPxZzvbk4h5BfHWLpjlk8UUpgk6uxqfti48c1RAoGBALBOKDZ6HwYRCSGMjUcg\n3NPEUi84JD8qmFc2B7Tv7h2he2ykIz9iFAGpwCIyETQsJKX1Ewi0OlNnD3RhEEAy\nl7jFGQ+mkzPSeCbadmcpYlgIJmf1KN/x7fDTAepeBpCEzfZVE80QKbxsaybd3Dp8\nCfwpwWUFtBxr4c7J+gNhAGe/AoGAPn8ZyqkrPv9wXtyfqFjxQbx4pWhVmNwrkBPi\nZ2Qh3q4dNOPwTvTO8vjghvzIyR8rAZzkjOJKVFgftgYWUZfM5gE7T2mTkBYq8W+U\n8LetF+S9qAM2gDnaDx0kuUTCq7t87DKk6URuQ/SbI0wCzYjjRD99KxvChVGPBHKo\n1DjqMuECgYEAgJGNm7/lJCS2wk81whfy/ttKGsEIkyhPFYQmdGzSYC5aDc2gp1R3\nxtOkYEvdjfaLfDGEa4UX8CHHF+w3t9u8hBtcdhMH6GYb9iv6z0VBTt4A/11HUR49\n3Z7TQ18Iyh3jAUCzFV9IJlLIExq5Y7P4B3ojWFBN607sDCt8BMPbDYs=\n-----END RSA PRIVATE KEY-----"

  @public_key "-----BEGIN PUBLIC KEY-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAw0P/Tq4gb4G/QVuMGbJo\nC/AfMNcv+m7NfrlOwkVzcU47jgESuYI4UtJayissCdBycHUnfVUd9qol+eznSODz\nCJhfJloqEIC+aSnuEPGA0POtWad6DU0E6/Ho5zQn5WAWUwbRQqowbrsm/GHo2+3v\neR5jGenwA6sYhINg/c3QQbksyV0uJ20Umyx88w8+TJuv53twOfmyDWuYNoQ3y5cc\nHKOZcLHxYOhvwg3PFaGfFHMFiNmF40dTXt9K96r7sbzc44iLD+VphbMPJEjkMuf8\nPGEFOBzy8pm3wJZw2v32RNW2VESwMYyqDzwHXGSq1a73cS7hEnc79gXlELsK04L9\nQQIDAQAB\n-----END PUBLIC KEY-----\n"

  @rsa_public_key {
    :RSAPublicKey,
    24_650_000_183_914_698_290_885_268_529_673_621_967_457_234_469_123_179_408_466_269_598_577_505_928_170_923_974_132_111_403_341_217_239_999_189_084_572_368_839_502_170_501_850_920_051_662_384_964_248_315_257_926_552_945_648_828_895_432_624_227_029_881_278_113_244_073_644_360_744_504_606_177_648_469_825_063_267_913_017_309_199_785_535_546_734_904_379_798_564_556_494_962_268_682_532_371_146_333_972_821_570_577_277_375_020_977_087_539_994_500_097_107_935_618_711_808_260_846_821_077_839_605_098_669_707_417_692_791_905_543_116_911_754_774_323_678_879_466_618_738_207_538_013_885_607_095_203_516_030_057_611_111_308_904_599_045_146_148_350_745_339_208_006_497_478_057_622_336_882_506_112_530_056_970_653_403_292_123_624_453_213_574_011_183_684_739_084_105_206_483_178_943_532_208_537_215_396_831_110_268_758_639_826_369_857,
    # credo:disable-for-previous-line Credo.Check.Readability.MaxLineLength
    65_537
  }

  defp make_fake_signature(key_id), do: "keyId=\"#{key_id}\""

  defp make_fake_conn(key_id),
    do: %Plug.Conn{req_headers: %{"signature" => make_fake_signature(key_id <> "#main-key")}}

  defp public_key_pem_from_private_key_pem(private_key_pem) do
    {:ok, _private_key, public_key} = Keys.keys_from_pem(private_key_pem)

    public_key_entry = :public_key.pem_entry_encode(:SubjectPublicKeyInfo, public_key)

    [public_key_entry]
    |> :public_key.pem_encode()
    |> IO.iodata_to_binary()
  end

  defp base58btc_encode(binary) do
    leading_zeroes = binary |> :binary.bin_to_list() |> Enum.take_while(&(&1 == 0)) |> length()
    encoded = binary |> :binary.decode_unsigned() |> encode_base58btc_integer("")
    String.duplicate("1", leading_zeroes) <> encoded
  end

  defp encode_base58btc_integer(0, encoded), do: encoded

  defp encode_base58btc_integer(integer, encoded) do
    character = binary_part(@base58btc_alphabet, rem(integer, 58), 1)
    encode_base58btc_integer(div(integer, 58), character <> encoded)
  end

  describe "Ed25519 actor keys" do
    test "extracts actor-controlled JWK and Multikey representations once" do
      {public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519)
      actor_id = "https://remote.example/users/alice"
      multibase = "z" <> base58btc_encode(<<0xED, 0x01, public_key::binary>>)

      actor = %{
        "id" => actor_id,
        "verificationMethod" => [
          %{
            "id" => actor_id <> "#jwk",
            "controller" => actor_id,
            "publicKeyJwk" => %{
              "kty" => "OKP",
              "crv" => "Ed25519",
              "x" => Base.url_encode64(public_key, padding: false)
            }
          },
          %{
            "id" => actor_id <> "#multikey",
            "controller" => actor_id,
            "publicKeyMultibase" => multibase
          }
        ]
      }

      assert [pem] = Keys.ed25519_public_key_pems(actor)
      assert Keys.public_keys_from_pem(pem) == [{:ed25519, public_key}]
    end

    test "rejects Ed25519 methods controlled by another actor" do
      {public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519)

      actor = %{
        "id" => "https://remote.example/users/alice",
        "verificationMethod" => [
          %{
            "id" => "https://remote.example/users/mallory#key",
            "controller" => "https://remote.example/users/mallory",
            "publicKeyJwk" => %{
              "kty" => "OKP",
              "crv" => "Ed25519",
              "x" => Base.url_encode64(public_key, padding: false)
            }
          }
        ]
      }

      assert Keys.ed25519_public_key_pems(actor) == []
    end
  end

  describe "fetch_public_key/1" do
    test "it returns key" do
      expected_result = {:ok, @rsa_public_key}

      user = insert(:user, public_key: @public_key)

      assert Signature.fetch_public_key(make_fake_conn(user.ap_id)) == expected_result
    end

    test "it returns error when not found user" do
      capture_log(fn ->
        assert Signature.fetch_public_key(make_fake_conn("https://test-ap-id")) ==
                 {:error, :error}
      end)
    end

    test "it returns error if public key is nil" do
      user = insert(:user, public_key: nil)

      assert Signature.fetch_public_key(make_fake_conn(user.ap_id)) == {:error, :error}
    end

    test "it returns error if public key is malformed" do
      user = insert(:user, public_key: "not a pem")

      assert Signature.fetch_public_key(make_fake_conn(user.ap_id)) == {:error, :error}
    end
  end

  describe "refetch_public_key/1" do
    test "it returns key" do
      ap_id = "https://mastodon.social/users/lambadalambda"

      assert Signature.refetch_public_key(make_fake_conn(ap_id)) == {:ok, @rsa_public_key}
    end

    test "it returns error when not found user" do
      capture_log(fn ->
        {:error, _} = Signature.refetch_public_key(make_fake_conn("https://test-ap_id"))
      end)
    end

    test "reuses a recently refreshed actor key without another remote fetch" do
      actor_id = "https://remote.example/users/recent-key"

      insert(:user,
        ap_id: actor_id,
        local: false,
        public_key: @public_key,
        last_refreshed_at: NaiveDateTime.utc_now()
      )

      with_mock(ActivityPub,
        make_user_from_ap_id: fn ^actor_id ->
          flunk("a fresh actor key must not trigger a remote actor fetch")
        end
      ) do
        assert Signature.refetch_public_key(make_fake_conn(actor_id)) == {:ok, @rsa_public_key}
        assert_not_called(ActivityPub.make_user_from_ap_id(actor_id))
      end
    end
  end

  describe "sign/2" do
    test "it returns signature headers" do
      user =
        insert(:user, %{
          ap_id: "https://mastodon.social/users/lambadalambda",
          keys: @private_key
        })

      assert Signature.sign(
               user,
               %{
                 host: "test.test",
                 "content-length": 100
               }
             ) ==
               "keyId=\"https://mastodon.social/users/lambadalambda#main-key\",algorithm=\"rsa-sha256\",headers=\"content-length host\",signature=\"sibUOoqsFfTDerquAkyprxzDjmJm6erYc42W5w1IyyxusWngSinq5ILTjaBxFvfarvc7ci1xAi+5gkBwtshRMWm7S+Uqix24Yg5EYafXRun9P25XVnYBEIH4XQ+wlnnzNIXQkU3PU9e6D8aajDZVp3hPJNeYt1gIPOA81bROI8/glzb1SAwQVGRbqUHHHKcwR8keiR/W2h7BwG3pVRy4JgnIZRSW7fQogKedDg02gzRXwUDFDk0pr2p3q6bUWHUXNV8cZIzlMK+v9NlyFbVYBTHctAR26GIAN6Hz0eV0mAQAePHDY1mXppbA8Gpp6hqaMuYfwifcXmcc+QFm4e+n3A==\""
    end

    test "it returns error" do
      user = insert(:user, %{ap_id: "https://mastodon.social/users/lambadalambda", keys: ""})

      assert Signature.sign(
               user,
               %{host: "test.test", "content-length": 100}
             ) == {:error, []}
    end
  end

  describe "validate_signature/1" do
    test "validates a legacy hs2019 signature with an Ed25519 actor key" do
      {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

      user =
        insert(:user,
          local: false,
          public_key: Keys.ed25519_public_key_to_pem(public_key),
          last_refreshed_at: NaiveDateTime.utc_now()
        )

      date = Signature.signed_date()
      signed_headers = ["(request-target)", "date", "host"]

      signing_string =
        HTTPSignatures.build_signing_string(
          %{
            "(request-target)" => "get /inbox",
            "date" => date,
            "host" => "example.com"
          },
          signed_headers
        )

      encoded_signature =
        :crypto.sign(:eddsa, :none, signing_string, [private_key, :ed25519])
        |> Base.encode64()

      signature =
        ~s(keyId="#{user.ap_id}#ed25519-key",algorithm="hs2019",) <>
          ~s(headers="#{Enum.join(signed_headers, " ")}",signature="#{encoded_signature}")

      conn = %Plug.Conn{
        method: "GET",
        request_path: "/inbox",
        query_string: "",
        req_headers: [
          {"host", "example.com"},
          {"date", date},
          {"signature", signature}
        ]
      }

      assert [{:ed25519, ^public_key}] = User.public_keys(user)

      assert {:ok, [{:ed25519, ^public_key}]} =
               User.get_or_fetch_public_keys_for_ap_id(user.ap_id)

      parsed_signature = HTTPSignatures.signature_for_conn(conn)
      assert parsed_signature["headers"] == signed_headers

      verification_headers =
        conn.req_headers
        |> Map.new()
        |> Map.put("(request-target)", "get /inbox")
        |> Map.put("(created)", parsed_signature["created"])
        |> Map.put("(expires)", parsed_signature["expires"])

      assert :crypto.verify(
               :eddsa,
               :none,
               HTTPSignatures.build_signing_string(verification_headers, signed_headers),
               Base.decode64!(parsed_signature["signature"]),
               [public_key, :ed25519]
             )

      Mox.expect(HTTPSignaturesMock, :validate_conn, fn _conn -> false end)

      assert Signature.validate_signature(conn)
    end

    test "rejects duplicate legacy Signature parameters before validation" do
      conn = %Plug.Conn{
        method: "POST",
        request_path: "/inbox",
        query_string: "",
        req_headers: [
          {"signature",
           "keyId=\"https://example.com/first#main-key\",KEYID=\"https://example.com/second#main-key\""}
        ]
      }

      refute Signature.validate_signature(conn)
    end

    test "treats HTTP signature errors as failed validation" do
      user = insert(:user)
      date = Signature.signed_date()

      conn = %Plug.Conn{
        method: "GET",
        request_path: "/inbox",
        req_headers: [
          {"host", "example.com"},
          {"date", date},
          {"signature",
           "keyId=\"#{user.ap_id}#main-key\",headers=\"(request-target) date host\",signature=\"invalid\""}
        ]
      }

      Mox.expect(HTTPSignaturesMock, :validate_conn, fn _conn ->
        {:error, :request_target_header}
      end)

      assert Signature.validate_signature(conn) == false
    end

    test "rejects legacy signatures without a signed time" do
      conn = %Plug.Conn{
        method: "GET",
        request_path: "/inbox",
        query_string: "",
        req_headers: [
          {"host", "example.com"},
          {"signature",
           "keyId=\"https://example.com/users/alice#main-key\",headers=\"(request-target) host\",signature=\"invalid\""}
        ]
      }

      refute Signature.validate_signature(conn)
    end

    test "rejects stale legacy signatures before key validation" do
      conn = %Plug.Conn{
        method: "GET",
        request_path: "/inbox",
        query_string: "",
        req_headers: [
          {"host", "example.com"},
          {"date", "Fri, 23 Aug 2019 18:11:24 GMT"},
          {"signature",
           "keyId=\"https://example.com/users/alice#main-key\",headers=\"(request-target) date host\",signature=\"invalid\""}
        ]
      }

      refute Signature.validate_signature(conn)
    end

    test "rejects body-bearing legacy signatures without a signed digest" do
      conn = %Plug.Conn{
        method: "POST",
        request_path: "/inbox",
        query_string: "",
        req_headers: [
          {"host", "example.com"},
          {"date", Signature.signed_date()},
          {"signature",
           "keyId=\"https://example.com/users/alice#main-key\",headers=\"(request-target) date host\",signature=\"invalid\""}
        ]
      }

      refute Signature.validate_signature(conn)
    end

    test "falls back to historical public keys" do
      historical_public_key = public_key_pem_from_private_key_pem(@private_key)
      user = insert(:user, public_key: nil, public_key_history: [historical_public_key])
      date = Signature.signed_date()

      signature =
        Signature.sign(%User{ap_id: user.ap_id, keys: @private_key}, %{
          "host" => "example.com",
          "date" => date,
          "(request-target)" => "get /inbox"
        })

      conn = %Plug.Conn{
        method: "GET",
        request_path: "/inbox",
        query_string: "",
        req_headers: [
          {"host", "example.com"},
          {"date", date},
          {"signature", signature}
        ]
      }

      Mox.expect(HTTPSignaturesMock, :validate_conn, fn _conn -> false end)

      assert Signature.validate_signature(conn)
    end
  end

  describe "key_id_to_actor_id/1" do
    test "it properly deduces the actor id for misskey" do
      assert Signature.key_id_to_actor_id("https://example.com/users/1234/publickey") ==
               {:ok, "https://example.com/users/1234"}
    end

    test "it properly deduces the actor id for mastodon and pleroma" do
      assert Signature.key_id_to_actor_id("https://example.com/users/1234#main-key") ==
               {:ok, "https://example.com/users/1234"}
    end

    test "it deduces the actor id for gotoSocial" do
      assert Signature.key_id_to_actor_id("https://example.com/users/1234/main-key") ==
               {:ok, "https://example.com/users/1234"}
    end

    test "it calls webfinger for 'acct:' accounts" do
      with_mock(Pleroma.Web.WebFinger,
        finger: fn _ -> {:ok, %{"ap_id" => "https://gensokyo.2hu/users/raymoo"}} end
      ) do
        assert Signature.key_id_to_actor_id("acct:raymoo@gensokyo.2hu") ==
                 {:ok, "https://gensokyo.2hu/users/raymoo"}
      end
    end
  end

  describe "signed_date" do
    test "it returns formatted current date" do
      with_mock(NaiveDateTime, utc_now: fn -> ~N[2019-08-23 18:11:24.822233] end) do
        assert Signature.signed_date() == "Fri, 23 Aug 2019 18:11:24 GMT"
      end
    end

    test "it returns formatted date" do
      assert Signature.signed_date(~N[2019-08-23 08:11:24.822233]) ==
               "Fri, 23 Aug 2019 08:11:24 GMT"
    end
  end
end
