# Unfathomably Worlds workspace state
# -----------------------------------
#
# File: world_object_state.ex
#
# Purpose:
#   Store a local user's durable relationship with a native federated object.
#
# Responsibilities:
#   - validate object identifiers, families, workflow states, and progress
#   - keep personal progress and notes private unless explicitly shared
#   - provide bounded current-user and public-profile listings
#   - update start and finish timestamps as workflow state changes
#
# This file intentionally does not publish ActivityPub activities or alter the
# remote object's author-controlled lifecycle.

defmodule Pleroma.WorldObjectState do
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.WorldObjectState

  @families ~w[
    audio video longform photo books bookmarks groups events development
    models marketplace games routes culture coordination publishing local generic
  ]

  @states %{
    "audio" => ~w[queued listening listened],
    "video" => ~w[watchlist watching watched],
    "longform" => ~w[saved reading finished],
    "photo" => ~w[saved],
    "books" => ~w[wishlist progress complete dropped],
    "bookmarks" => ~w[saved],
    "groups" => ~w[following],
    "events" => ~w[saved interested going attended],
    "development" => ~w[watching active completed],
    "models" => ~w[saved printing printed],
    "marketplace" => ~w[watching contacted closed],
    "games" => ~w[saved active completed],
    "routes" => ~w[saved planned completed],
    "culture" => ~w[wishlist progress complete dropped],
    "coordination" => ~w[watching helping completed],
    "publishing" => ~w[saved reading finished],
    "local" => ~w[saved],
    "generic" => ~w[saved]
  }

  @progress_units ~w[percent page chapter episode minute hour item move kilometre mile]
  @started_states ~w[listening watching reading progress going active printing contacted planned helping]
  @finished_states ~w[listened watched finished complete attended completed printed closed]
  @presentation_keys ~w[title subtitle author image media_url source_host duration]

  schema "world_object_states" do
    belongs_to(:user, User, type: FlakeId.Ecto.CompatType)
    field(:object_uri, :string)
    field(:family, :string)
    field(:state, :string)
    field(:progress, :float)
    field(:progress_total, :float)
    field(:progress_unit, :string)
    field(:rating, :integer)
    field(:note, :string)
    field(:public, :boolean, default: false)
    field(:presentation, :map, default: %{})
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)

    timestamps()
  end

  def families, do: @families
  def allowed_states(family), do: Map.get(@states, family, [])

  def get(%User{id: user_id}, object_uri) when is_binary(object_uri) do
    Repo.get_by(WorldObjectState, user_id: user_id, object_uri: String.trim(object_uri))
  end

  def get(%User{}, _object_uri), do: nil

  def list(%User{id: user_id}, params \\ %{}) do
    limit = bounded_limit(params["limit"] || params[:limit])

    WorldObjectState
    |> where(user_id: ^user_id)
    |> maybe_filter_family(params["family"] || params[:family])
    |> maybe_filter_state(params["state"] || params[:state])
    |> order_by([entry], desc: entry.updated_at, desc: entry.id)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_public(%User{id: user_id}, params \\ %{}) do
    limit = bounded_limit(params["limit"] || params[:limit])

    WorldObjectState
    |> where(user_id: ^user_id, public: true)
    |> maybe_filter_family(params["family"] || params[:family])
    |> maybe_filter_state(params["state"] || params[:state])
    |> order_by([entry], desc: entry.updated_at, desc: entry.id)
    |> limit(^limit)
    |> Repo.all()
  end

  def public_counts(%User{id: user_id}) do
    WorldObjectState
    |> where(user_id: ^user_id, public: true)
    |> group_by([entry], entry.family)
    |> select([entry], {entry.family, count(entry.id)})
    |> Repo.all()
    |> Map.new()
  end

  def put(%User{} = user, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    object_uri = attrs["object_uri"]
    previous = get(user, object_uri)
    family = attrs["family"] || previous_family(previous)
    state = attrs["state"] || previous_state(previous)
    {started_at, finished_at} = workflow_dates(previous, state, DateTime.utc_now())

    changes = %{
      user_id: user.id,
      object_uri: object_uri,
      family: family,
      state: state,
      progress: supplied_or_existing(attrs, "progress", previous),
      progress_total: supplied_or_existing(attrs, "progress_total", previous),
      progress_unit: supplied_or_existing(attrs, "progress_unit", previous),
      rating: supplied_or_existing(attrs, "rating", previous),
      note: supplied_or_existing(attrs, "note", previous),
      public: supplied_or_existing(attrs, "public", previous, false),
      presentation: merged_presentation(previous, attrs),
      started_at: started_at,
      finished_at: finished_at
    }

    (previous || %WorldObjectState{})
    |> changeset(changes)
    |> Repo.insert_or_update()
  end

  def remove(%User{} = user, object_uri) when is_binary(object_uri) do
    case get(user, object_uri) do
      %WorldObjectState{} = entry -> Repo.delete(entry)
      nil -> {:ok, nil}
    end
  end

  def remove(%User{}, _object_uri), do: {:error, :invalid_object_uri}

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :user_id,
      :object_uri,
      :family,
      :state,
      :progress,
      :progress_total,
      :progress_unit,
      :rating,
      :note,
      :public,
      :presentation,
      :started_at,
      :finished_at
    ])
    |> update_change(:object_uri, &String.trim/1)
    |> validate_required([:user_id, :object_uri, :family, :state])
    |> validate_length(:object_uri, max: 2_048)
    |> validate_length(:note, max: 5_000)
    |> validate_inclusion(:family, @families)
    |> validate_inclusion(:progress_unit, @progress_units)
    |> validate_number(:progress, greater_than_or_equal_to: 0)
    |> validate_number(:progress_total, greater_than: 0)
    |> validate_number(:rating, greater_than_or_equal_to: 1, less_than_or_equal_to: 10)
    |> validate_object_uri()
    |> validate_family_state()
    |> validate_progress()
    |> unique_constraint([:user_id, :object_uri])
  end

  defp validate_object_uri(changeset) do
    validate_change(changeset, :object_uri, fn :object_uri, value ->
      case URI.parse(value) do
        %URI{scheme: scheme, host: host, userinfo: nil}
        when scheme in ["http", "https"] and is_binary(host) ->
          []

        _other ->
          [object_uri: "must be an absolute HTTP or HTTPS URL without credentials"]
      end
    end)
  end

  defp validate_family_state(changeset) do
    family = get_field(changeset, :family)
    state = get_field(changeset, :state)

    if is_binary(state) and state in allowed_states(family) do
      changeset
    else
      add_error(changeset, :state, "is not supported for this world family")
    end
  end

  defp validate_progress(changeset) do
    progress = get_field(changeset, :progress)
    total = get_field(changeset, :progress_total)
    unit = get_field(changeset, :progress_unit)

    changeset =
      if is_number(progress) and is_nil(unit) do
        add_error(changeset, :progress_unit, "is required when progress is supplied")
      else
        changeset
      end

    cond do
      is_number(progress) and unit == "percent" and progress > 100 ->
        add_error(changeset, :progress, "must be at most 100 percent")

      is_number(progress) and is_number(total) and progress > total ->
        add_error(changeset, :progress, "cannot exceed the total")

      true ->
        changeset
    end
  end

  defp maybe_filter_family(query, family) when family in @families,
    do: where(query, family: ^family)

  defp maybe_filter_family(query, _family), do: query

  defp maybe_filter_state(query, state) when is_binary(state) and byte_size(state) <= 32,
    do: where(query, state: ^state)

  defp maybe_filter_state(query, _state), do: query

  defp bounded_limit(value) when is_integer(value), do: min(max(value, 1), 200)

  defp bounded_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> bounded_limit(parsed)
      _other -> 100
    end
  end

  defp bounded_limit(_value), do: 100

  defp supplied_or_existing(attrs, key, previous, default \\ nil)

  defp supplied_or_existing(attrs, key, %WorldObjectState{} = previous, default) do
    if Map.has_key?(attrs, key), do: attrs[key], else: Map.get(previous, String.to_existing_atom(key), default)
  end

  defp supplied_or_existing(attrs, key, nil, default), do: Map.get(attrs, key, default)

  defp previous_family(%WorldObjectState{family: family}), do: family
  defp previous_family(nil), do: nil
  defp previous_state(%WorldObjectState{state: state}), do: state
  defp previous_state(nil), do: nil

  defp workflow_dates(nil, state, now) when state in @finished_states, do: {now, now}
  defp workflow_dates(nil, state, now) when state in @started_states, do: {now, nil}
  defp workflow_dates(nil, _state, _now), do: {nil, nil}

  defp workflow_dates(%WorldObjectState{} = previous, state, now)
       when state in @finished_states,
       do: {previous.started_at || now, previous.finished_at || now}

  defp workflow_dates(%WorldObjectState{} = previous, state, now)
       when state in @started_states,
       do: {previous.started_at || now, nil}

  defp workflow_dates(%WorldObjectState{} = previous, _state, _now),
    do: {previous.started_at, nil}

  defp merged_presentation(previous, attrs) do
    old = if previous, do: previous.presentation || %{}, else: %{}

    case Map.fetch(attrs, "presentation") do
      {:ok, presentation} -> Map.merge(old, sanitize_presentation(presentation))
      :error -> old
    end
  end

  defp sanitize_presentation(presentation) when is_map(presentation) do
    presentation
    |> stringify_keys()
    |> Map.take(@presentation_keys)
    |> Enum.reject(fn {_key, value} -> not is_binary(value) or byte_size(value) > 2_048 end)
    |> Map.new()
  end

  defp sanitize_presentation(_presentation), do: %{}
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end

# end of lib/pleroma/world_object_state.ex
