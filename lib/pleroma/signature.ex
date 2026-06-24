# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Signature do
  @behaviour HTTPSignatures.Adapter

  alias Pleroma.EctoType.ActivityPub.ObjectValidators
  alias Pleroma.Keys
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Object.Fetcher

  import Plug.Conn, only: [put_req_header: 3]

  @http_signatures_impl Application.compile_env(
                          :pleroma,
                          [__MODULE__, :http_signatures_impl],
                          Pleroma.Signature.HTTPSignatures
                        )

  @known_suffixes ["/publickey", "/main-key"]
  @actor_key_fields [
    "publicKey",
    "verificationMethod",
    "assertionMethod",
    "authentication",
    "capabilityInvocation",
    "capabilityDelegation"
  ]

  def key_id_to_actor_id(key_id) do
    uri =
      key_id
      |> URI.parse()
      |> Map.put(:fragment, nil)
      |> remove_suffix(@known_suffixes)

    maybe_ap_id = URI.to_string(uri)

    case ObjectValidators.ObjectID.cast(maybe_ap_id) do
      {:ok, ap_id} ->
        {:ok, ap_id}

      _ ->
        case Pleroma.Web.WebFinger.finger(maybe_ap_id) do
          %{"ap_id" => ap_id} -> {:ok, ap_id}
          _ -> {:error, maybe_ap_id}
        end
    end
  end

  defp remove_suffix(uri, [test | rest]) do
    if not is_nil(uri.path) and String.ends_with?(uri.path, test) do
      Map.put(uri, :path, String.replace(uri.path, test, ""))
    else
      remove_suffix(uri, rest)
    end
  end

  defp remove_suffix(uri, []), do: uri

  def fetch_public_key(conn) do
    with %{"keyId" => kid} <- HTTPSignatures.signature_for_conn(conn),
         {:ok, actor_id} <- key_id_to_actor_id(kid),
         {:ok, public_key} <- public_key_for_key_id(actor_id, kid, :cached) do
      {:ok, public_key}
    else
      _ ->
        {:error, :error}
    end
  end

  def refetch_public_key(conn) do
    with %{"keyId" => kid} <- HTTPSignatures.signature_for_conn(conn),
         {:ok, actor_id} <- key_id_to_actor_id(kid),
         {:ok, public_key} <- public_key_for_key_id(actor_id, kid, :refetch) do
      {:ok, public_key}
    else
      _ ->
        {:error, :error}
    end
  end

  def get_actor_id(conn) do
    with %{"keyId" => kid} <- HTTPSignatures.signature_for_conn(conn),
         {:ok, actor_id} <- actor_id_for_key_id(kid) do
      {:ok, actor_id}
    else
      e ->
        {:error, e}
    end
  end

  def sign(%User{keys: keys} = user, headers) do
    with {:ok, private_key, _} <- Keys.keys_from_pem(keys) do
      HTTPSignatures.sign(private_key, user.ap_id <> "#main-key", normalize_headers(headers))
    end
  end

  defp normalize_headers(headers) do
    Map.new(headers, fn {key, value} -> {normalize_header_key(key), value} end)
  end

  defp normalize_header_key(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> String.downcase()
  end

  defp normalize_header_key(key) when is_binary(key), do: String.downcase(key)

  def signed_date, do: signed_date(NaiveDateTime.utc_now())

  def signed_date(%NaiveDateTime{} = date) do
    Timex.format!(date, "{WDshort}, {0D} {Mshort} {YYYY} {h24}:{m}:{s} GMT")
  end

  defp public_key_for_key_id(actor_id, key_id, :cached) do
    if primary_key_id?(actor_id, key_id) do
      public_key_for_primary_key_id(actor_id, key_id)
    else
      fetch_public_key_for_key_id(actor_id, key_id)
    end
  end

  defp public_key_for_key_id(actor_id, key_id, :refetch) do
    case ActivityPub.make_user_from_ap_id(actor_id) do
      {:ok, _user} ->
        case fetch_public_key_for_key_id(actor_id, key_id) do
          {:ok, public_key} ->
            {:ok, public_key}

          _ ->
            if primary_key_id?(actor_id, key_id) do
              User.get_or_fetch_public_key_for_ap_id(actor_id)
            else
              fetch_public_key_from_key_document(key_id)
            end
        end

      error ->
        case fetch_public_key_from_key_document(key_id) do
          {:ok, public_key} -> {:ok, public_key}
          _ -> error
        end
    end
  end

  defp public_key_for_primary_key_id(actor_id, key_id) do
    case User.get_or_fetch_public_key_for_ap_id(actor_id) do
      {:ok, public_key} ->
        {:ok, public_key}

      _ ->
        case User.get_cached_by_ap_id(actor_id) do
          %User{local: true} -> :error
          _ -> fetch_public_key_for_key_id(actor_id, key_id)
        end
    end
  end

  defp fetch_public_key_for_key_id(actor_id, key_id) do
    with {:ok, _user} <- User.get_or_fetch_by_ap_id(actor_id),
         {:ok, data} <- Fetcher.fetch_and_contain_remote_object_from_id(actor_id),
         {:ok, public_key} <- public_key_from_actor(data, actor_id, key_id) do
      {:ok, public_key}
    else
      _ -> fetch_public_key_from_key_document(key_id)
    end
  end

  defp fetch_public_key_from_key_document(key_id) do
    with {:ok, key_data} <- Fetcher.fetch_and_contain_remote_object_from_id(key_id),
         {:ok, actor_id} <- key_owner(key_data),
         {:ok, actor_data} <- Fetcher.fetch_and_contain_remote_object_from_id(actor_id),
         true <- actor_references_key?(actor_data, key_id),
         {:ok, public_key} <- public_key_from_key_object(key_data, actor_id, key_id) do
      {:ok, public_key}
    else
      e -> {:error, e}
    end
  end

  defp actor_id_for_key_id(key_id) do
    case key_id_to_actor_id(key_id) do
      {:ok, ^key_id} ->
        case actor_id_from_key_document(key_id) do
          {:ok, actor_id} -> {:ok, actor_id}
          _ -> {:ok, key_id}
        end

      {:ok, actor_id} ->
        {:ok, actor_id}

      _ ->
        actor_id_from_key_document(key_id)
    end
  end

  defp actor_id_from_key_document(key_id) do
    with {:ok, key_data} <- Fetcher.fetch_and_contain_remote_object_from_id(key_id),
         {:ok, actor_id} <- key_owner(key_data) do
      {:ok, actor_id}
    end
  end

  defp primary_key_id?(actor_id, key_id) do
    key_id in [
      actor_id,
      actor_id <> "#main-key",
      actor_id <> "/main-key",
      actor_id <> "/publickey"
    ]
  end

  defp public_key_from_pem(public_key_pem) do
    User.public_key(%{public_key: public_key_pem})
  rescue
    _ -> {:error, :invalid_public_key}
  end

  defp public_key_from_actor(data, actor_id, key_id) do
    data
    |> actor_key_objects()
    |> Enum.find_value(fn key_data ->
      case public_key_from_key_object(key_data, actor_id, key_id) do
        {:ok, public_key} -> public_key
        _ -> nil
      end
    end)
    |> case do
      public_key when is_tuple(public_key) -> {:ok, public_key}
      _ -> {:error, :public_key_not_found}
    end
  end

  defp public_key_from_key_object(key_data, actor_id, key_id) when is_map(key_data) do
    with %{"id" => ^key_id} <- key_data,
         true <- key_belongs_to_actor?(key_data, actor_id),
         {:ok, public_key} <- public_key_from_key_data(key_data) do
      {:ok, public_key}
    else
      _ -> {:error, :public_key_not_found}
    end
  end

  defp public_key_from_key_object(_, _, _), do: {:error, :public_key_not_found}

  defp public_key_from_key_data(%{"publicKeyPem" => public_key_pem})
       when is_binary(public_key_pem) do
    public_key_from_pem(public_key_pem)
  end

  defp public_key_from_key_data(%{"publicKeyMultibase" => public_key_multibase})
       when is_binary(public_key_multibase) do
    public_key_from_multibase(public_key_multibase)
  end

  defp public_key_from_key_data(%{"publicKeyJwk" => public_key_jwk})
       when is_map(public_key_jwk) do
    public_key_from_jwk(public_key_jwk)
  end

  defp public_key_from_key_data(_), do: {:error, :public_key_not_found}

  defp public_key_from_multibase("z" <> encoded) do
    with {:ok, <<0xED, 0x01, public_key::binary-size(32)>>} <- base58btc_decode(encoded) do
      {:ok, {:ed25519_public_key, public_key}}
    else
      _ -> {:error, :invalid_public_key}
    end
  end

  defp public_key_from_multibase(_), do: {:error, :invalid_public_key}

  defp public_key_from_jwk(%{"kty" => "OKP", "crv" => "Ed25519", "x" => encoded} = jwk)
       when is_binary(encoded) do
    with false <- Map.has_key?(jwk, "d"),
         {:ok, public_key} <- base64url_decode(encoded),
         32 <- byte_size(public_key) do
      {:ok, {:ed25519_public_key, public_key}}
    else
      _ -> {:error, :invalid_public_key}
    end
  end

  defp public_key_from_jwk(_), do: {:error, :invalid_public_key}

  @base58btc_decode_map ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
                        |> Enum.with_index()
                        |> Map.new()

  defp base58btc_decode(value) when is_binary(value) and byte_size(value) > 0 do
    with {:ok, number} <- base58btc_number(value) do
      leading_zeroes =
        value
        |> :binary.bin_to_list()
        |> Enum.take_while(&(&1 == ?1))
        |> length()

      decoded =
        if number == 0 do
          <<>>
        else
          :binary.encode_unsigned(number)
        end

      {:ok, :binary.copy(<<0>>, leading_zeroes) <> decoded}
    end
  end

  defp base58btc_decode(_), do: {:error, :invalid_base58btc}

  defp base58btc_number(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.reduce_while({:ok, 0}, fn char, {:ok, number} ->
      case Map.fetch(@base58btc_decode_map, char) do
        {:ok, digit} -> {:cont, {:ok, number * 58 + digit}}
        :error -> {:halt, {:error, :invalid_base58btc}}
      end
    end)
  end

  defp base64url_decode(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> Base.url_decode64(value, padding: true)
    end
  end

  defp actor_key_objects(data) when is_map(data) do
    @actor_key_fields
    |> Enum.flat_map(fn key -> embedded_key_objects(Map.get(data, key), data) end)
    |> Enum.uniq_by(&Map.get(&1, "id"))
  end

  defp actor_key_objects(_), do: []

  defp embedded_key_objects(values, actor_data) when is_list(values) do
    Enum.flat_map(values, &embedded_key_objects(&1, actor_data))
  end

  defp embedded_key_objects(%{"publicKeyPem" => public_key_pem} = key_data, _actor_data)
       when is_binary(public_key_pem) do
    [key_data]
  end

  defp embedded_key_objects(
         %{"publicKeyMultibase" => public_key_multibase} = key_data,
         _actor_data
       )
       when is_binary(public_key_multibase) do
    [key_data]
  end

  defp embedded_key_objects(%{"publicKeyJwk" => public_key_jwk} = key_data, _actor_data)
       when is_map(public_key_jwk) do
    [key_data]
  end

  defp embedded_key_objects(%{"publicKey" => public_key} = key_data, actor_data) do
    inherited = Map.take(key_data, ["id", "owner", "controller"])

    public_key
    |> embedded_key_objects(actor_data)
    |> Enum.map(&Map.merge(inherited, &1))
  end

  defp embedded_key_objects(key_id, _actor_data) when is_binary(key_id), do: []

  defp embedded_key_objects(_, _actor_data), do: []

  defp actor_references_key?(actor_data, key_id) do
    raw_reference? =
      actor_data
      |> actor_key_values()
      |> Enum.any?(fn
        ^key_id -> true
        %{"id" => ^key_id} -> true
        _ -> false
      end)

    embedded_reference? =
      actor_data
      |> actor_key_objects()
      |> Enum.any?(&(Map.get(&1, "id") == key_id))

    raw_reference? or embedded_reference?
  end

  defp actor_key_values(data) when is_map(data) do
    Enum.flat_map(@actor_key_fields, fn key -> List.wrap(Map.get(data, key)) end)
  end

  defp actor_key_values(_), do: []

  defp key_belongs_to_actor?(key_data, actor_id) do
    case key_owner(key_data) do
      {:ok, ^actor_id} -> true
      _ -> key_id_belongs_to_actor?(Map.get(key_data, "id"), actor_id)
    end
  end

  defp key_owner(%{"owner" => owner}) when is_binary(owner), do: {:ok, owner}
  defp key_owner(%{"controller" => controller}) when is_binary(controller), do: {:ok, controller}

  defp key_owner(%{"owner" => owners}) when is_list(owners) do
    owners
    |> Enum.find(&is_binary/1)
    |> case do
      owner when is_binary(owner) -> {:ok, owner}
      _ -> {:error, :key_owner_not_found}
    end
  end

  defp key_owner(%{"controller" => controllers}) when is_list(controllers) do
    controllers
    |> Enum.find(&is_binary/1)
    |> case do
      controller when is_binary(controller) -> {:ok, controller}
      _ -> {:error, :key_owner_not_found}
    end
  end

  defp key_owner(_), do: {:error, :key_owner_not_found}

  defp key_id_belongs_to_actor?(key_id, actor_id) when is_binary(key_id) do
    case key_id_to_actor_id(key_id) do
      {:ok, ^actor_id} -> true
      _ -> false
    end
  end

  defp key_id_belongs_to_actor?(_, _), do: false

  @spec validate_signature(map(), String.t()) :: boolean()
  def validate_signature(conn, request_target) do
    # Newer drafts for HTTP signatures now use @request-target instead of the
    # old (request-target). We'll now support both for incoming signatures.
    conn =
      conn
      |> put_req_header("(request-target)", request_target)
      |> put_req_header("@request-target", request_target)

    apply(@http_signatures_impl, :validate_conn, [conn]) == true
  end

  @spec validate_signature(map()) :: boolean()
  def validate_signature(conn) do
    # This (request-target) is non-standard, but many implementations do it
    # this way due to a misinterpretation of
    # https://datatracker.ietf.org/doc/html/draft-cavage-http-signatures-06
    # "path" was interpreted as not having the query, though later examples
    # show that it must be the absolute path + query. This behavior is kept to
    # make sure most software (Pleroma itself, Mastodon, and probably others)
    # do not break.
    request_target = String.downcase("#{conn.method}") <> " #{conn.request_path}"

    # This is the proper way to build the @request-target, as expected by
    # many HTTP signature libraries, clarified in the following draft:
    # https://www.ietf.org/archive/id/draft-ietf-httpbis-message-signatures-11.html#section-2.2.6
    # It is the same as before, but containing the query part as well.
    proper_target = request_target <> "?#{conn.query_string}"

    cond do
      # Normal, non-standard behavior but expected by Pleroma and more.
      validate_signature(conn, request_target) ->
        true

      # Has query string and the previous one failed: let's try the standard.
      conn.query_string != "" ->
        validate_signature(conn, proper_target)

      # If there's no query string and signature fails, it's rotten.
      true ->
        false
    end
  end
end
