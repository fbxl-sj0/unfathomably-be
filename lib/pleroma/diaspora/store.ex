# Unfathomably BE
# ----------------
#
# File: diaspora/store.ex
#
# Purpose:
#   Persist verified diaspora* entities that crossed a local relevance boundary.
#
# Responsibilities:
#   - deduplicate native GUIDs
#   - retain signed XML for diaspora* fetch requests
#   - map native entities to their ActivityPub projections
#
# This file intentionally does NOT retain unverified envelopes or pod history.

defmodule Pleroma.Diaspora.Store do
  import Ecto.Query

  alias Pleroma.Activity
  alias Pleroma.Diaspora.Record
  alias Pleroma.Repo

  def put(data, raw_xml, opts \\ [])

  def put(data, raw_xml, opts) when is_map(data) and is_binary(raw_xml) do
    attrs = %{
      guid: data["guid"],
      author: data["author"],
      type: data["type"],
      data: data,
      raw_xml: raw_xml,
      local: Keyword.get(opts, :local, false),
      ap_activity_id: Keyword.get(opts, :ap_activity_id),
      ap_activity_uri: Keyword.get(opts, :ap_activity_uri),
      ap_object_id: Keyword.get(opts, :ap_object_id)
    }

    %Record{}
    |> Record.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:guid])
    |> case do
      {:ok, _record} -> {:ok, Repo.get(Record, attrs.guid)}
      error -> error
    end
  end

  def put(_data, _raw_xml, _opts), do: {:error, :invalid_entity}

  def claim_activity(guid, activity_id, object_id) do
    activity_uri =
      case Activity.get_by_id(activity_id) do
        %Activity{data: %{"id" => value}} when is_binary(value) -> value
        _ -> nil
      end

    {claimed, _rows} =
      Record
      |> where(guid: ^guid)
      |> where([record], is_nil(record.ap_activity_id))
      |> Repo.update_all(
        set: [ap_activity_id: activity_id, ap_activity_uri: activity_uri, ap_object_id: object_id]
      )

    case Repo.get(Record, guid) do
      %Record{ap_activity_id: ^activity_id} when claimed == 1 -> {:ok, :claimed}
      %Record{ap_activity_id: existing} when not is_nil(existing) -> {:ok, existing}
      _ -> {:error, :record_not_found}
    end
  end

  def get(guid) when is_binary(guid), do: Repo.get(Record, guid)
  def get(_guid), do: nil
  def get_by_ap_activity_id(id), do: Repo.get_by(Record, ap_activity_id: id)

  @spec projected_children_of(binary(), pos_integer()) :: [Record.t()]
  def projected_children_of(parent_guid, limit \\ 100)

  def projected_children_of(parent_guid, limit)
      when is_binary(parent_guid) and is_integer(limit) and limit > 0 do
    limit = min(limit, 200)

    Record
    |> where(
      [record],
      record.type == "comment" and not is_nil(record.ap_activity_id) and
        fragment("?->>'parent_guid' = ?", record.data, ^parent_guid)
    )
    |> order_by([record], asc: record.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def projected_children_of(_, _), do: []

  def get_by_ap_activity_uri(uri) when is_binary(uri),
    do: Repo.get_by(Record, ap_activity_uri: uri)

  def get_by_ap_activity_uri(_uri), do: nil

  def get_by_ap_object_id(id) when is_binary(id) do
    Record |> where(ap_object_id: ^id) |> order_by(desc: :inserted_at) |> limit(1) |> Repo.one()
  end

  def get_by_ap_object_id(_id), do: nil
end

# end of diaspora/store.ex
