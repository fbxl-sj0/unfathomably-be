# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.QuestionValidator do
  use Ecto.Schema

  alias Pleroma.Config
  alias Pleroma.EctoType.ActivityPub.ObjectValidators
  alias Pleroma.Web.ActivityPub.ObjectValidators.ArticleNotePageValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonValidations
  alias Pleroma.Web.ActivityPub.ObjectValidators.QuestionOptionsValidator

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
      end
    end

    field(:closed, ObjectValidators.DateTime)
    field(:voters, {:array, ObjectValidators.ObjectID}, default: [])
    field(:votersCount, :integer)
    field(:nonAnonymous, :boolean)
    embeds_many(:anyOf, QuestionOptionsValidator)
    embeds_many(:oneOf, QuestionOptionsValidator)
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

  defp fix_closed(data) do
    cond do
      is_binary(data["closed"]) -> data
      is_binary(data["endTime"]) -> Map.put(data, "closed", data["endTime"])
      true -> Map.drop(data, ["closed"])
    end
  end

  defp fix(data) do
    data
    |> fix_interaction_counts()
    |> ArticleNotePageValidator.fix()
    |> fix_closed()
  end

  defp fix_interaction_counts(data) do
    data
    |> fix_interaction_count("likes", "like_count")
    |> fix_interaction_count("shares", "announcement_count")
  end

  defp fix_interaction_count(data, field, count_field) do
    case Map.get(data, field) do
      %{"totalItems" => count} when is_integer(count) ->
        data
        |> Map.put(count_field, count)
        |> Map.put(field, [])

      _ ->
        data
    end
  end

  def changeset(struct, data) do
    data = fix(data)

    struct
    |> cast(data, __schema__(:fields) -- [:anyOf, :oneOf, :attachment, :tag])
    |> cast_embed(:attachment)
    |> cast_embed(:anyOf)
    |> cast_embed(:oneOf)
    |> cast_embed(:tag)
  end

  defp validate_data(data_cng) do
    data_cng
    |> validate_inclusion(:type, ["Question"])
    |> validate_required([:id, :actor, :attributedTo, :type, :context])
    |> CommonValidations.validate_any_presence([:cc, :to])
    |> CommonValidations.validate_fields_match([:actor, :attributedTo])
    |> CommonValidations.validate_actor_presence()
    |> CommonValidations.validate_any_presence([:oneOf, :anyOf])
    |> validate_option_count()
    |> CommonValidations.validate_host_match()
  end

  defp validate_option_count(changeset) do
    option_count =
      length(get_field(changeset, :oneOf) || []) + length(get_field(changeset, :anyOf) || [])

    maximum = Config.get([:instance, :poll_limits, :max_options], 20)
    maximum = if is_integer(maximum) and maximum > 0, do: maximum, else: 20

    if option_count > maximum do
      add_error(changeset, :oneOf, "has too many poll options")
    else
      changeset
    end
  end
end
