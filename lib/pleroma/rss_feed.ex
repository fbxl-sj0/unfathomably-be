# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.RSSFeed do
  @moduledoc """
  Imports RSS and Atom feeds as read-only source actors.

  RSS feeds are not ActivityPub actors and do not have inboxes.  The instance
  therefore represents each followed feed as a synthetic remote Service actor
  and stores feed entries as cached remote Article objects from that actor.  The
  entries can be boosted, quoted, liked, and shown in timelines like ordinary
  remote posts, but no reply is sent back to the original feed.
  """

  import Ecto.Query
  import SweetXml

  alias Pleroma.Activity
  alias Pleroma.Config
  alias Pleroma.FollowingRelationship
  alias Pleroma.HTML
  alias Pleroma.HTTP
  alias Pleroma.Maps
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Workers.RSSFeedWorker

  require Logger
  require Pleroma.Constants

  @rss_tag "rss_feed"
  @feed_accept "application/rss+xml, application/atom+xml, application/xml, text/xml, */*;q=0.1"
  @default_batch_size 100
  @default_import_limit 20
  @default_refresh_interval_minutes 30
  @max_url_bytes 2048

  def rss_tag, do: @rss_tag

  def enabled? do
    Config.get([__MODULE__, :enabled], true)
  end

  def rss_source?(%User{tags: tags}) when is_list(tags), do: @rss_tag in tags
  def rss_source?(_), do: false

  def resolve(identifier) do
    with true <- enabled?(),
         {:ok, url} <- normalize_feed_url(identifier),
         {:ok, feed} <- fetch_feed(url),
         {:ok, %User{} = source} <- upsert_source(url, feed) do
      {:ok, source}
    else
      _ -> {:error, :not_found}
    end
  end

  def import_source(%User{} = source, opts \\ []) do
    if rss_source?(source) do
      do_import_source(source, opts)
    else
      {:error, :not_rss_feed}
    end
  end

  def local_items(%User{} = source, limit) do
    source.ap_id
    |> source_activities_query()
    |> Activity.with_preloaded_object(:left)
    |> limit(^limit)
    |> Repo.all()
  end

  def schedule_refreshes do
    if enabled?() do
      refreshable_sources()
      |> Enum.map(&RSSFeedWorker.enqueue/1)
      |> Enum.count(fn
        {:ok, _job} -> true
        _ -> false
      end)
    else
      0
    end
  end

  defp do_import_source(%User{} = source, opts) do
    limit = Keyword.get(opts, :limit, import_limit())

    with {:ok, feed} <- fetch_feed(source.ap_id),
         entries <- feed.entries |> Enum.take(limit) |> Enum.reverse(),
         imported <- Enum.reduce(entries, 0, &import_entry(source, &1, &2)),
         {:ok, _source} <- touch_source(source, feed) do
      {:ok, %{imported: imported, checked: length(entries)}}
    end
  end

  defp fetch_feed(url) do
    headers = [{"accept", @feed_accept}]

    with {:ok, %{status: status, body: body}} when status in 200..299 <-
           HTTP.get(url, headers, recv_timeout: :timer.seconds(10)),
         {:ok, feed} <- parse_feed(body, url) do
      {:ok, feed}
    else
      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      error ->
        error
    end
  rescue
    error ->
      {:error, error}
  catch
    _, error ->
      {:error, error}
  end

  defp parse_feed(body, url) when is_binary(body) do
    doc = SweetXml.parse(body, dtd: :none)

    rss_items =
      xpath(doc, ~x"/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='item']"l)

    atom_entries = xpath(doc, ~x"/*[local-name()='feed']/*[local-name()='entry']"l)

    entries =
      cond do
        rss_items != [] -> Enum.map(rss_items, &rss_entry(&1, url))
        atom_entries != [] -> Enum.map(atom_entries, &atom_entry(&1, url))
        true -> []
      end
      |> Enum.reject(&is_nil/1)

    if entries == [] do
      {:error, :invalid_feed}
    else
      {:ok,
       %{
         title: feed_title(doc),
         description: feed_description(doc),
         home_url: feed_home_url(doc, url),
         entries: entries
       }}
    end
  rescue
    _ -> {:error, :invalid_feed}
  catch
    _, _ -> {:error, :invalid_feed}
  end

  defp parse_feed(_, _), do: {:error, :invalid_feed}

  defp rss_entry(node, feed_url) do
    title = xpath_text(node, ~x"./*[local-name()='title']/text()"s)
    link = absolute_url(feed_url, xpath_text(node, ~x"./*[local-name()='link']/text()"s))
    guid = xpath_text(node, ~x"./*[local-name()='guid']/text()"s)
    published = xpath_text(node, ~x"./*[local-name()='pubDate']/text()"s)

    content =
      xpath_text(node, ~x"./*[local-name()='encoded']/text()"s) ||
        xpath_text(node, ~x"./*[local-name()='description']/text()"s)

    entry(title, link, guid, content, published)
  end

  defp atom_entry(node, feed_url) do
    title = xpath_text(node, ~x"./*[local-name()='title']/text()"s)
    link = atom_entry_link(node, feed_url)
    id = xpath_text(node, ~x"./*[local-name()='id']/text()"s)

    published =
      xpath_text(node, ~x"./*[local-name()='published']/text()"s) ||
        xpath_text(node, ~x"./*[local-name()='updated']/text()"s)

    content =
      xpath_text(node, ~x"./*[local-name()='content']/text()"s) ||
        xpath_text(node, ~x"./*[local-name()='summary']/text()"s)

    entry(title, link, id, content, published)
  end

  defp entry(title, link, external_id, content, published) do
    title = present_string(title) || present_string(strip_html(content)) || "Untitled feed item"
    external_id = present_string(external_id) || present_string(link) || title

    if present_string(external_id) do
      %{
        title: title,
        link: link,
        external_id: external_id,
        content: content,
        published: published
      }
    end
  end

  defp feed_title(doc) do
    xpath_text(
      doc,
      ~x"/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='title']/text()"s
    ) ||
      xpath_text(doc, ~x"/*[local-name()='feed']/*[local-name()='title']/text()"s) ||
      "RSS feed"
  end

  defp feed_description(doc) do
    xpath_text(
      doc,
      ~x"/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='description']/text()"s
    ) ||
      xpath_text(doc, ~x"/*[local-name()='feed']/*[local-name()='subtitle']/text()"s) ||
      ""
  end

  defp feed_home_url(doc, feed_url) do
    rss_link =
      xpath_text(
        doc,
        ~x"/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='link']/text()"s
      )

    atom_link =
      doc
      |> xpath(
        ~x"/*[local-name()='feed']/*[local-name()='link'][@rel='alternate' or not(@rel)]/@href"s
      )
      |> present_string()

    absolute_url(feed_url, rss_link || atom_link) || feed_url
  end

  defp atom_entry_link(node, feed_url) do
    href =
      node
      |> xpath(~x"./*[local-name()='link'][@rel='alternate' or not(@rel)]/@href"s)
      |> present_string()

    absolute_url(feed_url, href)
  end

  defp xpath_text(node, path) do
    node
    |> xpath(path)
    |> present_string()
  end

  defp absolute_url(_base_url, nil), do: nil

  defp absolute_url(base_url, url) when is_binary(url) do
    url = String.trim(url)

    cond do
      url == "" ->
        nil

      valid_http_url?(url) ->
        url

      true ->
        base_url
        |> URI.merge(url)
        |> to_string()
    end
  rescue
    _ -> nil
  end

  defp upsert_source(url, feed) do
    attrs = source_attrs(url, feed)

    case User.get_cached_by_ap_id(url) do
      %User{} = source ->
        source
        |> User.remote_user_changeset(attrs)
        |> User.update_and_set_cache()

      _ ->
        %User{local: false}
        |> User.remote_user_changeset(attrs)
        |> Repo.insert()
        |> User.set_cache()
    end
  end

  defp source_attrs(url, feed) do
    host = URI.parse(url).host || "feed.invalid"

    %{
      ap_id: url,
      uri: feed.home_url || url,
      nickname: source_nickname(url, host),
      name: feed.title,
      bio: feed.description,
      actor_type: "Service",
      inbox: nil,
      shared_inbox: nil,
      follower_address: url <> "#followers",
      following_address: url <> "#following",
      is_discoverable: true,
      tags: [@rss_tag]
    }
  end

  defp source_nickname(url, host) do
    local =
      url
      |> sha256()
      |> binary_part(0, 16)

    "rss-#{local}@#{host}"
  end

  defp import_entry(%User{} = source, entry, count) do
    object_id = entry_object_id(source.ap_id, entry)

    if Activity.get_create_by_object_ap_id_with_object(object_id) do
      count
    else
      object = entry_object(source, entry, object_id)
      published = parse_datetime(entry.published)

      params =
        %{
          actor: source,
          context: object_id,
          object: object,
          to: [source.follower_address],
          local: false,
          additional: %{"cc" => [Pleroma.Constants.as_public()]}
        }
        |> Maps.put_if_present(:published, published)

      case ActivityPub.create(params) do
        {:ok, _activity} ->
          count + 1

        {:error, reason} ->
          Logger.debug("RSS feed entry import failed for #{object_id}: #{inspect(reason)}")
          count
      end
    end
  end

  defp entry_object(%User{} = source, entry, object_id) do
    content = entry_content(entry)

    %{
      "id" => object_id,
      "type" => "Article",
      "actor" => source.ap_id,
      "attributedTo" => source.ap_id,
      "to" => [source.follower_address],
      "cc" => [Pleroma.Constants.as_public()],
      "context" => object_id,
      "name" => entry.title,
      "content" => content,
      "source" => %{"content" => strip_html(content), "mediaType" => "text/plain"}
    }
    |> Maps.put_if_present("url", entry.link)
    |> Maps.put_if_present("published", parse_datetime(entry.published))
  end

  defp entry_content(entry) do
    content =
      entry.content ||
        entry.title ||
        entry.link ||
        "Untitled feed item"

    content
    |> normalize_content()
    |> truncate_content()
  end

  defp normalize_content(content) do
    content = String.trim(to_string(content))

    if String.contains?(content, "<") do
      content
    else
      "<p>#{escape_html(content)}</p>"
    end
  end

  defp truncate_content(content) do
    limit = Config.get([:instance, :remote_limit], 100_000) || 100_000

    if String.length(content) > limit do
      String.slice(content, 0, limit)
    else
      content
    end
  end

  defp entry_object_id(feed_url, entry) do
    feed_url <> "#entry-" <> sha256(entry.external_id)
  end

  defp touch_source(%User{} = source, feed) do
    attrs =
      source.ap_id
      |> source_attrs(feed)
      |> Map.put(:last_refreshed_at, NaiveDateTime.utc_now())

    source
    |> User.remote_user_changeset(attrs)
    |> User.update_and_set_cache()
  end

  defp refreshable_sources do
    cutoff =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-refresh_interval_minutes() * 60, :second)

    User
    |> join(:inner, [u], r in FollowingRelationship,
      on: r.following_id == u.id and r.state == ^:follow_accept
    )
    |> where([u], u.local == false)
    |> where([u], u.is_active == true)
    |> where([u], u.invisible == false)
    |> where([u], fragment("? && ?", u.tags, ^[@rss_tag]))
    |> where([u], is_nil(u.last_refreshed_at) or u.last_refreshed_at < ^cutoff)
    |> distinct([u], u.id)
    |> limit(^batch_size())
    |> Repo.all()
  end

  defp source_activities_query(ap_id) do
    Activity
    |> where([a], a.actor == ^ap_id)
    |> where([a], fragment("?->>'type' = 'Create'", a.data))
    |> order_by([a], desc: a.updated_at)
  end

  defp normalize_feed_url(identifier) when is_binary(identifier) do
    identifier = String.trim(identifier)

    with true <- byte_size(identifier) <= @max_url_bytes,
         %URI{scheme: scheme, host: host} = uri
         when scheme in ["http", "https"] and is_binary(host) <-
           URI.parse(identifier),
         true <- is_nil(uri.userinfo),
         true <- safe_path?(uri.path),
         url <- %{uri | fragment: nil} |> URI.to_string(),
         true <- valid_http_url?(url) do
      {:ok, url}
    else
      _ -> {:error, :invalid_url}
    end
  end

  defp normalize_feed_url(_), do: {:error, :invalid_url}

  defp valid_http_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        true

      _ ->
        false
    end
  end

  defp valid_http_url?(_), do: false

  defp safe_path?(path) when is_binary(path), do: not String.contains?(path, "..")
  defp safe_path?(_), do: true

  defp parse_datetime(value) when is_binary(value) do
    value = String.trim(value)

    with {:ok, datetime} <- parse_datetime_value(value) do
      DateTime.to_iso8601(datetime)
    else
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp parse_datetime_value(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      _ ->
        with {:ok, datetime} <- Timex.parse(value, "{RFC1123}") do
          {:ok, Timex.to_datetime(datetime)}
        end
    end
  end

  defp present_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp present_string(_), do: nil

  defp strip_html(value) when is_binary(value), do: HTML.strip_tags(value)
  defp strip_html(_), do: nil

  defp escape_html(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp sha256(value) do
    value
    |> to_string()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp import_limit do
    Config.get([__MODULE__, :import_limit], @default_import_limit)
  end

  defp refresh_interval_minutes do
    Config.get([__MODULE__, :refresh_interval_minutes], @default_refresh_interval_minutes)
  end

  defp batch_size do
    Config.get([__MODULE__, :batch_size], @default_batch_size)
  end
end
