# Unfathomably BE
# ----------------
#
# File: diaspora/publisher.ex
#
# Purpose:
#   Publish eligible local activities as native diaspora* entities.
#
# Responsibilities:
#   - encode posts, comments, likes, reshares, quotes-as-links, and retractions
#   - sign public deliveries and send them only to locally relevant pods
#   - retain deterministic GUID mappings for retries and later interactions
#
# This file intentionally does NOT broadcast to every known pod, publish private
# messages, or claim unsupported ActivityPub object types have native schemas.

defmodule Pleroma.Diaspora.Publisher do
  import Ecto.Query

  alias Pleroma.Activity
  alias Pleroma.Diaspora
  alias Pleroma.Diaspora.Entity
  alias Pleroma.Diaspora.Identities
  alias Pleroma.Diaspora.Protocol
  alias Pleroma.Diaspora.Record
  alias Pleroma.Diaspora.Store
  alias Pleroma.FollowingRelationship
  alias Pleroma.HTML
  alias Pleroma.Keys
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User

  def publish(%Activity{} = activity) do
    with %User{} = actor <- User.get_cached_by_ap_id(activity.data["actor"]),
         true <- actor.local,
         false <- Identities.mirror?(actor),
         false <- Pleroma.Nostr.Identity.mirror?(actor),
         false <- Pleroma.ATProto.Identities.mirror?(actor),
         false <- activity.data["unfathomably:diaspora_ingest"] == true,
         false <- activity.data["unfathomably:nostr_ingest"] == true,
         false <- activity.data["unfathomably:atproto_ingest"] == true do
      case activity.data["type"] do
        "Follow" -> publish_contact(activity, actor, true)
        "Undo" -> publish_undo_contact(activity, actor)
        "Update" -> publish_profile(activity, actor)
        _ -> publish_public(activity, actor)
      end
    else
      _ -> :ok
    end
  end

  def publish(_activity), do: :ok

  def publish_unfollow(%Activity{}, %User{} = actor, %User{} = target) do
    publish_contact_target(actor, target, false)
  end

  def publish_unfollow(_activity, _actor, _target), do: :ok

  defp publish_profile(activity, actor) do
    with %{"id" => actor_id, "type" => actor_type} <- activity.data["object"],
         true <- actor_id == actor.ap_id and actor_type in ["Application", "Person", "Service"],
         data <- profile_data(activity, actor),
         pods when pods != [] <- delivery_pods(data, actor),
         {:ok, envelope} <- Protocol.build_public_envelope(actor, entity_xml(data)) do
      deliver(envelope, pods)
    else
      {:error, _reason} = error -> error
      _ -> :ok
    end
  end

  defp publish_public(activity, actor) do
    with {:ok, data, object_id} <- native_data(activity, actor),
         pods when pods != [] <- delivery_pods(data, actor),
         {:ok, data} <- maybe_sign_relayable(data, actor),
         xml <- entity_xml(data),
         {:ok, _record} <-
           Store.put(data, xml,
             local: true,
             ap_activity_id: activity.id,
             ap_activity_uri: activity.data["id"],
             ap_object_id: object_id
           ),
         {:ok, envelope} <- Protocol.build_public_envelope(actor, xml) do
      deliver(envelope, pods)
    else
      :ignore -> :ok
      [] -> :ok
      {:error, _reason} = error -> error
      _ -> :ok
    end
  end

  defp publish_contact(activity, actor, following) do
    with target_id when is_binary(target_id) <- object_id(activity.data["object"]),
         %User{} = target <- User.get_cached_by_ap_id(target_id) do
      publish_contact_target(actor, target, following)
    else
      _ -> :ok
    end
  end

  defp publish_contact_target(actor, target, following) do
    with %Entity{} = entity <- Identities.get_by_user(target),
         data = %{
           "type" => "contact",
           "author" => Diaspora.diaspora_id(actor),
           "recipient" => entity.diaspora_id,
           "following" => to_string(following),
           "sharing" => to_string(following),
           "blocking" => "false"
         },
         {:ok, envelope} <- Protocol.build_public_envelope(actor, entity_xml(data)),
         {:ok, payload} <- Protocol.build_private_payload(envelope, entity.public_key) do
      deliver_private(entity, payload)
    else
      {:error, _reason} = error -> error
      _ -> :ok
    end
  end

  defp publish_undo_contact(activity, actor) do
    with target_id when is_binary(target_id) <- object_id(activity.data["object"]),
         %Activity{data: %{"type" => "Follow"}} = follow <- Activity.get_by_ap_id(target_id) do
      publish_contact(follow, actor, false)
    else
      {:error, _reason} = error -> error
      _ -> :ok
    end
  end

  defp native_data(%Activity{data: %{"type" => "Create"}} = activity, actor) do
    with true <-
           "https://www.w3.org/ns/activitystreams#Public" in List.wrap(activity.data["to"]) or
             "https://www.w3.org/ns/activitystreams#Public" in List.wrap(activity.data["cc"]),
         %Object{} = object <- Object.normalize(activity, fetch: false),
         false <- object.data["type"] == "ChatMessage" do
      guid = guid(activity.data["id"])
      parent = Store.get_by_ap_object_id(object.data["inReplyTo"])

      data =
        if parent do
          base_data("comment", actor, guid, activity)
          |> Map.put("parent_guid", parent.guid)
        else
          base_data("status_message", actor, guid, activity)
          |> Map.put("public", "true")
        end

      text = object_text(object)
      {:ok, Map.put(data, "text", text), object.data["id"]}
    else
      _ -> :ignore
    end
  end

  defp native_data(%Activity{data: %{"type" => "Like"}} = activity, actor) do
    with %Record{} = target <- target_record(activity.data["object"]) do
      data =
        base_data("like", actor, guid(activity.data["id"]), activity)
        |> Map.put("parent_guid", target.guid)
        |> Map.put("parent_type", parent_type(target))
        |> Map.put("positive", "true")

      {:ok, data, nil}
    else
      _ -> :ignore
    end
  end

  defp native_data(%Activity{data: %{"type" => "Announce"}} = activity, actor) do
    with %Record{} = target <- target_record(activity.data["object"]) do
      data =
        base_data("reshare", actor, guid(activity.data["id"]), activity)
        |> Map.put("root_author", target.author)
        |> Map.put("root_guid", target.guid)

      {:ok, data, nil}
    else
      _ -> :ignore
    end
  end

  defp native_data(%Activity{data: %{"type" => "Delete"}} = activity, actor) do
    with %Record{} = target <- target_record(activity.data["object"]),
         true <- target.local do
      data =
        base_data("retraction", actor, guid(activity.data["id"]), activity)
        |> Map.put("target_guid", target.guid)
        |> Map.put("target_type", parent_type(target))

      {:ok, data, nil}
    else
      _ -> :ignore
    end
  end

  defp native_data(_activity, _actor), do: :ignore

  defp base_data(type, actor, guid, activity) do
    %{
      "type" => type,
      "author" => Diaspora.diaspora_id(actor),
      "guid" => guid,
      "created_at" => activity.data["published"] || DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp profile_data(activity, actor) do
    %{
      "type" => "profile",
      "author" => Diaspora.diaspora_id(actor),
      "edited_at" => activity.data["published"] || DateTime.to_iso8601(DateTime.utc_now()),
      "full_name" => actor.name || actor.nickname,
      "image_url" => avatar_url(actor.avatar),
      "image_url_medium" => avatar_url(actor.avatar),
      "image_url_small" => avatar_url(actor.avatar),
      "bio" => profile_bio(actor),
      "searchable" => to_string(actor.is_discoverable != false),
      "public" => "true",
      "nsfw" => "false"
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp profile_bio(%User{raw_bio: raw_bio}) when is_binary(raw_bio), do: raw_bio

  defp profile_bio(%User{bio: bio}) when is_binary(bio) do
    bio |> HTML.strip_tags() |> String.trim()
  end

  defp profile_bio(_actor), do: ""

  defp avatar_url(%{"url" => [%{"href" => url} | _]}) when is_binary(url), do: url
  defp avatar_url(%{"url" => %{"href" => url}}) when is_binary(url), do: url
  defp avatar_url(%{"url" => url}) when is_binary(url), do: url
  defp avatar_url(_avatar), do: nil

  defp object_text(object) do
    text = object.data["content"] |> to_string() |> HTML.strip_tags() |> String.trim()

    case object.data["quoteUrl"] do
      quote_url when is_binary(quote_url) -> String.slice(text <> "\n\n" <> quote_url, 0, 300_000)
      _ -> String.slice(text, 0, 300_000)
    end
  end

  defp entity_xml(data) do
    fields =
      data
      |> Map.drop(["type"])
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join("", fn {key, value} -> "<#{key}>#{escape(value)}</#{key}>" end)

    "<#{data["type"]}>#{fields}</#{data["type"]}>"
  end

  defp maybe_sign_relayable(%{"type" => type} = data, actor)
       when type in ["comment", "like"] do
    values =
      data
      |> Map.drop(["type", "author_signature"])
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {_key, value} -> to_string(value) end)
      |> Enum.join(";")

    with {:ok, private_key, _public_key} <- Keys.keys_from_pem(actor.keys) do
      signature = :public_key.sign(values, :sha256, private_key) |> Base.encode64()
      {:ok, Map.put(data, "author_signature", signature)}
    else
      _ -> {:error, :could_not_sign_relayable}
    end
  end

  defp maybe_sign_relayable(data, _actor), do: {:ok, data}

  defp deliver(envelope, pods) do
    Enum.reduce_while(pods, :ok, fn pod_url, :ok ->
      url = pod_url |> URI.merge("/receive/public") |> URI.to_string()

      case Pleroma.Workers.DiasporaDeliveryWorker.enqueue_delivery(
             url,
             envelope,
             "application/magic-envelope+xml"
           ) do
        {:ok, _job} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp deliver_private(entity, payload) do
    url = entity.receive_url || "#{entity.pod_url}/receive/users/#{entity.guid}"

    with true <- Pleroma.ATProto.URL.public_https_url?(url),
         {:ok, _job} <-
           Pleroma.Workers.DiasporaDeliveryWorker.enqueue_delivery(
             url,
             Jason.encode!(payload),
             "application/json"
           ) do
      :ok
    else
      false -> {:error, :unsafe_destination}
      {:error, _reason} = error -> error
    end
  end

  defp delivery_pods(%{"type" => type} = data, actor)
       when type in ["comment", "like", "retraction"] do
    guid = data["parent_guid"] || data["target_guid"]

    case guid |> Store.get() |> root_record(32) do
      %Record{local: false, author: author} ->
        case Identities.get_by_diaspora_id(author) do
          %Entity{pod_url: pod_url} when is_binary(pod_url) -> [pod_url]
          _ -> []
        end

      %Record{local: true} = root ->
        case local_record_actor(root) do
          %User{} = root_actor -> follower_pods(root_actor)
          _ -> follower_pods(actor)
        end

      _ ->
        []
    end
  end

  defp delivery_pods(_data, actor), do: follower_pods(actor)

  defp follower_pods(%User{id: actor_id}) do
    Entity
    |> join(:inner, [entity], relationship in FollowingRelationship,
      on: relationship.follower_id == entity.user_id
    )
    |> where(
      [_entity, relationship],
      relationship.following_id == ^actor_id and relationship.state == ^:follow_accept
    )
    |> select([entity], entity.pod_url)
    |> distinct(true)
    |> limit(100)
    |> Repo.all()
  end

  defp root_record(nil, _remaining), do: nil
  defp root_record(record, 0), do: record

  defp root_record(%Record{data: %{"parent_guid" => parent_guid}} = record, remaining)
       when is_binary(parent_guid) do
    case Store.get(parent_guid) do
      %Record{} = parent -> root_record(parent, remaining - 1)
      _ -> record
    end
  end

  defp root_record(record, _remaining), do: record

  defp local_record_actor(%Record{ap_activity_id: activity_id}) when not is_nil(activity_id) do
    with %Activity{} = activity <- Activity.get_by_id(activity_id),
         actor_id when is_binary(actor_id) <- activity.data["actor"] do
      User.get_cached_by_ap_id(actor_id)
    end
  end

  defp local_record_actor(_record), do: nil

  defp target_record(value) do
    value |> object_id() |> Store.get_by_ap_object_id()
  end

  defp object_id(%{"id" => id}) when is_binary(id), do: id
  defp object_id(id) when is_binary(id), do: id
  defp object_id(_value), do: nil

  defp parent_type(%Record{type: "comment"}), do: "Comment"
  defp parent_type(%Record{}), do: "Post"

  defp guid(value) do
    value = to_string(value)

    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
  end

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end

# end of diaspora/publisher.ex
