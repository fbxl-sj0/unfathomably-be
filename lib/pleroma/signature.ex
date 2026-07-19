# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Signature do
  @behaviour HTTPSignatures.Adapter

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
         {:ok, _user} <- ActivityPub.make_user_from_ap_id(actor_id),
         {:ok, public_key} <- User.get_or_fetch_public_key_for_ap_id(actor_id) do
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
    |> User.get_or_fetch_public_key_for_ap_id()
    |> validate_fetched_message_key(conn)
  end

  defp validate_refreshed_message_signature(conn, actor_id) do
    with {:ok, _user} <- ActivityPub.make_user_from_ap_id(actor_id) do
      actor_id
      |> User.get_or_fetch_public_key_for_ap_id()
      |> validate_fetched_message_key(conn)
    else
      error -> classify_key_fetch_error(error)
    end
  end

  defp validate_fetched_message_key({:ok, public_key}, conn) do
    MessageSignatures.validate_result(conn, public_key)
  end

  defp validate_fetched_message_key(error, _conn), do: classify_key_fetch_error(error)

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
          _ -> validate_with_historical_keys(conn)
        end

      _ ->
        false
    end
  rescue
    _ -> validate_with_historical_keys(conn)
  catch
    _, _ -> validate_with_historical_keys(conn)
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

  defp validate_conn_with_key(conn, public_key) do
    HTTPSignatures.validate_conn(conn, public_key) == true
  rescue
    _ -> false
  catch
    _, _ -> false
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
