# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.ArticleNotePageValidator do
  use Ecto.Schema

  alias Pleroma.EctoType.ActivityPub.ObjectValidators
  alias Pleroma.HTML
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Addressing
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonFixes
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonValidations
  alias Pleroma.Web.ActivityPub.Transmogrifier
  alias Pleroma.Web.CommonAPI.Utils

  import Ecto.Changeset

  @primary_key false
  @derive Jason.Encoder

  embedded_schema do
    quote do
      unquote do
        import Elixir.Pleroma.Web.ActivityPub.ObjectValidators.CommonFields
        message_fields()
        object_fields()
        status_object_fields()
      end
    end

    field(:replies, {:array, ObjectValidators.ObjectID}, default: [])
    field(:replies_collection, ObjectValidators.ObjectID)
    field(:source, :map)
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

  defp fix_url(%{"url" => url} = data) when is_bitstring(url), do: data
  defp fix_url(%{"url" => url} = data) when is_map(url), do: Map.put(data, "url", url["href"])
  defp fix_url(data), do: data

  defp fix_tag(%{"tag" => tag} = data) when is_list(tag) do
    Map.put(data, "tag", Enum.filter(tag, &is_map/1))
  end

  defp fix_tag(%{"tag" => tag} = data) when is_map(tag), do: Map.put(data, "tag", [tag])
  defp fix_tag(data), do: Map.drop(data, ["tag"])

  defp fix_replies(%{"replies" => %{"first" => %{"items" => replies}}} = data)
       when is_list(replies),
       do: Map.put(data, "replies", replies)

  defp fix_replies(%{"replies" => %{"items" => replies}} = data) when is_list(replies),
    do: Map.put(data, "replies", replies)

  defp fix_replies(%{"replies" => %{"orderedItems" => replies}} = data) when is_list(replies),
    do: Map.put(data, "replies", replies)

  # Collections are not supported here. If the `replies` field is not something
  # the ObjectID validator can handle, the activity/object would be rejected,
  # which is worse than dropping the unsupported reply collection.
  defp fix_replies(%{"replies" => replies} = data) when not is_list(replies),
    do: Map.drop(data, ["replies"])

  defp fix_replies(data), do: data

  defp fix_interaction_collection(data, field, count_field) do
    case data[field] do
      %{"items" => items} when is_list(items) ->
        Map.put(data, field, items)

      %{"orderedItems" => items} when is_list(items) ->
        Map.put(data, field, items)

      %{"totalItems" => total_items} = collection when is_integer(total_items) ->
        data
        |> maybe_put_collection_count(count_field, collection)
        |> Map.delete(field)

      collection when is_map(collection) ->
        Map.delete(data, field)

      _ ->
        data
    end
  end

  defp maybe_put_collection_count(data, count_field, %{"totalItems" => total_items})
       when is_integer(total_items) and total_items >= 0 do
    case data[count_field] do
      nil -> Map.put(data, count_field, total_items)
      _ -> data
    end
  end

  defp maybe_put_collection_count(data, _count_field, _collection), do: data

  defp fix_interaction_collections(data) do
    data
    |> fix_interaction_collection("likes", "like_count")
    |> fix_interaction_collection("announcements", "announcement_count")
    |> fix_interaction_collection("shares", "announcement_count")
  end

  defp fix_replies_collection(data) do
    collection_id =
      replies_collection_id(data["replies"]) ||
        replies_collection_id(data["comments"]) ||
        data["replies_collection"]

    data = Map.delete(data, "replies_collection")

    with collection_id when is_binary(collection_id) <- collection_id,
         {:ok, collection_id} <- ObjectValidators.ObjectID.cast(collection_id),
         true <- same_origin?(collection_id, data["id"]) do
      Map.put(data, "replies_collection", collection_id)
    else
      _ -> data
    end
  end

  defp replies_collection_id(collection) when is_binary(collection), do: collection
  defp replies_collection_id(%{"id" => id}) when is_binary(id), do: id
  defp replies_collection_id(%{"first" => %{"partOf" => id}}) when is_binary(id), do: id
  defp replies_collection_id(_), do: nil

  defp same_origin?(left, right) when is_binary(left) and is_binary(right) do
    left = URI.parse(left)
    right = URI.parse(right)

    is_binary(left.scheme) and is_binary(left.host) and is_binary(right.scheme) and
      is_binary(right.host) and left.scheme == right.scheme and
      String.downcase(left.host) == String.downcase(right.host) and
      uri_port(left) == uri_port(right)
  rescue
    URI.Error -> false
  end

  defp same_origin?(_, _), do: false

  defp uri_port(%URI{port: nil, scheme: scheme}), do: URI.default_port(scheme)
  defp uri_port(%URI{port: port}), do: port

  defp fix_quote_url(%{"quoteUrl" => _quote_url} = data), do: data

  # Fedibird
  # https://github.com/fedibird/mastodon/commit/dbd7ae6cf58a92ec67c512296b4daaea0d01e6ac
  defp fix_quote_url(%{"quoteUri" => quote_url} = data) do
    Map.put(data, "quoteUrl", quote_url)
  end

  # Old Fedibird (bug)
  # https://github.com/fedibird/mastodon/issues/9
  defp fix_quote_url(%{"quoteURL" => quote_url} = data) do
    Map.put(data, "quoteUrl", quote_url)
  end

  # Misskey fallback
  defp fix_quote_url(%{"_misskey_quote" => quote_url} = data) do
    Map.put(data, "quoteUrl", quote_url)
  end

  defp fix_quote_url(data), do: data

  def fix_attachments(%{"attachment" => attachment} = data) when is_map(attachment),
    do: Map.put(data, "attachment", [attachment])

  def fix_attachments(%{"attachment" => attachments} = data) when is_list(attachments) do
    attachments = Enum.filter(attachments, &is_map/1)

    if attachments == [] do
      Map.drop(data, ["attachment"])
    else
      Map.put(data, "attachment", attachments)
    end
  end

  def fix_attachments(%{"attachment" => _attachment} = data), do: Map.drop(data, ["attachment"])

  def fix_attachments(data), do: data

  defp remote_mention_resolver(
         %{"id" => ap_id, "tag" => tags},
         "@" <> nickname = mention,
         buffer,
         opts,
         acc
       )
       when is_binary(ap_id) and is_list(tags) do
    initial_host =
      ap_id
      |> URI.parse()
      |> Map.get(:host)

    with mention_tag when not is_nil(mention_tag) <-
           Enum.find(tags, &mention_tag?(&1, mention, initial_host)),
         href when is_binary(href) <- mention_tag["href"],
         %User{} = user <- User.get_cached_by_ap_id(href) do
      link = Pleroma.Formatter.mention_from_user(user, opts)
      {link, %{acc | mentions: MapSet.put(acc.mentions, {"@" <> nickname, user})}}
    else
      _ -> {buffer, acc}
    end
  end

  defp remote_mention_resolver(_object, _mention, buffer, _opts, acc), do: {buffer, acc}

  defp mention_tag?(%{"type" => "Mention", "name" => name}, mention, initial_host)
       when is_binary(name) do
    name == mention || mention == "#{name}@#{initial_host}"
  end

  defp mention_tag?(_tag, _mention, _initial_host), do: false

  defp scrub_content(%{"content" => content} = object) when is_binary(content) do
    Map.put(object, "content", HTML.filter_tags(content))
  end

  defp scrub_content(object), do: object

  defp mfm_parse_limit do
    min(Pleroma.Config.get([:instance, :limit]), Pleroma.Config.get([:instance, :remote_limit]))
  end

  defp normalize_source(%{"source" => source} = object) when is_binary(source) do
    object
    |> Map.put("source", %{"content" => source})
    |> normalize_source()
  end

  defp normalize_source(%{"source" => source} = object) when is_map(source) do
    source =
      case source["content"] do
        content when is_binary(content) ->
          if String.length(content) <= mfm_parse_limit() do
            source
          else
            Map.delete(source, "content")
          end

        nil ->
          source

        _ ->
          Map.delete(source, "content")
      end

    Map.put(object, "source", source)
  end

  defp normalize_source(object), do: object

  defp fix_misskey_content(%{"htmlMfm" => true, "content" => content} = object)
       when is_binary(content) do
    Map.put(object, "content", HTML.filter_tags(content))
  end

  defp fix_misskey_content(%{"htmlMfm" => true} = object), do: object

  defp fix_misskey_content(
         %{"source" => %{"mediaType" => "text/x.misskeymarkdown", "content" => content}} = object
       )
       when is_binary(content) do
    mention_handler = fn nick, buffer, opts, acc ->
      remote_mention_resolver(object, nick, buffer, opts, acc)
    end

    {linked, _mentions, _tags} =
      Utils.format_input(content, "text/x.misskeymarkdown", mention_handler: mention_handler)

    Map.put(object, "content", linked)
  end

  defp fix_misskey_content(%{"source" => %{"mediaType" => "text/x.misskeymarkdown"}} = object),
    do: scrub_content(object)

  defp fix_misskey_content(%{"_misskey_content" => content} = object) when is_binary(content) do
    object
    |> Map.put("source", %{
      "content" => content,
      "mediaType" => "text/x.misskeymarkdown"
    })
    |> Map.delete("_misskey_content")
    |> fix_misskey_content()
  end

  defp fix_misskey_content(object), do: object

  defp fix_group_thread_root_type(%{"type" => "Note"} = object) do
    if group_thread_root?(object) do
      object
      |> Map.put("type", "Page")
      |> Map.put("name", group_page_name(object))
    else
      object
    end
  end

  defp fix_group_thread_root_type(object), do: object

  defp group_thread_root?(object) do
    Addressing.group_addressing_context?(object) and root_object?(object)
  end

  defp root_object?(%{"inReplyTo" => value}) do
    value in [nil, "", []]
  end

  defp root_object?(_object), do: true

  defp group_page_name(object) do
    [
      object["name"],
      object["summary"],
      object["content"]
    ]
    |> Enum.find_value(&compact_title/1)
    |> Kernel.||("Untitled group post")
  end

  defp compact_title(value) when is_binary(value) do
    value =
      value
      |> String.replace(~r/<[^>]*>/, " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    case value do
      "" -> nil
      value -> String.slice(value, 0, 200)
    end
  end

  defp compact_title(_value), do: nil

  def fix(data) do
    data
    |> CommonFixes.fix_actor()
    |> CommonFixes.fix_object_defaults()
    |> fix_url()
    |> fix_tag()
    |> fix_replies_collection()
    |> fix_replies()
    |> fix_interaction_collections()
    |> fix_quote_url()
    |> fix_attachments()
    |> normalize_source()
    |> fix_misskey_content()
    |> fix_group_thread_root_type()
    |> CommonFixes.fix_quote_url()
    |> Transmogrifier.fix_emoji()
    |> Transmogrifier.fix_content_map()
    |> Transmogrifier.maybe_add_language()
  end

  def changeset(struct, data) do
    data = fix(data)

    struct
    |> cast(data, __schema__(:fields) -- [:attachment, :tag])
    |> cast_embed(:attachment)
    |> cast_embed(:tag)
  end

  defp validate_data(data_cng) do
    data_cng
    |> validate_inclusion(:type, ["Article", "Note", "Page"])
    |> validate_required([:id, :actor, :attributedTo, :type, :context])
    |> CommonValidations.validate_any_presence([:cc, :to])
    |> CommonValidations.validate_fields_match([:actor, :attributedTo])
    |> CommonValidations.validate_actor_presence()
    |> CommonValidations.validate_host_match()
  end
end
