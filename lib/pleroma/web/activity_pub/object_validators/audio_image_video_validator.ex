# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.AudioImageVideoValidator do
  use Ecto.Schema

  alias Pleroma.EctoType.ActivityPub.ObjectValidators
  alias Pleroma.Web.ActivityPub.ObjectValidators.AttachmentValidator
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonFixes
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonValidations
  alias Pleroma.Web.ActivityPub.Transmogrifier

  import Ecto.Changeset

  require Pleroma.Constants

  @maximum_remote_attachments 32
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
    field(:embedUrl, ObjectValidators.ObjectID)
    field(:isLiveBroadcast, :boolean, default: false)
    field(:schedules, {:array, :map}, default: [])
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

  defp find_attachment(url, object_type) do
    mpeg_url =
      Enum.find(url, fn
        %{"mediaType" => mime_type, "tag" => tags}
        when is_binary(mime_type) and is_list(tags) ->
          mime_type == "application/x-mpegURL"

        _ ->
          false
      end)

    tagged_urls =
      case mpeg_url do
        %{"tag" => tags} when is_list(tags) -> AttachmentValidator.normalize_url_candidates(tags)
        _ -> []
      end

    candidates = Enum.concat(url, tagged_urls)

    Enum.find(url, &direct_media_candidate?(&1, object_type)) ||
      Enum.find(tagged_urls, &direct_media_candidate?(&1, object_type)) ||
      Enum.find(candidates, &preferred_media_candidate?(&1, object_type)) ||
      Enum.find(candidates, &media_candidate?/1)
  end

  defp direct_media_candidate?(candidate, "Video") do
    candidate_media_type(candidate)
    |> media_type_matches?(["video/"])
  end

  defp direct_media_candidate?(candidate, "Audio") do
    candidate_media_type(candidate)
    |> media_type_matches?(["audio/"])
  end

  defp direct_media_candidate?(candidate, "Image") do
    candidate_media_type(candidate)
    |> media_type_matches?(["image/"])
  end

  defp direct_media_candidate?(_candidate, _type), do: false

  defp fix_url(%{"url" => url} = data) when is_list(url) or is_map(url) do
    candidates = AttachmentValidator.normalize_url_candidates(List.wrap(url))
    attachment = find_attachment(candidates, data["type"])

    link_element =
      Enum.find(candidates, fn
        %{"mediaType" => "text/html"} -> true
        %{"mimeType" => "text/html"} -> true
        _ -> false
      end)

    data
    |> put_selected_attachment(attachment, data["type"])
    |> put_object_page_url(link_element, data["id"])
  end

  defp fix_url(data), do: data

  defp put_selected_attachment(data, attachment, object_type) do
    existing =
      data
      |> Map.get("attachment", [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)

    attachments =
      [media_attachment(attachment, object_type) | existing]
      |> Enum.filter(&is_map/1)
      |> Enum.uniq_by(&attachment_identity/1)
      |> Enum.take(@maximum_remote_attachments)

    Map.put(data, "attachment", attachments)
  end

  defp media_attachment(%{} = candidate, object_type)
       when object_type in ["Audio", "Image", "Video"] do
    %{
      "type" => object_type,
      "mediaType" => candidate_media_type(candidate) || "application/octet-stream",
      "url" => [candidate]
    }
  end

  defp media_attachment(_candidate, _object_type), do: nil

  defp preferred_media_candidate?(candidate, "Video") do
    candidate_media_type(candidate)
    |> media_type_matches?(["video/", "application/x-mpegurl", "application/vnd.apple.mpegurl"])
  end

  defp preferred_media_candidate?(candidate, "Audio") do
    candidate_media_type(candidate)
    |> media_type_matches?(["audio/"])
  end

  defp preferred_media_candidate?(candidate, "Image") do
    candidate_media_type(candidate)
    |> media_type_matches?(["image/"])
  end

  defp preferred_media_candidate?(_candidate, _type), do: false

  defp media_candidate?(candidate) do
    candidate_media_type(candidate)
    |> media_type_matches?(["video/", "audio/", "image/"])
  end

  defp candidate_media_type(%{"mediaType" => media_type}) when is_binary(media_type),
    do: String.downcase(media_type)

  defp candidate_media_type(%{"mimeType" => media_type}) when is_binary(media_type),
    do: String.downcase(media_type)

  defp candidate_media_type(_candidate), do: nil

  defp media_type_matches?(media_type, prefixes) when is_binary(media_type),
    do: Enum.any?(prefixes, &String.starts_with?(media_type, &1))

  defp media_type_matches?(_media_type, _prefixes), do: false

  defp attachment_identity(attachment) do
    {candidate_media_type(attachment), attachment_reference(attachment) || attachment}
  end

  defp attachment_reference(%{"href" => href}) when is_binary(href), do: href

  defp attachment_reference(%{"url" => url}) do
    url
    |> List.wrap()
    |> Enum.find_value(fn
      %{"href" => href} when is_binary(href) -> href
      href when is_binary(href) -> href
      _candidate -> nil
    end)
  end

  defp attachment_reference(_attachment), do: nil

  defp put_object_page_url(data, %{"href" => href}, _fallback), do: Map.put(data, "url", href)

  defp put_object_page_url(data, _link, fallback) do
    if safe_http_url?(fallback), do: Map.put(data, "url", fallback), else: Map.delete(data, "url")
  end

  defp safe_http_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp safe_http_url?(_url), do: false

  defp fix_content(%{"mediaType" => "text/markdown", "content" => content} = data)
       when is_binary(content) do
    content =
      content
      |> Pleroma.Formatter.markdown_to_html()
      |> Pleroma.HTML.filter_tags()

    Map.put(data, "content", content)
  end

  defp fix_content(data), do: data

  # PeerTube advertises the remote likes collection by URL. The local `likes`
  # field stores individual actor IDs, so a collection URL must not be cast as
  # a one-element local interaction list.
  defp fix_likes_collection(%{"likes" => likes} = data) when is_binary(likes),
    do: Map.delete(data, "likes")

  defp fix_likes_collection(data), do: data

  defp fix_live_video_metadata(%{"type" => "Video"} = data) do
    data
    |> normalize_live_embed_url()
    |> Map.update("schedules", [], &normalize_live_schedules/1)
  end

  defp fix_live_video_metadata(data) do
    data
    |> Map.delete("embedUrl")
    |> Map.delete("isLiveBroadcast")
    |> Map.delete("schedules")
  end

  defp normalize_live_embed_url(%{"embedUrl" => embed_url, "id" => id} = data)
       when is_binary(embed_url) and is_binary(id) do
    if same_origin?(embed_url, id), do: data, else: Map.delete(data, "embedUrl")
  end

  defp normalize_live_embed_url(data), do: Map.delete(data, "embedUrl")

  defp normalize_live_schedules(schedules) when is_list(schedules) do
    schedules
    |> Enum.reduce([], fn
      %{"startDate" => start_date}, normalized when is_binary(start_date) ->
        if valid_iso8601_datetime?(start_date) do
          [%{"startDate" => start_date} | normalized]
        else
          normalized
        end

      _schedule, normalized ->
        normalized
    end)
    |> Enum.reverse()
    |> Enum.take(4)
  end

  defp normalize_live_schedules(_schedules), do: []

  defp valid_iso8601_datetime?(value) do
    match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value))
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

  defp fix_replies(%{"replies" => replies} = data) when is_list(replies), do: data

  defp fix_replies(%{"replies" => %{"first" => %{"items" => replies}}} = data)
       when is_list(replies),
       do: Map.put(data, "replies", replies)

  defp fix_replies(%{"replies" => %{"first" => %{"orderedItems" => replies}}} = data)
       when is_list(replies),
       do: Map.put(data, "replies", replies)

  defp fix_replies(%{"replies" => %{"items" => replies}} = data) when is_list(replies),
    do: Map.put(data, "replies", replies)

  defp fix_replies(%{"replies" => %{"orderedItems" => replies}} = data) when is_list(replies),
    do: Map.put(data, "replies", replies)

  defp fix_replies(%{"comments" => comments} = data) do
    data
    |> Map.delete("comments")
    |> Map.put("replies", comments)
    |> fix_replies()
  end

  defp fix_replies(data), do: Map.delete(data, "replies")

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

  defp fix_funkwhale_track(%{"type" => "Track"} = data) do
    data
    |> Map.put("type", "Audio")
    |> put_funkwhale_track_content()
    |> put_funkwhale_track_attachment()
    |> put_funkwhale_track_recipients()
  end

  defp fix_funkwhale_track(data), do: data

  defp put_funkwhale_track_content(%{"content" => content} = data)
       when is_binary(content) and content != "" do
    data
  end

  defp put_funkwhale_track_content(data) do
    data
    |> funkwhale_track_parts()
    |> Enum.reject(&blank?/1)
    |> Enum.join(" - ")
    |> case do
      "" -> data
      content -> Map.put(data, "content", html_escape(content))
    end
  end

  defp funkwhale_track_parts(data) do
    [
      data["name"],
      funkwhale_artist_credit(data["artist_credit"]),
      get_in(data, ["album", "name"])
    ]
  end

  defp funkwhale_artist_credit(credits) when is_list(credits) do
    credits
    |> Enum.map(fn
      %{"credit" => credit} when is_binary(credit) -> credit
      %{"artist" => %{"name" => name}} when is_binary(name) -> name
      _ -> nil
    end)
    |> Enum.reject(&blank?/1)
    |> Enum.join(", ")
  end

  defp funkwhale_artist_credit(_), do: nil

  defp put_funkwhale_track_attachment(%{"attachment" => [_ | _]} = data), do: data

  defp put_funkwhale_track_attachment(%{"id" => id} = data) when is_binary(id) do
    attachment = %{
      "type" => "Link",
      "mediaType" => "text/html",
      "name" => data["name"],
      "url" => [
        %{
          "type" => "Link",
          "href" => id,
          "mediaType" => "text/html"
        }
      ]
    }

    Map.put(data, "attachment", [attachment])
  end

  defp put_funkwhale_track_attachment(data), do: data

  defp put_funkwhale_track_recipients(data) do
    if any_recipient?(data) do
      data
    else
      cc =
        data
        |> Map.get("attributedTo")
        |> List.wrap()
        |> Enum.filter(&is_binary/1)

      data
      |> Map.put("to", [Pleroma.Constants.as_public()])
      |> Map.put("cc", cc)
    end
  end

  defp any_recipient?(data) do
    Enum.any?(~w(to cc audience), fn field ->
      data
      |> Map.get(field)
      |> List.wrap()
      |> Enum.any?()
    end)
  end

  defp blank?(value), do: value in [nil, ""]

  defp html_escape(text) when is_binary(text) do
    text
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp fix(data) do
    data
    |> fix_funkwhale_track()
    |> CommonFixes.fix_actor()
    |> CommonFixes.fix_object_defaults()
    |> CommonFixes.fix_quote_url()
    |> fix_likes_collection()
    |> fix_live_video_metadata()
    |> CommonFixes.fix_likes()
    |> Transmogrifier.fix_emoji()
    |> fix_url()
    |> fix_content()
    |> fix_replies_collection()
    |> fix_replies()
  end

  def changeset(struct, data) do
    data = fix(data)

    struct
    |> cast(data, __schema__(:fields) -- [:attachment, :tag])
    |> cast_embed(:attachment, required: true)
    |> cast_embed(:tag)
  end

  defp validate_data(data_cng) do
    data_cng
    |> validate_inclusion(:type, ~w[Audio Image Video])
    |> validate_required([:id, :actor, :attributedTo, :type, :context])
    |> CommonValidations.validate_any_presence([:cc, :to])
    |> CommonValidations.validate_fields_match([:actor, :attributedTo])
    |> CommonValidations.validate_actor_presence()
    |> CommonValidations.validate_host_match()
  end
end
