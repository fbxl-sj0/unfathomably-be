# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

# Code based on CreateChatMessageValidator
# NOTES
# - doesn't embed, will only get the object id
defmodule Pleroma.Web.ActivityPub.ObjectValidators.CreateGenericValidator do
  use Ecto.Schema

  alias Pleroma.EctoType.ActivityPub.ObjectValidators
  alias Pleroma.Object
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonFixes
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonValidations
  alias Pleroma.Web.ActivityPub.Transmogrifier

  import Ecto.Changeset

  require Pleroma.Constants

  @primary_key false

  embedded_schema do
    quote do
      unquote do
        import Elixir.Pleroma.Web.ActivityPub.ObjectValidators.CommonFields
        message_fields()
        activity_fields()
      end
    end

    field(:expires_at, ObjectValidators.DateTime)

    # Should be moved to object, done for CommonAPI.Utils.make_context
    field(:context, :string)
  end

  def cast_data(data, meta \\ []) do
    data = fix(data, meta)

    %__MODULE__{}
    |> changeset(data)
  end

  def cast_and_apply(data) do
    data
    |> cast_data
    |> apply_action(:insert)
  end

  def cast_and_validate(data, meta \\ []) do
    data
    |> cast_data(meta)
    |> validate_data(meta)
  end

  def changeset(struct, data) do
    struct
    |> cast(data, __schema__(:fields))
  end

  # CommonFixes.fix_activity_addressing adapted for Create specific behavior
  defp fix_addressing(data, object) do
    case User.get_cached_by_ap_id(data["actor"]) do
      %User{follower_address: follower_collection} ->
        data
        |> fix_create_recipients(object, follower_collection)
        |> Transmogrifier.fix_implicit_addressing(follower_collection)

      _ ->
        fix_create_recipients(data, object, nil)
    end
  end

  defp fix_create_recipients(data, object, follower_collection) do
    data
    |> CommonFixes.cast_and_filter_recipients("to", follower_collection, object["to"])
    |> CommonFixes.cast_and_filter_recipients("cc", follower_collection, object["cc"])
    |> CommonFixes.cast_and_filter_recipients("bto", follower_collection, object["bto"])
    |> CommonFixes.cast_and_filter_recipients("bcc", follower_collection, object["bcc"])
    |> CommonFixes.cast_and_filter_recipients("audience", follower_collection, object["audience"])
  end

  def fix(data, meta) do
    object = meta[:object_data]

    data
    |> CommonFixes.fix_actor()
    |> Map.put("context", object["context"])
    |> fix_addressing(object)
  end

  defp validate_data(cng, meta) do
    object = meta[:object_data]

    cng
    |> validate_required([:actor, :type, :object, :to, :cc])
    |> validate_inclusion(:type, ["Create"])
    |> CommonValidations.validate_actor_presence()
    |> validate_actors_match(object)
    |> validate_context_match(object)
    |> validate_addressing_match(object)
    |> validate_object_nonexistence()
    |> validate_object_containment()
  end

  def validate_object_containment(cng) do
    actor = get_field(cng, :actor)

    cng
    |> validate_change(:object, fn :object, object_id ->
      object_id_host = uri_host(object_id)
      actor_host = uri_host(actor)

      if is_binary(object_id_host) and object_id_host == actor_host do
        []
      else
        [{:object, "The host of the object id doesn't match with the host of the actor"}]
      end
    end)
  end

  def validate_object_nonexistence(cng) do
    cng
    |> validate_change(:object, fn :object, object_id ->
      if Object.get_cached_by_ap_id(object_id) do
        [{:object, "The object to create already exists"}]
      else
        []
      end
    end)
  end

  def validate_actors_match(cng, object) do
    attributed_to = object["attributedTo"] || object["actor"]

    cng
    |> validate_change(:actor, fn :actor, actor ->
      if actor == attributed_to do
        []
      else
        [{:actor, "Actor doesn't match with object attributedTo"}]
      end
    end)
  end

  def validate_context_match(cng, %{"context" => object_context}) do
    cng
    |> validate_change(:context, fn :context, context ->
      if context == object_context do
        []
      else
        [{:context, "context field not matching between Create and object (#{object_context})"}]
      end
    end)
  end

  def validate_addressing_match(cng, object) do
    audience_recipients = audience_recipients(cng, object)

    [:to, :cc, :bcc, :bto, :audience]
    |> Enum.reduce(cng, fn field, cng ->
      object_data = object[to_string(field)]

      validate_change(cng, field, fn field, data ->
        if addressing_matches?(field, data, object_data, audience_recipients) do
          []
        else
          [{field, "field doesn't match with object (#{inspect(object_data)})"}]
        end
      end)
    end)
  end

  defp audience_recipients(cng, object) do
    (normalize_recipients(get_field(cng, :audience)) ++ normalize_recipients(object["audience"]))
    |> Enum.uniq()
  end

  defp addressing_matches?(field, data, object_data, audience_recipients)
       when field in [:to, :cc] do
    # Lemmy-compatible communities often use the object `audience` as the real
    # group target, while repeating that same group address in either the outer
    # Create activity or the embedded Page/Note object.
    #
    # We still require all non-audience recipients to match exactly. This keeps
    # public, follower, direct, and hidden addressing strict while allowing the
    # community address to move between `to` and `cc`.
    strip_audience_recipient(data, audience_recipients) ==
      strip_audience_recipient(object_data, audience_recipients)
  end

  defp addressing_matches?(_field, data, object_data, _audience_recipients) do
    normalize_recipients(data) == normalize_recipients(object_data)
  end

  defp strip_audience_recipient(data, audience_recipients) do
    data
    |> normalize_recipients()
    |> Enum.reject(&(&1 in audience_recipients))
  end

  defp normalize_recipients(nil), do: []

  defp normalize_recipients(values) when is_list(values) do
    values
    |> Enum.flat_map(&normalize_recipients/1)
    |> Enum.uniq()
  end

  defp normalize_recipients(%{"id" => id}) when is_binary(id), do: normalize_recipients(id)
  defp normalize_recipients(%{"href" => href}) when is_binary(href), do: normalize_recipients(href)
  defp normalize_recipients(value) when is_binary(value), do: [normalize_public_recipient(value)]
  defp normalize_recipients(_), do: []

  defp normalize_public_recipient("Public"), do: Pleroma.Constants.as_public()
  defp normalize_public_recipient("as:Public"), do: Pleroma.Constants.as_public()
  defp normalize_public_recipient(value), do: value

  defp uri_host(uri) when is_binary(uri) do
    uri
    |> URI.parse()
    |> Map.get(:host)
  rescue
    URI.Error -> nil
  end

  defp uri_host(_), do: nil
end
