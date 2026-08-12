# Unfathomably BE
# ----------------
#
# File: atproto/store.ex
#
# Purpose:
#   Persist the deliberately small AT Protocol working set used by the bridge.
#
# Responsibilities:
#   - accept records selected by a local follow, explicit open, or interaction
#   - retain AT Protocol strong references and ActivityPub projection mappings
#   - make repeated AppView reads and publisher retries idempotent
#
# This file intentionally does NOT retain firehose traffic, CAR blocks, or any
# record that has not crossed a local relevance boundary.

defmodule Pleroma.ATProto.Store do
  import Ecto.Query

  alias Pleroma.Activity
  alias Pleroma.ATProto.Record
  alias Pleroma.Repo

  @sources ~w[follow explicit interaction local]
  @source_priority %{"interaction" => 0, "follow" => 1, "explicit" => 2, "local" => 3}
  @future_tolerance_seconds 900

  def put(view, source, opts \\ [])

  def put(%{"uri" => uri, "cid" => cid} = view, source, opts)
      when source in @sources and is_binary(uri) and is_binary(cid) do
    with {:ok, author_did, collection, rkey} <- split_uri(uri),
         {:ok, indexed_at} <- indexed_at(view) do
      existing = Repo.get(Record, uri)

      attrs = %{
        uri: uri,
        cid: cid,
        author_did: author_did,
        collection: collection,
        rkey: rkey,
        data: view,
        source: strongest_source(existing, source),
        local: Keyword.get(opts, :local, false) or match?(%Record{local: true}, existing),
        ap_activity_id: Keyword.get(opts, :ap_activity_id),
        ap_activity_uri: Keyword.get(opts, :ap_activity_uri),
        ap_object_id: Keyword.get(opts, :ap_object_id),
        indexed_at: indexed_at
      }

      changeset = Record.changeset(%Record{}, attrs)

      case Repo.insert(changeset,
             on_conflict: {:replace, [:cid, :data, :source, :local, :indexed_at, :updated_at]},
             conflict_target: [:uri],
             returning: true
           ) do
        {:ok, record} -> {:ok, record}
        error -> error
      end
    end
  end

  def put(_view, _source, _opts), do: {:error, :invalid_record}

  def claim_activity(uri, activity_id, object_id) do
    activity_uri =
      case Activity.get_by_id(activity_id) do
        %Activity{data: %{"id" => value}} when is_binary(value) -> value
        _ -> nil
      end

    {claimed, _rows} =
      Record
      |> where(uri: ^uri)
      |> where([record], is_nil(record.ap_activity_id))
      |> Repo.update_all(
        set: [
          ap_activity_id: activity_id,
          ap_activity_uri: activity_uri,
          ap_object_id: object_id
        ]
      )

    case Repo.get(Record, uri) do
      %Record{ap_activity_id: ^activity_id} when claimed == 1 -> {:ok, :claimed}
      %Record{ap_activity_id: existing} when not is_nil(existing) -> {:ok, existing}
      _ -> {:error, :record_not_found}
    end
  end

  def map_activity(uri, activity_id, object_id) do
    activity_uri =
      case Activity.get_by_id(activity_id) do
        %Activity{data: %{"id" => value}} when is_binary(value) -> value
        _ -> nil
      end

    Record
    |> where(uri: ^uri)
    |> Repo.update_all(
      set: [ap_activity_id: activity_id, ap_activity_uri: activity_uri, ap_object_id: object_id]
    )

    :ok
  end

  def get(uri) when is_binary(uri), do: Repo.get(Record, uri)
  def get(_uri), do: nil

  def delete(%Record{} = record), do: Repo.delete(record)

  def delete(uri) when is_binary(uri) do
    case get(uri) do
      %Record{} = record -> Repo.delete(record)
      nil -> {:ok, nil}
    end
  end

  def delete(_record), do: {:ok, nil}

  def get_by_ap_activity_id(id), do: Repo.get_by(Record, ap_activity_id: id)

  def get_by_ap_activity_uri(uri) when is_binary(uri),
    do: Repo.get_by(Record, ap_activity_uri: uri)

  def get_by_ap_activity_uri(_uri), do: nil

  def get_by_ap_object_id(id) when is_binary(id) do
    Record
    |> where(ap_object_id: ^id)
    |> order_by(desc: :indexed_at)
    |> limit(1)
    |> Repo.one()
  end

  def get_by_ap_object_id(_id), do: nil

  def split_uri(uri), do: Pleroma.ATProto.Validation.split_record_uri(uri)

  defp indexed_at(%{"indexedAt" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        now = DateTime.utc_now()
        maximum = DateTime.add(now, @future_tolerance_seconds, :second)
        if DateTime.compare(datetime, maximum) == :gt, do: {:ok, now}, else: {:ok, datetime}

      _ ->
        {:error, :invalid_indexed_at}
    end
  end

  defp indexed_at(_view), do: {:ok, DateTime.utc_now()}

  defp strongest_source(nil, source), do: source

  defp strongest_source(%Record{source: current}, source) do
    if Map.get(@source_priority, current, -1) >= Map.fetch!(@source_priority, source),
      do: current,
      else: source
  end
end

# end of atproto/store.ex
