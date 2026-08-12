# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.StaticFE.StaticFEView do
  use Pleroma.Web, :view

  alias Calendar.Strftime
  alias Pleroma.Emoji.Formatter
  alias Pleroma.User
  alias Pleroma.Web.Endpoint
  alias Pleroma.Web.Gettext
  alias Pleroma.Web.MediaProxy
  alias Pleroma.Web.Metadata.Utils
  alias Pleroma.Web.Router.Helpers

  import Phoenix.HTML
  use PhoenixHTMLHelpers

  @media_types ["image", "audio", "video"]

  def fetch_media_type(%{"mediaType" => mediaType}) do
    Utils.fetch_media_type(@media_types, mediaType)
  end

  def fetch_media_type(_attachment), do: nil

  def attachment_data(%{"url" => urls} = attachment) do
    source = urls |> List.wrap() |> List.first()

    with url when is_binary(url) <- attachment_url(source) do
      %{
        name: attachment_name(attachment),
        url: MediaProxy.url(url),
        mediaType: fetch_media_type(source) || fetch_media_type(attachment)
      }
    end
  end

  def attachment_data(_attachment), do: nil

  def format_date(date) when is_binary(date) do
    case DateTime.from_iso8601(date) do
      {:ok, date, _} -> Strftime.strftime!(date, "%Y/%m/%d %l:%M:%S %p UTC")
      _ -> Gettext.gettext("unknown date")
    end
  end

  def format_date(_), do: Gettext.gettext("unknown date")

  def instance_name, do: Pleroma.Config.get([:instance, :name], "Pleroma")

  def open_content? do
    Pleroma.Config.get(
      [:frontend_configurations, :collapse_message_with_subjects],
      true
    )
  end

  defp attachment_url(%{"href" => url}) when is_binary(url), do: url
  defp attachment_url(%{"url" => url}) when is_binary(url), do: url
  defp attachment_url(url) when is_binary(url), do: url
  defp attachment_url(_source), do: nil

  defp attachment_name(%{"name" => name}) when is_binary(name), do: name
  defp attachment_name(_attachment), do: ""
end
