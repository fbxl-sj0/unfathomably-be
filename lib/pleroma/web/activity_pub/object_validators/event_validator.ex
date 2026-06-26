# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.EventValidator do
  use Ecto.Schema

  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonFixes
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonValidations
  alias Pleroma.Web.ActivityPub.Transmogrifier

  import Ecto.Changeset

  @primary_key false
  @derive Jason.Encoder

  # Extends from NoteValidator
  embedded_schema do
    quote do
      unquote do
        import Elixir.Pleroma.Web.ActivityPub.ObjectValidators.CommonFields
        message_fields()
        object_fields()
        status_object_fields()
        event_object_fields()
      end
    end
  end

  def cast_and_apply(data) do
    data
    |> cast_data
    |> apply_action(:insert)
  end

  def cast_and_validate(data) do
    data
    |> cast_data()
    |> validate_data()
  end

  def cast_data(data) do
    %__MODULE__{}
    |> changeset(data)
  end

  defp fix(data) do
    data
    |> CommonFixes.fix_actor()
    |> CommonFixes.fix_object_defaults()
    |> fix_location()
    |> Transmogrifier.fix_emoji()
  end

  defp fix_location(%{"location" => locations} = data) when is_list(locations) do
    case Enum.find(locations, &physical_location?/1) do
      nil -> Map.delete(data, "location")
      location -> Map.put(data, "location", location)
    end
  end

  defp fix_location(%{"location" => %{"type" => type}} = data) when type != "Place" do
    Map.delete(data, "location")
  end

  defp fix_location(data), do: data

  defp physical_location?(%{"type" => "Place"}), do: true
  defp physical_location?(_), do: false

  def changeset(struct, data) do
    data = fix(data)

    struct
    |> cast(data, __schema__(:fields) -- [:attachment, :tag, :location])
    |> cast_embed(:attachment)
    |> cast_embed(:tag)
    |> cast_embed(:location)
  end

  defp validate_data(data_cng) do
    data_cng
    |> validate_inclusion(:type, ["Event"])
    |> validate_inclusion(:joinMode, ~w[free restricted invite])
    |> validate_required([:id, :actor, :attributedTo, :type, :context])
    |> CommonValidations.validate_any_presence([:cc, :to])
    |> CommonValidations.validate_fields_match([:actor, :attributedTo])
    |> CommonValidations.validate_actor_presence()
    |> CommonValidations.validate_host_match()
  end
end
