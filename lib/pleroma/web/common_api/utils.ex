# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.CommonAPI.Utils do
  import Pleroma.Web.Gettext

  alias Calendar.Strftime
  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.Conversation.Participation
  alias Pleroma.Formatter
  alias Pleroma.GroupMembership
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Utils
  alias Pleroma.Web.ActivityPub.Visibility
  alias Pleroma.Web.CommonAPI.ActivityDraft
  alias Pleroma.Web.MediaProxy
  alias Pleroma.Web.Plugs.AuthenticationPlug
  alias Pleroma.Web.Utils.Params

  require Logger
  require Pleroma.Constants

  @supported_locales ~w(
    aa ab ae af ak am an ar as av ay az ba be bg bh bi bm bn bo br bs ca ce ch co cr cs cu cv cy da
    de dv dz ee el en eo es et eu fa ff fi fj fo fr fy ga gd gl gn gu gv ha he hi ho hr ht hu hy hz
    ia id ie ig ii ik io is it iu ja jv ka kg ki kj kk kl km kn ko kr ks ku kv kw ky la lb lg li ln
    lo lt lu lv mg mh mi mk ml mn mr ms mt my na nb nd ne ng nl nn no nr nv ny oc oj om or os pa pi
    pl ps pt qu rm rn ro ru rw sa sc sd se sg si sk sl sm sn so sq sr ss st su sv sw ta te tg th ti
    tk tl tn to tr ts tt tw ty ug uk ur uz ve vi vo wa wo xh yi yo za zh zu ast ckb kab kmr zgh
  )

  def attachments_from_ids(%{media_ids: ids, descriptions: desc}, user) do
    attachments_from_ids_descs(ids, desc, user)
  end

  def attachments_from_ids(%{media_ids: ids}, user) do
    attachments_from_ids_no_descs(ids, user)
  end

  def attachments_from_ids(_, _), do: []

  def attachments_from_ids_no_descs([], _), do: []

  def attachments_from_ids_no_descs(ids, user) do
    Enum.map(ids, fn media_id ->
      case get_attachment(media_id, user) do
        %Object{data: data} -> data
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  def attachments_from_ids_descs([], _, _), do: []

  def attachments_from_ids_descs(ids, descs_str, user) do
    {_, descs} = Jason.decode(descs_str)

    Enum.map(ids, fn media_id ->
      with %Object{data: data} <- get_attachment(media_id, user) do
        Map.put(data, "name", descs[media_id])
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp get_attachment(media_id, user) do
    with %Object{data: data} = object <- Repo.get(Object, media_id),
         %{"type" => type} when type in Pleroma.Constants.upload_object_types() <- data,
         :ok <- Object.authorize_access(object, user) do
      object
    else
      _ -> nil
    end
  end

  @spec get_to_and_cc(ActivityDraft.t()) :: {list(String.t()), list(String.t())}

  def get_to_and_cc(%{in_reply_to_conversation: %Participation{} = participation}) do
    participation = Repo.preload(participation, :recipients)
    {Enum.map(participation.recipients, & &1.ap_id), []}
  end

  def get_to_and_cc(%{visibility: visibility} = draft) when visibility in ["public", "local"] do
    recipients = addressed_recipients(draft)

    to =
      case visibility do
        "public" -> [Pleroma.Constants.as_public() | recipients]
        "local" -> [Utils.as_local_public() | recipients]
      end

    cc = [draft.user.follower_address]

    if draft.in_reply_to do
      {Enum.uniq([draft.in_reply_to.data["actor"] | to]), cc}
    else
      {to, cc}
    end
  end

  def get_to_and_cc(%{visibility: "unlisted"} = draft) do
    to = [draft.user.follower_address | addressed_recipients(draft)]
    cc = [Pleroma.Constants.as_public()]

    if draft.in_reply_to do
      {Enum.uniq([draft.in_reply_to.data["actor"] | to]), cc}
    else
      {to, cc}
    end
  end

  def get_to_and_cc(%{visibility: "private"} = draft) do
    {to, cc} = get_to_and_cc(struct(draft, visibility: "direct"))
    {[draft.user.follower_address | to], cc}
  end

  def get_to_and_cc(%{visibility: "direct"} = draft) do
    # If the OP is a DM already, add the implicit actor.
    if draft.in_reply_to && Visibility.is_direct?(draft.in_reply_to) do
      {Enum.uniq([draft.in_reply_to.data["actor"] | addressed_recipients(draft)]), []}
    else
      {addressed_recipients(draft), []}
    end
  end

  def get_to_and_cc(%{visibility: {:list, _}} = draft), do: {addressed_recipients(draft), []}

  defp addressed_recipients(%{mentions: mentions, addressed_groups: groups}) do
    (mentions || [])
    |> Kernel.++(groups || [])
    |> Enum.uniq()
  end

  defp addressed_recipients(%{mentions: mentions}), do: mentions || []

  def get_addressed_users(_, to) when is_list(to) do
    to
    |> Enum.flat_map(&addressed_user_ap_ids/1)
    |> Enum.uniq()
  end

  def get_addressed_users(mentioned_users, _), do: mentioned_users

  def get_addressed_group_ap_ids(params, %User{} = actor) do
    groups =
      params
      |> group_targets()
      |> Enum.map(&group_from_target/1)

    cond do
      Enum.empty?(groups) ->
        {:ok, []}

      Enum.any?(groups, &is_nil/1) ->
        {:error, :group_not_found}

      Enum.any?(groups, &(not group_target_allowed?(&1, actor))) ->
        {:error, :group_forbidden}

      true ->
        {:ok, groups |> Enum.map(& &1.ap_id) |> Enum.uniq()}
    end
  end

  def get_addressed_group_ap_ids(_params, _actor), do: {:ok, []}

  defp addressed_user_ap_ids(identifier) when is_binary(identifier) do
    cond do
      String.starts_with?(identifier, ["http://", "https://"]) ->
        case User.get_cached_by_ap_id(identifier) do
          %User{} = user -> [user.ap_id]
          _ -> []
        end

      true ->
        User.get_ap_ids_by_nicknames([identifier])
    end
  end

  defp addressed_user_ap_ids(_), do: []

  defp group_targets(params) when is_map(params) do
    []
    |> add_group_targets(Map.get(params, :group_id, Map.get(params, "group_id")))
    |> add_group_targets(Map.get(params, :group_ids, Map.get(params, "group_ids")))
    |> add_group_targets(Map.get(params, "group_ids[]"))
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp group_targets(_), do: []

  defp add_group_targets(targets, value) when is_list(value), do: targets ++ value
  defp add_group_targets(targets, nil), do: targets
  defp add_group_targets(targets, value), do: targets ++ [value]

  defp group_from_target(target) when is_binary(target) do
    target
    |> resolve_group_target()
    |> case do
      %User{actor_type: "Group"} = group -> group
      _ -> nil
    end
  end

  defp group_from_target(_), do: nil

  defp resolve_group_target(target) do
    cond do
      String.starts_with?(target, ["http://", "https://"]) ->
        User.get_cached_by_ap_id(target)

      true ->
        User.get_cached_by_id(target) || User.get_cached_by_nickname(target)
    end
  end

  defp group_target_allowed?(%User{local: true, actor_type: "Group"} = group, %User{} = actor) do
    relationship = GroupMembership.relationship(actor, group)

    not Map.get(relationship, :blocked_by, false) and
      (not group.is_locked || Map.get(relationship, :member, false))
  end

  defp group_target_allowed?(%User{actor_type: "Group"}, %User{}), do: true

  def maybe_add_list_data(activity_params, user, {:list, list_id}) do
    case Pleroma.List.get(list_id, user) do
      %Pleroma.List{} = list ->
        activity_params
        |> put_in([:additional, "bcc"], [list.ap_id])
        |> put_in([:additional, "listMessage"], list.ap_id)
        |> put_in([:object, "listMessage"], list.ap_id)

      _ ->
        activity_params
    end
  end

  def maybe_add_list_data(activity_params, _, _), do: activity_params

  def make_poll_data(%{"poll" => %{"expires_in" => expires_in}} = data)
      when is_binary(expires_in) do
    # In some cases mastofe sends out strings instead of integers
    data
    |> put_in(["poll", "expires_in"], String.to_integer(expires_in))
    |> make_poll_data()
  end

  def make_poll_data(%{poll: %{options: options, expires_in: expires_in}} = data)
      when is_list(options) do
    limits = Config.get([:instance, :poll_limits])

    options = options |> Enum.uniq()

    with :ok <- validate_poll_expiration(expires_in, limits),
         :ok <- validate_poll_options_amount(options, limits),
         :ok <- validate_poll_options_length(options, limits) do
      {option_notes, emoji} =
        Enum.map_reduce(options, %{}, fn option, emoji ->
          note = %{
            "name" => option,
            "type" => "Note",
            "replies" => %{"type" => "Collection", "totalItems" => 0}
          }

          {note, Map.merge(emoji, Pleroma.Emoji.Formatter.get_emoji_map(option))}
        end)

      end_time =
        DateTime.utc_now()
        |> DateTime.add(expires_in)
        |> DateTime.to_iso8601()

      key = if Params.truthy_param?(data.poll[:multiple]), do: "anyOf", else: "oneOf"
      poll = %{"type" => "Question", key => option_notes, "closed" => end_time}

      {:ok, {poll, emoji}}
    end
  end

  def make_poll_data(%{"poll" => poll}) when is_map(poll) do
    {:error, "Invalid poll"}
  end

  def make_poll_data(_data) do
    {:ok, {%{}, %{}}}
  end

  defp validate_poll_options_amount(options, %{max_options: max_options}) do
    cond do
      Enum.count(options) < 1 ->
        {:error, "Poll must contain at least 1 option"}

      Enum.count(options) > max_options ->
        {:error, "Poll can't contain more than #{max_options} options"}

      true ->
        :ok
    end
  end

  defp validate_poll_options_length(options, %{max_option_chars: max_option_chars}) do
    if Enum.any?(options, &(String.length(&1) > max_option_chars)) do
      {:error, "Poll options cannot be longer than #{max_option_chars} characters each"}
    else
      :ok
    end
  end

  defp validate_poll_expiration(expires_in, %{min_expiration: min, max_expiration: max}) do
    cond do
      expires_in > max -> {:error, "Expiration date is too far in the future"}
      expires_in < min -> {:error, "Expiration date is too soon"}
      true -> :ok
    end
  end

  def make_content_html(%ActivityDraft{} = draft) do
    attachment_links =
      draft.params
      |> Map.get("attachment_links", Config.get([:instance, :attachment_links]))
      |> Params.truthy_param?()

    content_type = get_content_type(draft.params[:content_type])

    options =
      if draft.visibility == "direct" && Config.get([:instance, :safe_dm_mentions]) do
        [safe_mention: true]
      else
        []
      end

    draft.status
    |> format_input(content_type, options)
    |> maybe_add_attachments(draft.attachments, attachment_links)
  end

  def get_content_type(content_type) do
    if Enum.member?(Config.get([:instance, :allowed_post_formats]), content_type) do
      content_type
    else
      "text/plain"
    end
  end

  def make_context(_, %Participation{} = participation) do
    Repo.preload(participation, :conversation).conversation.ap_id
  end

  def make_context(%Activity{data: %{"context" => context}}, _), do: context
  def make_context(_, _), do: Utils.generate_context_id()

  def maybe_add_attachments(parsed, _attachments, false = _no_links), do: parsed

  def maybe_add_attachments({text, mentions, tags}, attachments, _no_links) do
    text = add_attachments(text, attachments)
    {text, mentions, tags}
  end

  def add_attachments(text, attachments) do
    attachment_text = Enum.map(attachments, &build_attachment_link/1)
    Enum.join([text | attachment_text], "<br>")
  end

  defp build_attachment_link(%{"url" => [%{"href" => href} | _]} = attachment) do
    name = attachment["name"] || URI.decode(Path.basename(href))
    href = MediaProxy.url(href)
    "<a href=\"#{href}\" class='attachment'>#{shortname(name)}</a>"
  end

  defp build_attachment_link(_), do: ""

  def format_input(text, format, options \\ [])

  @doc """
  Formatting text to plain text, BBCode, HTML, or Markdown
  """
  def format_input(text, "text/plain", options) do
    text
    |> Formatter.html_escape("text/plain")
    |> Formatter.linkify(options)
    |> (fn {text, mentions, tags} ->
          {String.replace(text, ~r/\r?\n/, "<br>"), mentions, tags}
        end).()
  end

  def format_input(text, "text/bbcode", options) do
    text
    |> String.replace(~r/\r/, "")
    |> Formatter.html_escape("text/plain")
    |> BBCode.to_html()
    |> (fn {:ok, html} -> html end).()
    |> Formatter.linkify(options)
    |> Formatter.html_escape("text/html")
  end

  def format_input(text, "text/html", options) do
    text
    |> Formatter.linkify(options)
    |> Formatter.html_escape("text/html")
  end

  def format_input(text, "text/x.misskeymarkdown", options) do
    text
    |> Formatter.markdown_to_html(%{breaks: true})
    |> safe_mfm_to_html()
    |> Formatter.linkify(options)
    |> Formatter.html_escape("text/x.misskeymarkdown")
  end

  def format_input(text, "text/markdown", options) do
    text
    |> Formatter.mentions_escape(options)
    |> Formatter.markdown_to_html()
    |> Formatter.linkify(options)
    |> Formatter.html_escape("text/html")
  end

  defp safe_mfm_to_html(html) do
    html
    |> MfmParser.Parser.parse()
    |> MfmParser.Encoder.to_html()
  rescue
    _ -> html
  catch
    _, _ -> html
  end

  def format_naive_asctime(date) do
    date |> DateTime.from_naive!("Etc/UTC") |> format_asctime
  end

  def format_asctime(date) do
    Strftime.strftime!(date, "%a %b %d %H:%M:%S %z %Y")
  end

  def date_to_asctime(date) when is_binary(date) do
    with {:ok, date, _offset} <- DateTime.from_iso8601(date) do
      format_asctime(date)
    else
      _e ->
        Logger.warning("Date #{date} in wrong format, must be ISO 8601")
        ""
    end
  end

  def date_to_asctime(date) do
    Logger.warning("Date #{date} in wrong format, must be ISO 8601")
    ""
  end

  def to_masto_date(date, default \\ "")

  def to_masto_date(%NaiveDateTime{} = date, _default) do
    date
    |> NaiveDateTime.to_iso8601()
    |> String.replace(~r/(\.\d+)?$/, ".000Z", global: false)
  end

  def to_masto_date(date, default) when is_binary(date) do
    with {:ok, date} <- NaiveDateTime.from_iso8601(date) do
      to_masto_date(date, default)
    else
      _ -> ""
    end
  end

  def to_masto_date(_, default), do: default

  defp shortname(name) do
    with max_length when max_length > 0 <-
           Config.get([Pleroma.Upload, :filename_display_max_length], 30),
         true <- String.length(name) > max_length do
      String.slice(name, 0..max_length) <> "…"
    else
      _ -> name
    end
  end

  @spec confirm_current_password(User.t(), String.t()) :: {:ok, User.t()} | {:error, String.t()}
  def confirm_current_password(user, password) do
    with %User{local: true} = db_user <- User.get_cached_by_id(user.id),
         true <- AuthenticationPlug.checkpw(password, db_user.password_hash) do
      {:ok, db_user}
    else
      _ -> {:error, dgettext("errors", "Invalid password.")}
    end
  end

  def maybe_notify_to_recipients(
        recipients,
        %Activity{data: %{"to" => to, "type" => _type}} = _activity
      ) do
    recipients ++ to
  end

  def maybe_notify_to_recipients(recipients, _), do: recipients

  def maybe_notify_mentioned_recipients(
        recipients,
        %Activity{data: %{"to" => _to, "type" => type} = data} = activity
      )
      when type == "Create" do
    object = Object.normalize(activity, fetch: false)

    object_data =
      cond do
        not is_nil(object) ->
          object.data

        is_map(data["object"]) ->
          data["object"]

        true ->
          %{}
      end

    tagged_mentions = maybe_extract_mentions(object_data)

    recipients ++ tagged_mentions
  end

  def maybe_notify_mentioned_recipients(recipients, _), do: recipients

  def maybe_notify_replied_to_author(
        recipients,
        %Activity{data: %{"type" => "Create"}} = activity
      ) do
    with %Object{data: %{"inReplyTo" => in_reply_to}} = object <-
           Object.normalize(activity, fetch: false),
         replied_to_id when is_binary(replied_to_id) <- normalize_in_reply_to(in_reply_to),
         %Object{data: %{"actor" => actor}} <- Object.get_cached_by_ap_id(replied_to_id),
         %User{local: true} = user <- User.get_cached_by_ap_id(actor),
         true <- Visibility.visible_for_user?(object, user) do
      recipients ++ [user.ap_id]
    else
      _ -> recipients
    end
  end

  def maybe_notify_replied_to_author(recipients, _), do: recipients

  defp normalize_in_reply_to(in_reply_to) when is_binary(in_reply_to), do: in_reply_to
  defp normalize_in_reply_to(%{"id" => id}) when is_binary(id), do: id
  defp normalize_in_reply_to([id | _]) when is_binary(id), do: id
  defp normalize_in_reply_to(_), do: nil

  def maybe_notify_subscribers(
        recipients,
        %Activity{data: %{"actor" => actor, "type" => "Create"}} = activity
      ) do
    # Do not notify subscribers if author is making a reply
    with %Object{data: object} <- Object.normalize(activity, fetch: false),
         nil <- object["inReplyTo"],
         %User{} = user <- User.get_cached_by_ap_id(actor) do
      subscriber_ids =
        user
        |> User.subscriber_users()
        |> Enum.filter(&Visibility.visible_for_user?(activity, &1))
        |> Enum.map(& &1.ap_id)

      recipients ++ subscriber_ids
    else
      _e -> recipients
    end
  end

  def maybe_notify_subscribers(recipients, _), do: recipients

  def maybe_notify_followers(recipients, %Activity{data: %{"type" => "Move"}} = activity) do
    with %User{} = user <- User.get_cached_by_ap_id(activity.actor) do
      user
      |> User.get_followers()
      |> Enum.map(& &1.ap_id)
      |> Enum.concat(recipients)
    else
      _e -> recipients
    end
  end

  def maybe_notify_followers(recipients, _), do: recipients

  def maybe_notify_participants(
        recipients,
        %Activity{data: %{"type" => "Update"}} = activity
      ) do
    with %Object{data: object} <- Object.normalize(activity, fetch: false) do
      participant_ids = Map.get(object, "participations", [])

      recipients ++ participant_ids
    else
      _e -> recipients
    end
  end

  def maybe_notify_participants(recipients, _), do: recipients

  def maybe_extract_mentions(%{"tag" => tag}) do
    tag
    |> Enum.filter(fn x -> is_map(x) && x["type"] == "Mention" end)
    |> Enum.map(fn x -> x["href"] end)
    |> Enum.uniq()
  end

  def maybe_extract_mentions(_), do: []

  def make_report_content_html(nil), do: {:ok, {nil, [], []}}

  def make_report_content_html(comment) do
    max_size = Config.get([:instance, :max_report_comment_size], 1000)

    if String.length(comment) <= max_size do
      {:ok, format_input(comment, "text/plain")}
    else
      {:error,
       dgettext("errors", "Comment must be up to %{max_size} characters", max_size: max_size)}
    end
  end

  def get_report_statuses(%User{ap_id: actor}, %{status_ids: status_ids})
      when is_list(status_ids) do
    {:ok, Activity.all_by_actor_and_id(actor, status_ids)}
  end

  def get_report_statuses(_, _), do: {:ok, nil}

  def validate_character_limit("" = _full_payload, [] = _attachments) do
    {:error, dgettext("errors", "Cannot post an empty status without attachments")}
  end

  def validate_character_limit(full_payload, _attachments) do
    limit = Config.get([:instance, :limit])
    length = String.length(full_payload)

    if length <= limit do
      :ok
    else
      {:error, dgettext("errors", "The status is over the character limit")}
    end
  end

  def validate_attachments_count([] = _attachments) do
    :ok
  end

  def validate_attachments_count(attachments) do
    limit = Config.get([:instance, :max_media_attachments])
    count = length(attachments)

    if count <= limit do
      :ok
    else
      {:error, dgettext("errors", "Too many attachments")}
    end
  end

  def get_valid_language(language) when is_binary(language) do
    case language |> String.split("_") |> Enum.at(0) do
      locale when locale in @supported_locales -> locale
      _ -> nil
    end
  end

  def get_valid_language(_), do: nil
end
