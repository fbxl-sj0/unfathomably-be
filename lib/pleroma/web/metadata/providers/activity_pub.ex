# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2024 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Metadata.Providers.ActivityPub do
  alias Pleroma.User
  alias Pleroma.Web.Metadata.Providers.Provider

  require Pleroma.Constants

  @behaviour Provider

  @impl Provider
  def build_tags(%{
        object: %{data: %{"id" => object_id}},
        user: %User{local: true, nickname: nickname} = user
      })
      when is_binary(object_id) and is_binary(nickname) do
    activity_pub_links(object_id) ++
      [{:meta, [name: "fediverse:creator", content: "@#{User.full_nickname(user)}"], []}]
  end

  @impl Provider
  def build_tags(%{object: %{data: %{"id" => object_id}}}) when is_binary(object_id) do
    activity_pub_links(object_id)
  end

  @impl Provider
  def build_tags(%{user: %{ap_id: ap_id}}) when is_binary(ap_id) do
    activity_pub_links(ap_id)
  end

  @impl Provider
  def build_tags(_), do: []

  defp activity_pub_links(href) do
    [
      {:link, [rel: "alternate", type: "application/activity+json", href: href], []},
      {:link,
       [
         rel: "alternate",
         type: Pleroma.Constants.activity_json_canonical_mime_type(),
         href: href
       ], []}
    ]
  end
end
