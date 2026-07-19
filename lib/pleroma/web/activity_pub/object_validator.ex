# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidator do
  @moduledoc """
  This module is responsible for validating an object (which can be an activity)
  and checking if it is both well formed and also compatible with our view of
  the system.
  """

  @behaviour Pleroma.Web.ActivityPub.ObjectValidator.Validating

  require Pleroma.Constants

  alias Pleroma.Activity
  alias Pleroma.EctoType.ActivityPub.ObjectValidators
  alias Pleroma.Object
  alias Pleroma.Object.Containment
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.CustomActivity
  alias Pleroma.Web.ActivityPub.CustomObject
  alias Pleroma.Web.ActivityPub.ObjectValidators.AcceptRejectValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.QuoteAuthorizationDeleteValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.QuoteRequestValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.AddRemoveValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.AnnounceValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.AnswerValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.ArticleNotePageValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.AudioImageVideoValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.BlockValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.ChatMessageValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.CreateChatMessageValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.CreateGenericValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.CustomActivityValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.CustomObjectValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.DeleteValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.EmojiReactValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.EventValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.FollowValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.JoinValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.LeaveValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.LikeValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.LockValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.QuestionValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.UndoValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.UpdateValidator

  @normalized_standard_input_fields ~w[contentMap nameMap summaryMap]

  @impl true
  def validate(object, meta)

  def validate(%{"type" => "QuoteRequest"} = object, meta) do
    with {:ok, object} <-
           object
           |> QuoteRequestValidator.cast_and_validate()
           |> Ecto.Changeset.apply_action(:insert) do
      {:ok, stringify_keys(object), meta}
    end
  end

  def validate(
        %{"type" => "Delete", "object" => %{"type" => "QuoteAuthorization"}} = object,
        meta
      ) do
    with {:ok, object} <-
           object
           |> QuoteAuthorizationDeleteValidator.cast_and_validate()
           |> Ecto.Changeset.apply_action(:insert) do
      {:ok, stringify_keys(object), meta}
    end
  end

  def validate(%{"type" => "Block"} = block_activity, meta) do
    with {:ok, block_activity} <-
           block_activity
           |> BlockValidator.cast_and_validate()
           |> Ecto.Changeset.apply_action(:insert) do
      block_activity = stringify_keys(block_activity)
      outgoing_blocks = Pleroma.Config.get([:activitypub, :outgoing_blocks])

      meta =
        if !outgoing_blocks do
          Keyword.put(meta, :do_not_federate, true)
        else
          meta
        end

      {:ok, block_activity, meta}
    end
  end

  def validate(%{"type" => "Undo"} = object, meta) do
    with {:ok, object} <-
           object
           |> UndoValidator.cast_and_validate()
           |> Ecto.Changeset.apply_action(:insert) do
      object = stringify_keys(object)

      case Activity.get_by_ap_id(object["object"]) do
        %Activity{} = undone_object ->
          meta =
            meta
            |> Keyword.put(:object_data, undone_object.data)

          {:ok, object, meta}

        _ ->
          {:error, :undone_activity_not_found}
      end
    end
  end

  def validate(%{"type" => "Delete"} = object, meta) do
    original_object = object

    with cng <- DeleteValidator.cast_and_validate(object),
         do_not_federate <- DeleteValidator.do_not_federate?(cng),
         {:ok, object} <- Ecto.Changeset.apply_action(cng, :insert) do
      object = stringify_keys(object)

      meta =
        meta
        |> Keyword.put(:do_not_federate, do_not_federate)
        |> Keyword.put(:delete_target, DeleteValidator.classify_target(original_object))

      {:ok, object, meta}
    end
  end

  def validate(
        %{"type" => "Create", "object" => %{"type" => "ChatMessage"} = object} = create_activity,
        meta
      ) do
    with {:ok, object_data} <- cast_and_apply(object),
         meta = Keyword.put(meta, :object_data, object_data |> stringify_keys),
         {:ok, create_activity} <-
           create_activity
           |> CreateChatMessageValidator.cast_and_validate(meta)
           |> Ecto.Changeset.apply_action(:insert) do
      create_activity = stringify_keys(create_activity)
      {:ok, create_activity, meta}
    end
  end

  def validate(
        %{"type" => "Create", "object" => %{"type" => objtype} = object} = create_activity,
        meta
      )
      when objtype in ~w[Question Answer Audio Video Image Event Article Document Note Page Track] do
    object = CreateGenericValidator.inherit_public_object_addressing(object, create_activity)
    create_activity = Map.put(create_activity, "object", object)

    with {:ok, object_data} <- cast_and_apply_and_stringify_with_history(object),
         meta = Keyword.put(meta, :object_data, object_data),
         {:ok, create_activity} <-
           create_activity
           |> CreateGenericValidator.cast_and_validate(meta)
           |> Ecto.Changeset.apply_action(:insert) do
      create_activity = stringify_keys(create_activity)
      {:ok, create_activity, meta}
    end
  end

  def validate(
        %{"type" => "Create", "object" => %{"type" => _type}} = create_activity,
        meta
      ) do
    if CustomObject.custom_object?(create_activity["object"]) do
      CustomObjectValidator.validate_create(create_activity, meta)
    else
      {:error, {:validator_not_set, {create_activity, meta}}}
    end
  end

  def validate(%{"type" => type} = object, meta)
      when type in ~w[Event Question Audio Video Image Article Document Note Page Track] do
    validator =
      case type do
        "Event" -> EventValidator
        "Question" -> QuestionValidator
        "Audio" -> AudioImageVideoValidator
        "Video" -> AudioImageVideoValidator
        "Image" -> AudioImageVideoValidator
        "Article" -> ArticleNotePageValidator
        "Document" -> ArticleNotePageValidator
        "Track" -> AudioImageVideoValidator
        "Note" -> ArticleNotePageValidator
        "Page" -> ArticleNotePageValidator
      end

    with {:ok, object} <-
           do_separate_with_history(object, fn object ->
             with {:ok, object} <- validate_standard_object(object, validator) do
               # Insert copy of hashtags as strings for the non-hashtag table indexing
               tag =
                 object
                 |> Map.get("tag")
                 |> List.wrap()
                 |> Enum.filter(fn tag -> is_binary(tag) or is_map(tag) end)
                 |> Kernel.++(Object.hashtags(%Object{data: object}))

               {:ok, Map.put(object, "tag", tag)}
             end
           end) do
      {:ok, object, meta}
    end
  end

  def validate(
        %{"type" => "Update", "object" => %{"type" => objtype} = object} = update_activity,
        meta
      )
      when objtype in ~w[Question Answer Audio Video Event Article Document Note Page Track] do
    object = CreateGenericValidator.inherit_public_object_addressing(object, update_activity)
    object = inherit_known_object_update_timestamp(object, update_activity, meta)
    update_activity = Map.put(update_activity, "object", object)

    with {_, false} <- {:local, Access.get(meta, :local, false)},
         {_, {:ok, object_data, _}} <- {:object_validation, validate(object, meta)},
         meta = Keyword.put(meta, :object_data, object_data),
         {:ok, update_activity} <-
           update_activity
           |> UpdateValidator.cast_and_validate(meta)
           |> Ecto.Changeset.apply_action(:insert) do
      update_activity = stringify_keys(update_activity)
      {:ok, update_activity, meta}
    else
      {:local, _} ->
        with {:ok, object} <-
               update_activity
               |> UpdateValidator.cast_and_validate(meta)
               |> Ecto.Changeset.apply_action(:insert) do
          object = stringify_keys(object)
          {:ok, object, meta}
        end

      {:object_validation, e} ->
        e

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  def validate(
        %{"type" => "Update", "object" => %{"type" => _type} = object} = update_activity,
        meta
      ) do
    if CustomObject.custom_object?(object) do
      if Access.get(meta, :local, false) do
        with {:ok, update_activity} <-
               update_activity
               |> UpdateValidator.cast_and_validate(meta)
               |> Ecto.Changeset.apply_action(:insert) do
          {:ok, stringify_keys(update_activity), meta}
        end
      else
        object_meta = Keyword.put(meta, :activity_actor, update_activity["actor"])

        with {:ok, object_data} <- CustomObjectValidator.validate(object, object_meta),
             meta = Keyword.put(meta, :object_data, object_data),
             {:ok, update_activity} <-
               update_activity
               |> UpdateValidator.cast_and_validate(meta)
               |> Ecto.Changeset.apply_action(:insert) do
          {:ok, stringify_keys(update_activity), meta}
        end
      end
    else
      validate_generic_update(update_activity, meta)
    end
  end

  def validate(%{"type" => "Update"} = object, meta) do
    validate_generic_update(object, meta)
  end

  def validate(%{"type" => type} = object, meta)
      when type in ~w[Accept Reject Follow Like EmojiReact Announce
      ChatMessage Answer Join Leave Lock] do
    validator =
      case type do
        "Accept" -> AcceptRejectValidator
        "Reject" -> AcceptRejectValidator
        "Follow" -> FollowValidator
        "Like" -> LikeValidator
        "EmojiReact" -> EmojiReactValidator
        "Announce" -> AnnounceValidator
        "ChatMessage" -> ChatMessageValidator
        "Answer" -> AnswerValidator
        "Join" -> JoinValidator
        "Leave" -> LeaveValidator
        "Lock" -> LockValidator
      end

    with {:ok, object} <-
           object
           |> validator.cast_and_validate()
           |> Ecto.Changeset.apply_action(:insert) do
      object = stringify_keys(object)
      {:ok, object, meta}
    end
  end

  def validate(%{"type" => type} = object, meta) when type in ~w(Add Remove) do
    with {:ok, object} <-
           object
           |> AddRemoveValidator.cast_and_validate()
           |> Ecto.Changeset.apply_action(:insert) do
      object = stringify_keys(object)
      {:ok, object, meta}
    end
  end

  def validate(%{"type" => _type} = object, meta) do
    cond do
      CustomActivity.custom_activity?(object) ->
        CustomActivityValidator.validate(object, meta)

      CustomObject.custom_object?(object) ->
        with {:ok, object} <- CustomObjectValidator.validate(object, meta) do
          {:ok, object, meta}
        end

      true ->
        {:error, {:validator_not_set, {object, meta}}}
    end
  end

  def validate(o, m), do: {:error, {:validator_not_set, {o, m}}}

  defp validate_generic_update(object, meta) do
    with {:ok, object} <-
           object
           |> UpdateValidator.cast_and_validate(meta)
           |> Ecto.Changeset.apply_action(:insert) do
      object = stringify_keys(object)
      {:ok, object, meta}
    end
  end

  # Wanderer timestamps an outer Update with published but omits object.updated.
  # Only borrow that timestamp for an object already known locally.  Unknown
  # object Updates retain the stricter embedded timestamp requirement used by
  # the initial-import path.
  defp inherit_known_object_update_timestamp(object, activity, meta) do
    object_id = object["id"]
    activity_timestamp = activity["published"]

    if not Access.get(meta, :local, false) and is_nil(object["updated"]) and
         is_binary(object_id) and is_binary(activity_timestamp) do
      case Object.get_by_ap_id(object_id) do
        %Object{} = known_object ->
          Map.put(
            object,
            "updated",
            monotonic_known_update_timestamp(known_object.data, activity_timestamp)
          )

        _unknown_object ->
          object
      end
    else
      object
    end
  end

  # Wanderer can emit several distinct Updates in one whole-second clock tick,
  # for example GPX upload followed immediately by a Trail edit.  Preserve
  # their authenticated arrival order within that second.  An Update from an
  # older second remains older and is still rejected by Object.Updater.
  defp monotonic_known_update_timestamp(known_object, activity_timestamp) do
    known_timestamp = known_object["updated"] || known_object["published"]

    with {:ok, activity_datetime, _offset} <- DateTime.from_iso8601(activity_timestamp),
         known_timestamp when is_binary(known_timestamp) <- known_timestamp,
         {:ok, known_datetime, _offset} <- DateTime.from_iso8601(known_timestamp),
         true <-
           DateTime.compare(known_datetime, activity_datetime) in [:eq, :gt] and
             DateTime.truncate(known_datetime, :second) ==
               DateTime.truncate(activity_datetime, :second) do
      known_datetime
      |> DateTime.add(1, :microsecond)
      |> DateTime.to_iso8601()
    else
      _other -> activity_timestamp
    end
  end

  def cast_and_apply_and_stringify_with_history(object) do
    do_separate_with_history(object, fn object ->
      with validator when is_atom(validator) <- standard_object_validator(object["type"]),
           {:ok, object_data} <- validate_standard_object(object, validator) do
        {:ok, object_data}
      else
        {:error, _reason} = error -> error
        _other -> {:error, {:validator_not_set, object}}
      end
    end)
  end

  defp validate_standard_object(object, validator) do
    with :ok <- CustomObjectValidator.validate_safety(object),
         {:ok, normalized} <-
           object
           |> validator.cast_and_validate()
           |> Ecto.Changeset.apply_action(:insert) do
      normalized = stringify_keys(normalized)
      known_fields = Enum.map(validator.__schema__(:fields), &to_string/1)

      extensions =
        object
        |> Map.drop(
          known_fields ++
            @normalized_standard_input_fields ++ Pleroma.Constants.object_internal_fields()
        )

      extension_fields = Map.keys(extensions) ++ compatible_standard_extension_fields(object)

      normalized =
        extensions
        |> Map.merge(normalized)
        |> merge_standard_tag_extensions(object)
        |> merge_standard_document_extensions(object)
        |> maybe_mark_standard_extensions(extension_fields)

      {:ok, normalized}
    end
  end

  defp maybe_mark_standard_extensions(object, []), do: object

  defp maybe_mark_standard_extensions(object, fields) do
    CustomObject.put_standard_internal_metadata(object, fields)
  end

  defp merge_standard_tag_extensions(normalized, %{"tag" => original_tags})
       when is_list(original_tags) do
    normalized_tags = List.wrap(normalized["tag"])

    merged_tags =
      Enum.map(normalized_tags, fn normalized_tag ->
        case Enum.find(original_tags, &same_standard_tag?(&1, normalized_tag)) do
          %{} = original_tag when is_map(normalized_tag) ->
            Map.merge(original_tag, normalized_tag)

          _other ->
            normalized_tag
        end
      end)

    retained_tags =
      Enum.reject(original_tags, fn original_tag ->
        Enum.any?(normalized_tags, &same_standard_tag?(original_tag, &1))
      end)

    Map.put(normalized, "tag", Enum.uniq(merged_tags ++ retained_tags))
  end

  # CommonsPub/ZenPub publishes the resource licence as a scalar `tag` on a
  # top-level Document. The Article validator quite correctly accepts only
  # ActivityStreams tag objects, but dropping the scalar here would erase
  # native publishing metadata that is otherwise safe and bounded.
  defp merge_standard_tag_extensions(normalized, %{"type" => "Document", "tag" => tag})
       when is_binary(tag),
       do: Map.put(normalized, "tag", tag)

  defp merge_standard_tag_extensions(normalized, _original), do: normalized

  # ZenPub uses `language` as publishing metadata even when it is not derived
  # from contentMap or an ActivityStreams language context. Preserve that
  # bounded scalar after the ordinary Document validator has run.
  defp merge_standard_document_extensions(normalized, %{
         "type" => "Document",
         "language" => language
       })
       when is_binary(language),
       do: Map.put(normalized, "language", language)

  defp merge_standard_document_extensions(normalized, _original), do: normalized

  defp compatible_standard_extension_fields(%{"type" => "Document"} = object) do
    []
    |> maybe_add_compatible_standard_extension("tag", is_binary(object["tag"]))
    |> maybe_add_compatible_standard_extension("language", is_binary(object["language"]))
  end

  defp compatible_standard_extension_fields(_object), do: []

  defp maybe_add_compatible_standard_extension(fields, field, true), do: fields ++ [field]
  defp maybe_add_compatible_standard_extension(fields, _field, false), do: fields

  defp same_standard_tag?(%{"type" => left_type} = left, %{"type" => right_type} = right)
       when is_binary(left_type) and is_binary(right_type) do
    left_type == right_type and standard_tag_identity(left) == standard_tag_identity(right)
  end

  defp same_standard_tag?(_left, _right), do: false

  defp standard_tag_identity(tag) do
    tag["id"] || tag["href"] || normalized_tag_name(tag["name"])
  end

  defp normalized_tag_name(name) when is_binary(name), do: String.downcase(name)
  defp normalized_tag_name(_name), do: nil

  defp standard_object_validator("Event"), do: EventValidator
  defp standard_object_validator("Question"), do: QuestionValidator
  defp standard_object_validator("Answer"), do: AnswerValidator

  defp standard_object_validator(type) when type in ~w[Audio Image Video Track],
    do: AudioImageVideoValidator

  defp standard_object_validator(type) when type in ~w[Article Document Note Page],
    do: ArticleNotePageValidator

  defp standard_object_validator(_type), do: nil

  def cast_and_apply(%{"type" => "ChatMessage"} = object) do
    ChatMessageValidator.cast_and_apply(object)
  end

  def cast_and_apply(%{"type" => "Question"} = object) do
    QuestionValidator.cast_and_apply(object)
  end

  def cast_and_apply(%{"type" => "Answer"} = object) do
    AnswerValidator.cast_and_apply(object)
  end

  def cast_and_apply(%{"type" => type} = object) when type in ~w[Audio Image Video Track] do
    AudioImageVideoValidator.cast_and_apply(object)
  end

  def cast_and_apply(%{"type" => "Event"} = object) do
    EventValidator.cast_and_apply(object)
  end

  def cast_and_apply(%{"type" => type} = object) when type in ~w[Article Document Note Page] do
    ArticleNotePageValidator.cast_and_apply(object)
  end

  def cast_and_apply(o), do: {:error, {:validator_not_set, o}}

  def stringify_keys(object) when is_struct(object) do
    object
    |> Map.from_struct()
    |> stringify_keys
  end

  def stringify_keys(object) when is_map(object) do
    object
    |> Enum.filter(fn {_, v} -> v != nil end)
    |> Map.new(fn {key, val} -> {to_string(key), stringify_keys(val)} end)
  end

  def stringify_keys(object) when is_list(object) do
    object
    |> Enum.map(&stringify_keys/1)
  end

  def stringify_keys(object), do: object

  def fetch_actor(object) when is_map(object) do
    with actor <- Containment.get_actor(object),
         {:ok, actor} <- ObjectValidators.ObjectID.cast(actor) do
      User.get_or_fetch_by_ap_id(actor)
    end
  end

  def fetch_actor(_object), do: nil

  def fetch_actor_and_object(%{"type" => type} = object) when type in ~w[Add Remove Lock] do
    fetch_actor(object)
    fetch_object_or_user(object["object"])
    :ok
  end

  def fetch_actor_and_object(object) when is_map(object) do
    fetch_actor(object)
    fetch_thread_or_object(object["object"])
  end

  def fetch_actor_and_object(_object), do: :ok

  defp fetch_object_or_user(object) when is_binary(object) do
    case User.get_cached_by_ap_id(object) do
      %User{} -> :ok
      _ -> Object.normalize(object, fetch: true)
    end
  end

  defp fetch_object_or_user(object) when is_map(object), do: Object.normalize(object, fetch: true)
  defp fetch_object_or_user(_object), do: nil

  defp fetch_thread_or_object(object) when is_binary(object) do
    case Object.get_cached_by_ap_id(object) || Activity.get_by_ap_id(object) do
      nil ->
        case Pleroma.Web.ActivityPub.RemoteReplies.fetch_thread_from_reply(object, depth: 0) do
          {:ok, _object} -> :ok
          {:error, _reason} = error -> error
          _ -> {:error, :remote_object_unavailable}
        end

      _object_or_activity ->
        :ok
    end
  end

  defp fetch_thread_or_object(object) when is_map(object) do
    Object.normalize(object, fetch: true)
    :ok
  end

  defp fetch_thread_or_object(_object), do: :ok

  defp for_each_history_item(
         %{"type" => "OrderedCollection", "orderedItems" => items} = history,
         object,
         fun
       ) do
    processed_items =
      Enum.map(items, fn item ->
        with item <- Map.put(item, "id", object["id"]),
             {:ok, item} <- fun.(item) do
          item
        else
          _ -> nil
        end
      end)

    if Enum.all?(processed_items, &(not is_nil(&1))) do
      {:ok, Map.put(history, "orderedItems", processed_items)}
    else
      {:error, :invalid_history}
    end
  end

  defp for_each_history_item(nil, _object, _fun) do
    {:ok, nil}
  end

  defp for_each_history_item(_, _object, _fun) do
    {:error, :invalid_history}
  end

  # fun is (object -> {:ok, validated_object_with_string_keys})
  defp do_separate_with_history(object, fun) do
    with history <- object["formerRepresentations"],
         object <- Map.drop(object, ["formerRepresentations"]),
         {_, {:ok, object}} <- {:main_body, fun.(object)},
         {_, {:ok, history}} <- {:history_items, for_each_history_item(history, object, fun)} do
      object =
        if history do
          Map.put(object, "formerRepresentations", history)
        else
          object
        end

      {:ok, object}
    else
      {:main_body, e} -> e
      {:history_items, e} -> e
    end
  end
end
