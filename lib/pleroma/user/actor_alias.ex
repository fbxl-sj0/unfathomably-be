# Unfathomably: Verified remote actor aliases
#
# File: actor_alias.ex
#
# Purpose:
#   Bind a remotely verified WebFinger handle to the canonical ActivityPub
#   actor record that WebFinger resolved.
#
# Responsibilities:
#   * Normalize acct handles without changing their local part.
#   * Store one current canonical actor binding for each verified handle.
#   * Return bindings only while their verification remains fresh.
#
# This file intentionally does not fetch WebFinger documents or decide how
# actor nickname collisions are presented.

defmodule Pleroma.User.ActorAlias do
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias FlakeId.Ecto.CompatType
  alias Pleroma.Config
  alias Pleroma.Repo
  alias Pleroma.User

  @maximum_alias_bytes 1024
  @default_max_age_seconds 86_400

  schema "actor_aliases" do
    field(:alias, :string)
    field(:verified_at, :utc_datetime_usec)
    belongs_to(:user, User, type: CompatType)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(binding, attrs) do
    binding
    |> cast(attrs, [:alias, :user_id, :verified_at])
    |> validate_required([:alias, :user_id, :verified_at])
    |> validate_length(:alias, max: @maximum_alias_bytes)
    |> unique_constraint(:alias)
  end

  @doc "Records a WebFinger handle that was verified to resolve to the user."
  def bind_verified(%User{id: user_id}, actor_alias) when not is_nil(user_id) do
    with {:ok, actor_alias} <- normalize(actor_alias) do
      now = DateTime.utc_now()

      %__MODULE__{}
      |> changeset(%{alias: actor_alias, user_id: user_id, verified_at: now})
      |> Repo.insert(
        on_conflict: [
          set: [user_id: user_id, verified_at: now, updated_at: now]
        ],
        conflict_target: :alias,
        returning: true
      )
    end
  end

  def bind_verified(_user, _actor_alias), do: {:error, :invalid_actor_alias}

  @doc "Returns the bound remote actor only while the alias proof is fresh."
  def get_fresh_user(actor_alias) do
    with {:ok, actor_alias} <- normalize(actor_alias) do
      cutoff =
        DateTime.add(
          DateTime.utc_now(),
          -max_age_seconds(),
          :second
        )

      __MODULE__
      |> join(:inner, [binding], user in User, on: user.id == binding.user_id)
      |> where([binding, _user], binding.alias == ^actor_alias)
      |> where([binding, _user], binding.verified_at >= ^cutoff)
      |> where([_binding, user], user.local == false)
      |> select([_binding, user], user)
      |> Repo.one()
    else
      _ -> nil
    end
  end

  def normalize(actor_alias) when is_binary(actor_alias) do
    actor_alias =
      actor_alias
      |> String.replace(~r/\p{C}+/u, "")
      |> String.trim()
      |> String.trim_leading("acct:")
      |> String.trim_leading("@")

    case String.split(actor_alias, "@", parts: 2) do
      [name, host] when name != "" and host != "" ->
        normalized = "#{name}@#{String.downcase(host)}"

        if byte_size(normalized) <= @maximum_alias_bytes do
          {:ok, normalized}
        else
          {:error, :invalid_actor_alias}
        end

      _ ->
        {:error, :invalid_actor_alias}
    end
  end

  def normalize(_actor_alias), do: {:error, :invalid_actor_alias}

  defp max_age_seconds do
    case Config.get([Pleroma.Web.WebFinger, :actor_alias_max_age], @default_max_age_seconds) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _ -> @default_max_age_seconds
    end
  end
end

# end of actor_alias.ex
