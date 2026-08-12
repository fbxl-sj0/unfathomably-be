# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Object.Fetcher do
  defmodule PrefetchedObject do
    @moduledoc false

    @enforce_keys [:requested_id, :data]
    defstruct [:requested_id, :data]

    @opaque t :: %__MODULE__{requested_id: String.t(), data: map()}
  end

  alias Pleroma.ATProto.BridgyCompat
  alias Pleroma.HTTP
  alias Pleroma.Instances
  alias Pleroma.Maps
  alias Pleroma.Nostr.MostrCompat
  alias Pleroma.Object
  alias Pleroma.Object.Containment
  alias Pleroma.Signature
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.CustomObject
  alias Pleroma.Web.ActivityPub.InternalFetchActor
  alias Pleroma.Web.ActivityPub.MRF
  alias Pleroma.Web.ActivityPub.ObjectValidator
  alias Pleroma.Web.ActivityPub.Pipeline
  alias Pleroma.Web.ActivityPub.RemoteReplies
  alias Pleroma.Web.ActivityPub.Transmogrifier
  alias Pleroma.Web.Federation.Churn
  alias Pleroma.Web.Federator

  require Logger
  require Pleroma.Constants

  @activity_types ~w(Accept Add Announce Block Create Delete Dislike EmojiReact Flag Follow Join Leave Like Listen Lock Move Reject Remove Undo Update)
  @collection_types ~w(Collection OrderedCollection CollectionPage OrderedCollectionPage)
  @max_canonical_html_bytes 1_048_576
  @max_canonical_url_bytes 2048
  # Existing objects arrive here without their enclosing Update activity.
  # Reconstructing that envelope lets activity-shaped MRF policies apply the
  # same media, visibility, and moderation rules used for inbox delivery.
  defp filter_reinjected_object(%{"actor" => actor} = object) when is_binary(actor) do
    update =
      object
      |> Map.take(["to", "cc", "bto", "bcc"])
      |> Map.merge(%{"type" => "Update", "actor" => actor, "object" => object})

    with {:ok, %{"object" => %{} = filtered_object}} <- MRF.filter(update) do
      {:ok, filtered_object}
    end
  end

  defp filter_reinjected_object(object), do: MRF.filter(object)

  @spec reinject_object(struct(), map()) :: {:ok, Object.t()} | {:error, any()}
  defp reinject_object(%Object{data: %{}} = object, new_data) do
    Logger.debug("Reinjecting object #{Pleroma.Helpers.UriHelper.log_safe_url(new_data["id"])}")

    with {:ok, new_data, _} <-
           ObjectValidator.validate(new_data,
             local: false,
             fetched_from: object.data["id"]
           ),
         {:ok, new_data} <- filter_reinjected_object(new_data),
         {:ok, new_object, _} <-
           Object.Updater.do_update_and_invalidate_cache(
             object,
             new_data,
             _touch_changeset? = true
           ) do
      {:ok, new_object}
    else
      e ->
        Logger.error("Error while processing object: #{inspect(e)}")
        {:error, e}
    end
  end

  defp reinject_object(_, new_data) do
    meta =
      if CustomObject.direct_resource?(new_data) do
        [local: false, fetched_from: new_data["id"], do_not_federate: true]
      else
        [local: false]
      end

    with {:ok, object, _} <- Pipeline.common_pipeline(new_data, meta) do
      {:ok, object}
    else
      e -> e
    end
  end

  def refetch_object(%Object{data: %{"id" => id}} = object) do
    case fetch_native_bridge_object(id) do
      {:ok, %Object{} = native_object} ->
        {:ok, native_object}

      result when result in [:miss, :not_applicable] ->
        with {:local, false} <- {:local, Object.local?(object)},
             {:ok, new_data} <- fetch_and_contain_remote_object_from_id(id),
             {:ok, object} <- reinject_object(object, new_data) do
          {:ok, object}
        else
          {:local, true} -> {:ok, object}
          e -> {:error, e}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @typep fetcher_errors ::
           :error | :reject | :allowed_depth | :fetch | :containment | :transmogrifier

  @transient_transport_errors [
    :closed,
    :connect_timeout,
    :econnrefused,
    :ehostunreach,
    :enetunreach,
    :enotconn,
    :nxdomain,
    :recv_body_timeout,
    :recv_chunk_timeout,
    :recv_response_timeout,
    :timeout
  ]

  # Note: will create a Create activity, which we need internally at the moment.
  @spec fetch_object_from_id(String.t(), list()) ::
          {:ok, Object.t()} | {fetcher_errors(), any()} | Pipeline.errors()
  def fetch_object_from_id(id, options \\ []) do
    case fetch_native_bridge_object(id) do
      {:ok, %Object{} = object} -> {:ok, object}
      result when result in [:miss, :not_applicable] -> do_fetch_object_from_id(id, options)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Resolves an object action target, including a bounded HTML canonical hint.

  Some alternate frontends publish their own URL in federated reactions while
  advertising the source ActivityPub object through `rel=canonical`. The hint
  is never ingested directly: its target must pass the normal remote object
  fetch, containment, identifier, actor-origin, validation, and MRF checks.
  """
  @spec resolve_object_reference(String.t(), list()) ::
          {:ok, Object.t()} | {fetcher_errors(), any()} | Pipeline.errors()
  def resolve_object_reference(id, options \\ [])

  def resolve_object_reference(id, options) when is_binary(id) do
    fetch_object_from_id(id, Keyword.put(options, :resolve_html_canonical, true))
  end

  def resolve_object_reference(_id, _options), do: {:error, "id must be a string"}

  defp do_fetch_object_from_id(id, options) do
    {prefetched_object, options} = Keyword.pop(options, :prefetched_object)
    {resolve_html_canonical?, options} = Keyword.pop(options, :resolve_html_canonical, false)

    with {_, nil} <- {:fetch_object, Object.get_cached_by_ap_id(id)},
         {_, true} <- {:allowed_depth, Federator.allowed_thread_distance?(options[:depth])},
         {_, {:ok, data}} <- {:fetch, fetch_object_data(id, prefetched_object)},
         data <- RemoteReplies.maybe_inline_reply_ids(data, options),
         {_, nil} <- {:normalize, Object.normalize(data, fetch: false)},
         params <- prepare_activity_params(data),
         {_, :ok} <- {:containment, contain_fetched_data(id, data, params)},
         {_, {:ok, activity}} <-
           {:transmogrifier, ingest_fetched_data(id, data, params, options)},
         {_, _data, %Object{} = object} <-
           {:object, data, Object.normalize(activity, fetch: false)} do
      {:ok, object}
    else
      {:allowed_depth, false} ->
        {:error, :allowed_depth}

      {:containment, _} ->
        {:error, "Object containment failed."}

      {:transmogrifier, {:error, {:reject, e}}} ->
        Logger.info(
          "Rejected #{Pleroma.Helpers.UriHelper.log_safe_url(id)} while fetching: #{Pleroma.Helpers.UriHelper.log_safe_text(e)}"
        )

        {:reject, e}

      {:transmogrifier, {:reject, e}} ->
        Logger.info(
          "Rejected #{Pleroma.Helpers.UriHelper.log_safe_url(id)} while fetching: #{Pleroma.Helpers.UriHelper.log_safe_text(e)}"
        )

        {:reject, e}

      {:transmogrifier, {:error, {:persist, {:error, %Ecto.Changeset{} = changeset}}} = error} ->
        maybe_return_existing_object(id, changeset, {:transmogrifier, error})

      {:transmogrifier, _} = e ->
        {:error, e}

      {:object, data, nil} ->
        reinject_object(%Object{}, data)

      {:normalize, object = %Object{}} ->
        {:ok, object}

      {:fetch_object, %Object{} = object} ->
        {:ok, object}

      {:fetch, {:error, {:content_type, _content_type} = error}}
      when resolve_html_canonical? ->
        resolve_html_canonical_object(id, options, error)

      {:fetch, {:error, error}} ->
        log_fetch_error(id, {:error, error})
        {:error, error}

      e ->
        log_fetch_error(id, e)
        {:error, e}
    end
  end

  # Reply-thread discovery must inspect a remote object before its ancestors
  # can be stored in order. Recheck containment here and require an ID-bound
  # fetch result so a raw map or caller-controlled option cannot bypass the
  # canonical HTTP fetch and identifier checks.
  defp fetch_object_data(
         id,
         %PrefetchedObject{requested_id: id, data: %{} = prefetched_data}
       ) do
    case Containment.contain_origin_from_id(id, prefetched_data) do
      :ok -> {:ok, prefetched_data}
      error -> {:error, error}
    end
  end

  defp fetch_object_data(_id, %PrefetchedObject{}),
    do: {:error, :prefetched_object_id_mismatch}

  defp fetch_object_data(id, _prefetched_data) do
    fetch_and_contain_remote_object_from_id(id)
  end

  defp maybe_return_existing_object(id, changeset, error) do
    with true <- object_unique_ap_id_error?(changeset),
         %Object{} = object <- Object.get_by_ap_id(id) do
      Object.set_cache(object)
    else
      _ -> {:error, error}
    end
  end

  defp object_unique_ap_id_error?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {:ap_id, {_message, opts}} ->
        Keyword.get(opts, :constraint_name) == "objects_unique_apid_index" or
          Keyword.get(opts, :constraint) == :unique

      _ ->
        false
    end)
  end

  defp prepare_activity_params(%{"type" => type} = data) when type in @activity_types, do: data

  defp prepare_activity_params(data) do
    actor = object_fetch_actor(data)
    object = put_object_fetch_actor(data, actor)

    %{
      "type" => "Create",
      "actor" => actor,
      "object" => object
    }
    |> Maps.put_if_present("to", data["to"])
    |> Maps.put_if_present("cc", data["cc"])
    |> Maps.put_if_present("bto", data["bto"])
    |> Maps.put_if_present("bcc", data["bcc"])
  end

  defp contain_fetched_data(id, data, _params) do
    if CustomObject.direct_resource?(data) do
      Containment.contain_origin_from_id(id, data)
    else
      Containment.contain_origin(id, prepare_activity_params(data))
    end
  end

  defp ingest_fetched_data(id, data, params, options) do
    if CustomObject.direct_resource?(data) do
      meta =
        options
        |> Keyword.put(:local, false)
        |> Keyword.put(:fetched_from, id)
        |> Keyword.put(:do_not_federate, true)

      case Pipeline.common_pipeline(data, meta) do
        {:ok, %Object{} = object, _meta} -> {:ok, object}
        {:error, _reason} = error -> error
        {:reject, _reason} = error -> error
      end
    else
      BridgyCompat.handle_incoming(params, fn reconciled ->
        MostrCompat.handle_incoming(
          reconciled,
          &Transmogrifier.handle_incoming(&1, Keyword.put(options, :fetched_from, id))
        )
      end)
    end
  end

  defp object_fetch_actor(%{"actor" => actor}) when is_binary(actor), do: actor

  defp object_fetch_actor(%{"actor" => %{"id" => actor}}) when is_binary(actor), do: actor

  defp object_fetch_actor(%{"actor" => actors}) when is_list(actors),
    do: actor_from_attributions(actors)

  defp object_fetch_actor(%{"attributedTo" => actor}) when is_binary(actor), do: actor

  defp object_fetch_actor(%{"attributedTo" => %{"id" => actor}}) when is_binary(actor), do: actor

  defp object_fetch_actor(%{"attributedTo" => attributions}) when is_list(attributions),
    do: actor_from_attributions(attributions)

  defp object_fetch_actor(data), do: Containment.get_actor(data)

  defp actor_from_attributions(attributions) do
    actor_from_attributions(attributions, ["Group"]) ||
      actor_from_attributions(attributions, ["Person", "Service", "Application"]) ||
      first_attribution_id(attributions)
  end

  defp actor_from_attributions(attributions, types) do
    Enum.find_value(attributions, fn
      %{"id" => id, "type" => type} when is_binary(id) ->
        if type in types, do: id

      _ ->
        nil
    end)
  end

  defp first_attribution_id(attributions) do
    Enum.find_value(attributions, fn
      id when is_binary(id) -> id
      %{"id" => id} when is_binary(id) -> id
      _ -> nil
    end)
  end

  defp put_object_fetch_actor(data, actor) when is_binary(actor) do
    data
    |> Map.put("actor", actor)
    |> Map.put("attributedTo", actor)
  end

  defp put_object_fetch_actor(data, _actor), do: data

  defp log_fetch_error(id, {:error, {:http, code}}) when code in [401, 403, 404, 410] do
    Logger.debug(
      "Remote object #{Pleroma.Helpers.UriHelper.log_safe_url(id)} returned HTTP #{code} while fetching"
    )
  end

  defp log_fetch_error(id, {:error, error}) when error in @transient_transport_errors do
    Logger.debug(
      "Transient error while fetching #{Pleroma.Helpers.UriHelper.log_safe_url(id)}: #{Pleroma.Helpers.UriHelper.log_safe_text(error)}"
    )
  end

  defp log_fetch_error(id, {:error, {:http, code}}) do
    Logger.warning(
      "Remote object #{Pleroma.Helpers.UriHelper.log_safe_url(id)} returned HTTP #{code} while fetching"
    )
  end

  defp log_fetch_error(id, {:error, :not_found}) do
    Logger.info(
      "Remote object #{Pleroma.Helpers.UriHelper.log_safe_url(id)} was not found while fetching"
    )
  end

  defp log_fetch_error(id, {:error, :forbidden}) do
    Logger.info(
      "Remote object #{Pleroma.Helpers.UriHelper.log_safe_url(id)} refused access while fetching"
    )
  end

  defp log_fetch_error(id, e) do
    case Churn.mark_deactivated_actor(e, id) do
      {:ok, actor_id} ->
        Logger.info(
          "Remote actor #{actor_id} is deactivated; marked local user inactive while fetching #{id}"
        )

      :noop ->
        Logger.warning(
          "Error while fetching #{Pleroma.Helpers.UriHelper.log_safe_url(id)}: #{Pleroma.Helpers.UriHelper.log_safe_text(e)}"
        )
    end
  end

  defp make_signature(id, date, actor \\ InternalFetchActor.get_actor()) do
    uri = URI.parse(id)

    signature =
      actor
      |> Signature.sign(%{
        "(request-target)": "get #{request_target(uri)}",
        host: signature_host(uri),
        date: date
      })

    {"signature", signature}
  end

  defp request_target(%URI{path: path, query: query}) do
    path =
      case path do
        path when path in [nil, ""] -> "/"
        path -> path
      end

    case query do
      query when query in [nil, ""] -> path
      query -> "#{path}?#{query}"
    end
  end

  defp signature_host(%URI{host: host, port: port, scheme: scheme}) do
    if port == URI.default_port(scheme) do
      host
    else
      "#{host}:#{port}"
    end
  end

  defp sign_fetch(headers, id, date) do
    if Pleroma.Config.get([:activitypub, :sign_object_fetches]) do
      [make_signature(id, date) | headers]
    else
      headers
    end
  end

  defp signed_fetch_options do
    if Pleroma.Config.get([:activitypub, :sign_object_fetches]) do
      actor = InternalFetchActor.get_actor()

      [
        follow_redirect: false,
        force_redirect: false,
        redirect_middleware:
          {Pleroma.Tesla.Middleware.FederationRedirect,
           signer: {__MODULE__, :resign_fetch_request, [actor]}}
      ]
    else
      []
    end
  end

  @doc false
  def resign_fetch_request(%Tesla.Env{} = env, %User{} = actor) do
    date = Signature.signed_date()

    case make_signature(env.url, date, actor) do
      {"signature", signature} when is_binary(signature) ->
        headers =
          env.headers
          |> Enum.reject(fn {key, _value} ->
            String.downcase(to_string(key)) in ["signature", "signature-input", "date", "host"]
          end)

        {:ok, %{env | headers: [{"signature", signature}, {"date", date} | headers]}}

      _ ->
        {:error, :signature_failed}
    end
  end

  defp maybe_date_fetch(headers, date) do
    if Pleroma.Config.get([:activitypub, :sign_object_fetches]) do
      [{"date", date} | headers]
    else
      headers
    end
  end

  def fetch_and_contain_remote_object_from_id(id)

  def fetch_and_contain_remote_object_from_id(%{"id" => id}),
    do: fetch_and_contain_remote_object_from_id(id)

  def fetch_and_contain_remote_object_from_id(id) when is_binary(id) do
    case fetch_native_bridge_object(id) do
      {:ok, %Object{data: data}} -> {:ok, data}
      result when result in [:miss, :not_applicable] -> fetch_activitypub_object(id)
      {:error, reason} -> {:error, reason}
    end
  end

  def fetch_and_contain_remote_object_from_id(_id),
    do: {:error, "id must be a string"}

  @doc """
  Fetches and contains a remote object for one subsequent internal ingestion.

  The returned value is bound to the requested identifier. It deliberately is
  not a boolean `skip_checks` option: callers cannot pass arbitrary decoded
  input through the prefetched path, and ingestion still repeats containment.
  """
  @spec fetch_prefetched_remote_object_from_id(String.t()) ::
          {:ok, PrefetchedObject.t()} | {:error, any()}
  def fetch_prefetched_remote_object_from_id(id) when is_binary(id) do
    with {:ok, %{} = data} <- fetch_and_contain_remote_object_from_id(id) do
      {:ok, %PrefetchedObject{requested_id: id, data: data}}
    end
  end

  def fetch_prefetched_remote_object_from_id(_id),
    do: {:error, "id must be a string"}

  @spec prefetched_object_data(PrefetchedObject.t()) :: {:ok, map()} | {:error, :invalid}
  def prefetched_object_data(%PrefetchedObject{data: %{} = data}), do: {:ok, data}
  def prefetched_object_data(_prefetched_object), do: {:error, :invalid}

  defp fetch_activitypub_object(id) do
    if Pleroma.Federation.enabled?() do
      do_fetch_activitypub_object(id)
    else
      {:error, :federation_disabled}
    end
  end

  defp do_fetch_activitypub_object(id) do
    Logger.debug("Fetching object #{Pleroma.Helpers.UriHelper.log_safe_url(id)} via AP")

    with {:scheme, true} <- {:scheme, String.starts_with?(id, "http")},
         {:mrf, true} <- {:mrf, MRF.id_filter(id)},
         {:dormant, false} <- {:dormant, Instances.dormant?(id)},
         {:ok, body, final_url} <- get_object(id),
         {:ok, data} <- safe_json_decode(body),
         :ok <- contain_final_response_origin(id, final_url, data),
         :ok <- contain_fetched_identifier(id, final_url, data),
         :ok <- contain_object_origin(id, data) do
      if not Instances.reachable?(id) do
        Instances.set_reachable(id)
      end

      {:ok, data}
    else
      {:scheme, _} ->
        {:error, "Unsupported URI scheme"}

      {:dormant, true} ->
        {:error, :unreachable_host}

      {:mrf, false} ->
        {:error, {:reject, "Filtered by id"}}

      {:error, e} ->
        maybe_record_transient_fetch_failure(id, e)
        {:error, e}

      e ->
        {:error, e}
    end
  end

  def fetch_and_contain_remote_collection_from_id(id) when is_binary(id) do
    cond do
      MostrCompat.legacy_reference?(id) -> {:error, :native_nostr_required}
      BridgyCompat.legacy_reference?(id) -> {:error, :native_atproto_required}
      true -> fetch_activitypub_collection(id)
    end
  end

  def fetch_and_contain_remote_collection_from_id(_id),
    do: {:error, "id must be a string"}

  defp fetch_native_bridge_object(id) do
    case BridgyCompat.fetch_native_object(id) do
      result when result in [:miss, :not_applicable] -> MostrCompat.fetch_native_object(id)
      result -> result
    end
  end

  defp fetch_activitypub_collection(id) do
    if Pleroma.Federation.enabled?() do
      do_fetch_activitypub_collection(id)
    else
      {:error, :federation_disabled}
    end
  end

  defp do_fetch_activitypub_collection(id) do
    Logger.debug("Fetching collection #{Pleroma.Helpers.UriHelper.log_safe_url(id)} via AP")

    with {:scheme, true} <- {:scheme, String.starts_with?(id, "http")},
         {:dormant, false} <- {:dormant, Instances.dormant?(id)},
         {:ok, body, final_url} <- get_object(id),
         {:ok, data} <- safe_json_decode(body),
         :ok <- contain_final_response_origin(id, final_url, data),
         :ok <- contain_collection_origin(id, data) do
      if not Instances.reachable?(id) do
        Instances.set_reachable(id)
      end

      {:ok, data}
    else
      {:scheme, _} ->
        {:error, "Unsupported URI scheme"}

      {:dormant, true} ->
        {:error, :unreachable_host}

      {:error, e} ->
        maybe_record_transient_fetch_failure(id, e)
        {:error, e}

      e ->
        {:error, e}
    end
  end

  defp maybe_record_transient_fetch_failure(id, error)
       when error in @transient_transport_errors do
    Instances.record_failure(id, error, source: "object_fetch")
  end

  defp maybe_record_transient_fetch_failure(_id, _error), do: :ok

  defp contain_fetched_identifier(id, _final_url, %{"id" => id}), do: :ok

  # A redirect to the object's own canonical identifier is authoritative
  # evidence for a human permalink alias. A same-origin document that merely
  # claims a different id is not: without a redirect or advertised `url`, that
  # behavior could turn any JSON endpoint into an object-identity alias.
  defp contain_fetched_identifier(id, final_url, %{"id" => canonical_id} = data)
       when is_binary(final_url) and is_binary(canonical_id) do
    advertised_alias? = advertised_identifier?(data["url"], id)

    canonical_redirect? =
      same_origin?(id, canonical_id) and same_resource_url?(final_url, canonical_id)

    if advertised_alias? or canonical_redirect?,
      do: :ok,
      else: {:error, :object_identifier_mismatch}
  end

  defp contain_fetched_identifier(id, _final_url, %{"url" => url}) do
    if advertised_identifier?(url, id),
      do: :ok,
      else: {:error, :object_identifier_mismatch}
  end

  defp contain_fetched_identifier(_id, _final_url, _data),
    do: {:error, :object_identifier_mismatch}

  defp advertised_identifier?(identifier, expected) when is_binary(identifier),
    do: identifier == expected

  defp advertised_identifier?(identifiers, expected) when is_list(identifiers),
    do: Enum.any?(identifiers, &advertised_identifier?(&1, expected))

  defp advertised_identifier?(%{"href" => identifier}, expected),
    do: advertised_identifier?(identifier, expected)

  defp advertised_identifier?(%{"id" => identifier}, expected),
    do: advertised_identifier?(identifier, expected)

  defp advertised_identifier?(_identifier, _expected), do: false

  defp contain_object_origin(id, data) do
    case Containment.contain_origin_from_id(id, data) do
      :ok -> :ok
      _ -> {:error, :object_origin_mismatch}
    end
  end

  defp contain_collection_origin(id, %{"id" => _} = data) do
    case Containment.contain_origin_from_id(id, data) do
      :ok -> :ok
      _ -> {:error, :collection_origin_mismatch}
    end
  end

  defp contain_collection_origin(id, %{"partOf" => part_of, "type" => type})
       when is_binary(part_of) and type in @collection_types do
    if same_origin?(id, part_of),
      do: :ok,
      else: {:error, :collection_origin_mismatch}
  end

  defp contain_collection_origin(_id, %{"type" => type} = data) when type in @collection_types do
    if collection_shape?(data),
      do: :ok,
      else: {:error, :collection_origin_mismatch}
  end

  defp contain_collection_origin(_id, _data), do: {:error, :collection_origin_mismatch}

  defp collection_shape?(data) do
    Enum.any?(~w(first items orderedItems totalItems partOf), &Map.has_key?(data, &1))
  end

  defp same_origin?(left, right) do
    left_uri = URI.parse(left)
    right_uri = URI.parse(right)

    valid_http_origin?(left_uri) and
      valid_http_origin?(right_uri) and
      left_uri.scheme == right_uri.scheme and
      normalize_host(left_uri.host) == normalize_host(right_uri.host) and
      effective_port(left_uri) == effective_port(right_uri)
  end

  defp valid_http_origin?(%URI{scheme: scheme, host: host}) do
    scheme in ["http", "https"] and is_binary(host) and host != ""
  end

  defp contain_final_response_origin(request_url, final_url, data)
       when is_binary(request_url) and is_binary(final_url) and is_map(data) do
    if same_resource_url?(request_url, final_url) do
      :ok
    else
      case authoritative_response_identifier(data) do
        identifier when is_binary(identifier) ->
          if same_origin?(final_url, identifier),
            do: :ok,
            else: {:error, :final_response_origin_mismatch}

        _ ->
          {:error, :final_response_origin_mismatch}
      end
    end
  end

  defp contain_final_response_origin(_request_url, _final_url, _data),
    do: {:error, :final_response_origin_mismatch}

  defp authoritative_response_identifier(%{"id" => id}) when is_binary(id), do: id

  defp authoritative_response_identifier(%{"partOf" => part_of}) when is_binary(part_of),
    do: part_of

  defp authoritative_response_identifier(%{"url" => url}) when is_binary(url), do: url

  defp authoritative_response_identifier(%{"url" => %{"href" => url}}) when is_binary(url),
    do: url

  defp authoritative_response_identifier(%{"url" => %{"id" => url}}) when is_binary(url), do: url
  defp authoritative_response_identifier(_data), do: nil

  defp same_resource_url?(left, right) do
    normalize_resource_url(left) == normalize_resource_url(right)
  end

  defp normalize_resource_url(url) when is_binary(url) do
    url
    |> URI.parse()
    |> Map.put(:fragment, nil)
    |> URI.to_string()
  end

  defp normalize_host(host) when is_binary(host), do: String.downcase(host)
  defp normalize_host(_host), do: nil

  defp effective_port(%URI{port: nil, scheme: scheme}), do: URI.default_port(scheme)
  defp effective_port(%URI{port: port}), do: port

  defp resolve_html_canonical_object(id, options, original_error) do
    case fetch_html_canonical_url(id) do
      {:ok, canonical_id} ->
        fetch_object_from_id(canonical_id, options)

      _ ->
        log_fetch_error(id, {:error, original_error})
        {:error, original_error}
    end
  end

  defp fetch_html_canonical_url(id) do
    headers = [{"accept", "text/html, application/xhtml+xml;q=0.9"}]

    with {:ok, %{status: status, body: body, headers: response_headers} = response}
         when status in 200..299 and is_binary(body) <-
           HTTP.get(id, headers, signed_fetch_options()),
         true <- html_response?(response_headers),
         true <- byte_size(body) <= @max_canonical_html_bytes,
         final_url <- response_url(response, id),
         true <- same_origin?(id, final_url),
         canonical when is_binary(canonical) <- html_canonical_url(final_url, body),
         true <- safe_html_canonical_url?(canonical, id, final_url) do
      {:ok, canonical}
    else
      _ -> {:error, :canonical_not_found}
    end
  end

  defp html_response?(headers) when is_list(headers) do
    case List.keyfind(headers, "content-type", 0) do
      {_, content_type} ->
        not is_nil(
          Pleroma.Web.MediaType.match(content_type, [
            {"text", "html"},
            {"application", "xhtml+xml"}
          ])
        )

      _ ->
        false
    end
  end

  defp html_response?(_headers), do: false

  defp html_canonical_url(base_url, body) do
    ~r/<link\b[^>]*>/i
    |> Regex.scan(body)
    |> Enum.find_value(fn [tag] ->
      rel = html_attribute(tag, "rel") || ""
      href = html_attribute(tag, "href")

      if is_binary(href) and canonical_relation?(rel) do
        base_url
        |> URI.merge(href)
        |> to_string()
      end
    end)
  rescue
    _ -> nil
  end

  defp canonical_relation?(rel) do
    rel
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.member?("canonical")
  end

  defp html_attribute(tag, attribute) do
    case Regex.run(~r/\b#{Regex.escape(attribute)}\s*=\s*(['"])(.*?)\1/i, tag) do
      [_all, _quote, value] -> HtmlEntities.decode(value)
      _ -> nil
    end
  end

  defp safe_html_canonical_url?(canonical, request_url, final_url) do
    with true <- byte_size(canonical) <= @max_canonical_url_bytes,
         %URI{scheme: request_scheme} <- URI.parse(request_url),
         %URI{scheme: scheme, host: host, userinfo: nil, fragment: nil}
         when scheme in ["http", "https"] and is_binary(host) and host != "" <-
           URI.parse(canonical),
         false <- request_scheme == "https" and scheme != "https",
         false <- same_resource_url?(canonical, request_url),
         false <- same_resource_url?(canonical, final_url),
         true <- MRF.id_filter(canonical) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp get_object(id) do
    date = Pleroma.Signature.signed_date()

    headers =
      [
        {"accept", Pleroma.Constants.activity_json_accept_header()}
      ]
      |> maybe_date_fetch(date)
      |> sign_fetch(id, date)

    case HTTP.get(id, headers, signed_fetch_options()) do
      {:ok, %{body: body, status: code, headers: headers} = response} when code in 200..299 ->
        case List.keyfind(headers, "content-type", 0) do
          {_, content_type} ->
            case Pleroma.Web.MediaType.match(content_type, [
                   {"application", "activity+json"},
                   {"application", "ld+json"},
                   {"application", "json"}
                 ]) do
              {"application", _subtype, _params} ->
                # Generic JSON and JSON-LD remain acceptable because decoded
                # documents still pass containment, validation, and MRF.
                {:ok, body, response_url(response, id)}

              nil ->
                {:error, {:content_type, content_type}}
            end

          _ ->
            {:error, {:content_type, nil}}
        end

      {:ok, %{status: code}} when code in [401, 403] ->
        {:error, :forbidden}

      {:ok, %{status: code}} when code in [404, 410] ->
        {:error, :not_found}

      {:ok, %{status: code}} ->
        {:error, {:http, code}}

      {:error, e} ->
        {:error, e}

      e ->
        {:error, e}
    end
  end

  defp response_url(%{url: url}, _request_url) when is_binary(url) and url != "", do: url
  defp response_url(_response, request_url), do: request_url

  defp safe_json_decode(nil), do: {:ok, nil}
  defp safe_json_decode(json), do: Jason.decode(json)
end
