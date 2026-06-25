# Pleroma: A lightweight social networking server

# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Metadata.Providers.TwitterCard do
  alias Pleroma.User
  alias Pleroma.Web.MediaProxy
  alias Pleroma.Web.Metadata
  alias Pleroma.Web.Metadata.Providers.Provider
  alias Pleroma.Web.Metadata.Utils

  @behaviour Provider
  @media_types ["image", "audio", "video"]

  @impl Provider
  def build_tags(%{activity_id: id, object: object, user: user}) do
    attachments = build_attachments(id, object)
    scrubbed_content = Utils.scrub_html_and_truncate(object)

    [
      title_tag(user),
      {:meta, [name: "twitter:description", content: scrubbed_content], []}
    ] ++
      if attachments == [] or Metadata.activity_nsfw?(object) do
        [
          image_tag(user),
          {:meta, [name: "twitter:card", content: "summary"], []}
        ]
      else
        attachments
      end
  end

  @impl Provider
  def build_tags(%{user: user}) do
    with truncated_bio = Utils.scrub_html_and_truncate(user.bio) do
      [
        title_tag(user),
        {:meta, [name: "twitter:description", content: truncated_bio], []},
        image_tag(user),
        {:meta, [name: "twitter:card", content: "summary"], []}
      ]
    end
  end

  defp title_tag(user) do
    {:meta, [name: "twitter:title", content: Utils.user_name_string(user)], []}
  end

  def image_tag(user) do
    {:meta, [name: "twitter:image", content: MediaProxy.preview_url(User.avatar_url(user))], []}
  end

  defp build_attachments(id, %{data: %{"attachment" => attachments}}) when is_list(attachments) do
    Enum.reduce(attachments, [], fn attachment, acc ->
      rendered_tags =
        attachment
        |> attachment_urls()
        |> Enum.reduce([], fn url, acc ->
          case fetch_media_type(url) do
            "audio" ->
              [
                {:meta, [name: "twitter:card", content: "player"], []},
                {:meta, [name: "twitter:player:width", content: "480"], []},
                {:meta, [name: "twitter:player:height", content: "80"], []},
                {:meta, [name: "twitter:player", content: player_url(id)], []}
                | acc
              ]

            # Not using preview_url for this. It saves bandwidth, but the image dimensions will
            # be wrong. We generate it on the fly and have no way to capture or analyze the
            # image to get the dimensions. This can be an issue for apps/FEs rendering images
            # in timelines too, but you can get clever with the aspect ratio metadata as a
            # workaround.
            "image" ->
              [
                {:meta, [name: "twitter:card", content: "summary_large_image"], []},
                {:meta,
                 [
                   name: "twitter:image",
                   content: MediaProxy.url(url["href"])
                 ], []},
                {:meta, [name: "twitter:image:alt", content: truncate(attachment["name"])], []}
                | acc
              ]
              |> maybe_add_dimensions(url)

            "video" ->
              # fallback to old placeholder values
              height = url["height"] || 480
              width = url["width"] || 480

              [
                {:meta, [name: "twitter:card", content: "player"], []},
                {:meta, [name: "twitter:player", content: player_url(id)], []},
                {:meta, [name: "twitter:player:width", content: "#{width}"], []},
                {:meta, [name: "twitter:player:height", content: "#{height}"], []},
                {:meta, [name: "twitter:player:stream", content: MediaProxy.url(url["href"])],
                 []},
                {:meta, [name: "twitter:player:stream:content_type", content: url["mediaType"]],
                 []}
                | acc
              ]

            _ ->
              acc
          end
        end)

      acc ++ rendered_tags
    end)
  end

  defp build_attachments(_id, _object), do: []

  defp attachment_urls(%{"url" => urls}) when is_list(urls), do: urls
  defp attachment_urls(%{"url" => url}) when is_map(url), do: [url]
  defp attachment_urls(_), do: []

  defp fetch_media_type(%{"mediaType" => media_type}) when is_binary(media_type) do
    Utils.fetch_media_type(@media_types, media_type)
  end

  defp fetch_media_type(_), do: nil

  defp player_url(id) do
    Pleroma.Web.Router.Helpers.o_status_url(Pleroma.Web.Endpoint, :notice_player, id)
  end

  # Videos have problems without dimensions, but we used to not provide WxH for images.
  # A default (read: incorrect) fallback for images is likely to cause rendering bugs.
  defp maybe_add_dimensions(metadata, url) do
    cond do
      !is_nil(url["height"]) && !is_nil(url["width"]) ->
        metadata ++
          [
            {:meta, [name: "twitter:player:width", content: "#{url["width"]}"], []},
            {:meta, [name: "twitter:player:height", content: "#{url["height"]}"], []}
          ]

      true ->
        metadata
    end
  end

  defp truncate(nil), do: ""

  defp truncate(text) do
    # truncate to 420 characters
    # see https://developer.twitter.com/en/docs/twitter-for-websites/cards/overview/markup
    Pleroma.Formatter.truncate(text, 420)
  end
end
