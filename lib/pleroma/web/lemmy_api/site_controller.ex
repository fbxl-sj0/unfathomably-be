# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.LemmyAPI.SiteController do
  @moduledoc """
  Exposes bounded Lemmy-compatible site metadata for community discovery.

  Unfathomably remains an ActivityPub-first server and does not implement the
  Lemmy administration or authentication APIs. The explicit compatibility
  marker prevents discovery consumers from treating this projection as proof
  of a complete Lemmy HTTP API.
  """

  use Pleroma.Web, :controller

  alias Pleroma.Config
  alias Pleroma.Stats
  alias Pleroma.Web.Endpoint
  alias Pleroma.Web.WebFinger

  plug(:skip_auth)

  def show(conn, _params) do
    instance = Config.get(:instance, [])
    global_stats = Stats.get_stats()
    site_stats = Stats.get_compatibility_site_stats()
    published = format_datetime(site_stats.published_at)
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    endpoint = Endpoint.url()
    registrations_open = Keyword.get(instance, :registrations_open, false)
    approval_required = Keyword.get(instance, :account_approval_required, false)

    json(conn, %{
      "admins" => [],
      "all_languages" => [%{"id" => 0, "code" => "und", "name" => "Undetermined"}],
      "blocked_urls" => [],
      "custom_emojis" => [],
      "discussion_languages" => [0],
      "site_view" => %{
        "site" => %{
          "id" => 1,
          "name" => Keyword.get(instance, :name, WebFinger.domain()),
          "sidebar" => Keyword.get(instance, :description),
          "description" => Keyword.get(instance, :short_description),
          "published" => published,
          "actor_id" => endpoint,
          "last_refreshed_at" => now,
          "inbox_url" => endpoint <> "/inbox",
          "public_key" => "",
          "instance_id" => 1,
          "icon" => asset_url(Keyword.get(instance, :instance_thumbnail))
        },
        "local_site" => local_site(instance, published, registrations_open, approval_required),
        "local_site_rate_limit" => local_site_rate_limit(published),
        "counts" => %{
          "site_id" => 1,
          "users" => global_stats.user_count,
          "posts" => site_stats.posts,
          "comments" => site_stats.comments,
          "communities" => site_stats.communities,
          "users_active_day" => site_stats.users_active_day,
          "users_active_week" => site_stats.users_active_week,
          "users_active_month" => site_stats.users_active_month,
          "users_active_half_year" => site_stats.users_active_half_year
        }
      },
      "taglines" => [],
      "version" => Pleroma.Application.compat_version(),
      "unfathomably" => %{
        "compatibility" => "community_discovery",
        "write_api" => false
      }
    })
  end

  defp local_site(instance, published, registrations_open, approval_required) do
    %{
      "id" => 1,
      "site_id" => 1,
      "site_setup" => true,
      "enable_downvotes" => true,
      "enable_nsfw" => true,
      "community_creation_admin_only" => false,
      "require_email_verification" => Keyword.get(instance, :account_activation_required, false),
      "application_email_admins" => false,
      "private_instance" => false,
      "default_theme" => "browser",
      "default_post_listing_type" => "Local",
      "legal_information" => Keyword.get(instance, :terms_of_service),
      "hide_modlog_mod_names" => false,
      "actor_name_max_length" => 100,
      "federation_enabled" => Keyword.get(instance, :federating, true),
      "captcha_enabled" => Config.get([Pleroma.Captcha, :enabled], false),
      "captcha_difficulty" => "medium",
      "published" => published,
      "registration_mode" => registration_mode(registrations_open, approval_required),
      "reports_email_admins" => false,
      "federation_signed_fetch" => Config.get([:activitypub, :authorized_fetch_mode], false),
      "default_post_listing_mode" => "List",
      "default_sort_type" => "Active"
    }
  end

  # Lemmy requires its rate-limit object in SiteView. These values are only
  # compatibility hints; Pleroma's own request-specific limiters remain the
  # authority and the response advertises that the write API is unavailable.
  defp local_site_rate_limit(published) do
    %{
      "id" => 1,
      "local_site_id" => 1,
      "message" => 180,
      "message_per_second" => 60,
      "post" => 6,
      "post_per_second" => 600,
      "register" => 3,
      "register_per_second" => 3600,
      "image" => 6,
      "image_per_second" => 3600,
      "comment" => 6,
      "comment_per_second" => 600,
      "search" => 60,
      "search_per_second" => 600,
      "published" => published
    }
  end

  defp registration_mode(false, _approval_required), do: "Closed"
  defp registration_mode(true, true), do: "RequireApplication"
  defp registration_mode(true, false), do: "Open"

  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp format_datetime(%NaiveDateTime{} = datetime) do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp format_datetime(_unknown), do: "1970-01-01T00:00:00Z"

  defp asset_url(nil), do: nil

  defp asset_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["http", "https"] -> url
      _relative -> Endpoint.url() |> URI.merge(url) |> to_string()
    end
  rescue
    URI.Error -> nil
  end

  defp asset_url(_invalid), do: nil
end

# end of site_controller.ex
