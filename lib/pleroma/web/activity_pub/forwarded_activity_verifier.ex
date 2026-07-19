# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ForwardedActivityVerifier do
  @moduledoc """
  Authenticates narrowly scoped inbox-forwarded Create activities.

  Legacy `RsaSignature2017` proofs require obsolete JSON-LD processing whose
  behavior differs between implementations. The embedded proof is therefore
  used only as a forwarding marker. Authorization comes from fetching the
  canonical activity from its HTTPS origin and applying strict actor, object,
  audience, and forwarder checks before that canonical document is processed.

  This intentionally does not authorize destructive or private activities.
  """

  alias Pleroma.Object.Fetcher
  alias Pleroma.Web.ActivityPub.Utils

  require Logger

  @legacy_signature_type "RsaSignature2017"
  @public "https://www.w3.org/ns/activitystreams#Public"
  @allowed_types ["Create"]
  @clock_skew_seconds 300
  @maximum_age_seconds 7 * 24 * 60 * 60
  @maximum_uri_bytes 2_048
  @minimum_rsa_signature_bytes 128
  @maximum_rsa_signature_bytes 1_024

  @type verification_error ::
          :invalid_forwarded_activity
          | :invalid_legacy_signature
          | :forwarder_not_addressed
          | :non_public_activity
          | :origin_mismatch
          | {:origin_fetch, term()}

  @spec verify_and_fetch(map(), String.t(), (String.t() -> {:ok, map()} | {:error, term()})) ::
          {:ok, map()} | {:error, verification_error()}
  def verify_and_fetch(
        data,
        signature_actor_id,
        fetcher \\ &Fetcher.fetch_and_contain_remote_object_from_id/1
      )

  def verify_and_fetch(%{} = data, signature_actor_id, fetcher)
      when is_binary(signature_actor_id) and is_function(fetcher, 1) do
    with :ok <- validate_forwarded_envelope(data),
         :ok <- validate_legacy_signature(data["signature"], data["actor"]),
         {:ok, canonical} <- fetch_origin(fetcher, data["id"]),
         :ok <- validate_canonical_activity(data, canonical, signature_actor_id) do
      Logger.info(
        "Accepted origin-authenticated forwarded Create activity " <>
          "activity_id=#{inspect(canonical["id"])} " <>
          "actor=#{inspect(canonical["actor"])} " <>
          "forwarder=#{inspect(signature_actor_id)}"
      )

      {:ok, Map.delete(canonical, "signature")}
    end
  end

  def verify_and_fetch(_, _, _), do: {:error, :invalid_forwarded_activity}

  defp validate_forwarded_envelope(%{
         "id" => activity_id,
         "type" => type,
         "actor" => actor_id,
         "object" => object
       })
       when type in @allowed_types and is_map(object) do
    object_id = Utils.get_ap_id(object)

    with :ok <- validate_https_uri(activity_id),
         :ok <- validate_https_uri(actor_id),
         :ok <- validate_https_uri(object_id),
         true <- same_origin?(activity_id, actor_id),
         true <- same_origin?(activity_id, object_id),
         true <- actor_id in ids(object["attributedTo"] || object["actor"]) do
      :ok
    else
      _ -> {:error, :origin_mismatch}
    end
  end

  defp validate_forwarded_envelope(_), do: {:error, :invalid_forwarded_activity}

  defp validate_legacy_signature(
         %{
           "type" => @legacy_signature_type,
           "creator" => creator,
           "created" => created,
           "signatureValue" => signature_value
         } = signature,
         actor_id
       )
       when is_binary(creator) and is_binary(created) and is_binary(signature_value) and
              is_binary(actor_id) do
    with true <- creator_for_actor?(creator, actor_id),
         {:ok, decoded_signature} <- Base.decode64(signature_value),
         true <-
           byte_size(decoded_signature) in @minimum_rsa_signature_bytes..@maximum_rsa_signature_bytes,
         {:ok, created_at, _offset} <- DateTime.from_iso8601(created),
         :ok <- validate_created_at(created_at),
         :ok <- validate_expiry(signature["expires"]) do
      :ok
    else
      _ -> {:error, :invalid_legacy_signature}
    end
  end

  defp validate_legacy_signature(_, _), do: {:error, :invalid_legacy_signature}

  defp validate_created_at(created_at) do
    now = DateTime.utc_now()
    age = DateTime.diff(now, created_at, :second)

    if age >= -@clock_skew_seconds and age <= @maximum_age_seconds do
      :ok
    else
      {:error, :invalid_legacy_signature}
    end
  end

  defp validate_expiry(nil), do: :ok

  defp validate_expiry(expires) when is_binary(expires) do
    with {:ok, expires_at, _offset} <- DateTime.from_iso8601(expires),
         true <- DateTime.diff(expires_at, DateTime.utc_now(), :second) >= -@clock_skew_seconds do
      :ok
    else
      _ -> {:error, :invalid_legacy_signature}
    end
  end

  defp validate_expiry(_), do: {:error, :invalid_legacy_signature}

  defp fetch_origin(fetcher, activity_id) do
    case fetcher.(activity_id) do
      {:ok, %{} = canonical} -> {:ok, canonical}
      {:error, reason} -> {:error, {:origin_fetch, reason}}
      _ -> {:error, {:origin_fetch, :invalid_response}}
    end
  end

  defp validate_canonical_activity(forwarded, canonical, signature_actor_id) do
    forwarded_object_id = Utils.get_ap_id(forwarded["object"])
    canonical_object = canonical["object"]
    canonical_object_id = Utils.get_ap_id(canonical_object)
    actor_id = canonical["actor"]
    targets = delivery_targets(canonical)

    with true <- canonical["id"] == forwarded["id"],
         true <- canonical["type"] == forwarded["type"],
         true <- actor_id == forwarded["actor"],
         true <- is_map(canonical_object),
         true <- canonical_object_id == forwarded_object_id,
         true <- actor_id in ids(canonical_object["attributedTo"] || canonical_object["actor"]),
         true <- same_origin?(canonical["id"], actor_id),
         true <- same_origin?(canonical["id"], canonical_object_id) do
      cond do
        @public not in targets -> {:error, :non_public_activity}
        signature_actor_id not in targets -> {:error, :forwarder_not_addressed}
        true -> :ok
      end
    else
      _ -> {:error, :origin_mismatch}
    end
  end

  defp delivery_targets(activity) do
    object = if is_map(activity["object"]), do: activity["object"], else: %{}

    Enum.flat_map([activity, object], fn container ->
      Enum.flat_map(~w(to cc audience tag), &ids(container[&1]))
    end)
    |> Enum.uniq()
  end

  defp ids(nil), do: []
  defp ids(values) when is_list(values), do: Enum.flat_map(values, &ids/1)
  defp ids(%{"id" => id}) when is_binary(id), do: [id]
  defp ids(%{"href" => href}) when is_binary(href), do: [href]
  defp ids(id) when is_binary(id), do: [id]
  defp ids(_), do: []

  defp creator_for_actor?(creator, actor_id) do
    byte_size(creator) <= @maximum_uri_bytes and
      (creator == actor_id <> "#main-key" or
         (String.starts_with?(creator, actor_id <> "#") and same_origin?(creator, actor_id)))
  end

  defp validate_https_uri(value)
       when is_binary(value) and byte_size(value) <= @maximum_uri_bytes do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" -> :ok
      _ -> {:error, :invalid_forwarded_activity}
    end
  end

  defp validate_https_uri(_), do: {:error, :invalid_forwarded_activity}

  defp same_origin?(left, right) when is_binary(left) and is_binary(right) do
    left_uri = URI.parse(left)
    right_uri = URI.parse(right)

    left_uri.scheme == right_uri.scheme and
      normalize_host(left_uri.host) == normalize_host(right_uri.host) and
      effective_port(left_uri) == effective_port(right_uri)
  end

  defp same_origin?(_, _), do: false

  defp normalize_host(host) when is_binary(host), do: String.downcase(host)
  defp normalize_host(_), do: nil

  defp effective_port(%URI{port: nil, scheme: scheme}), do: URI.default_port(scheme)
  defp effective_port(%URI{port: port}), do: port
end
