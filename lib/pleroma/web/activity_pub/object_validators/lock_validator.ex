# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.LockValidator do
  use Ecto.Schema

  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonFixes

  import Ecto.Changeset
  import Pleroma.Web.ActivityPub.ObjectValidators.CommonValidations

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
  end

  def cast_and_validate(data) do
    data
    |> cast_data()
    |> validate_data()
  end

  def cast_data(data) do
    data =
      data
      |> CommonFixes.fix_actor()
      |> CommonFixes.fix_activity_addressing()
      |> fix_object_context()

    %__MODULE__{}
    |> cast(data, __schema__(:fields))
  end

  defp fix_object_context(%{"object" => object_id} = data)
       when is_binary(object_id) or is_map(object_id) do
    with %Object{} = object <- Object.normalize(object_id, fetch: false) do
      CommonFixes.fix_activity_context(data, object)
    else
      _ -> data
    end
  end

  defp fix_object_context(data), do: data

  defp validate_data(data_cng) do
    data_cng
    |> validate_inclusion(:type, ["Lock"])
    |> validate_required([:id, :type, :object, :actor, :to, :cc])
    |> validate_actor_presence()
    |> validate_object_presence()
  end
end
