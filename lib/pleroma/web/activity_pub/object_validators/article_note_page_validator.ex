# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.ArticleNotePageValidator do
  use Ecto.Schema

  alias Pleroma.EctoType.ActivityPub.ObjectValidators
  alias Pleroma.HTML
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ContentLinks
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonFixes
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonValidations
  alias Pleroma.Web.ActivityPub.Transmogrifier
  alias Pleroma.Web.CommonAPI.Utils

  import Ecto.Changeset

  @default_remote_media_attachment_limit 32
  @source_content_media_types ~w[text/html text/markdown text/plain]

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
    field(:distinguished, :boolean, default: false)
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

  defp fix_url(%{"url" => url} = data) when is_map(url) or is_list(url) do
    case preferred_url(url) do
      nil -> Map.delete(data, "url")
      url -> Map.put(data, "url", url)
    end
  end

  defp fix_url(data), do: data

  # ActivityStreams permits Link objects and arrays in `url`. Prefer a browser
  # URL when peers, such as Bridgy Fed, include both an HTTPS presentation URL
  # and a protocol-native canonical URI.
  defp preferred_url(value) do
    candidates = url_candidates(value)

    Enum.find(candidates, &http_url?/1) || Enum.find(candidates, &absolute_uri?/1)
  end

  defp url_candidates(values) when is_list(values), do: Enum.flat_map(values, &url_candidates/1)
  defp url_candidates(value) when is_binary(value), do: [value]

  defp url_candidates(%{} = value) do
    [value["href"], value["id"], value["url"]]
    |> Enum.filter(&is_binary/1)
  end

  defp url_candidates(_value), do: []

  defp http_url?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] ->
        is_binary(host) and host != ""

      _other ->
        false
    end
  rescue
    URI.Error -> false
  end

  defp absolute_uri?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} -> is_binary(scheme) and scheme != ""
    end
  rescue
    URI.Error -> false
  end

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

  defp fix_quote_url(%{"quote" => %{"id" => quote_url}} = data) when is_binary(quote_url) do
    data
    |> Map.put("quote", quote_url)
    |> Map.put_new("quoteUrl", quote_url)
  end

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

  # GoToSocial's current interaction-control vocabulary places the approval
  # URI for a reply in `replyAuthorization`. Older releases used `approvedBy`.
  # The property is singular, so a multi-value input is not silently reduced to
  # whichever authorization happened to arrive first.
  defp fix_reply_authorization(data) do
    authorization =
      authorization_id(Map.get(data, "replyAuthorization")) ||
        authorization_id(Map.get(data, "approvedBy"))

    data = Map.drop(data, ["replyAuthorization", "approvedBy"])

    with in_reply_to when is_binary(in_reply_to) <- authorization_id(data["inReplyTo"]),
         authorization when is_binary(authorization) <- authorization do
      data
      |> Map.put("inReplyTo", in_reply_to)
      |> Map.put("replyAuthorization", authorization)
    else
      _ -> data
    end
  end

  defp authorization_id(value) when is_binary(value), do: value
  defp authorization_id(%{"id" => value}) when is_binary(value), do: value
  defp authorization_id([value]), do: authorization_id(value)
  defp authorization_id(_value), do: nil

  def fix_attachments(%{"attachment" => attachment} = data) when is_map(attachment),
    do: data |> Map.put("attachment", [attachment]) |> fix_attachments()

  def fix_attachments(%{"attachment" => attachments} = data) when is_list(attachments) do
    attachments = Enum.filter(attachments, &media_attachment?/1)

    {attachments, overflow} =
      Enum.split(attachments, remote_media_attachment_limit())

    data =
      if attachments == [] do
        Map.drop(data, ["attachment"])
      else
        Map.put(data, "attachment", attachments)
      end

    append_overflow_attachment_links(data, overflow)
  end

  def fix_attachments(%{"attachment" => _attachment} = data), do: Map.drop(data, ["attachment"])

  def fix_attachments(data), do: data

  # Profile-style metadata occasionally appears in a Note's attachment list.
  # PropertyValue entries are not media and have no URL, so feeding them to the
  # media validator would reject an otherwise valid post.
  defp media_attachment?(%{"url" => url}) when is_binary(url) or is_map(url) or is_list(url),
    do: true

  defp media_attachment?(%{"href" => href}) when is_binary(href), do: true
  defp media_attachment?(_attachment), do: false

  # Remote albums can legitimately contain more media than a local composer
  # permits. Keep a separate, generous ceiling for the structured attachment
  # array, then preserve another bounded page of media as links in the post.
  # This keeps large Pixelfed and gallery posts useful without allowing one
  # activity to create an unbounded embedded changeset.
  defp remote_media_attachment_limit do
    case Pleroma.Config.get(
           [:instance, :remote_media_attachment_limit],
           @default_remote_media_attachment_limit
         ) do
      limit when is_integer(limit) and limit > 0 -> limit
      _ -> @default_remote_media_attachment_limit
    end
  end

  defp append_overflow_attachment_links(data, []), do: data

  defp append_overflow_attachment_links(data, overflow) do
    limit = remote_media_attachment_limit()

    urls =
      overflow
      |> Enum.take(limit)
      |> Enum.map(&attachment_url/1)
      |> Enum.filter(&safe_remote_media_url?/1)
      |> Enum.uniq()

    omitted? = length(overflow) > limit

    case {data["content"], urls, omitted?} do
      {content, urls, omitted?} when (is_binary(content) or is_nil(content)) and urls != [] ->
        links = Enum.map_join(urls, "", &overflow_attachment_link/1)
        notice = if omitted?, do: "<p>Additional attachments omitted.</p>", else: ""
        Map.put(data, "content", (content || "") <> links <> notice)

      {content, [], true} when is_binary(content) or is_nil(content) ->
        Map.put(data, "content", (content || "") <> "<p>Additional attachments omitted.</p>")

      _ ->
        data
    end
  end

  defp attachment_url(%{"href" => href}) when is_binary(href), do: href
  defp attachment_url(%{"url" => url}), do: attachment_url_value(url)
  defp attachment_url(_attachment), do: nil

  defp attachment_url_value(url) when is_binary(url), do: url
  defp attachment_url_value(%{"href" => href}) when is_binary(href), do: href
  defp attachment_url_value(%{"url" => url}), do: attachment_url_value(url)

  defp attachment_url_value(urls) when is_list(urls),
    do: Enum.find_value(urls, &attachment_url_value/1)

  defp attachment_url_value(_url), do: nil

  defp safe_remote_media_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp safe_remote_media_url?(_url), do: false

  defp overflow_attachment_link(url) do
    escaped_url =
      url
      |> Phoenix.HTML.html_escape()
      |> Phoenix.HTML.safe_to_string()

    ~s(<p><a href="#{escaped_url}" rel="nofollow noopener noreferrer">Additional attachment</a></p>)
  end

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

  defp fix_markdown_content(%{"content" => source_content} = object)
       when is_binary(source_content) do
    if source_media_type(object["mediaType"]) == "text/markdown" do
      source_content =
        object
        |> get_in(["source", "content"])
        |> then(&(&1 || source_content))
        |> ContentLinks.absolutize_markdown(ContentLinks.canonical_base(object))

      mention_handler = fn nick, buffer, opts, acc ->
        remote_mention_resolver(object, nick, buffer, opts, acc)
      end

      {content, _mentions, _tags} =
        Utils.format_input(source_content, "text/markdown", mention_handler: mention_handler)

      existing_source = if is_map(object["source"]), do: object["source"], else: %{}

      source =
        Map.merge(existing_source, %{
          "content" => source_content,
          "mediaType" => "text/markdown"
        })

      object
      |> Map.put("content", content)
      |> Map.put("source", source)
    else
      object
    end
  end

  defp fix_markdown_content(object), do: object

  # Some peers send the only human-readable representation in `source.content`,
  # including non-public posts delivered directly to an authorized recipient.
  # Source is not a visibility boundary in ActivityStreams, so promoting it
  # does not change who may read the object. It does need the same formatting
  # and sanitization as ordinary content before it is stored and rendered.
  defp fix_source_content(%{"source" => %{"content" => source_content} = source} = object)
       when is_binary(source_content) do
    media_type = source_media_type(source["mediaType"])

    if empty_rendered_content?(object["content"]) and
         String.trim(source_content) != "" and
         media_type in @source_content_media_types do
      Map.put(object, "content", render_source_content(object, source_content, media_type))
    else
      object
    end
  end

  defp fix_source_content(object), do: object

  defp normalize_source_links(%{"source" => %{"content" => content} = source} = object)
       when is_binary(content) do
    base = ContentLinks.canonical_base(object)
    media_type = source["mediaType"]
    content = ContentLinks.normalize_source(content, media_type, base)
    put_in(object, ["source", "content"], content)
  end

  defp normalize_source_links(object), do: object

  defp normalize_rendered_links(%{"content" => content} = object) when is_binary(content) do
    content =
      content
      |> ContentLinks.absolutize_html(ContentLinks.canonical_base(object))
      |> HTML.filter_tags()

    Map.put(object, "content", content)
  end

  defp normalize_rendered_links(object), do: object

  defp source_media_type(media_type) when is_binary(media_type) do
    media_type
    |> String.split(";", parts: 2)
    |> List.first()
    |> String.trim()
    |> String.downcase()
  end

  defp source_media_type(_media_type), do: "text/plain"

  defp empty_rendered_content?(content) when is_binary(content) do
    content
    |> HTML.strip_tags()
    |> String.trim()
    |> then(&(&1 == ""))
  end

  defp empty_rendered_content?(_content), do: true

  defp render_source_content(_object, source_content, "text/html") do
    HTML.filter_tags(source_content)
  end

  defp render_source_content(object, source_content, media_type) do
    mention_handler = fn nick, buffer, opts, acc ->
      remote_mention_resolver(object, nick, buffer, opts, acc)
    end

    {content, _mentions, _tags} =
      Utils.format_input(source_content, media_type, mention_handler: mention_handler)

    content
  end

  def fix(data) do
    data
    |> CommonFixes.fix_actor()
    |> CommonFixes.fix_object_defaults()
    |> fix_url()
    |> fix_tag()
    |> fix_replies_collection()
    |> fix_replies()
    |> fix_quote_url()
    |> fix_reply_authorization()
    |> Pleroma.Web.ActivityPub.DistinguishedComment.normalize()
    |> fix_attachments()
    |> normalize_source()
    |> normalize_source_links()
    |> fix_markdown_content()
    |> fix_misskey_content()
    |> fix_source_content()
    |> normalize_rendered_links()
    |> CommonFixes.fix_quote_url()
    |> CommonFixes.fix_likes()
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
    |> validate_inclusion(:type, ["Article", "Document", "Note", "Page"])
    |> validate_required([:id, :actor, :attributedTo, :type, :context])
    |> CommonValidations.validate_any_presence([:cc, :to])
    |> CommonValidations.validate_fields_match([:actor, :attributedTo])
    |> CommonValidations.validate_actor_presence()
    |> validate_remote_content_length()
    |> CommonValidations.validate_object_visibility(field_name: :inReplyTo)
    |> CommonValidations.validate_reply_scope(field_name: :inReplyTo)
    |> CommonValidations.validate_reply_open(field_name: :inReplyTo)
    |> CommonValidations.validate_object_visibility(field_name: :quoteUrl)
    |> CommonValidations.validate_host_match()
  end

  # The remote limit describes user-visible text. Checking the normalized HTML
  # string itself would reject harmless markup while still failing to express
  # what the setting promises operators.
  defp validate_remote_content_length(changeset) do
    limit = Pleroma.Config.get([:instance, :remote_limit], 100_000)

    validate_change(changeset, :content, fn field, content ->
      visible_length = content |> Pleroma.HTML.strip_tags() |> String.length()

      if is_integer(limit) and limit > 0 and visible_length > limit do
        [{field, "is longer than the configured remote post limit"}]
      else
        []
      end
    end)
  end
end
