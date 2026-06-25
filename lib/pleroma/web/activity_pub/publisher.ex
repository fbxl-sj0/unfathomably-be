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
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Relay
  alias Pleroma.Web.ActivityPub.Transmogrifier

  require Pleroma.Constants

  import Pleroma.Web.ActivityPub.Visibility

  @behaviour Pleroma.Web.Federator.Publisher

  require Logger

  @moduledoc """
  ActivityPub outgoing federation module.
  """

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
  def publish_one(%{inbox: inbox, json: json, actor: %User{} = actor, id: id} = params) do
    Logger.debug("Federating #{id} to #{inbox}")
    uri = %{path: path} = URI.parse(inbox)
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
           HTTP.post(
             inbox,
             json,
             [
               {"Content-Type", "application/activity+json"},
               {"Date", date},
               {"signature", signature},
               {"digest", digest}
             ]
           ) do
      if not Map.has_key?(params, :unreachable_since) || params[:unreachable_since] do
        Instances.set_reachable(inbox)
      end

      result
    else
      {_post_result, %{status: code} = response} ->
        unless params[:unreachable_since], do: Instances.set_unreachable(inbox)

        Logger.metadata(activity: id, inbox: inbox, status: code)
        Logger.debug("Publisher failed to inbox #{inbox} with status #{code}")

        case response do
          %{status: 403} -> {:discard, :forbidden}
          %{status: 404} -> {:discard, :not_found}
          %{status: 410} -> {:discard, :not_found}
          _ -> {:error, response}
        end

      {:error, :pool_full} ->
        Logger.debug("Publisher snoozing worker job due to full connection pool")
        {:snooze, 30}

      e ->
        unless params[:unreachable_since], do: Instances.set_unreachable(inbox)
        Logger.metadata(activity: id, inbox: inbox)
        Logger.debug("Publisher failed to inbox #{inbox}: #{inspect(e)}")
        {:error, e}
    end
  end

  def publish_one(%{actor_id: actor_id} = params) do
    actor = User.get_cached_by_id(actor_id)

    params
    |> Map.delete(:actor_id)
    |> Map.put(:actor, actor)
    |> publish_one()
  end

  defp signature_host(%URI{port: port, scheme: scheme, host: host}) do
    if port == URI.default_port(scheme) do
      host
    else
      "#{host}:#{port}"
    end
  end

  def should_federate?(nil, _), do: false
  def should_federate?(_, true), do: true

  def should_federate?(inbox, _) do
    %{host: host} = URI.parse(inbox)

    quarantined_instances =
      Config.get([:instance, :quarantined_instances], [])
      |> Pleroma.Web.ActivityPub.MRF.instance_list_from_tuples()
      |> Pleroma.Web.ActivityPub.MRF.subdomains_regex()

    !Pleroma.Web.ActivityPub.MRF.subdomain_match?(quarantined_instances, host)
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
        URI.parse(ap_id).host == origin_host
      end)
    else
      _ -> followers
    end
  end

  defp maybe_skip_group_announce_origin(followers, _actor, _activity), do: followers

  defp announce_origin_host(object_ap_id) do
    case Object.get_cached_by_ap_id(object_ap_id) do
      %Object{data: %{"actor" => object_actor}} when is_binary(object_actor) ->
        URI.parse(object_actor).host

      _ ->
        URI.parse(object_ap_id).host
    end
  end

  defp get_cc_ap_ids(ap_id, recipients) do
    host = Map.get(URI.parse(ap_id), :host)

    recipients
    |> Enum.filter(fn %User{ap_id: ap_id} -> Map.get(URI.parse(ap_id), :host) == host end)
    |> Enum.map(& &1.ap_id)
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
    json = Jason.encode!(data)

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
end
