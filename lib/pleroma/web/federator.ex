# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Federator do
  alias Pleroma.Activity
  alias Pleroma.ATProto.BridgyCompat
  alias Pleroma.Object.Containment
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.CustomObject
  alias Pleroma.Web.ActivityPub.Transmogrifier
  alias Pleroma.Web.ActivityPub.Utils
  alias Pleroma.Web.Federator.Publisher
  alias Pleroma.Workers.PublisherWorker
  alias Pleroma.Workers.ReceiverWorker
  alias Pleroma.Workers.SignatureRetryWorker

  require Logger

  @behaviour Pleroma.Web.Federator.Publishing

  @doc """
  Returns `true` if the distance to target object does not exceed max configured value.
  Serves to prevent fetching of very long threads, especially useful on smaller instances.
  Addresses [memory leaks on recursive replies fetching](https://git.pleroma.social/pleroma/pleroma/issues/161).
  Applies to fetching of both ancestor (reply-to) and child (reply) objects.
  """
  # credo:disable-for-previous-line Credo.Check.Readability.MaxLineLength
  def allowed_thread_distance?(distance) do
    max_distance = Pleroma.Config.get([:instance, :federation_incoming_replies_max_depth])

    if max_distance && max_distance >= 0 do
      # Default depth is 0 (an object has zero distance from itself in its thread)
      (distance || 0) <= max_distance
    else
      true
    end
  end

  # Client API
  def incoming_failed_signature_ap_doc(%{
        method: method,
        params: params,
        req_headers: req_headers,
        request_path: request_path,
        query_string: query_string
      }) do
    SignatureRetryWorker.new(
      %{
        "op" => "incoming_failed_signature_ap_doc",
        "method" => method,
        "req_headers" => req_headers,
        "params" => params,
        "request_path" => request_path,
        "query_string" => query_string,
        "timeout" => :timer.seconds(20)
      },
      priority: 2
    )
    |> Oban.insert()
  end

  def incoming_ap_doc(%{params: params, req_headers: req_headers}) do
    if legacy_nostr_bridge_envelope?(params) do
      {:ok, :native_nostr_required}
    else
      ReceiverWorker.enqueue(
        "incoming_ap_doc",
        incoming_job_args(params, %{"req_headers" => req_headers}),
        priority: 2
      )
    end
  end

  def incoming_ap_doc(%{"type" => "Delete"} = params) do
    if legacy_nostr_bridge_envelope?(params) do
      {:ok, :native_nostr_required}
    else
      ReceiverWorker.enqueue("incoming_ap_doc", incoming_job_args(params), priority: 3)
    end
  end

  def incoming_ap_doc(params) do
    if legacy_nostr_bridge_envelope?(params) do
      {:ok, :native_nostr_required}
    else
      ReceiverWorker.enqueue("incoming_ap_doc", incoming_job_args(params))
    end
  end

  defp legacy_nostr_bridge_envelope?(params) do
    if Pleroma.Nostr.MostrCompat.legacy_envelope?(params) do
      params
      |> Map.get("actor")
      |> Utils.get_ap_id()
      |> Pleroma.Workers.LegacyNostrUnsubscribeWorker.enqueue()

      true
    else
      false
    end
  end

  defp incoming_job_args(params, extra \\ %{}) do
    extra
    |> Map.put("params", params)
    |> Map.put("activity_key", incoming_activity_key(params))
  end

  # Some software legitimately reuses a Create ID for a later Delete. The
  # activity type therefore forms part of the job identity, while idless
  # activities receive a deterministic content identity rather than all
  # competing for the same nil uniqueness key.
  defp incoming_activity_key(%{"id" => id, "type" => type})
       when is_binary(id) and id != "" and is_binary(type) and type != "" do
    type <> ":" <> id
  end

  defp incoming_activity_key(params) do
    digest =
      params
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "sha256:" <> digest
  end

  @impl true
  def publish(%{id: "pleroma:fakeid"} = activity) do
    if Pleroma.Federation.enabled?() do
      perform(:publish, activity)
    else
      {:ok, :federation_disabled}
    end
  end

  @impl true
  def publish(%Pleroma.Activity{data: %{"type" => type}} = activity) do
    if Pleroma.Federation.enabled?() do
      PublisherWorker.enqueue("publish", publish_args(activity), priority: publish_priority(type))
    else
      {:ok, :federation_disabled}
    end
  end

  @doc """
  Re-enqueues a stored activity while bounding repeated recovery requests.

  This is intended for explicit recovery workflows, not ordinary federation.
  Completed jobs remain part of the uniqueness window so a fast delivery does
  not let repeated button presses immediately enqueue the same activity again.
  """
  def republish(%Pleroma.Activity{data: %{"type" => type}} = activity, period \\ 900)
      when is_integer(period) and period > 0 do
    PublisherWorker.enqueue("publish", publish_args(activity),
      priority: publish_priority(type),
      unique: [period: period, states: Oban.Job.states()]
    )
  end

  defp publish_priority("Delete"), do: 3
  defp publish_priority(_), do: 0

  defp publish_args(
         %Activity{id: activity_id, data: %{"type" => "Undo", "object" => object}} = activity
       )
       when is_map(object) do
    %{"activity_id" => activity_id, "activity_data" => activity.data}
  end

  defp publish_args(%Activity{id: activity_id}), do: %{"activity_id" => activity_id}

  # Job Worker Callbacks

  @spec perform(atom(), module(), any()) :: {:ok, any()} | {:error, any()}
  def perform(:publish_one, module, params) do
    apply(module, :publish_one, [params])
  end

  def perform(:publish, activity) do
    Logger.debug(fn -> "Running publish for #{activity.data["id"]}" end)

    %User{} = actor = User.get_cached_by_ap_id(activity.data["actor"])
    Publisher.publish(actor, activity)
  end

  def perform(:incoming_ap_doc, params) do
    Logger.debug("Handling incoming AP activity")

    if legacy_nostr_bridge_envelope?(params) do
      {:error, {:reject, :native_nostr_required}}
    else
      actor =
        params
        |> Map.get("actor")
        |> Utils.get_ap_id()

      # NOTE: we use the actor ID to do the containment, this is fine because an
      # actor shouldn't be acting on objects outside their own AP server.
      with {_, :ok} <-
             {:correct_origin?, Containment.contain_origin_from_id(actor, params)},
           {_, {:ok, _user}} <- {:actor, User.get_or_fetch_by_ap_id(actor)},
           {:ok, activity} <- handle_incoming_or_duplicate(params),
           {:forward, :ok} <-
             {:forward, Pleroma.Web.ActivityPub.Forwarder.maybe_forward(params, activity)} do
        {:ok, activity}
      else
        {:correct_origin?, _} ->
          Logger.debug("Origin containment failure for #{params["id"]}")
          {:error, :origin_containment_failed}

        {:error, :already_present} ->
          Logger.debug("Already had #{params["id"]}")
          {:error, :already_present}

        {:actor, e} ->
          Logger.debug("Unhandled actor #{actor}, #{inspect(e)}")
          {:error, e}

        {:error, {:validate_object, _}} = e ->
          Logger.error("Incoming AP doc validation error: #{inspect(e)}")
          Logger.debug(Jason.encode!(params, pretty: true))
          e

        {:forward, {:error, reason}} ->
          {:error, {:forward_enqueue_failed, reason}}

        e ->
          # Just drop those for now
          Logger.debug(fn ->
            "Unhandled activity: #{inspect(e)}\n" <> Jason.encode!(params, pretty: true)
          end)

          {:error, e}
      end
    end
  end

  defp handle_incoming_or_duplicate(params) do
    BridgyCompat.handle_incoming(params, fn reconciled ->
      Pleroma.Nostr.MostrCompat.handle_incoming(reconciled, &handle_reconciled_incoming/1)
    end)
  end

  defp handle_reconciled_incoming(params) do
    case Activity.normalize(params["id"]) do
      nil ->
        Transmogrifier.handle_incoming(params)

      %Activity{} = activity ->
        maybe_reprocess_colliding_activity(activity, params)
    end
  end

  defp maybe_reprocess_colliding_activity(
         %Activity{} = _activity,
         %{"type" => "Create", "object" => object} = params
       ) do
    if CustomObject.custom_object?(object) do
      Transmogrifier.handle_incoming(params)
    else
      {:error, :already_present}
    end
  end

  #
  # BookWyrm uses the original Create activity ID again when it deletes a
  # status. The duplicate guard must not confuse that lifecycle transition
  # with a retransmitted Create. Give the inbound Delete a stable local ID so
  # normal Delete validation still decides whether the actor has authority.
  #
  defp maybe_reprocess_colliding_activity(
         %Activity{data: %{"type" => "Create", "object" => existing_object}},
         %{"id" => id, "type" => "Delete", "object" => deleted_object} = params
       ) do
    if Utils.get_ap_id(existing_object) == Utils.get_ap_id(deleted_object) do
      params
      |> Map.put("id", id <> "#unfathomably-delete")
      |> Transmogrifier.handle_incoming()
    else
      {:error, :already_present}
    end
  end

  defp maybe_reprocess_colliding_activity(%Activity{}, _params),
    do: {:error, :already_present}
end
