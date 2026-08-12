# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Filter do
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Pleroma.Config
  alias Pleroma.Repo
  alias Pleroma.User

  @default_max_account_filters 20
  @default_max_filter_phrase_length 255
  @valid_contexts ~w(home notifications public thread)

  @type t() :: %__MODULE__{}
  @type format() :: :postgres | :re

  schema "filters" do
    belongs_to(:user, User, type: FlakeId.Ecto.CompatType)
    field(:filter_id, :integer)
    field(:hide, :boolean, default: false)
    field(:whole_word, :boolean, default: true)
    field(:phrase, :string)
    field(:context, {:array, :string})
    field(:expires_at, :naive_datetime)

    timestamps()
  end

  @spec get(integer() | String.t(), User.t()) :: t() | nil
  def get(id, %{id: user_id} = _user) do
    query =
      from(
        f in __MODULE__,
        where: f.filter_id == ^id,
        where: f.user_id == ^user_id
      )

    Repo.one(query)
  end

  @spec get_active(Ecto.Query.t() | module()) :: Ecto.Query.t()
  def get_active(query) do
    from(f in query, where: is_nil(f.expires_at) or f.expires_at > ^NaiveDateTime.utc_now())
  end

  @spec get_irreversible(Ecto.Query.t()) :: Ecto.Query.t()
  def get_irreversible(query) do
    from(f in query, where: f.hide)
  end

  @spec get_filters(Ecto.Query.t() | module(), User.t()) :: [t()]
  def get_filters(query \\ __MODULE__, %User{id: user_id}) do
    query =
      from(
        f in query,
        where: f.user_id == ^user_id,
        order_by: [desc: :id]
      )

    Repo.all(query)
  end

  @spec create(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(attrs \\ %{}) do
    Repo.transaction(fn -> create_with_expiration(attrs) end)
  end

  defp create_with_expiration(attrs) do
    with :ok <- lock_filter_allocation(attrs),
         {:ok, filter} <- do_create(attrs),
         {:ok, _} <- maybe_add_expiration_job(filter) do
      filter
    else
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp do_create(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:phrase, :context, :hide, :expires_at, :whole_word, :user_id, :filter_id])
    |> maybe_add_filter_id()
    |> validate_required([:phrase, :context, :user_id, :filter_id])
    |> validate_length(:phrase, min: 1, max: max_filter_phrase_length())
    |> validate_length(:context, min: 1, max: length(@valid_contexts))
    |> validate_subset(:context, @valid_contexts)
    |> validate_account_filter_limit()
    |> maybe_add_expires_at(attrs)
    |> Repo.insert()
  end

  # Filter IDs are allocated from the user's current maximum. A transaction
  # advisory lock keeps simultaneous clients and clustered nodes from choosing
  # the same ID or racing past the configured account limit.
  defp lock_filter_allocation(attrs) do
    case Map.get(attrs, :user_id) || Map.get(attrs, "user_id") do
      nil ->
        :ok

      user_id ->
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
          [to_string(user_id)]
        )

        :ok
    end
  end

  defp validate_account_filter_limit(%{valid?: false} = changeset), do: changeset

  defp validate_account_filter_limit(changeset) do
    case fetch_field(changeset, :user_id) do
      {_source, user_id} ->
        count =
          __MODULE__
          |> where([filter], filter.user_id == ^user_id)
          |> Repo.aggregate(:count, :id)

        if count >= max_account_filters() do
          add_error(changeset, :user_id, "has reached the configured filter limit")
        else
          changeset
        end

      :error ->
        changeset
    end
  end

  defp max_account_filters do
    configured_positive_integer(:max_account_filters, @default_max_account_filters)
  end

  defp max_filter_phrase_length do
    :max_filter_phrase_length
    |> configured_positive_integer(@default_max_filter_phrase_length)
    |> min(@default_max_filter_phrase_length)
  end

  defp configured_positive_integer(key, default) do
    case Config.get([:instance, key], default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp maybe_add_filter_id(%{changes: %{filter_id: _}} = changeset), do: changeset

  defp maybe_add_filter_id(%{changes: %{user_id: user_id}} = changeset) do
    # The surrounding transaction holds this user's allocation lock, so the
    # maximum cannot change until this filter has been inserted.

    max_id_query =
      from(
        f in __MODULE__,
        where: f.user_id == ^user_id,
        select: max(f.filter_id)
      )

    filter_id =
      case Repo.one(max_id_query) do
        # Start allocating from 1
        nil ->
          1

        max_id ->
          max_id + 1
      end

    change(changeset, filter_id: filter_id)
  end

  # don't override expires_at, if passed expires_at and expires_in
  defp maybe_add_expires_at(%{changes: %{expires_at: %NaiveDateTime{} = _}} = changeset, _) do
    changeset
  end

  defp maybe_add_expires_at(changeset, %{expires_in: expires_in})
       when is_integer(expires_in) and expires_in > 0 do
    expires_at =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(expires_in)
      |> NaiveDateTime.truncate(:second)

    change(changeset, expires_at: expires_at)
  end

  defp maybe_add_expires_at(changeset, %{expires_in: nil}) do
    change(changeset, expires_at: nil)
  end

  defp maybe_add_expires_at(changeset, _), do: changeset

  defp maybe_add_expiration_job(%{expires_at: %NaiveDateTime{} = expires_at} = filter) do
    Pleroma.Workers.PurgeExpiredFilter.enqueue(%{
      filter_id: filter.id,
      expires_at: DateTime.from_naive!(expires_at, "Etc/UTC")
    })
  end

  defp maybe_add_expiration_job(_), do: {:ok, nil}

  @spec delete(t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def delete(%__MODULE__{} = filter) do
    Repo.transaction(fn -> delete_with_expiration(filter) end)
  end

  defp delete_with_expiration(filter) do
    with {:ok, _} <- maybe_delete_old_expiration_job(filter, nil),
         {:ok, filter} <- Repo.delete(filter) do
      filter
    else
      {:error, error} -> Repo.rollback(error)
    end
  end

  @spec update(t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def update(%__MODULE__{} = filter, params) do
    Repo.transaction(fn -> update_with_expiration(filter, params) end)
  end

  defp update_with_expiration(filter, params) do
    with {:ok, updated} <- do_update(filter, params),
         {:ok, _} <- maybe_delete_old_expiration_job(filter, updated),
         {:ok, _} <-
           maybe_add_expiration_job(updated) do
      updated
    else
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp do_update(filter, params) do
    filter
    |> cast(params, [:phrase, :context, :hide, :expires_at, :whole_word])
    |> validate_required([:phrase, :context])
    |> validate_length(:phrase, min: 1, max: max_filter_phrase_length())
    |> validate_length(:context, min: 1, max: length(@valid_contexts))
    |> validate_subset(:context, @valid_contexts)
    |> maybe_add_expires_at(params)
    |> Repo.update()
  end

  defp maybe_delete_old_expiration_job(%{expires_at: nil}, _), do: {:ok, nil}

  defp maybe_delete_old_expiration_job(%{expires_at: expires_at}, %{expires_at: expires_at}) do
    {:ok, nil}
  end

  defp maybe_delete_old_expiration_job(%{id: id}, _) do
    with %Oban.Job{} = job <- Pleroma.Workers.PurgeExpiredFilter.get_expiration(id) do
      Repo.delete(job)
    else
      nil -> {:ok, nil}
    end
  end

  # Mastodon filter phrases are literal text. Escaping before combining them
  # prevents punctuation from becoming active in either the Erlang or
  # PostgreSQL regular-expression engine.
  defp escape_phrase(phrase) when is_binary(phrase), do: Regex.escape(phrase)

  defp starts_with_word_character?(phrase),
    do: Regex.match?(~r/^[\p{L}\p{N}_]/u, phrase)

  defp ends_with_word_character?(phrase),
    do: Regex.match?(~r/[\p{L}\p{N}_]$/u, phrase)

  defp filter_pattern(%__MODULE__{phrase: phrase, whole_word: false}, _format),
    do: escape_phrase(phrase)

  defp filter_pattern(%__MODULE__{phrase: phrase}, :postgres) do
    prefix = if starts_with_word_character?(phrase), do: "\\m", else: ""
    suffix = if ends_with_word_character?(phrase), do: "\\M", else: ""
    prefix <> escape_phrase(phrase) <> suffix
  end

  defp filter_pattern(%__MODULE__{phrase: phrase}, :re) do
    prefix = if starts_with_word_character?(phrase), do: "(?<![\\p{L}\\p{N}_])", else: ""
    suffix = if ends_with_word_character?(phrase), do: "(?![\\p{L}\\p{N}_])", else: ""
    prefix <> escape_phrase(phrase) <> suffix
  end

  @spec matching([t()], String.t(), String.t()) :: [{t(), String.t()}]
  def matching(filters, text, context)
      when is_list(filters) and is_binary(text) and is_binary(context) do
    filters
    |> Enum.filter(&(context in (&1.context || [])))
    |> Enum.flat_map(fn filter ->
      regex = Regex.compile!(filter_pattern(filter, :re), "iu")

      case Regex.run(regex, text, capture: :first) do
        [match] -> [{filter, match}]
        _ -> []
      end
    end)
  end

  def matching(_filters, _text, _context), do: []

  @spec compose_regex(User.t() | [t()], format()) :: String.t() | Regex.t() | nil
  def compose_regex(user_or_filters, format \\ :postgres)

  def compose_regex(%User{} = user, format) do
    __MODULE__
    |> get_active()
    |> get_irreversible()
    |> get_filters(user)
    |> compose_regex(format)
  end

  def compose_regex([_ | _] = filters, format) do
    phrases =
      filters
      |> Enum.map(&filter_pattern(&1, format))
      |> Enum.join("|")

    case format do
      :postgres ->
        "(#{phrases})"

      :re ->
        Regex.compile!("(?:#{phrases})", "iu")

      _ ->
        nil
    end
  end

  def compose_regex(_, _), do: nil
end
