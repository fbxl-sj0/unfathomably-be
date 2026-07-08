# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.AnnounceValidator do
  use Ecto.Schema

  alias Pleroma.EctoType.ActivityPub.ObjectValidators
  alias Pleroma.Object
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonFixes
  alias Pleroma.Web.ActivityPub.Utils
  alias Pleroma.Web.ActivityPub.Visibility

  import Ecto.Changeset
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonValidations

  require Pleroma.Constants

  @relay_activity_object_types ~w[Add Block Dislike EmojiReact Like Remove]

  @primary_key false

  embedded_schema do
    quote do
      unquote do
        import Elixir.Pleroma.Web.ActivityPub.ObjectValidators.CommonFields
        message_fields()
        activity_fields()
      end
    end

    field(:context, :string)
    field(:published, ObjectValidators.DateTime)
  end

  def cast_and_validate(data) do
    data
    |> cast_data()
    |> validate_data()
  end

  def cast_data(data) do
    data =
      data
      |> fix()

    %__MODULE__{}
    |> changeset(data)
  end

  def changeset(struct, data) do
    struct
    |> cast(data, __schema__(:fields))
    |> maybe_put_embedded_relay_activity(data)
  end

  defp maybe_put_embedded_relay_activity(changeset, %{
         "object" => %{"type" => type} = object
       })
       when type in @relay_activity_object_types do
    put_change(changeset, :object, object)
  end

  defp maybe_put_embedded_relay_activity(changeset, _data), do: changeset

  defp fix(data) do
    data =
      data
      |> CommonFixes.fix_actor()
      |> CommonFixes.fix_activity_addressing()

    with %Object{} = object <- normalize_object_reference(data["object"]) do
      data
      |> CommonFixes.fix_activity_context(object)
      |> CommonFixes.fix_object_action_recipients(object)
      |> CommonFixes.fix_object_action_audience(object)
    else
      _ -> data
    end
  end

  defp normalize_object_reference(object) when is_binary(object) or is_map(object) do
    Object.normalize(object)
  end

  defp normalize_object_reference(_object), do: nil

  defp validate_data(data_cng) do
    data_cng
    |> validate_inclusion(:type, ["Announce"])
    |> validate_required([:id, :type, :object, :actor, :to, :cc])
    |> validate_non_empty_recipients()
    |> CommonValidations.validate_actor_presence()
    |> maybe_validate_object_presence()
    |> validate_existing_announce()
    |> validate_announcable()
  end

  defp validate_non_empty_recipients(cng) do
    recipients =
      [:to, :cc, :bto, :bcc]
      |> Enum.flat_map(fn field -> get_field(cng, field) || [] end)

    if recipients == [] do
      add_error(cng, :to, "must have at least one recipient")
    else
      cng
    end
  end

  defp maybe_validate_object_presence(cng) do
    case get_field(cng, :object) do
      %{"type" => type} when type in @relay_activity_object_types -> cng
      _ -> CommonValidations.validate_object_presence(cng)
    end
  end

  defp validate_announcable(cng) do
    with actor when is_binary(actor) <- get_field(cng, :actor),
         object when is_binary(object) <- get_field(cng, :object),
         %User{} = actor <- User.get_cached_by_ap_id(actor),
         %Object{} = object <- Object.get_cached_by_ap_id(object),
         false <- Visibility.is_public?(object) do
      same_actor = object.data["actor"] == actor.ap_id
      recipients = List.wrap(get_field(cng, :to)) ++ List.wrap(get_field(cng, :cc))
      local_public = Utils.as_local_public()

      is_public =
        Enum.member?(recipients, Pleroma.Constants.as_public()) or
          Enum.member?(recipients, local_public)

      cond do
        same_actor && is_public ->
          cng
          |> add_error(:actor, "can not announce this object publicly")

        !same_actor ->
          cng
          |> add_error(:actor, "can not announce this object")

        true ->
          cng
      end
    else
      _ -> cng
    end
  end

  defp validate_existing_announce(cng) do
    actor = get_field(cng, :actor)
    object = get_field(cng, :object)

    if is_binary(actor) && is_binary(object) &&
         Utils.get_existing_announce(actor, %{data: %{"id" => object}}) do
      cng
      |> add_error(:actor, "already announced this object")
      |> add_error(:object, "already announced by this actor")
    else
      cng
    end
  end
end
