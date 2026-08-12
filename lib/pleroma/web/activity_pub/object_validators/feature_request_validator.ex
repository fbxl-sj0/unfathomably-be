# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.FeatureRequestValidator do
  @moduledoc """
  Validates FEP-7aa9 requests to include a local actor in a remote collection.

  The requester may be supplied by the verified delivery signature before this
  validator runs. The target remains a local active actor; authorization policy
  is evaluated later so a valid request can receive either Accept or Reject.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Pleroma.EctoType.ActivityPub.ObjectValidators
  alias Pleroma.User
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
    |> validate_required([:id, :type, :actor, :object, :instrument])
    |> validate_inclusion(:type, ["FeatureRequest"])
    |> CommonValidations.validate_actor_presence()
    |> validate_local_target()
  end

  defp validate_local_target(changeset) do
    case get_field(changeset, :object) |> User.get_cached_by_ap_id() do
      %User{local: true, is_active: true} -> changeset
      _other -> add_error(changeset, :object, "must identify an active local actor")
    end
  end
end

# end of feature_request_validator.ex
