# Unfathomably native book library
# ---------------------------------
#
# File: book_shelf_entry.ex
#
# Purpose:
#
#   Maintain useful local reading state for federated Book and Edition objects.
#
# Responsibilities:
#
#   * validate canonical book URIs, shelves, and reading progress
#   * provide duplicate-safe shelf moves
#   * render stable BookWyrm Shelf and ShelfItem identifiers
#   * keep library bookkeeping separate from publishable reading activity
#
# This file intentionally does NOT contain HTTP controller or frontend logic.

defmodule Pleroma.BookShelfEntry do
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Pleroma.BookShelfEntry
  alias Pleroma.Config
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User

  @shelves ["to-read", "reading", "read", "stopped-reading"]
  @progress_modes ["page", "percent"]
  @book_object_types ["Book", "Edition", "Work"]

  schema "book_shelf_entries" do
    belongs_to(:user, User, type: FlakeId.Ecto.CompatType)
    field(:book_uri, :string)
    field(:shelf, :string)
    field(:progress, :integer)
    field(:progress_mode, :string)
    field(:presentation, :map, default: %{})
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)

    timestamps()
  end

  def shelves, do: @shelves

  @doc """
  Returns whether a URI identifies a book object that can safely participate in
  BookWyrm-shaped federation.

  Local-only metadata records may still be useful on a personal shelf, but an
  Add, Remove, or Review must not claim that an ordinary catalog HTML page is
  an ActivityPub Book. Cached Book/Edition/Work objects and book routes on an
  explicitly configured BookWyrm service are the bounded trust boundary.
  """
  def federatable_book_uri?(book_uri) when is_binary(book_uri) do
    book_uri = String.trim(book_uri)

    case Object.get_cached_by_ap_id(book_uri) do
      %Object{data: %{"type" => type}} -> book_object_type?(type)
      _ -> configured_bookwyrm_uri?(book_uri)
    end
  end

  def federatable_book_uri?(_book_uri), do: false

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :user_id,
      :book_uri,
      :shelf,
      :progress,
      :progress_mode,
      :presentation,
      :started_at,
      :finished_at
    ])
    |> update_change(:book_uri, &String.trim/1)
    |> validate_required([:user_id, :book_uri, :shelf])
    |> validate_inclusion(:shelf, @shelves)
    |> validate_inclusion(:progress_mode, @progress_modes)
    |> validate_number(:progress, greater_than_or_equal_to: 0)
    |> validate_progress_mode_required()
    |> validate_percent_progress()
    |> validate_reading_dates()
    |> validate_book_uri()
    |> unique_constraint([:user_id, :book_uri])
    |> check_constraint(:shelf, name: :book_shelf_entries_shelf_check)
    |> check_constraint(:progress_mode, name: :book_shelf_entries_progress_mode_check)
    |> check_constraint(:progress, name: :book_shelf_entries_progress_check)
    |> check_constraint(:finished_at, name: :book_shelf_entries_reading_dates_order)
  end

  def list(%User{id: user_id}, shelf \\ nil) do
    BookShelfEntry
    |> where(user_id: ^user_id)
    |> maybe_filter_shelf(shelf)
    |> order_by([entry], desc: entry.updated_at, desc: entry.id)
    |> Repo.all()
  end

  def put(%User{} = user, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    book_uri = Map.get(attrs, "book_uri")
    previous = get(user, book_uri)
    shelf = Map.get(attrs, "shelf")
    {started_at, finished_at} = reading_dates(previous, shelf, DateTime.utc_now())

    changes = %{
      user_id: user.id,
      book_uri: book_uri,
      shelf: shelf,
      progress: supplied_or_existing(attrs, "progress", previous),
      progress_mode: supplied_or_existing(attrs, "progress_mode", previous),
      presentation: merged_presentation(previous, attrs),
      started_at: started_at,
      finished_at: finished_at
    }

    (previous || %BookShelfEntry{})
    |> changeset(changes)
    |> Repo.insert_or_update()
  end

  def remove(%User{} = user, book_uri) when is_binary(book_uri) do
    case get(user, book_uri) do
      %BookShelfEntry{} = entry ->
        Repo.delete(entry)

      nil ->
        {:ok, nil}
    end
  end

  def remove(%User{}, _), do: {:error, :invalid_book_uri}

  def get(%User{id: user_id}, book_uri) when is_binary(book_uri) do
    Repo.get_by(BookShelfEntry, user_id: user_id, book_uri: String.trim(book_uri))
  end

  def get(%User{}, _), do: nil

  def collection_uri(%User{ap_id: ap_id}, shelf) when shelf in @shelves,
    do: "#{ap_id}/books/#{shelf}"

  def shelf_item(%User{} = user, %BookShelfEntry{} = entry) do
    %{
      "id" => "#{collection_uri(user, entry.shelf)}/items/#{entry.id}",
      "type" => "ShelfItem",
      "actor" => user.ap_id,
      "book" => entry.book_uri
    }
  end

  defp maybe_filter_shelf(query, shelf) when shelf in @shelves, do: where(query, shelf: ^shelf)
  defp maybe_filter_shelf(query, _), do: query

  defp validate_book_uri(changeset) do
    validate_change(changeset, :book_uri, fn :book_uri, value ->
      case URI.parse(value) do
        %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
          []

        _ ->
          [book_uri: "must be an absolute HTTP or HTTPS URL"]
      end
    end)
  end

  defp validate_percent_progress(changeset) do
    case {get_field(changeset, :progress_mode), get_field(changeset, :progress)} do
      {"percent", progress} when is_integer(progress) and progress > 100 ->
        add_error(changeset, :progress, "must be at most 100 when measured as percent")

      _ ->
        changeset
    end
  end

  defp validate_progress_mode_required(changeset) do
    if is_integer(get_field(changeset, :progress)) and
         is_nil(get_field(changeset, :progress_mode)) do
      add_error(changeset, :progress_mode, "is required when progress is supplied")
    else
      changeset
    end
  end

  defp validate_reading_dates(changeset) do
    case {get_field(changeset, :started_at), get_field(changeset, :finished_at)} do
      {%DateTime{} = started_at, %DateTime{} = finished_at} ->
        if DateTime.compare(finished_at, started_at) == :lt do
          add_error(changeset, :finished_at, "cannot be before the reading start")
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  defp supplied_or_existing(attrs, "progress", %BookShelfEntry{} = previous) do
    if Map.has_key?(attrs, "progress"), do: Map.get(attrs, "progress"), else: previous.progress
  end

  defp supplied_or_existing(attrs, "progress_mode", %BookShelfEntry{} = previous) do
    if Map.has_key?(attrs, "progress_mode"),
      do: Map.get(attrs, "progress_mode"),
      else: previous.progress_mode
  end

  defp supplied_or_existing(attrs, key, nil), do: Map.get(attrs, key)

  defp merged_presentation(previous, attrs) do
    previous_presentation = if previous, do: previous.presentation || %{}, else: %{}

    case Map.fetch(attrs, "presentation") do
      {:ok, presentation} -> Map.merge(previous_presentation, sanitize_presentation(presentation))
      :error -> previous_presentation
    end
  end

  defp reading_dates(nil, "reading", now), do: {now, nil}
  defp reading_dates(nil, "read", now), do: {now, now}
  defp reading_dates(nil, _shelf, _now), do: {nil, nil}
  defp reading_dates(%BookShelfEntry{shelf: "read"}, "reading", now), do: {now, nil}

  defp reading_dates(%BookShelfEntry{} = previous, "reading", now) do
    {previous.started_at || now, nil}
  end

  defp reading_dates(%BookShelfEntry{} = previous, "read", now) do
    {previous.started_at || now, previous.finished_at || now}
  end

  defp reading_dates(%BookShelfEntry{} = previous, "stopped-reading", _now) do
    {previous.started_at, nil}
  end

  defp reading_dates(%BookShelfEntry{}, "to-read", _now), do: {nil, nil}

  defp reading_dates(%BookShelfEntry{} = previous, _shelf, _now) do
    {previous.started_at, previous.finished_at}
  end

  defp sanitize_presentation(presentation) when is_map(presentation) do
    presentation
    |> stringify_keys()
    |> Map.take(["title", "subtitle", "author", "image", "isbn", "published_at"])
    |> Enum.reject(fn {_key, value} -> not is_binary(value) or byte_size(value) > 2_048 end)
    |> Map.new()
  end

  defp sanitize_presentation(_), do: %{}
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp book_object_type?(type) when type in @book_object_types, do: true
  defp book_object_type?(types) when is_list(types), do: Enum.any?(types, &book_object_type?/1)
  defp book_object_type?(_type), do: false

  defp configured_bookwyrm_uri?(book_uri) do
    uri = URI.parse(book_uri)
    host = if is_binary(uri.host), do: String.downcase(uri.host)

    configured_hosts =
      Config.get([:native_discovery, :bookwyrm_indexes], [])
      |> Enum.flat_map(fn index ->
        case URI.parse(to_string(index)) do
          %URI{host: configured_host} when is_binary(configured_host) ->
            [String.downcase(configured_host)]

          _ ->
            []
        end
      end)
      |> MapSet.new()

    uri.scheme in ["http", "https"] and is_binary(host) and
      MapSet.member?(configured_hosts, host) and
      is_binary(uri.path) and String.starts_with?(uri.path, "/book/")
  rescue
    _ -> false
  end
end

# end of book_shelf_entry.ex
