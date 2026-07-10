# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.Transmogrifier do
  @moduledoc """
  A module to handle coding from internal to wire ActivityPub and back.
  """
  alias Pleroma.Activity
  alias Pleroma.EctoType.ActivityPub.ObjectValidators
  alias Pleroma.Emoji
  alias Pleroma.Language.LanguageDetector
  alias Pleroma.Maps
  alias Pleroma.Object
  alias Pleroma.Object.Containment
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.ActivityPub.Addressing
  alias Pleroma.Web.ActivityPub.Builder
  alias Pleroma.Web.ActivityPub.ObjectValidator
  alias Pleroma.Web.ActivityPub.Pipeline
  alias Pleroma.Web.ActivityPub.Utils
  alias Pleroma.Web.ActivityPub.Visibility
  alias Pleroma.Web.FederatedTarget
  alias Pleroma.Web.Federator

  import Pleroma.Web.CommonAPI.Utils, only: [get_valid_language: 1]
  import Pleroma.Web.Utils.Guards, only: [not_empty_string: 1]

  require Logger
  require Pleroma.Constants

  @doc """
  Modifies an incoming AP object (mastodon format) to our internal format.
  """
  def fix_object(object, options \\ []) do
    object
    |> strip_internal_fields()
    |> fix_actor()
    |> fix_url()
    |> fix_attachments()
    |> fix_context()
    |> fix_in_reply_to(options)
    |> fix_emoji()
    |> fix_tag()
    |> fix_content_map()
    |> fix_addressing()
    |> fix_summary()
    |> maybe_add_language()
  end

  def fix_summary(%{"summary" => nil} = object) do
    Map.put(object, "summary", "")
  end

  def fix_summary(%{"summary" => _} = object) do
    # summary is present, nothing to do
    object
  end

  def fix_summary(object), do: Map.put(object, "summary", "")

  def fix_addressing_list(map, field) do
    addrs =
      map
      |> Map.get(field)
      |> List.wrap()
      |> Enum.map(&addressing_value/1)
      |> Enum.reject(&is_nil/1)

    Map.put(map, field, addrs)
  end

  defp addressing_value(%{"href" => value}), do: addressing_value(value)
  defp addressing_value(%{"id" => value}), do: addressing_value(value)
  defp addressing_value("Public"), do: Pleroma.Constants.as_public()
  defp addressing_value("as:Public"), do: Pleroma.Constants.as_public()
  defp addressing_value(value) when is_binary(value), do: value
  defp addressing_value(_), do: nil

  @doc """
  Bovine compatibility.

  Some producers emit the public ActivityStreams collection as "Public" or
  "as:Public". Normalize it before validation and visibility processing.
  """
  def fix_addressing_public(map, field) do
    Map.put(
      map,
      field,
      map
      |> Map.get(field, [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(fn
        "Public" -> Pleroma.Constants.as_public()
        "as:Public" -> Pleroma.Constants.as_public()
        x -> x
      end)
    )
  end

  # if directMessage flag is set to true, leave the addressing alone
  def fix_explicit_addressing(%{"directMessage" => true} = object, _follower_collection),
    do: object

  def fix_explicit_addressing(%{"to" => to, "cc" => cc} = object, follower_collection)
      when is_list(to) and is_list(cc) do
    explicit_mentions =
      Utils.determine_explicit_mentions(object) ++
        [Pleroma.Constants.as_public(), follower_collection]

    explicit_to = Enum.filter(to, fn x -> x in explicit_mentions end)
    explicit_cc = Enum.filter(to, fn x -> x not in explicit_mentions end)

    final_cc =
      (cc ++ explicit_cc)
      |> Enum.filter(& &1)
      |> Enum.filter(&is_binary/1)
      |> Enum.reject(fn x -> String.ends_with?(x, "/followers") and x != follower_collection end)
      |> Enum.uniq()

    object
    |> Map.put("to", explicit_to)
    |> Map.put("cc", final_cc)
  end

  def fix_explicit_addressing(%{"to" => _, "cc" => _} = object, follower_collection) do
    object
    |> fix_addressing_list("to")
    |> fix_addressing_list("cc")
    |> fix_explicit_addressing(follower_collection)
  end

  # if as:Public is addressed, then make sure the followers collection is also addressed
  # so that the activities will be delivered to local users.
  def fix_implicit_addressing(%{"to" => to, "cc" => cc} = object, followers_collection)
      when is_list(to) and is_list(cc) and is_binary(followers_collection) do
    recipients = to ++ cc

    if followers_collection not in recipients do
      cond do
        Pleroma.Constants.as_public() in cc ->
          to = to ++ [followers_collection]
          Map.put(object, "to", to)

        Pleroma.Constants.as_public() in to ->
          cc = cc ++ [followers_collection]
          Map.put(object, "cc", cc)

        true ->
          object
      end
    else
      object
    end
  end

  def fix_implicit_addressing(%{"to" => to, "cc" => cc} = object, followers_collection)
      when not is_list(to) or not is_list(cc) do
    object
    |> fix_addressing_list("to")
    |> fix_addressing_list("cc")
    |> fix_implicit_addressing(followers_collection)
  end

  def fix_implicit_addressing(object, _followers_collection), do: object

  def fix_addressing(object) do
    {:ok, %User{follower_address: follower_collection}} =
      object
      |> Containment.get_actor()
      |> User.get_or_fetch_by_ap_id()

    object
    |> fix_addressing_list("to")
    |> fix_addressing_list("cc")
    |> fix_addressing_list("bto")
    |> fix_addressing_list("bcc")
    |> fix_addressing_public("to")
    |> fix_addressing_public("cc")
    |> fix_addressing_public("bto")
    |> fix_addressing_public("bcc")
    |> fix_explicit_addressing(follower_collection)
    |> fix_implicit_addressing(follower_collection)
  end

  def fix_actor(%{"attributedTo" => actor} = object) do
    actor = Containment.get_actor(%{"actor" => actor})

    # Objects keep actor for legacy ActivityPub compatibility. Keeping it in
    # sync with attributedTo prevents downstream validators from seeing a split
    # identity for the same object.
    object
    |> Addressing.put_attributed_groups()
    |> Map.put("actor", actor)
    |> Map.put("attributedTo", actor)
  end

  def fix_in_reply_to(object, options \\ [])

  def fix_in_reply_to(%{"inReplyTo" => in_reply_to} = object, options)
      when not is_nil(in_reply_to) do
    in_reply_to_id = prepare_in_reply_to(in_reply_to)
    depth = (options[:depth] || 0) + 1

    if Federator.allowed_thread_distance?(depth) do
      with {:ok, replied_object} <- get_obj_helper(in_reply_to_id, options),
           %Activity{} <- Activity.get_create_by_object_ap_id(replied_object.data["id"]) do
        object
        |> Map.put("inReplyTo", replied_object.data["id"])
        |> Map.put("context", replied_object.data["context"] || object["conversation"])
        |> Map.drop(["conversation", "inReplyToAtomUri"])
      else
        e ->
          Logger.debug("Couldn't fetch #{inspect(in_reply_to_id)}, error: #{inspect(e)}")
          object
      end
    else
      object
    end
  end

  def fix_in_reply_to(object, _options), do: object

  def fix_quote_url_and_maybe_fetch(object, options \\ []) do
    quote_url =
      case Pleroma.Web.ActivityPub.ObjectValidators.CommonFixes.fix_quote_url(object) do
        %{"quoteUrl" => quote_url} -> quote_url
        _ -> nil
      end

    with {:quoting?, true} <- {:quoting?, not is_nil(quote_url)},
         {:ok, quoted_object} <- get_obj_helper(quote_url, options),
         %Activity{} <- Activity.get_create_by_object_ap_id(quoted_object.data["id"]) do
      Map.put(object, "quoteUrl", quoted_object.data["id"])
    else
      {:quoting?, _} ->
        object

      e ->
        Logger.debug("Couldn't fetch #{inspect(quote_url)}, error: #{inspect(e)}")
        object
    end
  end

  defp prepare_in_reply_to(in_reply_to) do
    cond do
      is_bitstring(in_reply_to) ->
        in_reply_to

      is_map(in_reply_to) && is_bitstring(in_reply_to["id"]) ->
        in_reply_to["id"]

      is_list(in_reply_to) && is_bitstring(Enum.at(in_reply_to, 0)) ->
        Enum.at(in_reply_to, 0)

      true ->
        ""
    end
  end

  def fix_context(object) do
    context = object["context"] || object["conversation"] || Utils.generate_context_id()

    object
    |> Map.put("context", context)
    |> Map.drop(["conversation"])
  end

  defp valid_media_type?(media_type) do
    is_binary(media_type) && media_type =~ Pleroma.Constants.mime_regex()
  end

  def fix_attachments(%{"attachment" => attachment} = object) when is_list(attachment) do
    attachments =
      Enum.map(attachment, fn
        data when is_map(data) ->
          url =
            cond do
              is_list(data["url"]) -> List.first(data["url"])
              is_map(data["url"]) -> data["url"]
              true -> nil
            end

          media_type =
            cond do
              is_map(url) && valid_media_type?(url["mediaType"]) ->
                url["mediaType"]

              valid_media_type?(data["mediaType"]) ->
                data["mediaType"]

              valid_media_type?(data["mimeType"]) ->
                data["mimeType"]

              true ->
                nil
            end

          href =
            cond do
              is_map(url) && is_binary(url["href"]) -> url["href"]
              is_binary(data["url"]) -> data["url"]
              is_binary(data["href"]) -> data["href"]
              true -> nil
            end

          if href do
            attachment_url =
              %{
                "href" => href,
                "type" => Map.get(url || %{}, "type", "Link")
              }
              |> Maps.put_if_present("mediaType", media_type)
              |> Maps.put_if_present("width", (url || %{})["width"] || data["width"])
              |> Maps.put_if_present("height", (url || %{})["height"] || data["height"])

            %{
              "url" => [attachment_url],
              "type" => data["type"] || "Document"
            }
            |> Maps.put_if_present("mediaType", media_type)
            |> Maps.put_if_present("name", data["name"])
            |> Maps.put_if_present("blurhash", data["blurhash"])
          else
            nil
          end

        _ ->
          nil
      end)
      |> Enum.filter(& &1)

    Map.put(object, "attachment", attachments)
  end

  def fix_attachments(%{"attachment" => attachment} = object) when is_map(attachment) do
    object
    |> Map.put("attachment", [attachment])
    |> fix_attachments()
  end

  def fix_attachments(object), do: object

  def fix_url(%{"url" => url} = object) when is_map(url) do
    Map.put(object, "url", url["href"])
  end

  def fix_url(%{"url" => url} = object) when is_list(url) do
    first_element = Enum.at(url, 0)

    url_string =
      cond do
        is_bitstring(first_element) -> first_element
        is_map(first_element) -> first_element["href"] || ""
        true -> ""
      end

    Map.put(object, "url", url_string)
  end

  def fix_url(object), do: object

  def fix_emoji(%{"tag" => tags} = object) when is_list(tags) do
    emoji =
      tags
      |> Enum.filter(&valid_emoji_tag?/1)
      |> Enum.reduce(%{}, fn data, mapping ->
        name = String.trim(data["name"], ":")

        Map.put(mapping, name, data["icon"]["url"])
      end)

    Map.put(object, "emoji", emoji)
  end

  def fix_emoji(%{"tag" => %{"type" => "Emoji", "name" => raw_name} = tag} = object)
      when is_binary(raw_name) do
    name = String.trim(raw_name, ":")

    emoji =
      if valid_emoji_tag?(tag) do
        %{name => tag["icon"]["url"]}
      else
        %{}
      end

    Map.put(object, "emoji", emoji)
  end

  def fix_emoji(object), do: object

  defp valid_emoji_tag?(%{"type" => "Emoji", "name" => name, "icon" => %{"url" => url}})
       when is_binary(name) and is_binary(url),
       do: true

  defp valid_emoji_tag?(_), do: false

  def fix_tag(%{"tag" => tag} = object) when is_list(tag) do
    tags =
      tag
      |> Enum.filter(fn
        %{"type" => "Hashtag", "name" => name} -> is_binary(name)
        _ -> false
      end)
      |> Enum.map(fn
        %{"name" => "#" <> hashtag} -> String.downcase(hashtag)
        %{"name" => hashtag} -> String.downcase(hashtag)
      end)

    Map.put(object, "tag", tag ++ tags)
  end

  def fix_tag(%{"tag" => %{} = tag} = object) do
    object
    |> Map.put("tag", [tag])
    |> fix_tag
  end

  def fix_tag(object), do: object

  def fix_content_map(%{"content" => content, "contentMap" => content_map} = object)
      when not_empty_string(content) and is_map(content_map),
      do: object

  def fix_content_map(%{"content" => content, "contentMap" => _} = object)
      when not_empty_string(content),
      do: Map.drop(object, ["contentMap"])

  def fix_content_map(%{"content" => content} = object) when not_empty_string(content), do: object

  def fix_content_map(%{"contentMap" => nil} = object), do: Map.drop(object, ["contentMap"])

  # content map usually only has one language so this will do for now.
  def fix_content_map(%{"contentMap" => content_map} = object) when is_map(content_map) do
    case Map.to_list(content_map) do
      [{_, content} | _] -> Map.put(object, "content", content)
      [] -> Map.drop(object, ["contentMap"])
    end
  end

  def fix_content_map(%{"contentMap" => _} = object), do: Map.drop(object, ["contentMap"])

  def fix_content_map(object), do: object

  defp fix_type(%{"type" => "Note", "inReplyTo" => reply_id, "name" => _} = object, options)
       when is_binary(reply_id) do
    options = Keyword.put(options, :fetch, true)

    with %Object{data: %{"type" => "Question"}} <- Object.normalize(reply_id, options) do
      Map.put(object, "type", "Answer")
    else
      _ -> object
    end
  end

  defp fix_type(object, _options), do: object

  # Reduce the object list to find the reported user.
  defp get_reported(objects) do
    Enum.reduce_while(objects, nil, fn ap_id, _ ->
      with %User{} = user <- User.get_cached_by_ap_id(ap_id) do
        {:halt, user}
      else
        _ -> {:cont, nil}
      end
    end)
  end

  defp reject_third_party_report(%User{local: false}, %User{local: false} = account) do
    {:reject, "[Transmogrifier] third-party report: #{account.ap_id}"}
  end

  defp reject_third_party_report(_, _), do: :ok

  @misskey_reactions %{
    "like" => "👍",
    "love" => "❤️",
    "laugh" => "😆",
    "hmm" => "🤔",
    "surprise" => "😮",
    "congrats" => "🎉",
    "angry" => "💢",
    "confused" => "😥",
    "rip" => "😇",
    "pudding" => "🍮",
    "star" => "⭐"
  }

  defp misskey_like_reaction(%{"_misskey_reaction" => reaction})
       when is_binary(reaction),
       do: reaction

  defp misskey_like_reaction(%{"content" => reaction}) when is_binary(reaction) do
    misskey_like_fallback_reaction(reaction)
  end

  defp misskey_like_reaction(%{"name" => reaction}) when is_binary(reaction) do
    misskey_like_fallback_reaction(reaction)
  end

  defp misskey_like_reaction(_), do: nil

  defp misskey_like_fallback_reaction(reaction) do
    cond do
      Map.has_key?(@misskey_reactions, reaction) -> reaction
      Emoji.is_unicode_emoji?(reaction) -> reaction
      Emoji.is_custom_emoji?(reaction) -> reaction
      true -> nil
    end
  end

  def handle_incoming(data, options \\ [])

  # Flag objects are placed ahead of the ID check because Mastodon 2.8 and earlier send them
  # with nil ID.
  def handle_incoming(%{"type" => "Flag", "object" => objects, "actor" => actor} = data, _options) do
    with context <- data["context"] || Utils.generate_context_id(),
         content <- data["content"] || "",
         objects <- List.wrap(objects),
         %User{} = actor <- User.get_cached_by_ap_id(actor),
         # Reduce the object list to find the reported user.
         %User{} = account <- get_reported(objects),
         :ok <- reject_third_party_report(actor, account),
         # Remove the reported user from the object list.
         statuses <- Enum.filter(objects, fn ap_id -> ap_id != account.ap_id end) do
      %{
        actor: actor,
        context: context,
        account: account,
        statuses: statuses,
        content: content,
        additional: %{"cc" => [account.ap_id]}
      }
      |> ActivityPub.flag()
    end
  end

  # disallow objects with bogus IDs
  def handle_incoming(%{"id" => nil}, _options), do: :error
  def handle_incoming(%{"id" => ""}, _options), do: :error
  # length of https:// = 8, should validate better, but good enough for now.
  def handle_incoming(%{"id" => id}, _options) when is_binary(id) and byte_size(id) < 8,
    do: :error

  # Some implementations send View or Read as lightweight receipts.  We do not
  # currently store per-object remote read state, but treating these activities
  # as successfully consumed prevents harmless receipts from becoming inbox
  # retry noise.
  def handle_incoming(%{"type" => type}, _options) when type in ~w{View Read},
    do: {:ok, :ignored}

  def handle_incoming(%{"type" => "Offer"} = data, _options) do
    if owncast_stream_lifecycle?(data), do: {:ok, :ignored}, else: :error
  end

  def handle_incoming(%{"type" => "Leave"} = data, _options) do
    if owncast_stream_lifecycle?(data) do
      {:ok, :ignored}
    else
      handle_actor_activity(data)
    end
  end

  def handle_incoming(
        %{"type" => "Listen", "object" => %{"type" => "Audio"} = object} = data,
        options
      ) do
    actor = Containment.get_actor(data)

    data =
      Map.put(data, "actor", actor)
      |> fix_addressing

    with {:ok, %User{} = user} <- User.get_or_fetch_by_ap_id(data["actor"]) do
      reply_depth = (options[:depth] || 0) + 1
      options = Keyword.put(options, :depth, reply_depth)
      object = fix_object(object, options)

      params = %{
        to: data["to"],
        object: object,
        actor: user,
        context: nil,
        local: false,
        published: data["published"],
        additional: Map.take(data, ["cc", "id"])
      }

      ActivityPub.listen(params)
    else
      _e -> :error
    end
  end

  # Rewrite misskey likes into EmojiReacts.
  def handle_incoming(%{"type" => "Like"} = data, options) do
    case misskey_like_reaction(data) do
      reaction when is_binary(reaction) ->
        data
        |> Map.put("type", "EmojiReact")
        |> Map.put("content", @misskey_reactions[reaction] || reaction)
        |> handle_incoming(options)

      _ ->
        with :ok <- ObjectValidator.fetch_actor_and_object(data),
             {:ok, activity, _meta} <-
               Pipeline.common_pipeline(data, local: false) do
          {:ok, activity}
        else
          e -> {:error, e}
        end
    end
  end

  # Rewrite Dislike activities into thumbs-down EmojiReacts.
  def handle_incoming(%{"type" => "Dislike"} = data, options) do
    data
    |> Map.put("type", "EmojiReact")
    |> Map.put("content", "👎")
    |> handle_incoming(options)
  end

  def handle_incoming(%{"type" => "Undo", "object" => %{"type" => "Dislike"}} = data, options) do
    data
    |> put_in(["object", "type"], "EmojiReact")
    |> put_in(["object", "content"], "👎")
    |> handle_incoming(options)
  end

  def handle_incoming(
        %{"type" => "Announce", "object" => %{"type" => type} = object},
        options
      )
      when type in [
             "Create",
             "Like",
             "EmojiReact",
             "Dislike",
             "Undo",
             "Delete",
             "Update",
             "Add",
             "Remove",
             "Flag",
             "Lock"
           ] do
    handle_incoming(object, options)
  end

  def handle_incoming(
        %{"type" => "Create", "object" => %{"type" => objtype, "id" => obj_id}} = data,
        options
      )
      when objtype in ~w{Question Answer ChatMessage Audio Video Event Article Note Page Image Track} do
    fetch_options = Keyword.put(options, :depth, (options[:depth] || 0) + 1)

    object =
      data["object"]
      |> strip_internal_fields()
      |> fix_type(fetch_options)
      |> fix_in_reply_to(fetch_options)
      |> fix_quote_url_and_maybe_fetch(fetch_options)
      |> maybe_add_language_from_activity(data)

    data = Map.put(data, "object", object)
    options = Keyword.put(options, :local, false)

    with {:ok, %User{}} <- ObjectValidator.fetch_actor(data),
         nil <- Activity.get_create_by_object_ap_id(obj_id),
         {:ok, activity, _} <- Pipeline.common_pipeline(data, options) do
      {:ok, activity}
    else
      %Activity{} = activity -> {:ok, activity}
      e -> e
    end
  end

  def handle_incoming(%{"type" => "Announce", "object" => object} = data, options)
      when is_binary(object) do
    prefetch_announced_object(object, options)
    handle_object_action(data)
  end

  def handle_incoming(%{"type" => type} = data, _options)
      when type in ~w{Like EmojiReact Announce Add Remove Lock} do
    handle_object_action(data)
  end

  def handle_incoming(
        %{"type" => "Block"} = data,
        _options
      ) do
    with {:ok, %User{}} <- ObjectValidator.fetch_actor(data),
         {:ok, %User{}} <- fetch_blocked_actor(data),
         :ok <- maybe_fetch_block_target(data),
         {:ok, activity, _} <-
           Pipeline.common_pipeline(data, local: false) do
      {:ok, activity}
    end
  end

  def handle_incoming(
        %{"type" => type} = data,
        _options
      )
      when type in ~w{Update Follow Accept Reject Join} do
    handle_actor_activity(data)
  end

  def handle_incoming(
        %{"type" => "Delete"} = data,
        _options
      ) do
    with {:ok, activity, _} <-
           Pipeline.common_pipeline(data, local: false) do
      {:ok, activity}
    else
      {:error, {:validate, _}} = e ->
        # Check if we have a create activity for this
        with {:ok, object_id} <- ObjectValidators.ObjectID.cast(data["object"]),
             :ok <- Containment.contain_origin(object_id, %{"actor" => data["actor"]}),
             %Activity{data: %{"actor" => actor}} <-
               Activity.create_by_object_ap_id(object_id) |> Ecto.Query.first() |> Repo.one(),
             # We have one, insert a tombstone and retry
             {:ok, tombstone_data, _} <- Builder.tombstone(actor, object_id),
             {:ok, _tombstone} <- Object.create(tombstone_data) do
          handle_incoming(data)
        else
          _ -> e
        end

      e ->
        {:error, e}
    end
  end

  def handle_incoming(
        %{
          "type" => "Undo",
          "object" => %{"type" => "Follow", "object" => followed},
          "actor" => follower,
          "id" => id
        } = _data,
        _options
      ) do
    with %User{local: true} = followed <- User.get_cached_by_ap_id(followed),
         {:ok, %User{} = follower} <- User.get_or_fetch_by_ap_id(follower),
         {:ok, activity} <- ActivityPub.unfollow(follower, followed, id, false) do
      User.unfollow(follower, followed)
      {:ok, activity}
    else
      _e -> :error
    end
  end

  def handle_incoming(
        %{
          "type" => "Undo",
          "object" => %{"type" => type}
        } = data,
        _options
      )
      when type in ["Like", "EmojiReact", "Announce", "Block", "Join", "Lock"] do
    data = fix_undo_object_id(data)

    with {:ok, activity, _} <- Pipeline.common_pipeline(data, local: false) do
      {:ok, activity}
    else
      _ -> {:ok, :ignored}
    end
  end

  # For Undos that don't have the complete object attached, try to find it in our database.
  def handle_incoming(
        %{
          "type" => "Undo",
          "object" => object
        } = activity,
        options
      )
      when is_binary(object) do
    with %Activity{data: data} <- Activity.get_by_ap_id(object) do
      activity
      |> Map.put("object", data)
      |> handle_incoming(options)
    else
      _e -> {:ok, :ignored}
    end
  end

  def handle_incoming(
        %{
          "type" => "Move",
          "actor" => origin_actor,
          "object" => origin_actor,
          "target" => target_actor
        },
        _options
      ) do
    with %User{} = origin_user <- User.get_cached_by_ap_id(origin_actor),
         {:ok, %User{} = target_user} <- User.get_or_fetch_by_ap_id(target_actor),
         true <- origin_actor in target_user.also_known_as do
      ActivityPub.move(origin_user, target_user, false)
    else
      _e -> :error
    end
  end

  def handle_incoming(_, _), do: :error

  defp handle_object_action(data) do
    with :ok <- ObjectValidator.fetch_actor_and_object(data),
         {:ok, activity, _meta} <-
           Pipeline.common_pipeline(data, local: false) do
      {:ok, activity}
    else
      e -> {:error, e}
    end
  end

  defp handle_actor_activity(data) do
    with {:ok, %User{}} <- ObjectValidator.fetch_actor(data),
         {:ok, activity, _} <-
           Pipeline.common_pipeline(data, local: false) do
      {:ok, activity}
    end
  end

  @spec get_obj_helper(String.t(), Keyword.t()) :: {:ok, Object.t()} | nil
  def get_obj_helper(id, options \\ []) do
    options = Keyword.put(options, :fetch, true)

    case Object.normalize(id, options) do
      %Object{} = object -> {:ok, object}
      _ -> nil
    end
  end

  @spec get_embedded_obj_helper(String.t() | Object.t(), User.t()) :: {:ok, Object.t()} | nil
  def get_embedded_obj_helper(%{"attributedTo" => attributed_to, "id" => object_id} = data, %User{
        ap_id: ap_id
      })
      when attributed_to == ap_id do
    with {:ok, activity} <-
           handle_incoming(%{
             "type" => "Create",
             "to" => data["to"],
             "cc" => data["cc"],
             "actor" => attributed_to,
             "object" => data
           }) do
      {:ok, Object.normalize(activity, fetch: false)}
    else
      _ -> get_obj_helper(object_id)
    end
  end

  def get_embedded_obj_helper(object_id, _) do
    get_obj_helper(object_id)
  end

  def set_reply_to_uri(%{"inReplyTo" => in_reply_to} = object) when is_binary(in_reply_to) do
    with false <- String.starts_with?(in_reply_to, "http"),
         {:ok, %{data: replied_to_object}} <- get_obj_helper(in_reply_to) do
      Map.put(object, "inReplyTo", replied_to_object["external_url"] || in_reply_to)
    else
      _e -> object
    end
  end

  def set_reply_to_uri(obj), do: obj

  @doc """
  Fedibird compatibility
  https://github.com/fedibird/mastodon/commit/dbd7ae6cf58a92ec67c512296b4daaea0d01e6ac
  """
  def set_quote_url(%{"quoteUrl" => quote_url} = object) when is_binary(quote_url) do
    object
    |> Map.put("quoteUri", quote_url)
    |> Map.put("_misskey_quote", quote_url)
  end

  def set_quote_url(obj), do: obj

  @doc """
  Inline first page of the `replies` collection,
  containing any replies in chronological order.
  """
  def set_replies(obj_data) do
    with object_ap_id when not is_nil(object_ap_id) <- obj_data["id"],
         limit when limit > 0 <-
           Pleroma.Config.get([:activitypub, :note_replies_output_limit], 0),
         collection <-
           Pleroma.Web.ActivityPub.ObjectView.render("object_replies.json", %{
             render_params: %{object_ap_id: object_ap_id, limit: limit, skip_ap_ctx: true}
           }) do
      Map.put(obj_data, "replies", collection)
    else
      0 -> Map.put(obj_data, "replies", obj_data["id"] <> "/replies")
      _ -> obj_data
    end
  end

  defp set_voters_count(%{"voters" => [_ | _] = voters} = obj) do
    obj
    |> Map.merge(%{"votersCount" => length(voters)})
    |> Map.delete("voters")
  end

  defp set_voters_count(obj), do: obj

  # Prepares the object of an outgoing create activity.
  def prepare_object(object) do
    object
    |> add_hashtags
    |> add_mention_tags
    |> add_emoji_tags
    |> add_attributed_to
    |> maybe_add_content_map
    |> prepare_attachments
    |> set_conversation
    |> set_reply_to_uri
    |> set_quote_url
    |> set_replies
    |> set_voters_count
    |> strip_internal_fields
    |> strip_internal_tags
    |> set_type
    |> maybe_process_history
  end

  defp maybe_process_history(%{"formerRepresentations" => %{"orderedItems" => history}} = object) do
    processed_history =
      Enum.map(
        history,
        fn
          item when is_map(item) -> prepare_object(item)
          item -> item
        end
      )

    put_in(object, ["formerRepresentations", "orderedItems"], processed_history)
  end

  defp maybe_process_history(object) do
    object
  end

  #  @doc
  #  """
  #  internal -> Mastodon
  #  """

  def prepare_outgoing(%{"type" => activity_type, "object" => object_id} = data)
      when activity_type in ["Create", "Listen"] do
    object =
      object_id
      |> Object.normalize(fetch: false)
      |> Map.get(:data)
      |> prepare_object

    data =
      data
      |> Map.put("object", object)
      |> Map.merge(Utils.make_json_ld_header(data))
      |> Map.delete("bcc")

    {:ok, data}
  end

  def prepare_outgoing(%{"type" => "Update", "object" => %{"type" => objtype} = object} = data)
      when objtype in Pleroma.Constants.updatable_object_types() do
    object =
      object
      |> prepare_object

    data =
      data
      |> Map.put("object", object)
      |> Map.merge(Utils.make_json_ld_header(data))
      |> Map.delete("bcc")

    {:ok, data}
  end

  def prepare_outgoing(%{"type" => "Update", "object" => %{"type" => objtype} = object} = data)
      when objtype in Pleroma.Constants.actor_types() do
    object =
      object
      |> maybe_fix_user_object()
      |> strip_internal_fields()

    data =
      data
      |> Map.put("object", object)
      |> strip_internal_fields()
      |> Map.merge(Utils.make_json_ld_header(object))
      |> Map.delete("bcc")

    {:ok, data}
  end

  def prepare_outgoing(%{"type" => "Update", "object" => %{"type" => objtype}}) do
    raise "refusing to serve Update activity for non-updateable object type #{inspect(objtype)}"
  end

  def prepare_outgoing(%{"type" => "Announce", "actor" => ap_id, "object" => _object_id} = data) do
    data =
      data
      |> maybe_expand_group_announce_object()

    data =
      case data do
        %{"object" => %{} = _object} ->
          data

        %{"object" => object_id} ->
          object =
            object_id
            |> Object.normalize(fetch: false)

          if Visibility.is_private?(object) && object.data["actor"] == ap_id do
            data |> Map.put("object", object |> Map.get(:data) |> prepare_object)
          else
            data |> maybe_fix_object_url
          end
      end

    data =
      data
      |> strip_internal_fields
      |> Map.merge(Utils.make_json_ld_header(data))
      |> Map.delete("bcc")

    {:ok, data}
  end

  # Mastodon Accept/Reject requires a non-normalized object containing the actor URIs,
  # because of course it does.
  def prepare_outgoing(%{"type" => "Accept"} = data) do
    with follow_activity <- Activity.normalize(data["object"]) do
      object = %{
        "actor" => follow_activity.actor,
        "object" => follow_activity.data["object"],
        "id" => follow_activity.data["id"],
        "type" => "Follow"
      }

      data =
        data
        |> Map.put("object", object)
        |> Map.merge(Utils.make_json_ld_header(data))

      {:ok, data}
    end
  end

  def prepare_outgoing(%{"type" => "Reject"} = data) do
    with follow_activity <- Activity.normalize(data["object"]) do
      object = %{
        "actor" => follow_activity.actor,
        "object" => follow_activity.data["object"],
        "id" => follow_activity.data["id"],
        "type" => "Follow"
      }

      data =
        data
        |> Map.put("object", object)
        |> Map.merge(Utils.make_json_ld_header(data))

      {:ok, data}
    end
  end

  def prepare_outgoing(%{"type" => "Flag"} = data) do
    with {:ok, stripped_activity} <- Utils.strip_report_status_data(data),
         stripped_activity <- Utils.maybe_anonymize_reporter(stripped_activity),
         stripped_activity <- Map.merge(stripped_activity, Utils.make_json_ld_header()) do
      {:ok, stripped_activity}
    end
  end

  def prepare_outgoing(%{"type" => _type} = data) do
    data =
      data
      |> maybe_expand_group_announce_object()
      |> maybe_expand_undo_object()
      |> strip_internal_fields
      |> normalize_threadiverse_audience()
      |> maybe_fix_object_url
      |> Map.merge(Utils.make_json_ld_header(data))

    {:ok, data}
  end

  defp normalize_threadiverse_audience(%{"object" => %{} = object} = data) do
    data
    |> normalize_threadiverse_audience_for_activity()
    |> Map.put("object", normalize_threadiverse_audience(object))
  end

  defp normalize_threadiverse_audience(data),
    do: normalize_threadiverse_audience_for_activity(data)

  defp normalize_threadiverse_audience_for_activity(%{"audience" => []} = data) do
    Map.delete(data, "audience")
  end

  defp normalize_threadiverse_audience_for_activity(%{"audience" => [audience]} = data)
       when is_binary(audience) do
    Map.put(data, "audience", audience)
  end

  defp normalize_threadiverse_audience_for_activity(data), do: data

  defp owncast_stream_lifecycle?(%{"type" => "Offer"} = data) do
    data
    |> Map.keys()
    |> Enum.any?(&(is_binary(&1) and String.starts_with?(&1, "https://owncast.online/ns#")))
  end

  defp owncast_stream_lifecycle?(%{"type" => "Leave", "actor" => actor, "object" => object})
       when is_binary(actor) and is_binary(object) do
    actor_uri = URI.parse(actor)
    object_uri = URI.parse(object)

    is_binary(actor_uri.host) and actor_uri.host == object_uri.host and
      object_uri.path in [nil, "", "/"]
  end

  defp owncast_stream_lifecycle?(_), do: false

  defp prefetch_announced_object(object, options) do
    case get_obj_helper(object, options) do
      {:ok, _object} ->
        :ok

      _ ->
        with {:error, reason} <- Pleroma.Object.Fetcher.fetch_object_from_id(object, options),
             true <- reason == "Object containment failed." do
          Logger.debug("Object containment failed")
        end
    end
  end

  defp maybe_expand_undo_object(%{"type" => "Undo", "object" => object_id} = data)
       when is_binary(object_id) do
    case Activity.get_by_ap_id(object_id) do
      %Activity{data: object} -> Map.put(data, "object", object)
      _ -> data
    end
  end

  defp maybe_expand_undo_object(data), do: data

  defp maybe_expand_group_announce_object(
         %{"type" => "Announce", "actor" => group_ap_id, "object" => object_id} = data
       )
       when is_binary(group_ap_id) and is_binary(object_id) do
    with %User{actor_type: "Group"} = group <- User.get_by_ap_id(group_ap_id),
         %Object{data: %{"type" => type} = object_data} when type in ["Article", "Note", "Page"] <-
           Object.get_by_ap_id(object_id),
         true <- group_root_object?(object_data, group_ap_id),
         author when is_binary(author) <- object_author(object_data) do
      Map.put(data, "object", group_root_create_activity(object_data, author, group))
    else
      _ -> data
    end
  end

  defp maybe_expand_group_announce_object(data), do: data

  defp group_root_object?(object_data, group_ap_id) do
    is_nil(object_data["inReplyTo"]) and
      (object_data["audience"] == group_ap_id or group_ap_id in List.wrap(object_data["to"]) or
         group_ap_id in List.wrap(object_data["cc"]))
  end

  defp object_author(%{"attributedTo" => author}) when is_binary(author), do: author
  defp object_author(%{"actor" => author}) when is_binary(author), do: author
  defp object_author(_), do: nil

  defp group_root_create_activity(object_data, author, %User{} = group) do
    %{
      "id" => group_root_create_id(object_data),
      "type" => "Create",
      "actor" => author,
      "object" => group_root_post_object(object_data, author, group),
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [group.ap_id],
      "audience" => group.ap_id
    }
  end

  defp group_root_create_id(%{"id" => object_id}) do
    case Activity.get_create_by_object_ap_id(object_id) do
      %Activity{data: %{"id" => activity_id}} when is_binary(activity_id) -> activity_id
      _ -> object_id <> "/activity"
    end
  end

  defp group_root_post_object(object_data, author, %User{} = group) do
    object_data
    |> Map.put("type", group_root_post_type(group))
    |> Map.put("attributedTo", author)
    |> Map.delete("actor")
    |> Map.delete("bto")
    |> Map.delete("bcc")
  end

  defp group_root_post_type(%User{} = group) do
    if discourse_group_actor?(group), do: "Article", else: "Page"
  end

  defp discourse_group_actor?(%User{} = group) do
    host = uri_host(group.ap_id)

    actor_paths =
      [group.ap_id, group.inbox, group.shared_inbox]
      |> Enum.map(&uri_path/1)
      |> Enum.reject(&is_nil/1)

    profile_paths =
      [group.uri]
      |> Enum.map(&uri_path/1)
      |> Enum.reject(&is_nil/1)

    String.contains?(host || "", "discourse") or
      (Enum.any?(profile_paths, &String.starts_with?(&1, "/c/")) and
         Enum.any?(actor_paths, &String.contains?(&1, "/ap/actor/")))
  end

  defp uri_host(uri) when is_binary(uri) do
    uri
    |> URI.parse()
    |> Map.get(:host)
    |> case do
      host when is_binary(host) -> String.downcase(host)
      _ -> nil
    end
  rescue
    URI.Error -> nil
  end

  defp uri_host(_), do: nil

  defp uri_path(uri) when is_binary(uri) do
    uri
    |> URI.parse()
    |> Map.get(:path)
    |> case do
      path when is_binary(path) -> String.downcase(path)
      _ -> nil
    end
  rescue
    URI.Error -> nil
  end

  defp uri_path(_), do: nil

  def maybe_fix_object_url(%{"object" => object} = data) when is_binary(object) do
    with false <- String.starts_with?(object, "http"),
         {:fetch, {:ok, relative_object}} <- {:fetch, get_obj_helper(object)},
         %{data: %{"external_url" => external_url}} when not is_nil(external_url) <-
           relative_object do
      Map.put(data, "object", external_url)
    else
      {:fetch, e} ->
        Logger.error("Couldn't fetch #{object} #{inspect(e)}")
        data

      _ ->
        data
    end
  end

  def maybe_fix_object_url(data), do: data

  defp fix_undo_object_id(
         %{"object" => %{"type" => "Like", "actor" => actor, "object" => object}} = data
       ) do
    actor_id = embedded_actor_id(actor)
    object_id = embedded_ap_id(object)

    data =
      data
      |> maybe_put_in(["actor"], embedded_actor_id(data["actor"]))
      |> maybe_put_in(["object", "actor"], actor_id)
      |> maybe_put_in(["object", "object"], object_id)

    if is_binary(actor_id) and is_binary(object_id) do
      case Utils.get_existing_like(actor_id, %{data: %{"id" => object_id}}) do
        %Activity{data: %{"id" => like_id}} ->
          put_in(data, ["object", "id"], like_id)

        _ ->
          data
      end
    else
      data
    end
  end

  defp fix_undo_object_id(
         %{
           "object" => %{
             "type" => "EmojiReact",
             "actor" => actor,
             "object" => object_id,
             "content" => content
           }
         } = data
       ) do
    actor_id = embedded_actor_id(actor)
    object_id = embedded_ap_id(object_id)

    data =
      data
      |> maybe_put_in(["actor"], embedded_actor_id(data["actor"]))
      |> maybe_put_in(["object", "actor"], actor_id)
      |> maybe_put_in(["object", "object"], object_id)

    if is_binary(actor_id) and is_binary(object_id) do
      case Utils.get_existing_emoji_reaction(actor_id, %{data: %{"id" => object_id}}, content) do
        %Activity{data: %{"id" => reaction_id}} ->
          put_in(data, ["object", "id"], reaction_id)

        _ ->
          data
      end
    else
      data
    end
  end

  defp fix_undo_object_id(data), do: data

  defp embedded_actor_id(actor) when is_binary(actor), do: actor

  defp embedded_actor_id(%{} = actor) do
    Containment.get_actor(%{"actor" => actor})
  rescue
    _ -> nil
  end

  defp embedded_actor_id(_), do: nil

  defp embedded_ap_id(id) when is_binary(id), do: id
  defp embedded_ap_id(%{"id" => id}) when is_binary(id), do: id
  defp embedded_ap_id(_), do: nil

  defp maybe_put_in(data, _path, nil), do: data
  defp maybe_put_in(data, path, value), do: put_in(data, path, value)

  def add_hashtags(object) do
    tags =
      object
      |> Map.get("tag", [])
      |> tag_values()
      |> Enum.map(fn
        # Expand internal representation tags into AS2 tags.
        tag when is_binary(tag) ->
          %{
            "href" => Pleroma.Web.Endpoint.url() <> "/tags/#{tag}",
            "name" => "##{tag}",
            "type" => "Hashtag"
          }

        # Do not process tags which are already AS2 tag objects.
        tag when is_map(tag) ->
          tag
      end)

    Map.put(object, "tag", tags)
  end

  defp tag_values(tags) when is_list(tags) do
    Enum.filter(tags, &(is_binary(&1) or is_map(&1)))
  end

  defp tag_values(tag) when is_binary(tag) or is_map(tag), do: [tag]
  defp tag_values(_), do: []

  # Mention tags are generated during outgoing transformation so older stored
  # objects that predate mention tag persistence still federate correctly.
  def add_mention_tags(object) do
    mentioned =
      object["to"]
      |> ap_id_values()
      |> User.get_users_from_set(local_only: false)
      |> Enum.reject(&FederatedTarget.group?/1)
      |> Enum.reject(&Addressing.suppress_implicit_mention_user?(&1, object))

    mentions = Enum.map(mentioned, &build_mention_tag/1)

    tags =
      object["tag"]
      |> tag_values()
      |> Enum.reject(&group_mention_tag?/1)

    Map.put(object, "tag", tags ++ mentions)
  end

  defp group_mention_tag?(%{"type" => "Mention", "href" => href}) when is_binary(href) do
    href
    |> User.get_cached_by_ap_id()
    |> FederatedTarget.group?()
  end

  defp group_mention_tag?(_), do: false

  defp ap_id_values(values) when is_list(values), do: Enum.flat_map(values, &ap_id_values/1)
  defp ap_id_values(value) when is_binary(value), do: [value]
  defp ap_id_values(%{"id" => value}) when is_binary(value), do: [value]
  defp ap_id_values(%{"href" => value}) when is_binary(value), do: [value]
  defp ap_id_values(_), do: []

  defp build_mention_tag(%{ap_id: ap_id, nickname: nickname} = _) do
    %{"type" => "Mention", "href" => ap_id, "name" => "@#{nickname}"}
  end

  def take_emoji_tags(%User{emoji: emoji}) do
    emoji
    |> Map.to_list()
    |> Enum.map(&Pleroma.Emoji.build_emoji_tag/1)
  end

  # Emoji tags use the stable timestamp supplied by Pleroma.Emoji.build_emoji_tag/1
  # because custom emoji packs do not consistently expose per-file mtimes.
  def add_emoji_tags(%{"emoji" => emoji} = object) do
    tags = tag_values(object["tag"])

    out =
      emoji
      |> emoji_values()
      |> Enum.map(&Pleroma.Emoji.build_emoji_tag/1)

    Map.put(object, "tag", tags ++ out)
  end

  def add_emoji_tags(object), do: object

  defp emoji_values(emoji) when is_map(emoji) do
    emoji
    |> Map.to_list()
    |> emoji_values()
  end

  defp emoji_values(emoji) when is_list(emoji) do
    Enum.filter(emoji, fn
      {name, url} when is_binary(name) and is_binary(url) -> true
      _ -> false
    end)
  end

  defp emoji_values(_), do: []

  def set_conversation(object) do
    Map.put(object, "conversation", object["context"])
  end

  def set_type(%{"type" => "Answer"} = object) do
    Map.put(object, "type", "Note")
  end

  def set_type(object), do: object

  def add_attributed_to(%{"actor" => actor} = object) when is_binary(actor) do
    object
    |> Map.put("actor", actor)
    |> Map.put("attributedTo", object["attributedTo"] || actor)
  end

  def add_attributed_to(%{"attributedTo" => attributed_to} = object)
      when is_binary(attributed_to) do
    object
    |> Map.put("actor", attributed_to)
    |> Map.put("attributedTo", attributed_to)
  end

  def add_attributed_to(object), do: object

  # ChatMessage attachments already use their client-facing shape and should not
  # be flattened like status attachments.
  def prepare_attachments(%{"type" => "ChatMessage"} = object), do: object

  def prepare_attachments(object) do
    attachments =
      object
      |> Map.get("attachment", [])
      |> List.wrap()
      |> Enum.map(&prepare_attachment/1)
      |> Enum.reject(&is_nil/1)

    Map.put(object, "attachment", attachments)
  end

  defp prepare_attachment(
         %{"url" => [%{"mediaType" => media_type, "href" => href} = url | _]} = data
       )
       when is_binary(media_type) and is_binary(href) do
    %{
      "url" => href,
      "mediaType" => media_type,
      "name" => data["name"],
      "type" => "Document"
    }
    |> Maps.put_if_present("width", url["width"])
    |> Maps.put_if_present("height", url["height"])
    |> Maps.put_if_present("blurhash", data["blurhash"])
  end

  defp prepare_attachment(_), do: nil

  def strip_internal_fields(object) do
    Map.drop(object, Pleroma.Constants.object_internal_fields())
  end

  defp strip_internal_tags(%{"tag" => tags} = object) do
    tags = Enum.filter(tags, fn x -> is_map(x) end)

    Map.put(object, "tag", tags)
  end

  defp strip_internal_tags(object), do: object

  def maybe_fix_user_url(%{"url" => url} = data) when is_map(url) do
    Map.put(data, "url", url["href"])
  end

  def maybe_fix_user_url(data), do: data

  def maybe_fix_user_object(data), do: maybe_fix_user_url(data)

  defp fetch_blocked_actor(%{"object" => object}) when is_binary(object) do
    with {:ok, object} <- ObjectValidators.ObjectID.cast(object) do
      User.get_or_fetch_by_ap_id(object)
    end
  end

  defp fetch_blocked_actor(_), do: {:error, :not_found}

  defp maybe_fetch_block_target(%{"target" => target}) when is_binary(target) do
    case ObjectValidators.ObjectID.cast(target) do
      {:ok, target} -> User.get_or_fetch_by_ap_id(target)
      _ -> :ok
    end

    :ok
  end

  defp maybe_fetch_block_target(_), do: :ok

  defp maybe_add_content_map(%{"language" => language, "content" => content} = object)
       when not_empty_string(language) do
    Map.put(object, "contentMap", Map.put(%{}, language, content))
  end

  defp maybe_add_content_map(object), do: object

  def maybe_add_language(object) do
    language =
      get_language_from_context(object) |> get_valid_language() ||
        get_language_from_content_map(object) |> get_valid_language() ||
        get_language_from_content(object) |> get_valid_language()

    if language do
      Map.put(object, "language", language)
    else
      object
    end
  end

  def maybe_add_language_from_activity(object, activity) do
    language = get_language_from_context(activity) |> get_valid_language()

    if language do
      Map.put(object, "language", language)
    else
      object
    end
  end

  defp get_language_from_context(%{"@context" => context}) when is_list(context) do
    case context
         |> Enum.find(fn
           %{"@language" => language} -> language != "und"
           _ -> nil
         end) do
      %{"@language" => language} -> language
      _ -> nil
    end
  end

  defp get_language_from_context(_), do: nil

  defp get_language_from_content_map(%{"contentMap" => content_map, "content" => source_content})
       when is_map(content_map) do
    content_groups = Map.to_list(content_map)

    case Enum.find(content_groups, fn {_, content} -> content == source_content end) do
      {language, _} -> language
      _ -> nil
    end
  end

  defp get_language_from_content_map(_), do: nil

  defp get_language_from_content(%{"content" => content}) do
    LanguageDetector.detect(content)
  end

  defp get_language_from_content(_), do: nil
end
