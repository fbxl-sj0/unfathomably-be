# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.EmojiReactValidator do
  use Ecto.Schema

  alias Pleroma.Emoji
  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonFixes
  alias Pleroma.Web.ActivityPub.ObjectValidators.TagValidator

  import Ecto.Changeset
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonValidations

  @primary_key false
  @max_reaction_length 100
  @max_reaction_bytes 400
  @numeric_emoji_entity ~r/\A&#(?:[0-9]{1,7}|[xX][0-9A-Fa-f]{1,6});\z/

  embedded_schema do
    quote do
      unquote do
        import Elixir.Pleroma.Web.ActivityPub.ObjectValidators.CommonFields
        message_fields()
        activity_fields()
        embeds_many(:tag, TagValidator)
      end
    end

    field(:context, :string)
    field(:content, :string)
    field(:_misskey_reaction, :string)
    field(:_pleroma_reaction_type, :string)
  end

  def cast_and_validate(data) do
    data
    |> cast_data()
    |> validate_data()
  end

  @doc "Returns true when a reaction name fits the shared wire and storage bounds."
  def valid_reaction_name?(value) when is_binary(value) do
    String.valid?(value) and String.length(value) <= @max_reaction_length and
      byte_size(value) <= @max_reaction_bytes
  end

  def valid_reaction_name?(_value), do: false

  def cast_data(data) do
    data =
      data
      |> fix()

    %__MODULE__{}
    |> changeset(data)
  end

  def changeset(struct, data) do
    struct
    |> cast(data, __schema__(:fields) -- [:tag])
    |> cast_embed(:tag)
  end

  defp fix(data) do
    data =
      data
      |> decode_numeric_emoji_entities()
      |> fix_emoji_qualification()
      |> CommonFixes.fix_actor()
      |> CommonFixes.fix_activity_addressing()

    data = Map.put_new(data, "tag", [])

    case normalize_object_reference(data["object"]) do
      %Object{} = object ->
        data
        |> CommonFixes.fix_activity_context(object)
        |> CommonFixes.fix_object_action_recipients(object)
        |> CommonFixes.fix_object_action_audience(object)

      _ ->
        data
    end
  end

  defp normalize_object_reference(object) when is_binary(object) or is_map(object) do
    Object.normalize(object)
  end

  defp normalize_object_reference(_object), do: nil

  defp decode_numeric_emoji_entities(data) do
    Enum.reduce(["content", "_misskey_reaction"], data, fn field, data ->
      case data[field] do
        value when is_binary(value) ->
          Map.put(data, field, decode_numeric_emoji_entity(value))

        _value ->
          data
      end
    end)
  end

  defp decode_numeric_emoji_entity(value) do
    if Regex.match?(@numeric_emoji_entity, value) do
      decoded = HtmlEntities.decode(value)

      if single_grapheme?(decoded) and Emoji.is_unicode_emoji?(decoded) do
        decoded
      else
        value
      end
    else
      value
    end
  rescue
    _error -> value
  end

  defp single_grapheme?(value) when is_binary(value) do
    case String.next_grapheme(value) do
      {_grapheme, ""} -> true
      _other -> false
    end
  end

  defp single_grapheme?(_value), do: false

  defp fix_emoji_qualification(%{"content" => emoji} = data) when is_binary(emoji) do
    new_emoji = Pleroma.Emoji.fully_qualify_emoji(emoji)

    cond do
      Pleroma.Emoji.is_unicode_emoji?(emoji) ->
        data

      Pleroma.Emoji.is_unicode_emoji?(new_emoji) ->
        data |> Map.put("content", new_emoji)

      true ->
        data
    end
  end

  defp fix_emoji_qualification(data), do: data

  defp validate_emoji(cng) do
    content = get_field(cng, :content)

    if Emoji.is_unicode_emoji?(content) || Emoji.is_custom_emoji?(content) do
      cng
    else
      cng
      |> add_error(:content, "is not a valid emoji")
    end
  end

  defp maybe_validate_tag_presence(cng) do
    content = get_field(cng, :content)

    if Emoji.is_unicode_emoji?(content) do
      cng
    else
      tag = get_field(cng, :tag)
      emoji_name = Emoji.maybe_strip_name(content)

      case tag do
        [%{name: ^emoji_name, type: "Emoji", icon: %{url: _}}] ->
          cng

        _ ->
          cng
          |> add_error(:tag, "does not contain an Emoji tag")
      end
    end
  end

  defp validate_reaction_lengths(changeset) do
    [:content, :_misskey_reaction]
    |> Enum.reduce(changeset, fn field, changeset ->
      case get_field(changeset, field) do
        nil ->
          changeset

        value ->
          if valid_reaction_name?(value) do
            changeset
          else
            add_error(changeset, field, "is too long")
          end
      end
    end)
  end

  defp validate_data(data_cng) do
    data_cng
    |> validate_inclusion(:type, ["EmojiReact"])
    |> validate_inclusion(:_pleroma_reaction_type, ["Dislike"], allow_nil: true)
    |> validate_required([:id, :type, :object, :actor, :context, :to, :cc, :content])
    |> validate_reaction_lengths()
    |> CommonValidations.validate_actor_presence()
    |> CommonValidations.validate_object_presence()
    |> CommonValidations.validate_object_visibility()
    |> validate_emoji()
    |> maybe_validate_tag_presence()
  end
end
