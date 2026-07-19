# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.QuoteAuthorizationDeleteValidator do
  use Ecto.Schema

  import Ecto.Changeset

  alias Pleroma.EctoType.ActivityPub.ObjectValidators
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonValidations

  @primary_key false

  embedded_schema do
    field(:id, ObjectValidators.ObjectID, primary_key: true)
    field(:type, :string)
    field(:actor, ObjectValidators.ObjectID)
    field(:to, ObjectValidators.Recipients, default: [])
    field(:cc, ObjectValidators.Recipients, default: [])
    field(:object, :map)
  end

  def cast_and_validate(data) do
    %__MODULE__{}
    |> cast(data, __schema__(:fields))
    |> validate_required([:id, :type, :actor, :object])
    |> validate_inclusion(:type, ["Delete"])
    |> CommonValidations.validate_actor_presence()
    |> validate_document()
  end

  defp validate_document(changeset) do
    actor = get_field(changeset, :actor)

    case get_field(changeset, :object) do
      %{
        "type" => "QuoteAuthorization",
        "attributedTo" => ^actor,
        "interactingObject" => quote,
        "interactionTarget" => target
      }
      when is_binary(quote) and is_binary(target) ->
        changeset

      _ ->
        add_error(changeset, :object, "is not a valid quote authorization")
    end
  end
end

# end of quote_authorization_delete_validator.ex
