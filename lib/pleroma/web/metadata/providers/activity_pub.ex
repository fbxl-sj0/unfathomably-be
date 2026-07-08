# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2024 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Metadata.Providers.ActivityPub do
  alias Pleroma.Web.Metadata.Providers.Provider

  @behaviour Provider

  @impl Provider
  def build_tags(%{object: %{data: %{"id" => object_id}}}) when is_binary(object_id) do
    [{:link, [rel: "alternate", type: "application/activity+json", href: object_id], []}]
  end

  @impl Provider
  def build_tags(%{user: %{ap_id: ap_id}}) when is_binary(ap_id) do
    [{:link, [rel: "alternate", type: "application/activity+json", href: ap_id], []}]
  end

  @impl Provider
  def build_tags(_), do: []
end
