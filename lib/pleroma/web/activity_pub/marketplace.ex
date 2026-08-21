# Unfathomably BE
# ----------------
#
# File: marketplace.ex
#
# Purpose:
#   Deliver bounded local marketplace offers to explicitly connected
#   Flohmarkt-compatible instance actors.
#
# Responsibilities:
#   - expose the local /users/instance marketplace actor
#   - establish administrator-approved remote instance follows
#   - select eligible public offers for private connector delivery
#   - translate only those deliveries to the Flohmarkt-compatible shape
#
# This file intentionally does not crawl peers, poll listings, backfill old
# listings, or change ordinary ActivityPub delivery.

defmodule Pleroma.Web.ActivityPub.Marketplace do
  alias Pleroma.FederationConnectorPeer
  alias Pleroma.FollowingRelationship
  alias Pleroma.Object
  alias Pleroma.User
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Web.Endpoint

  require Logger

  @family "marketplace"
  @native_family "https://unfathomably.social/ns#family"
  @public "https://www.w3.org/ns/activitystreams#Public"
  @service_webfinger_nickname "instance"
  # `instance` is reserved for ordinary local registrations. The public actor
  # URI must still match Flohmarkt's /users/instance convention, so retain a
  # separate invisible local nickname and route the public alias explicitly.
  @service_nickname "federation_marketplace"

  def service_actor do
    actor_ap_id = service_actor_ap_id()

    case User.get_by_ap_id(actor_ap_id) do
      %User{} = actor -> {:ok, actor}
      nil -> create_service_actor(actor_ap_id)
    end
  end

  @doc """
  Returns the provisioned local marketplace actor without creating it.

  ActivityPub and WebFinger reads must be idempotent. Startup owns actor
  provisioning; request handlers use this lookup so an inbound discovery probe
  cannot mutate local federation state during an endpoint-startup race.
  """
  def get_service_actor do
    case User.get_by_ap_id(service_actor_ap_id()) do
      %User{} = actor -> {:ok, actor}
      nil -> {:error, :not_found}
    end
  end

  def service_actor_ap_id, do: Endpoint.url() <> "/users/instance"

  def service_actor_nickname, do: @service_nickname

  @doc """
  Provisions the local marketplace actor during application startup.

  This writes only the invisible local actor when it is missing. It never
  contacts a marketplace, follows a peer, or changes connector policy. Making
  the identity available before a peer probes WebFinger lets compatible
  marketplace software discover the instance without relying on a prior admin
  action or a direct actor-URL guess.
  """
  def init do
    case service_actor() do
      {:ok, _actor} ->
        :ok

      {:error, reason} ->
        Logger.error("Could not provision marketplace service actor: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Returns the conventional public handle used by marketplace software.

  The service actor deliberately has an internal nickname so it cannot collide
  with a local registration. Its ActivityPub URI and WebFinger identity must
  nevertheless remain `/users/instance` and `instance@host`, which is the
  convention used by Flohmarkt instance actors.
  """
  def service_actor_webfinger_nickname, do: @service_webfinger_nickname

  @doc """
  Returns the public WebFinger local part for an actor without creating one.

  WebFinger requests must be read-only. Looking up the conventional alias is
  therefore allowed to recognize an existing service actor but must not cause
  a marketplace connector actor to appear merely because a remote peer probed
  the instance.
  """
  def webfinger_nickname(%User{} = user) do
    if user.ap_id == service_actor_ap_id(),
      do: service_actor_webfinger_nickname(),
      else: user.nickname
  end

  def connect(actor_ap_id) do
    with {:ok, actor_ap_id} <- normalize_actor_ap_id(actor_ap_id),
         {:ok, service_actor} <- service_actor(),
         {:ok, %User{} = remote_actor} <- User.get_or_fetch_by_ap_id(actor_ap_id),
         :ok <- validate_remote_instance_actor(remote_actor),
         :ok <- follow_peer(service_actor, remote_actor),
         {:ok, peer} <- FederationConnectorPeer.upsert(@family, remote_actor.ap_id) do
      {:ok, peer}
    end
  end

  def disconnect(id) do
    case FederationConnectorPeer.get(id, @family) do
      %FederationConnectorPeer{} = peer ->
        withdraw_peer_follow(peer)
        FederationConnectorPeer.delete(peer)

      nil ->
        {:error, :not_found}
    end
  end

  def peers, do: FederationConnectorPeer.list(@family)

  @doc """
  Returns the author-facing connector state without exposing remote peer URLs.

  Peer selection is an administrator and moderation concern. Authors only need
  to know whether their eligible listing can leave this instance and what the
  receiving marketplace requires from its payload.
  """
  def connector_status do
    connection_states =
      FederationConnectorPeer.enabled(@family)
      |> Enum.map(fn peer ->
        peer.actor_ap_id |> User.get_cached_by_ap_id() |> connection_status()
      end)

    connected_peers = Enum.count(connection_states, &(&1 == :active))
    pending_peers = Enum.count(connection_states, &(&1 == :pending))
    unavailable_peers = Enum.count(connection_states, &(&1 == :unavailable))

    %{
      marketplace: %{
        connected_peers: connected_peers,
        pending_peers: pending_peers,
        ready: connected_peers > 0,
        requirements: ["public_offer", "price", "currency", "latitude", "longitude"],
        service_actor: service_actor_ap_id(),
        unavailable_peers: unavailable_peers
      }
    }
  end

  def peer_json(%FederationConnectorPeer{} = peer) do
    remote_actor = User.get_cached_by_ap_id(peer.actor_ap_id)
    status = if peer.enabled, do: connection_status(remote_actor), else: :disabled

    %{
      actor: peer.actor_ap_id,
      connected: status == :active,
      enabled: peer.enabled,
      id: to_string(peer.id),
      scope: peer.scope || %{},
      status: Atom.to_string(status)
    }
  end

  def add_peer_recipients(create_data, object) when is_map(create_data) and is_map(object) do
    recipients =
      if eligible_listing?(object) and public_activity?(create_data),
        do: connected_peer_actor_ids(),
        else: []

    data =
      if recipients == [] do
        create_data
      else
        Map.update(create_data, "bcc", recipients, &Enum.uniq(List.wrap(&1) ++ recipients))
      end

    {:ok, data}
  end

  def add_peer_recipients(create_data, _object), do: {:ok, create_data}

  def prepare_delivery_json(json, inbox) when is_binary(json) and is_binary(inbox) do
    with true <- marketplace_peer_inbox?(inbox),
         {:ok, activity} <- Jason.decode(json),
         {:ok, prepared} <- flohmarkt_activity(activity) do
      Jason.encode!(prepared)
    else
      _ -> json
    end
  rescue
    _ -> json
  catch
    _, _ -> json
  end

  def prepare_delivery_json(json, _inbox), do: json

  @doc false
  def prepare_activity_for_marketplace(activity), do: flohmarkt_activity(activity)

  def flohmarkt_object(%Object{data: object}, %User{} = seller) when is_map(object) do
    with true <- eligible_listing?(object),
         {:ok, item_id} <- compatibility_item_id(object),
         {:ok, coordinates} <- coordinates(object) do
      {:ok, flohmarkt_note(object, seller.ap_id, seller.follower_address, item_id, coordinates)}
    else
      false -> {:error, :not_marketplace_listing}
      error -> error
    end
  end

  def flohmarkt_object(_object, _seller), do: {:error, :not_marketplace_listing}

  defp create_service_actor(actor_ap_id) do
    case User.get_or_create_service_actor_by_ap_id(actor_ap_id, @service_nickname) do
      %User{} = actor -> {:ok, actor}
      {:ok, %User{} = actor} -> {:ok, actor}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:service_actor_creation_failed, other}}
    end
  end

  defp flohmarkt_activity(%{"type" => "Create", "object" => object} = activity)
       when is_map(object) do
    with true <- eligible_listing?(object),
         {:ok, item_id} <- compatibility_item_id(object),
         {:ok, coordinates} <- coordinates(object),
         actor when is_binary(actor) <- activity["actor"] do
      {:ok,
       activity
       |> Map.delete("bcc")
       |> Map.put("@context", activity_context())
       |> Map.put(
         "object",
         flohmarkt_note(object, actor, actor <> "/followers", item_id, coordinates)
       )}
    else
      _ -> {:error, :not_marketplace_listing}
    end
  end

  defp flohmarkt_activity(%{"type" => "Update", "object" => object} = activity)
       when is_map(object) do
    with true <- eligible_listing?(object),
         {:ok, item_id} <- compatibility_item_id(object) do
      if object["state"] in ["sold", "withdrawn"] do
        {:ok,
         activity
         |> Map.delete("bcc")
         |> Map.put("type", "Delete")
         |> Map.put("object", %{"id" => item_id, "type" => "Tombstone"})}
      else
        with {:ok, coordinates} <- coordinates(object),
             actor when is_binary(actor) <- activity["actor"] do
          {:ok,
           activity
           |> Map.delete("bcc")
           |> Map.put("@context", activity_context())
           |> Map.put(
             "object",
             flohmarkt_note(object, actor, actor <> "/followers", item_id, coordinates)
           )}
        else
          _ -> {:error, :not_marketplace_listing}
        end
      end
    else
      _ -> {:error, :not_marketplace_listing}
    end
  end

  defp flohmarkt_activity(%{"type" => "Delete", "object" => object_ap_id} = activity)
       when is_binary(object_ap_id) do
    with %Object{data: object} <- Object.get_cached_by_ap_id(object_ap_id),
         true <- eligible_listing?(object),
         {:ok, item_id} <- compatibility_item_id(object) do
      {:ok,
       activity
       |> Map.delete("bcc")
       |> Map.put("object", %{"id" => item_id, "type" => "Tombstone"})}
    else
      _ -> {:error, :not_marketplace_listing}
    end
  end

  defp flohmarkt_activity(_activity), do: {:error, :not_marketplace_activity}

  defp flohmarkt_note(object, actor, follower_address, item_id, coordinates) do
    title = scalar(object["name"])
    content = scalar(object["content"])
    price = scalar(object["price"])
    currency = scalar(object["priceCurrency"])

    %{
      "@context" => activity_context(),
      "actor" => actor,
      "attributedTo" => actor,
      "attachment" =>
        List.wrap(object["attachment"]) ++ [fep0837_proposal(object, actor, item_id, coordinates)],
      "cc" => [follower_address],
      "content" => content,
      "flohmarkt:data" => %{
        "coordinates" => %{"lat" => coordinates.latitude, "lng" => coordinates.longitude},
        "currency" => currency,
        "description" => content,
        "name" => title,
        "original_id" => Path.basename(item_id),
        "price" => price
      },
      "id" => item_id,
      "name" => title,
      "published" => object["published"],
      "tag" => List.wrap(object["tag"]),
      "to" => [@public],
      "type" => "Note",
      "url" => public_url(object, item_id)
    }
  end

  defp fep0837_proposal(object, actor, item_id, coordinates) do
    %{
      "attributedTo" => actor,
      "content" => scalar(object["content"]),
      "id" => String.replace(item_id, "/items/", "/proposals/"),
      "location" => %{
        "latitude" => coordinates.latitude,
        "longitude" => coordinates.longitude,
        "type" => "Place"
      },
      "name" => scalar(object["name"]),
      "published" => object["published"],
      "publishes" => %{
        "action" => "transfer",
        "resourceQuantity" => %{
          "hasNumericalValue" => scalar(object["quantity"]) || "1",
          "hasUnit" => "one"
        },
        "type" => "Intent"
      },
      "purpose" => "offer",
      "reciprocal" => %{
        "action" => "transfer",
        "resourceQuantity" => %{
          "hasNumericalValue" => scalar(object["price"]),
          "hasUnit" => scalar(object["priceCurrency"])
        },
        "type" => "Intent"
      },
      "to" => [@public],
      "type" => "Proposal"
    }
  end

  defp activity_context do
    [
      "https://www.w3.org/ns/activitystreams",
      %{
        "Agreement" => "vf:Agreement",
        "Commitment" => "vf:Commitment",
        "Intent" => "vf:Intent",
        "Proposal" => "vf:Proposal",
        "action" => "vf:action",
        "hasNumericalValue" => "om2:hasNumericalValue",
        "hasUnit" => "om2:hasUnit",
        "om2" => "http://www.ontology-of-units-of-measure.org/resource/om-2/",
        "publishes" => "vf:publishes",
        "purpose" => "vf:purpose",
        "reciprocal" => "vf:reciprocal",
        "resourceQuantity" => "vf:resourceQuantity",
        "vf" => "https://w3id.org/valueflows/ont/vf#"
      }
    ]
  end

  defp connected_peer_actor_ids do
    with {:ok, service_actor} <- service_actor() do
      FederationConnectorPeer.enabled(@family)
      |> Enum.map(& &1.actor_ap_id)
      |> Enum.filter(fn actor_ap_id ->
        case User.get_cached_by_ap_id(actor_ap_id) do
          %User{} = remote_actor -> FollowingRelationship.following?(service_actor, remote_actor)
          nil -> false
        end
      end)
    else
      _ -> []
    end
  end

  defp marketplace_peer_inbox?(inbox) do
    FederationConnectorPeer.enabled(@family)
    |> Enum.any?(fn peer ->
      case User.get_cached_by_ap_id(peer.actor_ap_id) do
        %User{} = remote_actor ->
          inbox in Enum.reject([remote_actor.inbox, remote_actor.shared_inbox], &is_nil/1)

        nil ->
          false
      end
    end)
  end

  defp connection_status(%User{} = remote_actor) do
    case User.get_cached_by_ap_id(service_actor_ap_id()) do
      %User{} = service_actor ->
        case FollowingRelationship.get(service_actor, remote_actor) do
          %{state: :follow_accept} -> :active
          %{state: :follow_pending} -> :pending
          _ -> :unavailable
        end

      nil ->
        :unavailable
    end
  end

  defp connection_status(_), do: :unavailable

  defp follow_peer(service_actor, remote_actor) do
    if FollowingRelationship.following?(service_actor, remote_actor) do
      :ok
    else
      case CommonAPI.follow(service_actor, remote_actor) do
        {:ok, _follower, _followed, _activity} -> :ok
        {:error, :already_following} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Connector removal must stop delivery immediately even when a remote server
  # is temporarily unavailable. The normal CommonAPI path records and queues
  # the signed Undo when possible; deletion of our local connector policy is
  # intentionally independent from that best-effort network acknowledgement.
  defp withdraw_peer_follow(%FederationConnectorPeer{} = peer) do
    with {:ok, service_actor} <- service_actor(),
         %User{} = remote_actor <- User.get_cached_by_ap_id(peer.actor_ap_id),
         %FollowingRelationship{} <- FollowingRelationship.get(service_actor, remote_actor) do
      case CommonAPI.unfollow(service_actor, remote_actor) do
        {:ok, _service_actor} ->
          :ok

        error ->
          Logger.warning(
            "Could not withdraw marketplace connector follow for #{peer.actor_ap_id}: #{inspect(error)}"
          )
      end
    else
      _ -> :ok
    end
  end

  defp validate_remote_instance_actor(%User{local: true}), do: {:error, :local_actor}

  defp validate_remote_instance_actor(%User{ap_id: ap_id}) do
    case normalize_actor_ap_id(ap_id) do
      {:ok, ^ap_id} -> :ok
      _ -> {:error, :not_instance_actor}
    end
  end

  defp normalize_actor_ap_id(value) when is_binary(value) do
    value = String.trim(value)
    uri = URI.parse(value)

    cond do
      uri.scheme != "https" or not is_binary(uri.host) or uri.host == "" ->
        {:error, :invalid_actor_url}

      uri.query || uri.fragment || uri.userinfo ->
        {:error, :invalid_actor_url}

      uri.path in [nil, "", "/"] ->
        {:ok, "https://#{uri.host}" <> port_suffix(uri) <> "/users/instance"}

      uri.path == "/users/instance" ->
        {:ok, URI.to_string(uri)}

      true ->
        {:error, :not_instance_actor}
    end
  rescue
    URI.Error -> {:error, :invalid_actor_url}
  end

  defp normalize_actor_ap_id(_), do: {:error, :invalid_actor_url}

  defp port_suffix(%URI{port: nil}), do: ""
  defp port_suffix(%URI{port: 443}), do: ""
  defp port_suffix(%URI{port: port}), do: ":#{port}"

  defp public_activity?(activity),
    do: @public in List.wrap(activity["to"]) or @public in List.wrap(activity["cc"])

  defp eligible_listing?(object) when is_map(object) do
    object[@native_family] == "markets" and object["listingType"] == "offer" and
      object["marketplaceDelivery"] == true and
      is_binary(scalar(object["price"])) and is_binary(scalar(object["priceCurrency"])) and
      match?({:ok, _coordinates}, coordinates(object))
  end

  defp eligible_listing?(_), do: false

  defp coordinates(object) do
    with {:ok, latitude} <- bounded_coordinate(scalar(object["latitude"]), -90.0, 90.0),
         {:ok, longitude} <- bounded_coordinate(scalar(object["longitude"]), -180.0, 180.0) do
      {:ok, %{latitude: latitude, longitude: longitude}}
    end
  end

  defp bounded_coordinate(value, minimum, maximum) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} when number >= minimum and number <= maximum -> {:ok, value}
      _ -> {:error, :invalid_coordinates}
    end
  end

  defp bounded_coordinate(_value, _minimum, _maximum), do: {:error, :invalid_coordinates}

  defp compatibility_item_id(object) do
    with object_id when is_binary(object_id) <- object["id"],
         %URI{scheme: scheme, host: host, path: path} <- URI.parse(object_id),
         true <- scheme in ["http", "https"] and is_binary(host),
         uuid when is_binary(uuid) and uuid != "" <- Path.basename(path),
         nickname when is_binary(nickname) and nickname != "" <- actor_nickname(object) do
      {:ok, Endpoint.url() <> "/users/" <> nickname <> "/items/" <> uuid}
    else
      _ -> {:error, :invalid_object_id}
    end
  rescue
    _ -> {:error, :invalid_object_id}
  end

  defp actor_nickname(%{"actor" => actor}) when is_binary(actor) do
    actor |> URI.parse() |> Map.get(:path, "") |> Path.basename()
  end

  defp actor_nickname(_object), do: nil

  defp public_url(object, fallback) do
    case object["url"] do
      url when is_binary(url) -> url
      [%{"href" => url} | _] when is_binary(url) -> url
      [%{"url" => url} | _] when is_binary(url) -> url
      _ -> fallback
    end
  end

  defp scalar(value) when is_binary(value), do: value
  defp scalar(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp scalar(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp scalar(_value), do: nil
end

# end of lib/pleroma/web/activity_pub/marketplace.ex
