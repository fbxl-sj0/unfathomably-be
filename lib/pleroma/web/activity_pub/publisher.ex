# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

# credo:disable-for-this-file Credo.Check.Readability.PredicateFunctionNames

defmodule Pleroma.Web.ActivityPub.Publisher do
  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.Delivery
  alias Pleroma.HTTP
  alias Pleroma.Instances
  alias Pleroma.Instances.Instance
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ActivityPub
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
    400 => :bad_request,
    401 => :unauthorized,
    403 => :forbidden,
    404 => :not_found,
    405 => :method_not_allowed,
    406 => :not_acceptable,
    410 => :gone,
    501 => :not_implemented
  }

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
    Logger.metadata(activity: id)
    Logger.debug("Publisher rejected malformed JSON body #{inspect(json)}")
    {:cancel, :bad_request}
  end

  def publish_one(%{inbox: inbox, json: json, actor: %User{} = actor, id: id} = params) do
    Logger.debug("Federating #{id} to #{inbox}")

    with {:ok, uri, path} <- signature_uri(inbox) do
      json = prepare_delivery_json(json, inbox)
      digest = "SHA-256=" <> (:crypto.hash(:sha256, json) |> Base.encode64())

      date = Pleroma.Signature.signed_date()

      signature =
        Pleroma.Signature.sign(actor, %{
          "(request-target)": "post #{path}",
          host: signature_host(uri),
          "content-length": byte_size(json),
          digest: digest,
          date: date
        })

      with {:ok, %{status: code}} = result when code in 200..299 <-
             post_with_signature_fallback(inbox, json, actor, date, signature, digest) do
        if not Map.has_key?(params, :unreachable_since) || params[:unreachable_since] do
          Instances.record_delivery_success(inbox, source: "publisher")
        end

        result
      else
        {_post_result, %{status: code} = response} ->
          Logger.metadata(activity: id, inbox: inbox, status: code)

          Logger.debug(fn ->
            "Publisher failed to inbox #{inbox} with status #{code}: " <>
              delivery_error_body(response)
          end)

          case Map.fetch(@terminal_delivery_statuses, code) do
            {:ok, reason} ->
              {:cancel, reason}

            :error ->
              unless known_unreachable?(params), do: Instances.set_unreachable(inbox)
              {:error, response}
          end

        {:error, {:already_started, _}} ->
          Logger.debug("Publisher snoozing worker job due worker :already_started race condition")
          connection_pool_snooze()

        {:error, :pool_full} ->
          Logger.debug("Publisher snoozing worker job due to full connection pool")
          connection_pool_snooze()

        e ->
          Logger.metadata(activity: id, inbox: inbox)
          Logger.debug("Publisher failed to inbox #{inbox}: #{inspect(e)}")

          if known_unreachable?(params) do
            {:cancel, :unreachable_host}
          else
            Instances.record_delivery_failure(inbox, e, source: "publisher")
            {:error, e}
          end
      end
    else
      {:error, reason} ->
        Logger.metadata(activity: id, inbox: inbox)
        Logger.debug("Publisher rejected malformed inbox #{inspect(inbox)}")
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

  def publish_one(%{actor: actor, id: id}) do
    Logger.metadata(activity: id)
    Logger.debug("Publisher rejected malformed actor #{inspect(actor)}")
    {:cancel, :bad_request}
  end

  def publish_one(params) when is_map(params) do
    Logger.debug("Publisher rejected malformed delivery params #{inspect(params)}")
    {:cancel, :bad_request}
  end

  defp prepare_delivery_json(json, inbox) do
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

  defp post_with_signature_fallback(inbox, json, actor, date, signature, digest) do
    legacy_result =
      HTTP.post(
        inbox,
        json,
        [
          {"Content-Type", "application/activity+json"},
          {"Date", date},
          {"signature", signature},
          {"digest", digest}
        ]
      )

    case legacy_result do
      {:ok, %{status: status}} when status in [400, 401] ->
        content_digest = Pleroma.HTTP.MessageSignatures.content_digest(json)

        signed_headers = %{
          "content-digest" => content_digest
        }

        case Pleroma.Signature.sign_rfc9421(actor, "POST", inbox, signed_headers) do
          {:ok, signature_headers} ->
            HTTP.post(
              inbox,
              json,
              [
                {"Content-Type", "application/activity+json"},
                {"Content-Digest", content_digest},
                {"Date", date}
                | signature_headers
              ]
            )

          _ ->
            legacy_result
        end

      _ ->
        legacy_result
    end
  end

  defp signature_uri(inbox) when is_binary(inbox) do
    uri = URI.parse(inbox)

    with %URI{scheme: scheme, host: host} <- uri,
         true <- scheme in ["http", "https"],
         true <- is_binary(host),
         normalized_host when is_binary(normalized_host) <- Instances.host(inbox) do
      {:ok, uri, uri.path || "/"}
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
  def should_federate?(_, true), do: true
  def should_federate?(inbox, _) when not is_binary(inbox), do: false

  def should_federate?(inbox, _) do
    host = uri_host(inbox)

    quarantined_instances =
      Config.get([:instance, :quarantined_instances], [])
      |> Pleroma.Web.ActivityPub.MRF.instance_list_from_tuples()
      |> Pleroma.Web.ActivityPub.MRF.subdomains_regex()

    is_binary(host) and !Pleroma.Web.ActivityPub.MRF.subdomain_match?(quarantined_instances, host)
  end

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

    fetchers =
      with %Activity{data: %{"type" => "Delete"}} <- activity,
           %Object{id: object_id} <- Object.normalize(activity, fetch: false),
           fetchers <- User.get_delivered_users_by_object_id(object_id),
           _ <- Delivery.delete_all_by_object_id(object_id) do
        fetchers
      else
        _ ->
          []
      end

    mentioned = Pleroma.Web.Federator.Publisher.remote_users(actor, activity)
    non_mentioned = (followers ++ fetchers) -- mentioned

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

  def publish(%User{} = actor, %{data: %{"bcc" => bcc}} = activity)
      when is_list(bcc) and bcc != [] do
    public = is_public?(activity)
    {:ok, data} = Transmogrifier.prepare_outgoing(activity.data)
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
      Enum.each(Enum.with_index(inboxes), fn {inboxes, priority} ->
        Enum.each(inboxes, fn {inbox, unreachable_since} ->
          %User{ap_id: ap_id} =
            Enum.find(all_recipients, fn user -> determine_inbox(activity, user) == inbox end)

          # Get all the recipients on the same host and add them to cc. Otherwise, a remote
          # instance would only accept a first message for the first recipient and ignore the rest.
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

          Pleroma.Web.Federator.Publisher.enqueue_one(
            __MODULE__,
            %{
              inbox: inbox,
              json: json,
              actor_id: actor.id,
              id: activity.data["id"],
              unreachable_since: unreachable_since
            },
            priority: priority
          )
        end)
      end)
    end)
  end

  # Publishes an activity to all relevant peers.
  def publish(%User{} = actor, %Activity{} = activity) do
    public = is_public?(activity)

    if public && Config.get([:instance, :allow_relay]) do
      Logger.debug(fn -> "Relaying #{activity.data["id"]} out" end)
      Relay.publish(activity)
    end

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

    [{priority_inboxes, 0}, {inboxes, 1}]
    |> Enum.each(fn {inboxes, priority} ->
      inboxes
      |> Instances.filter_reachable()
      |> Enum.each(fn {inbox, unreachable_since} ->
        Pleroma.Web.Federator.Publisher.enqueue_one(
          __MODULE__,
          %{
            inbox: inbox,
            json: json,
            actor_id: actor.id,
            id: activity.data["id"],
            unreachable_since: unreachable_since
          },
          priority: priority
        )
      end)
    end)

    :ok
  end

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
