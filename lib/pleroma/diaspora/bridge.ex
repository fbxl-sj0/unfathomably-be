# Unfathomably BE
# ----------------
#
# File: diaspora/bridge.ex
#
# Purpose:
#   Translate verified, locally relevant diaspora* entities into activities.
#
# Responsibilities:
#   - enforce follow and direct-interaction relevance before persistence
#   - project status messages, comments, likes, reshares, and retractions
#   - preserve native GUID and author provenance on projected objects
#
# This file intentionally does NOT accept unsigned XML, ingest arbitrary public
# pod traffic, or implement diaspora* private messages.

defmodule Pleroma.Diaspora.Bridge do
  import Ecto.Query

  alias Pleroma.Activity
  alias Pleroma.Diaspora.Identities
  alias Pleroma.Diaspora.Protocol
  alias Pleroma.Diaspora.Record
  alias Pleroma.Diaspora.Store
  alias Pleroma.FollowingRelationship
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Web.CommonAPI.ActivityDraft

  def receive_public(envelope) do
    with true <- Pleroma.Diaspora.enabled?(),
         {:ok, data, raw_xml} <- Protocol.parse_public_envelope(envelope),
         true <- data["type"] != "contact" and relevant?(data),
         true <- valid_envelope_author?(data),
         {:ok, stored} <- Store.put(data, raw_xml),
         :ok <- maybe_translate(data, stored) do
      :ok
    else
      false -> {:error, :not_relevant}
      error -> error
    end
  end

  def receive_private(envelope, %User{local: true} = recipient) do
    with true <- Pleroma.Diaspora.enabled?(),
         {:ok, data, raw_xml} <- Protocol.parse_public_envelope(envelope),
         true <- privately_relevant?(data, recipient),
         true <- valid_envelope_author?(data),
         {:ok, stored} <- Store.put(data, raw_xml),
         :ok <- maybe_translate(data, stored, recipient) do
      :ok
    else
      false -> {:error, :not_relevant}
      error -> error
    end
  end

  def receive_private(_envelope, _recipient), do: {:error, :not_relevant}

  defp relevant?(%{"type" => "status_message", "public" => public})
       when public not in [true, "true"],
       do: false

  defp relevant?(%{"type" => "status_message", "author" => author}) do
    case Identities.get_by_diaspora_id(author) do
      entity when not is_nil(entity) -> locally_followed?(entity.user_id)
      nil -> false
    end
  end

  defp relevant?(%{"type" => type} = data)
       when type in ["comment", "like", "reshare", "retraction"] do
    [data["parent_guid"], data["target_guid"], data["root_guid"]]
    |> Enum.filter(&is_binary/1)
    |> Enum.any?(&match?(%Record{}, Store.get(&1)))
  end

  defp relevant?(%{"type" => "contact"}), do: false

  defp relevant?(%{"type" => "profile", "author" => author}) do
    case Identities.get_by_diaspora_id(author) do
      entity when not is_nil(entity) -> locally_followed?(entity.user_id)
      nil -> false
    end
  end

  defp relevant?(_data), do: false

  defp privately_relevant?(%{"type" => "contact", "recipient" => recipient}, user) do
    recipient == Pleroma.Diaspora.diaspora_id(user)
  end

  # Encrypted Diaspora posts are aspect-scoped. Until the bridge can map that
  # audience to an equivalent local visibility, importing one as a public
  # ActivityPub object would disclose it beyond its intended recipients.
  defp privately_relevant?(_data, _user), do: false

  defp valid_envelope_author?(%{"author" => author, "envelope_author" => author}), do: true

  defp valid_envelope_author?(%{
         "type" => type,
         "parent_guid" => parent_guid,
         "envelope_author" => envelope_author
       })
       when type in ["comment", "like"] and is_binary(parent_guid) do
    case root_record(Store.get(parent_guid), 32) do
      %Record{author: ^envelope_author} -> true
      _ -> false
    end
  end

  defp valid_envelope_author?(_data), do: false

  defp root_record(%Record{type: type, data: data} = record, remaining)
       when type in ["comment", "like"] and remaining > 0 do
    case Store.get(data["parent_guid"]) do
      %Record{} = parent -> root_record(parent, remaining - 1)
      nil -> record
    end
  end

  defp root_record(record, _remaining), do: record

  defp locally_followed?(user_id) do
    FollowingRelationship
    |> join(:inner, [relationship], follower in User, on: follower.id == relationship.follower_id)
    |> where(
      [relationship, follower],
      relationship.following_id == ^user_id and relationship.state == ^:follow_accept and
        follower.local == true
    )
    |> Repo.exists?()
  end

  defp maybe_translate(_data, %Record{ap_activity_id: id}) when not is_nil(id) do
    _ = Pleroma.Workers.DiasporaThreadRepairWorker.enqueue_for_activity_id(id)
    :ok
  end

  defp maybe_translate(%{"type" => type} = data, stored)
       when type in ["status_message", "comment"] do
    import_post(data, stored)
  end

  defp maybe_translate(%{"type" => "like"} = data, stored), do: import_like(data, stored)
  defp maybe_translate(%{"type" => "reshare"} = data, stored), do: import_reshare(data, stored)
  defp maybe_translate(%{"type" => "retraction"} = data, _stored), do: import_retraction(data)

  defp maybe_translate(%{"type" => "profile"} = data, _stored),
    do: Identities.apply_entity_profile(data)

  defp maybe_translate(_data, _stored), do: :ok

  defp maybe_translate(%{"type" => "contact"} = data, _stored, recipient) do
    with {:ok, actor} <- Identities.resolve(data["author"]) do
      case data["following"] do
        "true" -> User.follow(actor, recipient, :follow_accept)
        "false" -> User.unfollow(actor, recipient)
        _ -> :ok
      end

      :ok
    else
      _ -> :ok
    end
  end

  defp maybe_translate(data, stored, _recipient), do: maybe_translate(data, stored)

  defp import_post(data, stored) do
    with {:ok, actor} <- Identities.resolve(data["author"]),
         {:ok, draft} <- ActivityDraft.create(actor, inbound_params(data)),
         {:ok, activity} <-
           draft.changes
           |> inbound_changes(data)
           |> ActivityPub.create() do
      object = Object.normalize(activity, fetch: false)

      case Store.claim_activity(stored.guid, activity.id, object && object.data["id"]) do
        {:ok, :claimed} -> :ok
        {:ok, _existing_id} -> :ok
        error -> error
      end
    end
  end

  defp inbound_params(data) do
    %{
      status: data["text"] || "",
      content_type: "text/markdown",
      visibility: "public"
    }
    |> maybe_put(:in_reply_to_status_id, mapped_activity_id(data["parent_guid"]))
  end

  defp inbound_changes(changes, data) do
    published = published_at(data["created_at"])

    object =
      changes.object
      |> Map.put("published", DateTime.to_iso8601(published))
      |> Map.put("unfathomably:diaspora", %{
        "guid" => data["guid"],
        "author" => data["author"]
      })

    changes
    |> Map.put(:object, object)
    |> Map.put(:additional, Map.put(changes.additional, "unfathomably:diaspora_ingest", true))
    |> Map.put(:local, false)
    |> Map.put(:published, DateTime.to_iso8601(published))
  end

  defp import_like(data, stored) do
    with %Activity{} = target <- target_activity(data),
         {:ok, actor} <- Identities.resolve(data["author"]),
         {:ok, activity} <- CommonAPI.favorite(actor, target.id) do
      Store.claim_activity(stored.guid, activity.id, nil)
      :ok
    else
      _ -> :ok
    end
  end

  defp import_reshare(data, stored) do
    with %Activity{} = target <- target_activity(data),
         {:ok, actor} <- Identities.resolve(data["author"]),
         {:ok, activity} <- CommonAPI.repeat(target.id, actor) do
      Store.claim_activity(stored.guid, activity.id, nil)
      :ok
    else
      _ -> :ok
    end
  end

  defp import_retraction(data) do
    guid = data["target_guid"] || data["parent_guid"]

    with %Record{author: author, ap_activity_id: activity_id} <- Store.get(guid),
         true <- author == data["author"],
         %Activity{} = activity <- Activity.get_by_id(activity_id),
         %User{} = actor <- User.get_cached_by_ap_id(activity.data["actor"]) do
      CommonAPI.delete(activity.id, actor)
    else
      _ -> :ok
    end
  end

  defp target_activity(data) do
    guid = data["parent_guid"] || data["target_guid"] || data["root_guid"]

    with %Record{ap_activity_id: id} when not is_nil(id) <- Store.get(guid),
         %Activity{} = activity <- Activity.get_by_id(id) do
      canonical_create(activity)
    else
      _ -> nil
    end
  end

  defp canonical_create(%Activity{data: %{"type" => "Create"}} = activity), do: activity

  defp canonical_create(activity) do
    with %Object{data: %{"id" => id}} <- Object.normalize(activity, fetch: false) do
      Activity.get_create_by_object_ap_id(id)
    end
  end

  defp mapped_activity_id(guid) when is_binary(guid) do
    case Store.get(guid) do
      %Record{ap_activity_id: id} when not is_nil(id) -> id
      _ -> nil
    end
  end

  defp mapped_activity_id(_guid), do: nil

  defp published_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> DateTime.utc_now()
    end
  end

  defp published_at(_value), do: DateTime.utc_now()
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

# end of diaspora/bridge.ex
