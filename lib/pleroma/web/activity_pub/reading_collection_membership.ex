# Unfathomably BookWyrm collection membership
# --------------------------------------------
#
# File: reading_collection_membership.ex
#
# Purpose:
#   Validate and project public BookWyrm shelf and list membership changes.
#
# Responsibilities:
#   - recognize actor-owned Shelf, BookList, and open SuggestionList targets
#   - verify inline ShelfItem, ListItem, and SuggestionListItem authority
#   - keep a bounded, deduplicated local view of received membership changes
#   - serialize concurrent Add and Remove updates with a database row lock
#
# This file intentionally does not fetch unknown collections, expose non-public
# shelves, accept cross-origin list curation claims, or mutate remote resources.

defmodule Pleroma.Web.ActivityPub.ReadingCollectionMembership do
  import Ecto.Query

  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User

  require Pleroma.Constants

  @state_field "_unfathomably_reading_members"
  @maximum_members 200

  @spec authorized?(String.t(), User.t(), term()) :: boolean()
  def authorized?(target, %User{} = actor, item)
      when is_binary(target) and is_map(item) do
    case Object.get_by_ap_id(target) do
      %Object{} = collection -> authorized_collection?(collection, actor, item)
      _collection -> false
    end
  end

  def authorized?(_target, _actor, _item), do: false

  @spec apply_change(String.t(), String.t(), User.t(), map()) ::
          {:ok, Object.t()} | {:ignore, atom()} | {:error, term()}
  def apply_change(operation, target, %User{} = actor, item)
      when operation in ["Add", "Remove"] and is_binary(target) and is_map(item) do
    Repo.transaction(fn ->
      with %Object{} = collection <- locked_collection(target),
           true <- authorized_collection?(collection, actor, item),
           %{} = member <- normalize_member(item) do
        update_members(collection, operation, member)
      else
        nil -> Repo.rollback({:ignore, :unknown_reading_collection})
        false -> Repo.rollback({:ignore, :unauthorized_reading_collection})
        _item -> Repo.rollback({:ignore, :invalid_reading_collection_item})
      end
    end)
    |> case do
      {:ok, %Object{} = collection} -> {:ok, collection}
      {:error, {:ignore, reason}} -> {:ignore, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  def apply_change(_operation, _target, _actor, _item),
    do: {:ignore, :invalid_reading_collection_change}

  defp locked_collection(target) do
    Repo.one(
      from(object in Object,
        where: fragment("?->>'id' = ?", object.data, ^target),
        lock: "FOR UPDATE",
        limit: 1
      )
    )
  end

  defp authorized_collection?(%Object{data: data}, %User{} = actor, item) do
    public_collection?(data) and
      valid_item_identity?(item, actor) and
      collection_authority?(data, actor, item)
  end

  defp collection_authority?(%{"type" => "Shelf"} = data, actor, %{"type" => "ShelfItem"}) do
    id = reference_id(data["id"])

    reference_id(data["owner"]) == actor.ap_id and
      is_binary(id) and
      is_binary(actor.ap_id) and
      same_origin?(id, actor.ap_id) and
      String.starts_with?(
        String.trim_trailing(id, "/"),
        String.trim_trailing(actor.ap_id, "/") <> "/books/"
      )
  end

  defp collection_authority?(
         %{"type" => "BookList"} = data,
         actor,
         %{"type" => "ListItem"}
       ) do
    reference_id(data["owner"]) == actor.ap_id or same_origin?(data["id"], actor.ap_id)
  end

  defp collection_authority?(
         %{"type" => "SuggestionList"} = data,
         _actor,
         %{"type" => "SuggestionListItem"}
       ) do
    collection_id = reference_id(data["id"])
    subject_id = reference_id(data["book"])

    safe_http_url?(collection_id) and
      safe_http_url?(subject_id) and
      same_origin?(collection_id, subject_id)
  end

  defp collection_authority?(_data, _actor, _item), do: false

  defp public_collection?(data) do
    recipients = references(data["to"]) ++ references(data["cc"])
    Pleroma.Constants.as_public() in recipients
  end

  defp valid_item_identity?(item, actor) do
    item_id = reference_id(item["id"])
    book_id = reference_id(item["book"])

    reference_id(item["actor"]) == actor.ap_id and
      safe_http_url?(item_id) and
      same_origin?(item_id, actor.ap_id) and
      safe_http_url?(book_id)
  end

  defp normalize_member(item) do
    with id when is_binary(id) <- reference_id(item["id"]),
         type when type in ["ShelfItem", "ListItem", "SuggestionListItem"] <- item["type"],
         actor when is_binary(actor) <- reference_id(item["actor"]),
         book when is_binary(book) <- reference_id(item["book"]) do
      %{
        "id" => id,
        "type" => type,
        "actor" => actor,
        "book" => book
      }
      |> put_if_present("order", nonnegative_integer(item["order"]))
      |> put_if_present("published", bounded_text(item["published"], 80))
      |> put_if_present("updated", bounded_text(item["updated"], 80))
    else
      _item -> nil
    end
  end

  defp update_members(%Object{data: data} = collection, operation, member) do
    existing =
      data
      |> Map.get(@state_field, [])
      |> case do
        members when is_list(members) -> Enum.filter(members, &is_map/1)
        _members -> []
      end

    members =
      case operation do
        "Add" ->
          [member | Enum.reject(existing, &same_member?(&1, member))]
          |> Enum.take(@maximum_members)

        "Remove" ->
          Enum.reject(existing, &same_member?(&1, member))
      end

    if members == existing do
      collection
    else
      case Object.update_data(collection, %{@state_field => members}) do
        {:ok, %Object{} = updated} -> updated
        {:error, reason} -> Repo.rollback(reason)
      end
    end
  end

  defp same_member?(left, right) do
    reference_id(left["id"]) == reference_id(right["id"]) or
      (reference_id(left["actor"]) == reference_id(right["actor"]) and
         reference_id(left["book"]) == reference_id(right["book"]))
  end

  defp references(value) when is_binary(value), do: [value]
  defp references(%{"id" => id}) when is_binary(id), do: [id]
  defp references(values) when is_list(values), do: Enum.flat_map(values, &references/1)
  defp references(_value), do: []

  defp reference_id(value) when is_binary(value), do: value
  defp reference_id(%{"id" => id}) when is_binary(id), do: id
  defp reference_id(_value), do: nil

  defp same_origin?(left, right) do
    with {:ok, left_origin} <- origin(left),
         {:ok, right_origin} <- origin(right) do
      left_origin == right_origin
    else
      _origin -> false
    end
  end

  defp origin(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, {scheme, String.downcase(host), port || default_port(scheme)}}

      _uri ->
        :error
    end
  rescue
    URI.Error -> :error
  end

  defp origin(_value), do: :error

  defp safe_http_url?(value), do: match?({:ok, _origin}, origin(value))

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443

  defp nonnegative_integer(value) when is_integer(value) and value >= 0, do: value
  defp nonnegative_integer(_value), do: nil

  defp bounded_text(value, maximum) when is_binary(value) do
    value
    |> String.trim()
    |> String.slice(0, maximum)
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp bounded_text(_value, _maximum), do: nil

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
end

# end of reading_collection_membership.ex
