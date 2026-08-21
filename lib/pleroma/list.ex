# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.List do
  use Ecto.Schema

  import Ecto.Query
  import Ecto.Changeset

  alias Pleroma.Activity
  alias Pleroma.Repo
  alias Pleroma.User

  @per_account_limit 50
  @title_length_limit 256

  schema "lists" do
    belongs_to(:user, User, type: FlakeId.Ecto.CompatType)
    field(:title, :string)
    field(:following, {:array, :string}, default: [])
    field(:ap_id, :string)
    field(:exclusive, :boolean, default: false)

    timestamps()
  end

  def title_changeset(list, attrs \\ %{}) do
    update_changeset(list, attrs)
  end

  def update_changeset(list, attrs \\ %{}) do
    list
    |> cast(attrs, [:title, :exclusive])
    |> validate_required([:title])
    |> validate_length(:title, max: @title_length_limit)
  end

  def follow_changeset(list, attrs \\ %{}) do
    list
    |> cast(attrs, [:following])
    |> validate_required([:following])
  end

  def for_user(user, _opts) do
    query =
      from(
        l in Pleroma.List,
        where: l.user_id == ^user.id,
        order_by: [desc: l.id],
        limit: 50
      )

    Repo.all(query)
  end

  def get(id, %{id: user_id} = _user) do
    with {:ok, id} <- normalize_id(id) do
      query =
        from(
          l in Pleroma.List,
          where: l.id == ^id,
          where: l.user_id == ^user_id
        )

      Repo.one(query)
    else
      :error -> nil
    end
  end

  defp normalize_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> :error
    end
  end

  defp normalize_id(_), do: :error

  def get_by_ap_id(ap_id) do
    Repo.get_by(__MODULE__, ap_id: ap_id)
  end

  def get_following(%Pleroma.List{following: following} = _list) do
    query =
      from(
        u in User,
        where: u.follower_address in ^following
      )

    {:ok, Repo.all(query)}
  end

  # Get lists the activity should be streamed to.
  def get_lists_from_activity(%Activity{actor: ap_id}) do
    actor = User.get_cached_by_ap_id(ap_id)

    query =
      from(
        l in Pleroma.List,
        where: fragment("? && ?", l.following, ^[actor.follower_address])
      )

    Repo.all(query)
  end

  # Get lists to which the account belongs.
  def get_lists_account_belongs(%User{} = owner, user) do
    Pleroma.List
    |> where([l], l.user_id == ^owner.id)
    |> where([l], fragment("? = ANY(?)", ^user.follower_address, l.following))
    |> Repo.all()
  end

  def rename(%Pleroma.List{} = list, title) do
    __MODULE__.update(list, %{title: title})
  end

  def update(%Pleroma.List{} = list, attrs) do
    list
    |> update_changeset(attrs)
    |> Repo.update()
  end

  def create(title, %User{} = creator) when is_binary(title) do
    create(%{title: title}, creator)
  end

  def create(attrs, %User{} = creator) when is_map(attrs) do
    %Pleroma.List{user_id: creator.id}
    |> update_changeset(attrs)
    |> create_checked(creator)
  end

  def create(title, %User{} = creator) do
    %Pleroma.List{user_id: creator.id}
    |> title_changeset(%{title: title})
    |> create_checked(creator)
  end

  defp create_checked(changeset, creator) do
    if changeset.valid? do
      create_valid(changeset, creator)
    else
      {:error, changeset}
    end
  end

  defp create_valid(changeset, creator) do
    Repo.transaction(fn ->
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
        ["lists:" <> to_string(creator.id)]
      )

      if Repo.aggregate(from(l in __MODULE__, where: l.user_id == ^creator.id), :count, :id) >=
           @per_account_limit do
        Repo.rollback(add_error(changeset, :user_id, "has reached the list limit"))
      end

      list = Repo.insert!(changeset)

      list
      |> change(ap_id: "#{creator.ap_id}/lists/#{list.id}")
      |> Repo.update!()
    end)
  end

  def follow(%Pleroma.List{id: id}, %User{} = followed) do
    list = Repo.get(Pleroma.List, id)
    %{following: following} = list
    update_follows(list, %{following: Enum.uniq([followed.follower_address | following])})
  end

  def unfollow(%Pleroma.List{id: id}, %User{} = unfollowed) do
    list = Repo.get(Pleroma.List, id)
    %{following: following} = list
    update_follows(list, %{following: List.delete(following, unfollowed.follower_address)})
  end

  def delete(%Pleroma.List{} = list) do
    Repo.delete(list)
  end

  def update_follows(%Pleroma.List{} = list, attrs) do
    list
    |> follow_changeset(attrs)
    |> Repo.update()
  end

  def memberships(%User{follower_address: follower_address}) do
    Pleroma.List
    |> where([l], ^follower_address in l.following)
    |> select([l], l.ap_id)
    |> Repo.all()
  end

  def memberships(_), do: []

  def member?(%Pleroma.List{following: following}, %User{follower_address: follower_address}) do
    Enum.member?(following, follower_address)
  end

  def member?(_, _), do: false

  def get_exclusive_list_members(%User{id: user_id}) do
    Pleroma.List
    |> where([l], l.user_id == ^user_id)
    |> where([l], l.exclusive == true)
    |> select([l], l.following)
    |> Repo.all()
    |> List.flatten()
    |> Enum.uniq()
  end
end
