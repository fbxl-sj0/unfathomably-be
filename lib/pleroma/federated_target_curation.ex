# Unfathomably Backend
#
# File: federated_target_curation.ex
#
# Purpose:
#   Store the remote communities deliberately featured by instance staff.
#
# Responsibilities:
#   - keep one curation row per remote actor
#   - retain disabled rows for reversible administration
#   - expose a bounded, ordered set to Worlds discovery
#
# This file intentionally does not resolve actors, authorize administrators,
# follow communities, or change remote ActivityPub state.

defmodule Pleroma.FederatedTargetCuration do
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias FlakeId.Ecto.CompatType
  alias Pleroma.Repo
  alias Pleroma.User

  @primary_key {:id, CompatType, autogenerate: true}
  @max_entries 200
  @maximum_position 1_000_000

  schema "federated_target_curations" do
    belongs_to(:target, User, type: CompatType)
    field(:enabled, :boolean, default: true)
    field(:position, :integer, default: 0)

    timestamps()
  end

  def changeset(curation, attrs) do
    curation
    |> cast(attrs, [:target_id, :enabled, :position])
    |> validate_required([:target_id, :enabled, :position])
    |> validate_number(:position,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: @maximum_position
    )
    |> foreign_key_constraint(:target_id)
    |> unique_constraint(:target_id)
  end

  @doc "Return the bounded administration list, including disabled entries."
  def list do
    __MODULE__
    |> order_by([curation],
      desc: curation.enabled,
      asc: curation.position,
      asc: curation.inserted_at
    )
    |> limit(^@max_entries)
    |> preload(:target)
    |> Repo.all()
  end

  @doc "Return enabled target actors in administrator-defined order."
  def active_targets do
    User
    |> join(:inner, [target], curation in __MODULE__, on: curation.target_id == target.id)
    |> where(
      [target, curation],
      curation.enabled == true and target.local == false and target.is_active == true and
        target.invisible == false
    )
    |> order_by([_target, curation],
      asc: curation.position,
      asc: curation.inserted_at
    )
    |> limit(^@max_entries)
    |> Repo.all()
  end

  @doc "Return enabled curation positions for the supplied actors."
  def active_positions(targets) when is_list(targets) do
    target_ids =
      targets
      |> Enum.map(&Map.get(&1, :id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if target_ids == [] do
      %{}
    else
      __MODULE__
      |> where([curation], curation.enabled == true and curation.target_id in ^target_ids)
      |> select([curation], {curation.target_id, curation.position})
      |> Repo.all()
      |> Map.new()
    end
  end

  def active_positions(_targets), do: %{}

  @doc "Create or re-enable one duplicate-safe curation row."
  def put(%User{id: target_id}) when not is_nil(target_id) do
    case Repo.get_by(__MODULE__, target_id: target_id) do
      %__MODULE__{} = curation ->
        __MODULE__.update(curation, %{enabled: true})

      nil ->
        if Repo.aggregate(__MODULE__, :count, :id) >= @max_entries do
          {:error, :curation_limit_reached}
        else
          insert(target_id)
        end
    end
  end

  def put(_target), do: {:error, :invalid_target}

  def get(id), do: Repo.get(__MODULE__, id) |> maybe_preload_target()

  def update(%__MODULE__{} = curation, attrs) when is_map(attrs) do
    curation
    |> changeset(attrs)
    |> Repo.update()
    |> preload_result()
  end

  def delete(%__MODULE__{} = curation), do: Repo.delete(curation)

  defp insert(target_id) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    %__MODULE__{}
    |> changeset(%{
      target_id: target_id,
      enabled: true,
      position: next_position()
    })
    |> Repo.insert(
      on_conflict: [set: [enabled: true, updated_at: now]],
      conflict_target: [:target_id],
      returning: true
    )
    |> preload_result()
  end

  defp next_position do
    maximum = Repo.one(from(curation in __MODULE__, select: max(curation.position))) || -10
    min(maximum + 10, @maximum_position)
  end

  defp preload_result({:ok, %__MODULE__{} = curation}) do
    {:ok, Repo.preload(curation, :target, force: true)}
  end

  defp preload_result(result), do: result

  defp maybe_preload_target(%__MODULE__{} = curation), do: Repo.preload(curation, :target)
  defp maybe_preload_target(nil), do: nil
end

# end of lib/pleroma/federated_target_curation.ex
