# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.AddRemoveValidator do
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonValidations

  require Pleroma.Constants

  alias Pleroma.Repo
  alias Pleroma.User

  @primary_key false

  embedded_schema do
    field(:target)

    quote do
      unquote do
        import Elixir.Pleroma.Web.ActivityPub.ObjectValidators.CommonFields
        message_fields()
        activity_fields()
      end
    end
  end

  def cast_and_validate(data) do
    actor = get_or_fetch_actor(data["actor"])
    maybe_fetch_collection_object(data)

    data
    |> maybe_fix_data_for_mastodon(actor)
    |> cast_data()
    |> validate_data(actor)
  end

  defp get_or_fetch_actor(actor) when is_binary(actor) do
    with {:ok, %User{} = actor} <- User.get_or_fetch_by_ap_id(actor),
         {:ok, %User{} = actor} <- maybe_refetch_user(actor) do
      actor
    else
      _ -> nil
    end
  end

  defp get_or_fetch_actor(_actor), do: nil

  defp maybe_fix_data_for_mastodon(data, actor) do
    # Mastodon sends pin/unpin objects without id, to, cc fields
    data
    |> Map.put_new("id", Pleroma.Web.ActivityPub.Utils.generate_activity_id())
    |> Map.put_new("to", [Pleroma.Constants.as_public()])
    |> maybe_put_mastodon_cc(actor)
  end

  defp maybe_put_mastodon_cc(data, %User{} = actor) do
    Map.put_new(data, "cc", [actor.follower_address])
  end

  defp maybe_put_mastodon_cc(data, _actor) do
    Map.put_new(data, "cc", [])
  end

  defp cast_data(data) do
    cast(%__MODULE__{}, data, __schema__(:fields))
  end

  defp validate_data(changeset, actor) do
    changeset
    |> validate_required([:id, :target, :object, :actor, :type, :to, :cc])
    |> validate_inclusion(:type, ~w(Add Remove))
    |> CommonValidations.validate_actor_presence()
    |> validate_collection_belongs_to_actor(actor)
    |> CommonValidations.validate_object_or_user_presence()
  end

  defp validate_collection_belongs_to_actor(changeset, %User{} = actor) do
    validate_change(changeset, :target, fn :target, target ->
      cond do
        target == actor.featured_address ->
          []

        collection_owner(target) ->
          []

        group_collection_target?(target) ->
          []

        true ->
          [target: "collection doesn't belong to actor or a known group"]
      end
    end)
  end

  defp validate_collection_belongs_to_actor(changeset, _actor) do
    changeset
  end

  defp collection_owner(target) when is_binary(target) do
    User
    |> where([user], user.featured_address == ^target or user.attributed_to_address == ^target)
    |> limit(1)
    |> Repo.one()
  end

  defp collection_owner(_), do: nil

  defp maybe_fetch_collection_object(%{"object" => object, "target" => target})
       when is_binary(object) and is_binary(target) do
    if moderator_collection_target?(target) do
      fetch_collection_object(object)
    else
      {:ok, nil}
    end
  end

  defp maybe_fetch_collection_object(_), do: {:ok, nil}

  defp fetch_collection_object(object) do
    case User.get_or_fetch_by_ap_id(object) do
      {:ok, %User{} = user} -> {:ok, user}
      _ -> {:ok, nil}
    end
  rescue
    URI.Error -> {:ok, nil}
    ArgumentError -> {:ok, nil}
  end

  defp moderator_collection_target?(target) do
    case collection_owner(target) do
      %User{attributed_to_address: ^target} ->
        true

      _ ->
        String.ends_with?(target, ["/moderators", "/collections/moderators"])
    end
  end

  defp group_collection_target?(target) when is_binary(target) do
    String.ends_with?(target, [
      "/moderators",
      "/collections/moderators",
      "/pinned",
      "/collections/featured"
    ])
  end

  defp group_collection_target?(_), do: false

  defp maybe_refetch_user(%User{featured_address: address} = user) when is_binary(address) do
    {:ok, user}
  end

  defp maybe_refetch_user(%User{ap_id: ap_id}) do
    # Maybe it could use User.get_or_fetch_by_ap_id to avoid refreshing too often
    User.fetch_by_ap_id(ap_id)
  end
end
