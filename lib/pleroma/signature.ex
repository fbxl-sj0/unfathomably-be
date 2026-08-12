# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Signature do
  @behaviour HTTPSignatures.Adapter

  alias Pleroma.Config
  alias Pleroma.EctoType.ActivityPub.ObjectValidators
  alias Pleroma.HTTP.MessageSignatures
  alias Pleroma.Keys
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ActivityPub

  import Plug.Conn, only: [get_req_header: 2, put_req_header: 3]

  @http_signatures_impl Application.compile_env(
                          :pleroma,
                          [__MODULE__, :http_signatures_impl],
                          HTTPSignatures
                        )

  @known_suffixes ["/publickey", "/main-key"]
  @legacy_signature_max_age_seconds 43_200
  @legacy_signature_clock_skew_seconds 300
  @legacy_payload_methods ["POST", "PUT", "PATCH"]
  @public_key_refetch_cooldown_seconds 300

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
          {:ok, %{"ap_id" => ap_id}} -> {:ok, ap_id}
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
    with kid when is_binary(kid) <- key_id_for_conn(conn),
         {:ok, actor_id} <- key_id_to_actor_id(kid),
         {:ok, public_key} <- User.get_or_fetch_public_key_for_ap_id(actor_id) do
      {:ok, public_key}
    else
      e ->
        {:error, e}
    end
  end

  def refetch_public_key(conn) do
    with kid when is_binary(kid) <- key_id_for_conn(conn),
         {:ok, actor_id} <- key_id_to_actor_id(kid),
         {:ok, public_key} <- refetch_public_key_for_actor(actor_id) do
      {:ok, public_key}
    else
      e ->
        {:error, e}
    end
  end

  def get_actor_id(conn) do
    with kid when is_binary(kid) <- key_id_for_conn(conn),
         {:ok, actor_id} <- key_id_to_actor_id(kid) do
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

  def sign_rfc9421(%User{keys: keys} = user, method, target_uri, headers) do
    with {:ok, private_key, _} <- Keys.keys_from_pem(keys) do
      MessageSignatures.sign(
        private_key,
        user.ap_id <> "#main-key",
        method,
        target_uri,
        headers
      )
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

  @spec validate_signature(map(), String.t()) :: boolean()
  def validate_signature(conn, request_target) do
    # Newer drafts for HTTP signatures now use @request-target instead of the
    # old (request-target). We'll now support both for incoming signatures.
    conn =
      conn
      |> put_req_header("(request-target)", request_target)
      |> put_req_header("@request-target", request_target)

    validate_conn_or_historical_keys(conn)
  end

  @type validation_error :: :invalid_signature | :key_unavailable | atom()
  @type validation_result :: :ok | {:error, validation_error()}

  @spec validate_signature(map()) :: boolean()
  def validate_signature(conn) do
    validate_signature_result(conn) == :ok
  end

  @spec validate_signature_result(map()) :: validation_result()
  def validate_signature_result(conn) do
    if MessageSignatures.present?(conn) do
      validate_message_signature_result(conn)
    else
      if validate_legacy_signature(conn), do: :ok, else: {:error, :invalid_signature}
    end
  end

  defp validate_legacy_signature(conn) do
    signature = signature_for_conn(conn)

    with :ok <- validate_legacy_freshness(conn, signature),
         :ok <- validate_legacy_payload_binding(conn, signature) do
      request_target = String.downcase("#{conn.method}") <> " #{conn.request_path}"
      query_target = request_target <> "?#{conn.query_string}"

      cond do
        # Query parameters affect the requested resource and must be bound by
        # the signature when the sender includes them. Try this form first so a
        # valid path-only signature cannot mask a tampered query string.
        conn.query_string != "" and validate_signature(conn, query_target) ->
          true

        # Old Pleroma and Mastodon-family peers historically signed only the
        # path. Retain that form as a compatibility fallback.
        validate_signature(conn, request_target) ->
          true

        true ->
          false
      end
    else
      _ -> false
    end
  end

  defp validate_legacy_freshness(conn, signature) do
    headers = legacy_signature_headers(signature)

    cond do
      "(created)" in headers ->
        signature
        |> Map.get("created")
        |> parse_legacy_created()
        |> validate_legacy_timestamp()

      "date" in headers ->
        case get_req_header(conn, "date") do
          [date] -> date |> parse_legacy_http_date() |> validate_legacy_timestamp()
          _ -> {:error, :invalid_date}
        end

      true ->
        {:error, :missing_signature_time}
    end
  end

  defp validate_legacy_payload_binding(%{method: method} = conn, signature)
       when method in @legacy_payload_methods do
    headers = legacy_signature_headers(signature)

    cond do
      "digest" in headers and get_req_header(conn, "digest") != [] ->
        :ok

      "content-digest" in headers and
          get_in(conn, [Access.key(:assigns, %{}), :content_digest_valid]) == true ->
        :ok

      true ->
        {:error, :missing_verified_digest}
    end
  end

  defp validate_legacy_payload_binding(_conn, _signature), do: :ok

  defp legacy_signature_headers(%{"headers" => headers}) when is_list(headers) do
    Enum.map(headers, &String.downcase/1)
  end

  defp legacy_signature_headers(_signature), do: []

  defp parse_legacy_created(value) when is_integer(value), do: {:ok, value}

  defp parse_legacy_created(value) when is_binary(value) do
    case Integer.parse(value) do
      {timestamp, ""} -> {:ok, timestamp}
      _ -> {:error, :invalid_created}
    end
  end

  defp parse_legacy_created(_value), do: {:error, :invalid_created}

  defp parse_legacy_http_date(value) when is_binary(value) do
    case :httpd_util.convert_request_date(String.to_charlist(value)) do
      {{year, month, day}, {hour, minute, second}} ->
        with {:ok, naive} <-
               NaiveDateTime.new(year, month, day, hour, minute, second),
             {:ok, datetime} <- DateTime.from_naive(naive, "Etc/UTC") do
          {:ok, DateTime.to_unix(datetime)}
        else
          _ -> {:error, :invalid_date}
        end

      _ ->
        {:error, :invalid_date}
    end
  rescue
    _ -> {:error, :invalid_date}
  catch
    _, _ -> {:error, :invalid_date}
  end

  defp parse_legacy_http_date(_value), do: {:error, :invalid_date}

  defp validate_legacy_timestamp({:ok, timestamp}) do
    now = System.system_time(:second)

    cond do
      timestamp > now + @legacy_signature_clock_skew_seconds ->
        {:error, :signature_from_future}

      timestamp < now - @legacy_signature_max_age_seconds ->
        {:error, :stale_signature}

      true ->
        :ok
    end
  end

  defp validate_legacy_timestamp(error), do: error

  defp validate_message_signature_result(conn) do
    with {:ok, kid} <- MessageSignatures.key_id(conn),
         {:ok, actor_id} <- key_id_to_actor_id(kid) do
      validate_message_signature_for_actor_result(conn, actor_id)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_message_signature_for_actor_result(conn, actor_id) do
    current_result = validate_current_message_signature(conn, actor_id)

    case current_result do
      :ok ->
        :ok

      _ ->
        refreshed_result = validate_refreshed_message_signature(conn, actor_id)

        case refreshed_result do
          :ok ->
            :ok

          _ ->
            case validate_message_signature_with_historical_keys(conn, actor_id) do
              :ok -> :ok
              _ -> final_message_signature_error([current_result, refreshed_result])
            end
        end
    end
  end

  defp validate_current_message_signature(conn, actor_id) do
    actor_id
    |> User.get_or_fetch_public_keys_for_ap_id()
    |> validate_fetched_message_keys(conn)
  end

  defp validate_refreshed_message_signature(conn, actor_id) do
    with {:ok, _public_key} <- refetch_public_key_for_actor(actor_id) do
      actor_id
      |> User.get_or_fetch_public_keys_for_ap_id()
      |> validate_fetched_message_keys(conn)
    else
      error -> classify_key_fetch_error(error)
    end
  end

  # A failed signature can be supplied by an unauthenticated peer, so it must
  # not provide an unlimited synchronous actor-refresh primitive. Fresh actors
  # reuse their cached key; missing or stale actors retain the normal rotation
  # recovery path.
  defp refetch_public_key_for_actor(actor_id) do
    if public_key_refetch_due?(actor_id) do
      with {:ok, _user} <- ActivityPub.make_user_from_ap_id(actor_id) do
        User.get_or_fetch_public_key_for_ap_id(actor_id)
      end
    else
      User.get_or_fetch_public_key_for_ap_id(actor_id)
    end
  end

  defp public_key_refetch_due?(actor_id) do
    case User.get_by_ap_id(actor_id) do
      %User{last_refreshed_at: %NaiveDateTime{} = refreshed_at, public_key: public_key}
      when is_binary(public_key) and public_key != "" ->
        NaiveDateTime.diff(NaiveDateTime.utc_now(), refreshed_at, :second) >=
          public_key_refetch_cooldown_seconds()

      _ ->
        true
    end
  end

  defp public_key_refetch_cooldown_seconds do
    case Config.get(
           [:activitypub, :public_key_refetch_cooldown_seconds],
           @public_key_refetch_cooldown_seconds
         ) do
      seconds when is_integer(seconds) and seconds >= 0 -> seconds
      _ -> @public_key_refetch_cooldown_seconds
    end
  end

  defp validate_fetched_message_keys({:ok, public_keys}, conn) when is_list(public_keys) do
    if Enum.any?(public_keys, &(MessageSignatures.validate_result(conn, &1) == :ok)) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp validate_fetched_message_keys(error, _conn), do: classify_key_fetch_error(error)

  defp validate_message_signature_with_historical_keys(conn, actor_id) do
    with {:ok, public_keys} <- historical_public_keys_for_ap_id(actor_id) do
      if Enum.any?(public_keys, &(MessageSignatures.validate_result(conn, &1) == :ok)) do
        :ok
      else
        {:error, :invalid_signature}
      end
    else
      _ -> {:error, :invalid_signature}
    end
  end

  defp final_message_signature_error(results) do
    if {:error, :key_unavailable} in results do
      {:error, :key_unavailable}
    else
      {:error, :invalid_signature}
    end
  end

  defp classify_key_fetch_error({:error, reason})
       when reason in [:not_found, :forbidden, :unauthorized, :invalid_uri],
       do: {:error, :invalid_signature}

  defp classify_key_fetch_error({:error, {:http, status}})
       when status in [400, 401, 403, 404, 405, 406, 410, 422],
       do: {:error, :invalid_signature}

  defp classify_key_fetch_error(_), do: {:error, :key_unavailable}

  defp validate_conn_or_historical_keys(conn) do
    case signature_for_conn(conn) do
      signature when map_size(signature) > 0 ->
        case apply(@http_signatures_impl, :validate_conn, [conn]) do
          true -> true
          _ -> validate_with_actor_or_historical_keys(conn)
        end

      _ ->
        false
    end
  rescue
    _ -> validate_with_actor_or_historical_keys(conn)
  catch
    _, _ -> validate_with_actor_or_historical_keys(conn)
  end

  defp validate_with_actor_or_historical_keys(conn) do
    validate_with_current_actor_keys(conn) || validate_with_historical_keys(conn)
  end

  defp validate_with_current_actor_keys(conn) do
    with %{"keyId" => kid} <- signature_for_conn(conn),
         {:ok, actor_id} <- key_id_to_actor_id(kid),
         {:ok, public_keys} <- User.get_or_fetch_public_keys_for_ap_id(actor_id) do
      Enum.any?(public_keys, &validate_conn_with_key(conn, &1))
    else
      _ -> false
    end
  end

  defp validate_with_historical_keys(conn) do
    with %{"keyId" => kid} <- signature_for_conn(conn),
         {:ok, actor_id} <- key_id_to_actor_id(kid),
         {:ok, public_keys} <- historical_public_keys_for_ap_id(actor_id) do
      Enum.any?(public_keys, &validate_conn_with_key(conn, &1))
    else
      _ -> false
    end
  end

  defp historical_public_keys_for_ap_id(actor_id) do
    case User.get_historical_public_keys_for_ap_id(actor_id) do
      {:ok, public_keys} ->
        {:ok, public_keys}

      _ ->
        with %User{} = user <- User.get_by_ap_id(actor_id),
             public_keys when public_keys != [] <- User.historical_public_keys(user) do
          {:ok, public_keys}
        else
          _ -> :error
        end
    end
  end

  defp validate_conn_with_key(conn, {:ed25519, public_key})
       when is_binary(public_key) and byte_size(public_key) == 32 do
    headers = Map.new(conn.req_headers)
    signature = signature_for_conn(conn)
    signed_headers = signature["headers"] || []
    algorithm = signature["algorithm"] |> to_string() |> String.downcase()

    headers =
      headers
      |> Map.put("(created)", signature["created"])
      |> Map.put("(expires)", signature["expires"])

    with true <- algorithm in ["hs2019", "ed25519"],
         true <- "host" in signed_headers,
         true <- "(request-target)" in signed_headers or "@request-target" in signed_headers,
         true <- signed_legacy_headers_present?(headers, signed_headers),
         encoded_signature when is_binary(encoded_signature) <- signature["signature"],
         {:ok, decoded_signature} when byte_size(decoded_signature) == 64 <-
           Base.decode64(encoded_signature),
         signing_string <- HTTPSignatures.build_signing_string(headers, signed_headers) do
      :crypto.verify(:eddsa, :none, decoded_signature, signing_string, [public_key, :ed25519])
    else
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp validate_conn_with_key(conn, public_key) do
    HTTPSignatures.validate_conn(conn, public_key) == true
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp signed_legacy_headers_present?(headers, signed_headers) do
    Enum.all?(signed_headers, fn header ->
      case headers[header] do
        value when is_binary(value) -> value != ""
        value when is_integer(value) -> true
        value when is_float(value) -> true
        _ -> false
      end
    end)
  end

  # Authentication parameters are unambiguous only when every name occurs once.
  # The dependency parser otherwise keeps the last value, which lets the key
  # lookup and verification path silently accept a malformed Signature header.
  defp signature_for_conn(conn) do
    with [signature] when is_binary(signature) <- get_req_header(conn, "signature"),
         true <- unique_signature_parameters?(signature) do
      HTTPSignatures.signature_for_conn(conn)
    else
      _ -> %{}
    end
  end

  defp key_id_for_conn(conn) do
    if MessageSignatures.present?(conn) do
      case MessageSignatures.key_id(conn) do
        {:ok, key_id} -> key_id
        _ -> nil
      end
    else
      case signature_for_conn(conn) do
        %{"keyId" => key_id} -> key_id
        _ -> nil
      end
    end
  end

  defp unique_signature_parameters?(signature) do
    parameter_names =
      signature
      |> String.split(",")
      |> Enum.map(fn parameter ->
        parameter
        |> String.split("=", parts: 2)
        |> hd()
        |> String.trim()
        |> String.downcase()
      end)

    parameter_names != [] and "" not in parameter_names and
      length(parameter_names) == MapSet.size(MapSet.new(parameter_names))
  end
end
