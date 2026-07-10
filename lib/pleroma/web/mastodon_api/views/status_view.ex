# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.StatusView do
  use Pleroma.Web, :view

  require Pleroma.Constants

  import Ecto.Query, only: [where: 3]

  alias Pleroma.Activity
  alias Pleroma.HTML
  alias Pleroma.Maps
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.UserRelationship
  alias Pleroma.Web.ActivityPub.Addressing
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Web.CommonAPI.Utils
  alias Pleroma.Web.FederatedTarget
  alias Pleroma.Web.MastodonAPI.AccountView
  alias Pleroma.Web.MastodonAPI.FederatedTargetView
  alias Pleroma.Web.MastodonAPI.PollView
  alias Pleroma.Web.MastodonAPI.StatusView
  alias Pleroma.Web.MediaProxy
  alias Pleroma.Web.PleromaAPI.EmojiReactionController
  alias Pleroma.Web.RichMedia.Card

  import Pleroma.Web.ActivityPub.Visibility, only: [get_visibility: 1, visible_for_user?: 2]

  # This is a naive way to do this, just spawning a process per activity
  # to fetch the preview. However it should be fine considering
  # pagination is restricted to 40 activities at a time
  defp fetch_rich_media_for_activities(activities, opts) do
    opts = Map.put(opts, :stream, false)

    Enum.each(activities, fn activity ->
      Card.get_by_activity(activity, opts)
    end)
  end

  # Reply targets are loaded in one query for the page. Keeping this uncached
  # avoids stale relationship context when statuses are deleted or refetched.
  defp get_replied_to_activities([]), do: %{}

  defp get_replied_to_activities(activities) do
    activities
    |> Enum.map(fn
      %{data: %{"type" => "Create"}} = activity ->
        object = Object.normalize(activity, fetch: false)
        object && object.data["inReplyTo"] != "" && object.data["inReplyTo"]

      _ ->
        nil
    end)
    |> Enum.filter(& &1)
    |> Activity.create_by_object_ap_id_with_object()
    |> Repo.all()
    |> Enum.reduce(%{}, fn activity, acc ->
      object = Object.normalize(activity, fetch: false)
      if object, do: Map.put(acc, object.data["id"], activity), else: acc
    end)
  end

  defp get_quoted_activities([]), do: %{}

  defp get_quoted_activities(activities) do
    activities
    |> Enum.map(fn
      %{data: %{"type" => "Create"}} = activity ->
        object = Object.normalize(activity, fetch: false)
        object && object.data["quoteUrl"] != "" && object.data["quoteUrl"]

      _ ->
        nil
    end)
    |> Enum.filter(& &1)
    |> Activity.create_by_object_ap_id_with_object()
    |> Repo.all()
    |> Enum.reduce(%{}, fn activity, acc ->
      object = Object.normalize(activity, fetch: false)
      if object, do: Map.put(acc, object.data["id"], activity), else: acc
    end)
  end

  defp get_status_groups_by_address(activities, reading_user) do
    addresses =
      activities
      |> Enum.flat_map(&status_group_candidate_ap_ids/1)
      |> Enum.uniq()

    if addresses == [] do
      %{}
    else
      User
      |> where([user], user.ap_id in ^addresses or user.follower_address in ^addresses)
      |> Repo.all()
      |> Enum.filter(&FederatedTarget.group?/1)
      |> Enum.reduce(%{}, fn group, acc ->
        rendered_group = render_status_group(group, reading_user)

        acc
        |> maybe_put_group_address(group.ap_id, rendered_group)
        |> maybe_put_group_address(group.follower_address, rendered_group)
      end)
    end
  end

  defp maybe_put_group_address(map, address, rendered_group) when is_binary(address) do
    Map.put(map, address, rendered_group)
  end

  defp maybe_put_group_address(map, _address, _rendered_group), do: map

  defp status_group(%Activity{} = activity, %Object{} = object, opts) do
    cond do
      match?(%User{}, opts[:group]) ->
        render_status_group(opts[:group], opts[:for])

      is_map(opts[:groups_by_address]) ->
        activity
        |> status_group_candidate_ap_ids(object)
        |> Enum.find_value(&Map.get(opts[:groups_by_address], &1))

      true ->
        activity
        |> status_group_candidate_ap_ids(object)
        |> find_status_group()
        |> case do
          %User{} = group -> render_status_group(group, opts[:for])
          _ -> nil
        end
    end
  end

  defp status_group(_activity, _object, _opts), do: nil

  defp render_status_group(%User{} = group, reading_user) do
    FederatedTargetView.render("group.json", %{
      group: group,
      for: reading_user,
      include_interaction_score: false,
      refresh_counts: false
    })
  end

  defp find_status_group([]), do: nil

  defp find_status_group(addresses) do
    User
    |> where([user], user.ap_id in ^addresses or user.follower_address in ^addresses)
    |> Repo.all()
    |> Enum.find(&FederatedTarget.group?/1)
  end

  defp status_group_candidate_ap_ids(%Activity{} = activity) do
    object = Object.normalize(activity, fetch: false)
    status_group_candidate_ap_ids(activity, object)
  end

  defp status_group_candidate_ap_ids(%Activity{} = activity, %Object{} = object) do
    [activity.data, object.data]
    |> Enum.flat_map(&status_group_candidate_ap_ids_from_data/1)
    |> Enum.uniq()
  end

  defp status_group_candidate_ap_ids(_activity, _object), do: []

  defp status_group_candidate_ap_ids_from_data(data) when is_map(data) do
    addressing_values =
      ["to", "cc", "bto", "bcc", "audience", "target", "context"]
      |> Enum.flat_map(&data_address_values(Map.get(data, &1)))

    tag_values =
      data
      |> Map.get("tag", [])
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"type" => "Mention", "href" => href} -> data_address_values(href)
        _ -> []
      end)

    addressing_values ++ tag_values
  end

  defp status_group_candidate_ap_ids_from_data(_data), do: []

  defp data_address_values(values) when is_list(values) do
    Enum.flat_map(values, &data_address_values/1)
  end

  defp data_address_values(value) when is_binary(value), do: [value]
  defp data_address_values(_value), do: []

  # DEPRECATED This field seems to be a left-over from the StatusNet era.
  # If your application uses `pleroma.conversation_id`: this field is deprecated.
  # It is currently stubbed instead by doing a CRC32 of the context, and
  # clearing the MSB to avoid overflow exceptions with signed integers on the
  # different clients using this field (Java/Kotlin code, mostly; see Husky.)
  # This should be removed in a future version of Pleroma. Pleroma-FE currently
  # depends on this field, as well.
  defp get_context_id(%{data: %{"context" => context}}) when is_binary(context) do
    import Bitwise

    :erlang.crc32(context)
    |> band(bnot(0x8000_0000))
  end

  defp get_context_id(_), do: nil

  # Check if the user reblogged this status
  defp reblogged?(activity, %User{ap_id: ap_id}) do
    with %Object{data: %{"announcements" => announcements}} when is_list(announcements) <-
           Object.normalize(activity, fetch: false) do
      ap_id in announcements
    else
      _ -> false
    end
  end

  # False if the user is logged out
  defp reblogged?(_activity, _user), do: false

  def render("index.json", opts) do
    reading_user = opts[:for]

    # To do: check AdminAPIControllerTest on the reasons behind nil activities in the list
    activities = Enum.filter(opts.activities, & &1)

    # Start prefetching rich media before doing anything else
    fetch_rich_media_for_activities(activities, opts)
    replied_to_activities = get_replied_to_activities(activities)
    quoted_activities = get_quoted_activities(activities)

    parent_activities =
      activities
      |> Enum.filter(&(&1.data["type"] == "Announce" && &1.data["object"]))
      |> Enum.map(&Object.normalize(&1, fetch: false).data["id"])
      |> Activity.create_by_object_ap_id()
      |> Activity.with_preloaded_object(:left)
      |> Activity.with_preloaded_bookmark(reading_user)
      |> Activity.with_set_thread_muted_field(reading_user)
      |> Repo.all()

    relationships_opt =
      cond do
        Map.has_key?(opts, :relationships) ->
          opts[:relationships]

        is_nil(reading_user) ->
          UserRelationship.view_relationships_option(nil, [])

        true ->
          # Note: unresolved users are filtered out
          actors =
            (activities ++ parent_activities)
            |> Enum.map(&CommonAPI.get_user(&1.data["actor"], false))
            |> Enum.filter(& &1)

          UserRelationship.view_relationships_option(reading_user, actors, subset: :source_mutes)
      end

    opts =
      opts
      |> Map.put(:replied_to_activities, replied_to_activities)
      |> Map.put(:quoted_activities, quoted_activities)
      |> Map.put(:parent_activities, parent_activities)
      |> Map.put(
        :groups_by_address,
        get_status_groups_by_address(activities ++ parent_activities, reading_user)
      )
      |> Map.put(:relationships, relationships_opt)

    safe_render_many(activities, StatusView, "show.json", opts)
  end

  def render(
        "show.json",
        %{activity: %{data: %{"type" => "Announce", "object" => _object}} = activity} = opts
      ) do
    user = CommonAPI.get_user(activity.data["actor"])
    created_at = Utils.to_masto_date(activity.data["published"])
    object = Object.normalize(activity, fetch: false)

    reblogged_parent_activity =
      if opts[:parent_activities] do
        Activity.Queries.find_by_object_ap_id(
          opts[:parent_activities],
          object.data["id"]
        )
      else
        Activity.create_by_object_ap_id(object.data["id"])
        |> Activity.with_preloaded_bookmark(opts[:for])
        |> Activity.with_set_thread_muted_field(opts[:for])
        |> Ecto.Query.first()
        |> Repo.one()
      end

    reblog_rendering_opts = Map.put(opts, :activity, reblogged_parent_activity)
    reblogged = render("show.json", reblog_rendering_opts)

    favorited = opts[:for] && opts[:for].ap_id in (object.data["likes"] || [])

    bookmark = Activity.get_bookmark(reblogged_parent_activity, opts[:for])
    bookmarked = bookmark != nil
    bookmark_folder = if bookmark, do: Map.get(bookmark, :folder_id), else: nil

    mentions =
      activity.recipients
      |> Enum.map(fn ap_id -> User.get_cached_by_ap_id(ap_id) end)
      |> Enum.filter(& &1)
      |> Enum.map(fn user -> AccountView.render("mention.json", %{user: user}) end)

    {pinned?, pinned_at} = pin_data(object, user)

    %{
      id: to_string(activity.id),
      uri: object.data["id"],
      url: object.data["id"],
      account:
        AccountView.render("show.json", %{
          user: user,
          for: opts[:for]
        }),
      in_reply_to_id: nil,
      in_reply_to_account_id: nil,
      reblog: reblogged,
      content: reblogged[:content] || "",
      created_at: created_at,
      reblogs_count: 0,
      replies_count: 0,
      favourites_count: 0,
      reblogged: reblogged?(reblogged_parent_activity, opts[:for]),
      favourited: present?(favorited),
      bookmarked: present?(bookmarked),
      muted: false,
      pinned: pinned?,
      sensitive: false,
      spoiler_text: "",
      visibility: get_visibility(activity),
      media_attachments: reblogged[:media_attachments] || [],
      mentions: mentions,
      tags: reblogged[:tags] || [],
      application: build_application(object.data["generator"]),
      language: get_language(object),
      emojis: [],
      group: reblogged[:group] || status_group(activity, object, opts),
      pleroma: %{
        local: activity.local,
        comments_enabled: object.data["commentsEnabled"] != false,
        pinned_at: pinned_at,
        bookmark_folder: bookmark_folder
      }
    }
  end

  def render("show.json", %{activity: %{data: %{"object" => _object}} = activity} = opts) do
    object = Object.normalize(activity, fetch: false)

    render_status_with_object(activity, object, opts)
  end

  def render("show.json", _) do
    nil
  end

  def render("history.json", opts), do: render_history(opts)

  def render("history_item.json", opts), do: render_history_item(opts)

  def render("source.json", opts), do: render_source(opts)

  def render("card.json", %Card{} = card), do: render_card(card)

  def render("card.json", %{embed: %Card{} = card}), do: render_card(card)

  def render("card.json", _), do: nil

  def render("attachment.json", opts), do: render_attachment(opts)

  def render("attachment_meta.json", opts), do: render_attachment_meta(opts)

  def render("context.json", opts), do: render_context(opts)

  def render("translation.json", opts), do: render_translation(opts)

  defp render_status_with_object(activity, %Object{} = object, opts) do
    actor = object.data["actor"] || activity.actor
    user = CommonAPI.get_user(actor)
    user_follower_address = user.follower_address

    like_count = object.data["like_count"] || 0
    announcement_count = object.data["announcement_count"] || 0

    hashtags = Object.hashtags(object)
    sensitive = object.data["sensitive"] || Enum.member?(hashtags, "nsfw")

    tags = Object.tags(object)

    tag_mentions =
      tags
      |> Enum.filter(fn tag -> is_map(tag) and tag["type"] == "Mention" end)
      |> Enum.map(fn tag -> tag["href"] end)

    mentions =
      object.data["to"]
      |> Addressing.filter_implicit_mention_ap_ids(object.data)
      |> Kernel.++(tag_mentions)
      |> Enum.uniq()
      |> Enum.map(fn
        Pleroma.Constants.as_public() -> nil
        ^user_follower_address -> nil
        ap_id -> User.get_cached_by_ap_id(ap_id)
      end)
      |> Enum.filter(& &1)
      |> Enum.reject(&FederatedTarget.group?/1)
      |> Enum.map(fn user -> AccountView.render("mention.json", %{user: user}) end)

    favorited = opts[:for] && opts[:for].ap_id in (object.data["likes"] || [])

    bookmark = Activity.get_bookmark(activity, opts[:for])
    bookmarked = bookmark != nil
    bookmark_folder = if bookmark, do: Map.get(bookmark, :folder_id), else: nil

    client_posted_this_activity = opts[:for] && user.id == opts[:for].id

    expires_at =
      with true <- client_posted_this_activity,
           %Oban.Job{scheduled_at: scheduled_at} <-
             Pleroma.Workers.PurgeExpiredActivity.get_expiration(activity.id) do
        scheduled_at
      else
        _ -> nil
      end

    thread_muted? =
      cond do
        is_nil(opts[:for]) -> false
        is_boolean(activity.thread_muted?) -> activity.thread_muted?
        true -> CommonAPI.thread_muted?(opts[:for], activity)
      end

    attachment_data = object.data["attachment"] || []
    attachments = render_many(attachment_data, StatusView, "attachment.json", as: :attachment)

    created_at = Utils.to_masto_date(object.data["published"])

    edited_at =
      with %{"updated" => updated} <- object.data,
           date <- Utils.to_masto_date(updated),
           true <- date != "" do
        date
      else
        _ ->
          nil
      end

    reply_to = get_reply_to(activity, opts)
    reply_to_user = reply_to && CommonAPI.get_user(reply_to.data["actor"])

    quote_activity = get_quote(activity, opts)

    quote_id =
      case quote_activity do
        %Activity{id: id} -> id
        _ -> nil
      end

    quote_post =
      if visible_for_user?(quote_activity, opts[:for]) and opts[:show_quote] != false do
        quote_rendering_opts = Map.merge(opts, %{activity: quote_activity, show_quote: false})
        render("show.json", quote_rendering_opts)
      else
        nil
      end

    history_len =
      1 +
        (Object.Updater.history_for(object.data)
         |> Map.get("orderedItems")
         |> length())

    # See render("history.json", ...) for more details
    # Here the implicit index of the current content is 0
    chrono_order = history_len - 1

    content =
      object
      |> render_content()

    content_html =
      content
      |> Activity.HTML.get_cached_scrubbed_html_for_activity(
        User.html_filter_policy(opts[:for]),
        activity,
        "mastoapi:content:#{chrono_order}"
      )

    content_plaintext =
      content
      |> Activity.HTML.get_cached_stripped_html_for_activity(
        activity,
        "mastoapi:content:#{chrono_order}"
      )

    summary = object.data["summary"] || ""

    card =
      case Card.get_by_activity(activity, Map.put(opts, :stream, false)) do
        %Card{} = result -> render("card.json", result)
        _ -> nil
      end

    url =
      if user.local do
        Pleroma.Web.Router.Helpers.o_status_url(Pleroma.Web.Endpoint, :notice, activity)
      else
        object.data["url"] || object.data["external_url"] || object.data["id"]
      end

    direct_conversation_id =
      with {_, nil} <- {:direct_conversation_id, opts[:direct_conversation_id]},
           {_, true} <- {:include_id, opts[:with_direct_conversation_id]},
           {_, %User{} = for_user} <- {:for_user, opts[:for]} do
        Activity.direct_conversation_id(activity, for_user)
      else
        {:direct_conversation_id, participation_id} when is_integer(participation_id) ->
          participation_id

        _e ->
          nil
      end

    emoji_reactions =
      object
      |> Object.get_emoji_reactions()
      |> EmojiReactionController.filter_allowed_users(
        opts[:for],
        Map.get(opts, :with_muted, false)
      )
      |> Stream.map(fn {emoji, users, url} ->
        build_emoji_map(emoji, users, url, opts[:for])
      end)
      |> Stream.reject(&(&1.count == 0))
      |> Enum.to_list()

    # Status muted state (would do 1 request per status unless user mutes are preloaded)
    muted =
      thread_muted? ||
        UserRelationship.exists?(
          get_in(opts, [:relationships, :user_relationships]),
          :mute,
          opts[:for],
          user,
          fn for_user, user -> User.mutes?(for_user, user) end
        )

    {pinned?, pinned_at} = pin_data(object, user)

    %{
      id: to_string(activity.id),
      uri: object.data["id"],
      url: url,
      account:
        AccountView.render("show.json", %{
          user: user,
          for: opts[:for]
        }),
      in_reply_to_id: reply_to && to_string(reply_to.id),
      in_reply_to_account_id: reply_to_user && to_string(reply_to_user.id),
      reblog: nil,
      card: card,
      content: content_html,
      text: opts[:with_source] && get_source_text(object.data["source"]),
      created_at: created_at,
      edited_at: edited_at,
      reblogs_count: announcement_count,
      replies_count: replies_count(object),
      favourites_count: like_count,
      reblogged: reblogged?(activity, opts[:for]),
      favourited: present?(favorited),
      bookmarked: present?(bookmarked),
      muted: muted,
      pinned: pinned?,
      sensitive: sensitive,
      spoiler_text: summary,
      visibility: get_visibility(object),
      media_attachments: attachments,
      poll: render(PollView, "show.json", object: object, for: opts[:for]),
      mentions: mentions,
      tags: build_tags(tags),
      application: build_application(object.data["generator"]),
      language: get_language(object),
      emojis: build_emojis(object.data["emoji"]),
      quotes_count: object.data["quotesCount"] || 0,
      group: status_group(activity, object, opts),
      pleroma: %{
        local: activity.local,
        conversation_id: get_context_id(activity),
        context: object.data["context"],
        in_reply_to_account_acct: reply_to_user && reply_to_user.nickname,
        quote: quote_post,
        quote_id: quote_id,
        quote_url: object.data["quoteUrl"],
        quote_visible: visible_for_user?(quote_activity, opts[:for]),
        comments_enabled: object.data["commentsEnabled"] != false,
        content: %{"text/plain" => content_plaintext},
        spoiler_text: %{"text/plain" => summary},
        expires_at: expires_at,
        direct_conversation_id: direct_conversation_id,
        thread_muted: thread_muted?,
        emoji_reactions: emoji_reactions,
        parent_visible: visible_for_user?(reply_to, opts[:for]),
        pinned_at: pinned_at,
        bookmark_folder: bookmark_folder,
        content_type: opts[:with_source] && (object.data["content_type"] || "text/plain"),
        quotes_count: object.data["quotesCount"] || 0,
        event: build_event(object.data, opts[:for], attachments)
      }
    }
  end

  defp render_status_with_object(_activity, _object, _opts), do: nil

  defp render_history(%{activity: %{data: %{"object" => _object}} = activity} = opts) do
    object = Object.normalize(activity, fetch: false)

    hashtags = Object.hashtags(object)

    user = CommonAPI.get_user(activity.data["actor"])

    past_history =
      Object.Updater.history_for(object.data)
      |> Map.get("orderedItems")
      |> Enum.map(&Map.put(&1, "id", object.data["id"]))
      |> Enum.map(&%Object{data: &1, id: object.id})

    history =
      [object | past_history]
      # Mastodon expects the original to be at the first
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.map(fn {object, chrono_order} ->
        %{
          # The history is prepended every time there is a new edit.
          # In chrono_order, the oldest item is always at 0, and so on.
          # The chrono_order is an invariant kept between edits.
          chrono_order: chrono_order,
          object: object
        }
      end)

    individual_opts =
      opts
      |> Map.put(:as, :item)
      |> Map.put(:user, user)
      |> Map.put(:hashtags, hashtags)

    render_many(history, StatusView, "history_item.json", individual_opts)
  end

  defp render_history_item(
         %{
           activity: activity,
           user: user,
           item: %{object: object, chrono_order: chrono_order},
           hashtags: hashtags
         } = opts
       ) do
    sensitive = object.data["sensitive"] || Enum.member?(hashtags, "nsfw")

    attachment_data = object.data["attachment"] || []
    attachments = render_many(attachment_data, StatusView, "attachment.json", as: :attachment)

    created_at = Utils.to_masto_date(object.data["updated"] || object.data["published"])

    content =
      object
      |> render_content()

    content_html =
      content
      |> Activity.HTML.get_cached_scrubbed_html_for_activity(
        User.html_filter_policy(opts[:for]),
        activity,
        "mastoapi:content:#{chrono_order}"
      )

    summary = object.data["summary"] || ""

    %{
      account:
        AccountView.render("show.json", %{
          user: user,
          for: opts[:for]
        }),
      content: content_html,
      sensitive: sensitive,
      spoiler_text: summary,
      created_at: created_at,
      media_attachments: attachments,
      emojis: build_emojis(object.data["emoji"]),
      poll: render(PollView, "show.json", object: object, for: opts[:for])
    }
  end

  defp render_source(%{activity: %{data: %{"object" => _object}} = activity} = _opts) do
    object = Object.normalize(activity, fetch: false)

    %{
      id: activity.id,
      text: get_source_text(Map.get(object.data, "source", "")),
      spoiler_text: Map.get(object.data, "summary", ""),
      content_type: get_source_content_type(object.data["source"]),
      location: build_source_location(object.data)
    }
  end

  defp render_card(%Card{fields: rich_media}) do
    page_url_data = URI.parse(rich_media["url"])

    page_url = page_url_data |> to_string

    image_url = proxied_url(rich_media["image"], page_url_data)
    audio_url = proxied_url(rich_media["audio"], page_url_data)
    video_url = proxied_url(rich_media["video"], page_url_data)

    %{
      type: "link",
      provider_name: page_url_data.host,
      provider_url: page_url_data.scheme <> "://" <> page_url_data.host,
      url: page_url,
      image: image_url,
      image_description: rich_media["image:alt"] || "",
      title: rich_media["title"] || "",
      description: rich_media["description"] || "",
      pleroma: %{
        opengraph:
          rich_media
          |> Maps.put_if_present("image", image_url)
          |> Maps.put_if_present("audio", audio_url)
          |> Maps.put_if_present("video", video_url)
      }
    }
  end

  defp render_attachment(%{attachment: attachment}) do
    [attachment_url | _] = attachment["url"]
    href_remote = attachment_url["href"]

    media_type =
      (attachment_url["mediaType"] || attachment_url["mimeType"])
      |> attachment_media_type(href_remote)

    href = href_remote |> MediaProxy.url()
    href_preview = attachment_url["href"] |> MediaProxy.preview_url()
    meta = render("attachment_meta.json", %{attachment: attachment})

    type =
      cond do
        String.contains?(media_type, "image") -> "image"
        String.contains?(media_type, "video") -> "video"
        String.contains?(media_type, "audio") -> "audio"
        true -> "unknown"
      end

    attachment_id =
      with {_, ap_id} when is_binary(ap_id) <- {:ap_id, attachment["id"]},
           {_, %Object{data: _object_data, id: object_id}} <-
             {:object, Object.get_by_ap_id(ap_id)} do
        to_string(object_id)
      else
        _ ->
          <<hash_id::signed-32, _rest::binary>> = :crypto.hash(:md5, href)
          to_string(attachment["id"] || hash_id)
      end

    description =
      if attachment["summary"] do
        HTML.strip_tags(attachment["summary"])
      else
        attachment["name"]
      end

    name = if attachment["summary"], do: attachment["name"]

    pleroma =
      %{mime_type: media_type}
      |> Maps.put_if_present(:name, name)

    %{
      id: attachment_id,
      url: href,
      remote_url: href_remote,
      preview_url: href_preview,
      text_url: href,
      type: type,
      description: description,
      pleroma: pleroma,
      blurhash: attachment["blurhash"]
    }
    |> Maps.put_if_present(:meta, meta)
  end

  defp render_attachment_meta(%{
         attachment: %{"url" => [%{"width" => width, "height" => height} | _]}
       })
       when is_integer(width) and is_integer(height) and height > 0 do
    %{
      original: %{
        width: width,
        height: height,
        aspect: width / height
      }
    }
  end

  defp render_attachment_meta(%{
         attachment: %{"url" => [%{"width" => width, "height" => height} | _]}
       })
       when is_integer(width) and is_integer(height) do
    %{
      original: %{
        width: width,
        height: height
      }
    }
  end

  defp render_attachment_meta(_), do: nil

  defp render_context(%{activity: activity, activities: activities, user: user}) do
    %{ancestors: ancestors, descendants: descendants} =
      activities
      |> Enum.reverse()
      |> Enum.group_by(fn %{id: id} ->
        if id < activity.id, do: :ancestors, else: :descendants
      end)
      |> Map.put_new(:ancestors, [])
      |> Map.put_new(:descendants, [])

    %{
      ancestors: render("index.json", for: user, activities: ancestors, as: :activity),
      descendants: render("index.json", for: user, activities: descendants, as: :activity)
    }
  end

  defp render_translation(%{
         content: content,
         detected_source_language: detected_source_language,
         provider: provider
       }) do
    %{content: content, detected_source_language: detected_source_language, provider: provider}
  end

  defp attachment_media_type("application/octet-stream", href),
    do: infer_media_type_from_href(href)

  defp attachment_media_type(nil, href), do: infer_media_type_from_href(href)
  defp attachment_media_type("", href), do: infer_media_type_from_href(href)
  defp attachment_media_type(media_type, _href), do: media_type

  defp infer_media_type_from_href(href) when is_binary(href) do
    case URI.parse(href) do
      %URI{path: path} when is_binary(path) ->
        case String.downcase(Path.extname(path)) do
          ".jpg" ->
            "image/jpeg"

          ".jpeg" ->
            "image/jpeg"

          ".svg" ->
            "image/svg+xml"

          extension when extension in [".avif", ".gif", ".png", ".webp"] ->
            "image/" <> String.trim_leading(extension, ".")

          extension
          when extension in [".m4v", ".mov", ".mp4", ".mpeg", ".mpg", ".ogv", ".webm"] ->
            "video/" <> String.trim_leading(extension, ".")

          extension
          when extension in [".aac", ".flac", ".m4a", ".mp3", ".oga", ".ogg", ".opus", ".wav"] ->
            "audio/" <> String.trim_leading(extension, ".")

          _ ->
            "application/octet-stream"
        end

      _ ->
        "application/octet-stream"
    end
  end

  defp infer_media_type_from_href(_href), do: "application/octet-stream"

  def get_reply_to(activity, %{replied_to_activities: replied_to_activities}) do
    object = Object.normalize(activity, fetch: false)

    with nil <- replied_to_activities[object.data["inReplyTo"]] do
      # If user didn't participate in the thread
      Activity.get_in_reply_to_activity(activity)
    end
  end

  def get_reply_to(%{data: %{"object" => _object}} = activity, _) do
    object = Object.normalize(activity, fetch: false)

    if object.data["inReplyTo"] && object.data["inReplyTo"] != "" do
      Activity.get_create_by_object_ap_id(object.data["inReplyTo"])
    else
      nil
    end
  end

  def get_quote(activity, %{quoted_activities: quoted_activities}) do
    object = Object.normalize(activity, fetch: false)

    with nil <- quoted_activities[object.data["quoteUrl"]] do
      # For when a quote post is inside an Announce
      Activity.get_create_by_object_ap_id_with_object(object.data["quoteUrl"])
    end
  end

  def get_quote(%{data: %{"object" => _object}} = activity, _) do
    object = Object.normalize(activity, fetch: false)

    if object.data["quoteUrl"] && object.data["quoteUrl"] != "" do
      Activity.get_create_by_object_ap_id(object.data["quoteUrl"])
    else
      nil
    end
  end

  def render_content(%{data: %{"name" => name, "type" => type}} = object)
      when not is_nil(name) and name != "" and type != "Event" do
    url = content_url(object)
    content = object.data["content"] || ""

    "<p><a href=\"#{url}\">#{name}</a></p>#{content}"
  end

  def render_content(object), do: object.data["content"] || ""

  defp content_url(%{data: data}) do
    data
    |> Map.get("url")
    |> content_url(data["id"])
  end

  defp content_url(url, _fallback) when is_binary(url) and url != "", do: url

  defp content_url(%{"href" => href}, fallback), do: content_url(href, fallback)

  defp content_url([first | _], fallback), do: content_url(first, fallback)

  defp content_url(_, fallback) when is_binary(fallback) and fallback != "", do: fallback

  defp content_url(_, _fallback), do: "#"

  @doc """
  Builds a dictionary tags.

  ## Examples

  iex> Pleroma.Web.MastodonAPI.StatusView.build_tags(["fediverse", "nextcloud"])
  [{"name": "fediverse", "url": "/tag/fediverse"},
   {"name": "nextcloud", "url": "/tag/nextcloud"}]

  """
  @spec build_tags(list(any())) :: list(map())
  def build_tags(object_tags) when is_list(object_tags) do
    object_tags
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&%{name: &1, url: "#{Pleroma.Web.Endpoint.url()}/tag/#{URI.encode(&1)}"})
  end

  def build_tags(_), do: []

  @doc """
  Builds list emojis.

  Arguments: `nil` or list tuple of name and url.

  Returns list emojis.

  ## Examples

  iex> Pleroma.Web.MastodonAPI.StatusView.build_emojis([{"2hu", "corndog.png"}])
  [%{shortcode: "2hu", static_url: "corndog.png", url: "corndog.png", visible_in_picker: false}]

  """
  @spec build_emojis(nil | list(tuple())) :: list(map())
  def build_emojis(nil), do: []

  def build_emojis(emojis) do
    emojis
    |> Enum.map(fn {name, url} ->
      name = HTML.strip_tags(name)

      url =
        url
        |> HTML.strip_tags()
        |> MediaProxy.url()

      %{shortcode: name, url: url, static_url: url, visible_in_picker: false}
    end)
  end

  defp build_event(%{"type" => "Event"} = data, for_user, attachments) do
    banner = event_banner(attachments)

    %{
      name: data["name"],
      start_time: data["startTime"],
      end_time: data["endTime"],
      join_mode: data["joinMode"],
      participants_count: data["participation_count"],
      location: build_event_location(data["location"]),
      join_state: build_event_join_state(for_user, data["id"]),
      participation_request_count: maybe_put_participation_request_count(data, for_user)
    }
    |> Maps.put_if_present(:banner, banner)
    |> Maps.put_if_present(:links, event_links(attachments, banner))
  end

  defp build_event(_, _, _), do: nil

  defp event_banner(attachments) when is_list(attachments) do
    Enum.find(attachments, fn attachment ->
      attachment[:type] == "image" and event_banner_attachment?(attachment)
    end) || Enum.find(attachments, &(&1[:type] == "image"))
  end

  defp event_banner(_), do: nil

  defp event_banner_attachment?(attachment) do
    name =
      attachment
      |> get_in([:pleroma, :name])
      |> to_string()
      |> String.downcase()

    description =
      attachment
      |> Map.get(:description)
      |> to_string()
      |> String.downcase()

    String.contains?(name, "banner") or String.contains?(description, "banner")
  end

  defp event_links(attachments, nil) when is_list(attachments), do: attachments

  defp event_links(attachments, banner) when is_list(attachments) do
    links = Enum.reject(attachments, &(&1[:id] == banner[:id]))
    if links == [], do: nil, else: links
  end

  defp event_links(_, _), do: nil

  defp build_event_location(%{"type" => "Place"} = location) do
    %{
      name: location["name"],
      url: location["url"],
      longitude: location["longitude"],
      latitude: location["latitude"]
    }
    |> maybe_put_address(location["address"])
  end

  defp build_event_location(_), do: nil

  defp maybe_put_address(location, %{"type" => "PostalAddress"} = address) do
    Map.merge(location, %{
      street: address["streetAddress"],
      postal_code: address["postalCode"],
      locality: address["addressLocality"],
      region: address["addressRegion"],
      country: address["addressCountry"]
    })
  end

  defp maybe_put_address(location, _), do: location

  defp build_event_join_state(%{ap_id: actor}, id) do
    latest_join = Pleroma.Web.ActivityPub.Utils.get_existing_join(actor, id)

    if latest_join do
      latest_join.data["state"]
    end
  end

  defp build_event_join_state(_, _), do: nil

  defp maybe_put_participation_request_count(%{"actor" => actor} = data, %{ap_id: actor}) do
    data["participation_request_count"]
  end

  defp maybe_put_participation_request_count(_, _), do: nil

  defp present?(nil), do: false
  defp present?(false), do: false
  defp present?(_), do: true

  defp pin_data(%Object{data: %{"id" => object_id}}, %User{pinned_objects: pinned_objects}) do
    if pinned_at = pinned_objects[object_id] do
      {true, Utils.to_masto_date(pinned_at)}
    else
      {false, nil}
    end
  end

  defp build_emoji_map(emoji, users, url, current_user) do
    users = active_emoji_reaction_users(users)
    user_ap_ids = Enum.map(users, & &1.ap_id)

    %{
      name: Pleroma.Web.PleromaAPI.EmojiReactionView.emoji_name(emoji, url),
      count: length(users),
      url: MediaProxy.url(url),
      me: !!(current_user && current_user.ap_id in user_ap_ids),
      account_ids: Enum.map(users, & &1.id)
    }
  end

  defp active_emoji_reaction_users(user_ap_ids) do
    user_ap_ids
    |> Enum.map(&User.get_cached_by_ap_id/1)
    |> Enum.filter(fn
      %User{is_active: true} -> true
      _ -> false
    end)
  end

  @spec build_application(map() | nil) :: map() | nil
  defp build_application(%{"type" => _type, "name" => name, "url" => url}),
    do: %{name: name, website: url}

  defp build_application(_), do: nil

  # Workaround for Elixir issue #10771
  # Avoid applying URI.merge unless necessary
  # Keep the explicit absolute-URI branch for compatibility with older runtime
  # targets and harmless behavior on newer Elixir versions.
  @spec build_image_url(struct() | nil, struct()) :: String.t() | nil
  defp build_image_url(
         %URI{scheme: image_scheme, host: image_host} = image_url_data,
         %URI{} = _page_url_data
       )
       when not is_nil(image_scheme) and not is_nil(image_host) do
    image_url_data |> to_string
  end

  defp build_image_url(%URI{} = image_url_data, %URI{} = page_url_data) do
    URI.merge(page_url_data, image_url_data) |> to_string
  end

  defp build_image_url(_, _), do: nil

  defp proxied_url(url, page_url_data) do
    if is_binary(url) do
      build_image_url(URI.parse(url), page_url_data) |> MediaProxy.url()
    else
      nil
    end
  end

  defp replies_count(%Object{data: data}) do
    [
      integer_count(data["repliesCount"]),
      integer_count(data["replies_count"]),
      integer_count(data["commentsCount"]),
      integer_count(data["comments_count"]),
      reply_collection_count(data["replies"]),
      reply_collection_count(data["comments"])
    ]
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> 0 end)
  end

  defp integer_count(value) when is_integer(value), do: value

  defp integer_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _} -> integer
      _ -> nil
    end
  end

  defp integer_count(_), do: nil

  defp reply_collection_count(%{"totalItems" => count}), do: integer_count(count)
  defp reply_collection_count(%{"total_items" => count}), do: integer_count(count)
  defp reply_collection_count(%{"total" => count}), do: integer_count(count)
  defp reply_collection_count(%{"count" => count}), do: integer_count(count)

  defp reply_collection_count(%{"items" => replies}) when is_list(replies),
    do: reply_collection_count(replies)

  defp reply_collection_count(%{"orderedItems" => replies}) when is_list(replies),
    do: reply_collection_count(replies)

  defp reply_collection_count(replies) when is_list(replies) do
    replies
    |> Enum.filter(&is_binary/1)
    |> length()
  end

  defp reply_collection_count(_), do: nil

  defp get_source_text(%{"content" => content} = _source) do
    content
  end

  defp get_source_text(source) when is_binary(source) do
    source
  end

  defp get_source_text(_) do
    ""
  end

  defp get_language(%{data: %{"language" => "und"}}), do: nil

  defp get_language(object), do: object.data["language"]

  defp get_source_content_type(%{"mediaType" => type} = _source) do
    type
  end

  defp get_source_content_type(_source) do
    Utils.get_content_type(nil)
  end

  def build_source_location(%{"location_id" => location_id}) when is_binary(location_id) do
    location = Geospatial.Service.service().get_by_id(location_id) |> List.first()

    if location do
      Pleroma.Web.PleromaAPI.SearchView.render("show_location.json", %{location: location})
    else
      nil
    end
  end

  def build_source_location(_), do: nil
end
