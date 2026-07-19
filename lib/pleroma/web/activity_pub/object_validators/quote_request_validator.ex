# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.QuoteRequestValidator do
  use Ecto.Schema

  import Ecto.Changeset

  alias Pleroma.EctoType.ActivityPub.ObjectValidators
  alias Pleroma.Object
  alias Pleroma.Object.Fetcher
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonValidations

  @primary_key false

  embedded_schema do
    quote do
      unquote do
        import Elixir.Pleroma.Web.ActivityPub.ObjectValidators.CommonFields
        message_fields()
        activity_fields()
      end
    end

    field(:instrument, ObjectValidators.ObjectID)
  end

  def cast_and_validate(data) do
    %__MODULE__{}
    |> cast(data, __schema__(:fields))
    |> validate_required([:id, :type, :actor, :object, :instrument, :to])
    |> validate_inclusion(:type, ["QuoteRequest"])
    |> CommonValidations.validate_actor_presence()
    |> validate_relationship()
  end

  defp validate_relationship(changeset) do
    actor = get_field(changeset, :actor)
    target = get_field(changeset, :object)
    instrument = get_field(changeset, :instrument)

    with %Object{} = quote_object <- get_object(instrument),
         %Object{} = quoted_object <- get_object(target),
         true <- quote_object.data["actor"] == actor,
         true <- quote_object.data["quoteUrl"] == quoted_object.data["id"],
         true <- quoted_object.data["actor"] in List.wrap(get_field(changeset, :to)) do
      changeset
    else
      _ -> add_error(changeset, :instrument, "does not describe the supplied quote")
    end
  end

  defp get_object(ap_id) do
    Object.get_by_ap_id(ap_id) ||
      case Fetcher.fetch_object_from_id(ap_id) do
        {:ok, object} -> object
        _ -> nil
      end
  end
end

# end of quote_request_validator.ex
