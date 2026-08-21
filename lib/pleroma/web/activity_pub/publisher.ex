# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

# credo:disable-for-this-file Credo.Check.Readability.PredicateFunctionNames

defmodule Pleroma.Web.ActivityPub.Publisher do
  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.Delivery
  alias Pleroma.Helpers.UriHelper
  alias Pleroma.HTTP
  alias Pleroma.HTTP.SignatureNegotiation
  alias Pleroma.Instances
  alias Pleroma.Instances.Instance
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.ActivityPub.FollowersSynchronization
  alias Pleroma.Web.ActivityPub.Marketplace
  alias Pleroma.Web.ActivityPub.MRF.QuoteToLinkTagPolicy
  alias Pleroma.Web.ActivityPub.Relay
  alias Pleroma.Web.ActivityPub.Transmogrifier

  require Pleroma.Constants

  import Pleroma.Web.ActivityPub.Visibility

  @behaviour Pleroma.Web.Federator.Publisher

  require Logger

  @moduledoc """
  ActivityPub outgoing federation module.
  """

  @terminal_delivery_statuses %{
    301 => :moved_permanently,
    308 => :permanent_redirect,
    400 => :bad_request,
    401 => :unauthorized,
    403 => :forbidden,
    404 => :not_found,
    405 => :method_not_allowed,
    406 => :not_acceptable,
    410 => :gone,
    501 => :not_implemented
  }

  # HTTP signatures bind the destination host and request path. Inbox
  # redirects must therefore be resolved through a refreshed actor document,
  # not followed as an ordinary HTTP redirect with stale request semantics.
  @delivery_http_options [
    redirect_middleware: nil,
    adapter: [follow_redirect: false, force_redirect: false]
  ]

  @delivery_error_body_limit 2_048

  @doc """
  Determine if an activity can be represented by running it through Transmogrifier.
  """
  def is_representable?(%Activity{} = activity) do
    match?({:ok, _data}, Transmogrifier.prepare_outgoing(activity.data))
  end

  @doc """
  Publish a single message to a peer.  Takes a struct with the following
  parameters set:

  * `inbox`: the inbox to publish to
  * `json`: the JSON message body representing the ActivityPub message
  * `actor`: the actor which is signing the message
  * `id`: the ActivityStreams URI of the message
  """
  def publish_one(%{json: json, actor: %User{}, id: id}) when not is_binary(json) do
    Logger.metadata(activity: UriHelper.log_safe_url(id))
    Logger.debug("Publisher rejected malformed JSON body")
    {:cancel, :bad_request}
  end

  def publish_one(%{inbox: inbox, json: json, actor: %User{} = actor, id: id} = params) do
    safe_id = UriHelper.log_safe_url(id)
    safe_inbox = UriHelper.log_safe_url(inbox)
    Logger.debug("Federating #{safe_id} to #{safe_inbox}")

    with {:ok, uri, path} <- signature_uri(inbox) do
      json = prepare_delivery_json(json, inbox)
      collection_synchronization = FollowersSynchronization.outbound_header(actor, inbox)
      digest = "SHA-256=" <> (:crypto.hash(:sha256, json) |> Base.encode64())

      date = Pleroma.Signature.signed_date()

      signature_headers =
        %{
          "(request-target)": "post #{path}",
          host: signature_host(uri),
          "content-length": byte_size(json),
          digest: digest,
          date: date
        }
        |> maybe_put_collection_synchronization(collection_synchronization)

      signature = Pleroma.Signature.sign(actor, signature_headers)

      with {:ok, %{status: code}} = result when code in 200..299 <-
             post_with_signature_fallback(
               inbox,
               json,
               actor,
               date,
               signature,
               digest,
               collection_synchronization
             ) do
        if not Map.has_key?(params, :unreachable_since) || params[:unreachable_since] do
          Instances.record_delivery_success(inbox, source: "publisher")
        end

        result
      else
        {_post_result, %{status: code} = response} ->
          Logger.metadata(activity: safe_id, inbox: safe_inbox, status: code)

          Logger.debug(fn ->
            "Publisher failed to inbox #{safe_inbox} with status #{code}: " <>
              delivery_error_body(response)
          end)

          case Map.fetch(@terminal_delivery_statuses, code) do
            {:ok, :gone} ->
              Instances.record_gone(inbox, source: "publisher", status: code)
              {:cancel, :gone}

            {:ok, reason} ->
              {:cancel, reason}

            :error ->
              unless known_unreachable?(params) do
                Instances.record_delivery_failure(inbox, {:http, code},
                  source: "publisher",
                  status: code
                )
              end

              {:error, response}
          end

        {:error, {:already_started, _}} ->
          Logger.debug("Publisher snoozing worker job due worker :already_started race condition")
          connection_pool_snooze()

        {:error, :pool_full} ->
          Logger.debug("Publisher snoozing worker job due to full connection pool")
          connection_pool_snooze()

        e ->
          Logger.metadata(activity: safe_id, inbox: safe_inbox)
          Logger.debug("Publisher failed to inbox #{safe_inbox}: #{inspect(e)}")

          if known_unreachable?(params) do
            {:cancel, :unreachable_host}
          else
            Instances.record_delivery_failure(inbox, e, source: "publisher")
            {:error, e}
          end
      end
    else
      {:error, reason} ->
        Logger.metadata(activity: safe_id, inbox: safe_inbox)
        Logger.debug("Publisher rejected malformed inbox #{safe_inbox}")
        {:cancel, reason}
    end
  end

  def publish_one(%{actor_id: actor_id} = params) do
    actor = User.get_cached_by_id(actor_id)

    params
    |> Map.delete(:actor_id)
    |> Map.put(:actor, actor)
    |> publish_one()
  end

  def publish_one(%{actor: _actor, id: id}) do
    Logger.metadata(activity: UriHelper.log_safe_url(id))
    Logger.debug("Publisher rejected malformed actor")
    {:cancel, :bad_request}
  end

  def publish_one(params) when is_map(params) do
    Logger.debug(
      "Publisher rejected malformed delivery params; keys=#{inspect(Map.keys(params))}"
    )

    {:cancel, :bad_request}
  end

  defp prepare_delivery_json(json, inbox) do
    json = Marketplace.prepare_delivery_json(json, inbox)

    with {:ok,
          %{"type" => "Delete", "object" => %{"id" => object_id, "type" => "Tombstone"}} =
            data}
         when is_binary(object_id) <- Jason.decode(json),
         true <- ibis_delivery?(inbox) do
      data
      |> Map.put("object", object_id)
      |> Jason.encode!()
    else
      _ -> json
    end
  end

  defp ibis_delivery?(inbox) do
    with %URI{host: host} = uri when is_binary(host) <- URI.parse(inbox),
         metadata when is_map(metadata) <- Instance.get_or_update_metadata(uri),
         software_name when is_binary(software_name) <-
           Map.get(metadata, :software_name) || Map.get(metadata, "software_name") do
      String.downcase(String.trim(software_name)) == "ibis"
    else
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp post_with_signature_fallback(
         inbox,
         json,
         actor,
         date,
         signature,
         digest,
         collection_synchronization
       ) do
    if SignatureNegotiation.prefers_rfc9421?(inbox) do
      case post_rfc9421(inbox, json, actor, date, collection_synchronization) do
        {:ok, %{status: status}} when status in [400, 401] ->
          SignatureNegotiation.forget(inbox)
          post_legacy(inbox, json, date, signature, digest, collection_synchronization)

        {:error, _reason} ->
          SignatureNegotiation.forget(inbox)
          post_legacy(inbox, json, date, signature, digest, collection_synchronization)

        result ->
          result
      end
    else
      legacy_result =
        post_legacy(inbox, json, date, signature, digest, collection_synchronization)

      case legacy_result do
        {:ok, %{status: status}} when status in [400, 401] ->
          case post_rfc9421(inbox, json, actor, date, collection_synchronization) do
            {:ok, %{status: successful_status}} = result when successful_status in 200..299 ->
              SignatureNegotiation.remember_rfc9421(inbox)
              result

            {:error, _reason} ->
              legacy_result

            result ->
              result
          end

        {:ok, response} = result ->
          SignatureNegotiation.observe_response(inbox, response)
          result

        result ->
          result
      end
    end
  end

  defp post_legacy(inbox, json, date, signature, digest, collection_synchronization) do
    headers =
      [
        {"Content-Type", "application/activity+json"},
        {"Date", date},
        {"signature", signature},
        {"digest", digest}
      ]
      |> maybe_add_collection_synchronization_header(collection_synchronization)

    HTTP.post(
      inbox,
      json,
      headers,
      Keyword.put(@delivery_http_options, :public_only, true)
    )
  end

  defp post_rfc9421(inbox, json, actor, date, collection_synchronization) do
    content_digest = Pleroma.HTTP.MessageSignatures.content_digest(json)

    signed_headers =
      %{"content-digest" => content_digest}
      |> maybe_put_collection_synchronization(collection_synchronization)

    with {:ok, signature_headers} <-
           Pleroma.Signature.sign_rfc9421(actor, "POST", inbox, signed_headers) do
      headers =
        [
          {"Content-Type", "application/activity+json"},
          {"Content-Digest", content_digest},
          {"Date", date}
          | signature_headers
        ]
        |> maybe_add_collection_synchronization_header(collection_synchronization)

      HTTP.post(
        inbox,
        json,
        headers,
        Keyword.put(@delivery_http_options, :public_only, true)
      )
    end
  end

  defp maybe_put_collection_synchronization(headers, nil), do: headers

  defp maybe_put_collection_synchronization(headers, value) when is_binary(value) do
    Map.put(headers, "collection-synchronization", value)
  end

  defp maybe_add_collection_synchronization_header(headers, nil), do: headers

  defp maybe_add_collection_synchronization_header(headers, value) when is_binary(value) do
    [{"Collection-Synchronization", value} | headers]
  end

  defp signature_uri(inbox) when is_binary(inbox) do
    uri = URI.parse(inbox)

    with %URI{scheme: scheme, host: host} <- uri,
         true <- scheme in ["http", "https"],
         true <- is_binary(host),
         normalized_host when is_binary(normalized_host) <- Instances.host(inbox) do
      path = uri.path || "/"

      request_target =
        if Config.get([:activitypub, :sign_query_part], true) and is_binary(uri.query) do
          path <> "?" <> uri.query
        else
          path
        end

      {:ok, uri, request_target}
    else
      _ -> {:error, :bad_request}
    end
  rescue
    URI.Error -> {:error, :bad_request}
  end

  defp signature_uri(_), do: {:error, :bad_request}

  defp delivery_error_body(%{body: body}) when is_binary(body) do
    body
    |> String.slice(0, @delivery_error_body_limit)
    |> inspect()
  end

  defp delivery_error_body(_response), do: "no response body"

  defp known_unreachable?(%{unreachable_since: unreachable_since})
       when unreachable_since in [nil, false],
       do: false

  defp known_unreachable?(%{unreachable_since: _unreachable_since}), do: true
  defp known_unreachable?(_params), do: false

  defp connection_pool_snooze, do: {:snooze, 3}

  defp signature_host(%URI{port: port, scheme: scheme, host: host}) do
    if port == URI.default_port(scheme) do
      host
    else
      "#{host}:#{port}"
    end
  end

  def should_federate?(nil, _), do: false

  def should_federate?(inbox, public) when is_binary(inbox) do
    host = uri_host(inbox)

    rejected_instances =
      Config.get([:mrf_simple, :reject], [])
      |> Pleroma.Web.ActivityPub.MRF.instance_list_from_tuples()
      |> Pleroma.Web.ActivityPub.MRF.subdomains_regex()

    quarantined_instances =
      Config.get([:instance, :quarantined_instances], [])
      |> Pleroma.Web.ActivityPub.MRF.instance_list_from_tuples()
      |> Pleroma.Web.ActivityPub.MRF.subdomains_regex()

    is_binary(host) and
      !Pleroma.Web.ActivityPub.MRF.subdomain_match?(rejected_instances, host) and
      (public or !Pleroma.Web.ActivityPub.MRF.subdomain_match?(quarantined_instances, host))
  end

  def should_federate?(_, true), do: true
  def should_federate?(_, _), do: false

  @spec recipients(User.t(), Activity.t()) :: [[User.t()]]
  defp recipients(actor, activity) do
    followers =
      if actor.follower_address in activity.recipients do
        actor
        |> User.get_external_followers()
        |> maybe_skip_group_announce_origin(actor, activity)
      else
        []
      end

    delete_recipients =
      with %Activity{data: %{"type" => "Delete"}} <- activity,
           %Object{id: object_id, data: %{"id" => object_ap_id}} <-
             Object.normalize(activity, fetch: false),
           delivered_users <- User.get_delivered_users_by_object_id(object_id),
           interacting_users <- User.get_remote_interactors_by_object_ap_id(object_ap_id),
           _ <- Delivery.delete_all_by_object_id(object_id) do
        Enum.uniq_by(delivered_users ++ interacting_users, & &1.id)
      else
        _ ->
          []
      end

    mentioned = Pleroma.Web.Federator.Publisher.remote_users(actor, activity)
    non_mentioned = (followers ++ delete_recipients) -- mentioned

    [mentioned, non_mentioned]
  end

  defp maybe_skip_group_announce_origin(
         followers,
         %User{actor_type: "Group"},
         %Activity{data: %{"type" => "Announce", "object" => object_ap_id}}
       )
       when is_binary(object_ap_id) do
    with origin_host when is_binary(origin_host) <- announce_origin_host(object_ap_id) do
      Enum.reject(followers, fn %User{ap_id: ap_id} ->
        uri_host(ap_id) == origin_host
      end)
    else
      _ -> followers
    end
  end

  defp maybe_skip_group_announce_origin(followers, _actor, _activity), do: followers

  defp announce_origin_host(object_ap_id) do
    case Object.get_cached_by_ap_id(object_ap_id) do
      %Object{data: %{"actor" => object_actor}} when is_binary(object_actor) ->
        uri_host(object_actor)

      _ ->
        uri_host(object_ap_id)
    end
  end

  defp get_cc_ap_ids(ap_id, recipients) do
    host = uri_host(ap_id)

    if is_binary(host) do
      recipients
      |> Enum.filter(fn %User{ap_id: ap_id} -> uri_host(ap_id) == host end)
      |> Enum.map(& &1.ap_id)
    else
      []
    end
  end

  defp maybe_use_sharedinbox(%User{shared_inbox: nil, inbox: inbox}), do: inbox
  defp maybe_use_sharedinbox(%User{shared_inbox: shared_inbox}), do: shared_inbox

  @doc """
  Determine a user inbox to use based on heuristics.  These heuristics
  are based on an approximation of the ``sharedInbox`` rules in the
  [ActivityPub specification][ap-sharedinbox].

  Please do not edit this function (or its children) without reading
  the spec, as editing the code is likely to introduce some breakage
  without some familiarity.

     [ap-sharedinbox]: https://www.w3.org/TR/activitypub/#shared-inbox-delivery
  """
  def determine_inbox(
        %Activity{data: activity_data},
        %User{inbox: inbox} = user
      ) do
    to = activity_data["to"] || []
    cc = activity_data["cc"] || []
    type = activity_data["type"]

    cond do
      type == "Delete" ->
        maybe_use_sharedinbox(user)

      Pleroma.Constants.as_public() in to || Pleroma.Constants.as_public() in cc ->
        maybe_use_sharedinbox(user)

      length(to) + length(cc) > 1 ->
        maybe_use_sharedinbox(user)

      true ->
        inbox
    end
  end

  @doc """
  Publishes an activity with BCC to all relevant peers.
  """

  def publish(%User{} = actor, %Activity{} = activity) do
    if Pleroma.Federation.enabled?(), do: do_publish(actor, activity), else: :ok
  end

  defp do_publish(%User{} = actor, %{data: %{"bcc" => bcc}} = activity)
       when is_list(bcc) and bcc != [] do
    public = is_public?(activity)
    {:ok, data} = Transmogrifier.prepare_outgoing(activity.data)
    data = QuoteToLinkTagPolicy.add_object_link_tag(data)
    {actor, activity, data} = maybe_replace_actor(actor, activity, data)

    [priority_recipients, recipients] = recipients(actor, activity)
    all_recipients = priority_recipients ++ recipients

    inboxes =
      [priority_recipients, recipients]
      |> Enum.map(fn recipients ->
        recipients
        |> Enum.map(fn %User{} = user ->
          determine_inbox(activity, user)
        end)
        |> Enum.uniq()
        |> Enum.filter(fn inbox -> should_federate?(inbox, public) end)
        |> Instances.filter_reachable()
      end)

    [priority_inboxes, inboxes] = inboxes
    inboxes = [priority_inboxes, Map.drop(inboxes, Map.keys(priority_inboxes))]

    Repo.checkout(fn ->
      Enum.reduce_while(Enum.with_index(inboxes), :ok, fn {inboxes, priority}, :ok ->
        result =
          Enum.reduce_while(inboxes, :ok, fn {inbox, unreachable_since}, :ok ->
            %User{ap_id: ap_id} =
              Enum.find(all_recipients, fn user ->
                determine_inbox(activity, user) == inbox
              end)

            # Get all recipients on the same host and add them to cc. Otherwise, a remote
            # instance may accept only the first recipient and ignore the rest.
            cc = get_cc_ap_ids(ap_id, all_recipients)

            cc =
              if Pleroma.Constants.as_public() in Map.get(data, "cc", []) and
                   Pleroma.Constants.as_public() not in cc do
                [Pleroma.Constants.as_public() | cc]
              else
                cc
              end

            json =
              data
              |> Map.put("cc", cc)
              |> Jason.encode!()

            enqueue_delivery(
              actor,
              activity.data["id"],
              inbox,
              json,
              unreachable_since,
              priority
            )
            |> continue_enqueue()
          end)

        case result do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end)
  end

  # Publishes an activity to all relevant peers.
  defp do_publish(%User{} = actor, %Activity{} = activity) do
    public = is_public?(activity)

    {:ok, data} = Transmogrifier.prepare_outgoing(activity.data)
    {actor, activity, data} = maybe_replace_actor(actor, activity, data)
    activity = delivery_activity(activity, data)

    json =
      data
      |> Map.put_new("cc", [])
      |> Jason.encode!()

    [priority_inboxes, inboxes] =
      recipients(actor, activity)
      |> Enum.map(fn recipients ->
        recipients
        |> Enum.map(fn %User{} = user ->
          determine_inbox(activity, user)
        end)
        |> Enum.uniq()
        |> Enum.filter(fn inbox -> should_federate?(inbox, public) end)
      end)

    inboxes = inboxes -- priority_inboxes

    result =
      [{priority_inboxes, 0}, {inboxes, 1}]
      |> Enum.reduce_while(:ok, fn {inboxes, priority}, :ok ->
        result =
          inboxes
          |> Instances.filter_reachable()
          |> Enum.reduce_while(:ok, fn {inbox, unreachable_since}, :ok ->
            enqueue_delivery(
              actor,
              activity.data["id"],
              inbox,
              json,
              unreachable_since,
              priority
            )
            |> continue_enqueue()
          end)

        case result do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    with :ok <- result do
      maybe_publish_relay(public, activity)
    end
  end

  defp enqueue_delivery(actor, activity_id, inbox, json, unreachable_since, priority) do
    case Pleroma.Web.Federator.Publisher.enqueue_one(
           __MODULE__,
           %{
             inbox: inbox,
             json: json,
             actor_id: actor.id,
             id: activity_id,
             unreachable_since: unreachable_since
           },
           priority: priority
         ) do
      {:ok, %Oban.Job{}} ->
        :ok

      {:error, reason} ->
        {:error, {:delivery_enqueue_failed, UriHelper.log_safe_url(inbox), reason}}

      result ->
        {:error, {:invalid_delivery_enqueue_result, UriHelper.log_safe_url(inbox), result}}
    end
  end

  defp continue_enqueue(:ok), do: {:cont, :ok}
  defp continue_enqueue({:error, _reason} = error), do: {:halt, error}

  # Direct inbox jobs must exist before the relay Announce is created. If
  # either insertion fails, the owning publish worker retries while the unique
  # delivery jobs prevent already-inserted work from being duplicated.
  defp maybe_publish_relay(true, %Activity{data: %{"type" => "Create"}} = activity) do
    if Config.get([:instance, :allow_relay]) do
      Logger.debug(fn ->
        "Relaying #{UriHelper.log_safe_url(activity.data["id"])} out"
      end)

      case Relay.publish(activity) do
        {:ok, %Activity{}} -> :ok
        {:error, reason} -> {:error, {:relay_publish_failed, reason}}
        result -> {:error, {:invalid_relay_publish_result, result}}
      end
    else
      :ok
    end
  end

  defp maybe_publish_relay(_public, _activity), do: :ok

  defp delivery_activity(%Activity{} = activity, data) do
    # Transmogrifier may translate both an object's identifier and its audience
    # for a native remote representation. Inbox selection must use that same
    # representation or one signed activity can be delivered through recipients
    # that are absent from its wire payload. Preserve already-resolved database
    # recipients when the translation did not alter the audience.
    {original_recipients, _to, _cc} = ActivityPub.get_recipients(activity.data)
    {prepared_recipients, _to, _cc} = ActivityPub.get_recipients(data)

    recipients =
      if MapSet.equal?(MapSet.new(original_recipients), MapSet.new(prepared_recipients)) do
        activity.recipients
      else
        prepared_recipients
      end

    %Activity{activity | data: data, recipients: recipients}
  end

  defp maybe_replace_actor(%User{} = actor, %Activity{} = activity, data) do
    if data["actor"] == actor.ap_id do
      {actor, activity, data}
    else
      case User.get_cached_by_ap_id(data["actor"]) do
        %User{} = replacement ->
          {replacement, %Activity{activity | actor: replacement.ap_id}, data}

        _ ->
          {actor, activity, data}
      end
    end
  end

  def gather_webfinger_links(%User{} = user) do
    [
      %{"rel" => "self", "type" => "application/activity+json", "href" => user.ap_id},
      %{
        "rel" => "self",
        "type" => "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\"",
        "href" => user.ap_id
      },
      %{
        "rel" => "http://ostatus.org/schema/1.0/subscribe",
        "template" => "#{Pleroma.Web.Endpoint.url()}/ostatus_subscribe?acct={uri}"
      }
    ]
  end

  def gather_nodeinfo_protocol_names, do: ["activitypub"]

  defp uri_host(uri) when is_binary(uri) do
    Instances.host(uri)
  end

  defp uri_host(_), do: nil
end
