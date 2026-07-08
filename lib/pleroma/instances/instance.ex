# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Instances.Instance do
  @moduledoc "Instance."

  alias Pleroma.Config
  alias Pleroma.Instances
  alias Pleroma.Instances.Cache, as: InstanceCache
  alias Pleroma.Instances.Instance
  alias Pleroma.Maps
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Workers.DeleteWorker

  use Ecto.Schema

  import Ecto.Query
  import Ecto.Changeset

  require Logger

  schema "instances" do
    field(:host, :string)
    field(:unreachable_since, :naive_datetime_usec)
    field(:favicon, :string)
    field(:favicon_updated_at, :naive_datetime)

    embeds_one :metadata, Pleroma.Instances.Metadata, primary_key: false, on_replace: :update do
      field(:software_name, :string)
      field(:software_version, :string)
      field(:software_repository, :string)
      field(:failure_count, :integer, default: 0)
      field(:last_failure_at, :utc_datetime)
      field(:last_failure_reason, :string)
      field(:last_success_at, :utc_datetime)
      field(:last_status, :string)
      field(:backoff_until, :utc_datetime)
      field(:redirect_target, :string)
      field(:gone_at, :utc_datetime)
    end

    field(:metadata_updated_at, :utc_datetime)

    timestamps()
  end

  defdelegate host(url_or_host), to: Instances

  def changeset(struct, params \\ %{}) do
    struct
    |> cast(params, __schema__(:fields) -- [:metadata])
    |> cast_embed(:metadata, with: &metadata_changeset/2)
    |> validate_required([:host])
    |> unique_constraint(:host)
  end

  def metadata_changeset(struct, params \\ %{}) do
    struct
    |> cast(params, [
      :software_name,
      :software_version,
      :software_repository,
      :failure_count,
      :last_failure_at,
      :last_failure_reason,
      :last_success_at,
      :last_status,
      :backoff_until,
      :redirect_target,
      :gone_at
    ])
  end

  def filter_reachable([]), do: %{}

  def filter_reachable(urls_or_hosts) when is_list(urls_or_hosts) do
    case InstanceCache.filter_reachable(urls_or_hosts) do
      {:ok, result} ->
        result

      :error ->
        hosts =
          urls_or_hosts
          |> Enum.map(&(&1 && host(&1)))
          |> Enum.filter(&(to_string(&1) != ""))

        unreachable_hosts =
          Repo.all(
            from(i in Instance,
              where: i.host in ^hosts,
              select: {i.host, i.unreachable_since}
            )
          )

        unreachable_since_by_host = Map.new(unreachable_hosts, & &1)

        reachability_datetime_threshold = Instances.reachability_datetime_threshold()

        for entry <- Enum.filter(urls_or_hosts, &is_binary/1) do
          host = host(entry)
          unreachable_since = unreachable_since_by_host[host]

          if !unreachable_since ||
               NaiveDateTime.compare(unreachable_since, reachability_datetime_threshold) == :gt do
            {entry, unreachable_since}
          end
        end
        |> Enum.filter(& &1)
        |> Map.new(& &1)
    end
  end

  def reachable?(url_or_host) when is_binary(url_or_host) do
    case InstanceCache.reachable?(url_or_host) do
      {:ok, reachable?} ->
        reachable?

      :error ->
        reachable_from_database?(url_or_host)
    end
  end

  def reachable?(_), do: true

  defp reachable_from_database?(url_or_host) do
    with host when is_binary(host) <- host(url_or_host) do
      not Repo.exists?(
        from(i in Instance,
          where:
            i.host == ^host and
              i.unreachable_since <= ^Instances.reachability_datetime_threshold()
        )
      )
    else
      _ -> true
    end
  end

  def dormant?(url_or_host) when is_binary(url_or_host) do
    case InstanceCache.dormant?(url_or_host) do
      {:ok, dormant?} ->
        dormant?

      :error ->
        Repo.exists?(
          from(i in Instance,
            where:
              i.host == ^host(url_or_host) and
                i.unreachable_since <= ^Instances.dormant_datetime_threshold()
          )
        )
    end
  end

  def dormant?(_), do: false

  def any_dormant? do
    case InstanceCache.any_dormant?() do
      {:ok, any_dormant?} ->
        any_dormant?

      :error ->
        Repo.exists?(
          from(i in Instance,
            where: i.unreachable_since <= ^Instances.dormant_datetime_threshold()
          )
        )
    end
  end

  def set_reachable(url_or_host) when is_binary(url_or_host) do
    host = host(url_or_host)

    with {:ok, instance} <-
           %Instance{host: host}
           |> changeset(%{unreachable_since: nil})
           |> Repo.insert(on_conflict: {:replace, [:unreachable_since]}, conflict_target: :host) do
      Pleroma.Workers.ReachabilityWorker.delete_jobs_for_host(host)
      InstanceCache.sync(instance)
      {:ok, instance}
    end
  end

  def set_reachable(_), do: {:error, nil}

  def record_success(url_or_host, opts \\ [])

  def record_success(url_or_host, opts) when is_binary(url_or_host) do
    update_instance_health(url_or_host, opts, fn instance, now ->
      %{
        unreachable_since: nil,
        metadata:
          merge_metadata(instance, %{
            failure_count: 0,
            last_success_at: now,
            last_status: metadata_status(opts, "reachable"),
            backoff_until: nil,
            redirect_target: nil,
            gone_at: nil
          })
      }
    end)
  end

  def record_success(_, _), do: {:error, nil}

  def record_failure(url_or_host, reason \\ :failure, opts \\ [])

  def record_failure(url_or_host, reason, opts) when is_binary(url_or_host) do
    update_instance_health(url_or_host, opts, fn instance, now ->
      failure_count = metadata_integer(instance, :failure_count) + 1

      %{
        unreachable_since: instance.unreachable_since || DateTime.to_naive(now),
        metadata:
          merge_metadata(instance, %{
            failure_count: failure_count,
            last_failure_at: now,
            last_failure_reason: metadata_reason(reason, opts),
            last_status: metadata_status(opts, "unreachable"),
            backoff_until: backoff_until(now, failure_count)
          })
      }
    end)
  end

  def record_failure(_, _, _), do: {:error, nil}

  def record_redirect(url_or_host, target, opts \\ [])

  def record_redirect(url_or_host, target, opts)
      when is_binary(url_or_host) and is_binary(target) do
    update_instance_health(url_or_host, opts, fn instance, now ->
      %{
        unreachable_since: nil,
        metadata:
          merge_metadata(instance, %{
            failure_count: 0,
            last_success_at: now,
            last_status: metadata_status(opts, "redirect"),
            backoff_until: nil,
            redirect_target: target,
            gone_at: nil
          })
      }
    end)
  end

  def record_redirect(_, _, _), do: {:error, nil}

  def record_gone(url_or_host, opts \\ [])

  def record_gone(url_or_host, opts) when is_binary(url_or_host) do
    update_instance_health(url_or_host, opts, fn instance, now ->
      failure_count = metadata_integer(instance, :failure_count) + 1

      %{
        metadata:
          merge_metadata(instance, %{
            failure_count: failure_count,
            last_failure_at: now,
            last_failure_reason: metadata_reason(:gone, opts),
            last_status: metadata_status(opts, "gone"),
            gone_at: now,
            backoff_until: backoff_until(now, failure_count)
          })
      }
    end)
  end

  def record_gone(_, _), do: {:error, nil}

  def set_unreachable(url_or_host, unreachable_since \\ nil)

  def set_unreachable(url_or_host, unreachable_since) when is_binary(url_or_host) do
    unreachable_since = parse_datetime(unreachable_since) || NaiveDateTime.utc_now()
    host = host(url_or_host)

    with normalized_host when is_binary(normalized_host) <- host do
      existing_record = Repo.get_by(Instance, %{host: normalized_host})
      changes = %{unreachable_since: unreachable_since}

      result =
        cond do
          is_nil(existing_record) ->
            %Instance{}
            |> changeset(Map.put(changes, :host, normalized_host))
            |> insert_unreachable(normalized_host, unreachable_since)

          existing_record.unreachable_since &&
              NaiveDateTime.compare(existing_record.unreachable_since, unreachable_since) != :gt ->
            {:ok, existing_record}

          true ->
            existing_record
            |> changeset(changes)
            |> Repo.update()
        end

      tap_cache_update(result)
    else
      _ -> {:error, nil}
    end
  end

  def set_unreachable(_, _), do: {:error, nil}

  defp insert_unreachable(changeset, host, unreachable_since) do
    case Repo.insert(changeset) do
      {:error, %Ecto.Changeset{} = changeset} = error ->
        if instance_unique_host_error?(changeset) do
          set_unreachable(host, unreachable_since)
        else
          error
        end

      result ->
        result
    end
  rescue
    e in Ecto.ConstraintError ->
      if instance_unique_host_error?(e) do
        set_unreachable(host, unreachable_since)
      else
        reraise e, __STACKTRACE__
      end
  end

  def get_consistently_unreachable do
    reachability_datetime_threshold = Instances.reachability_datetime_threshold()

    query =
      from(i in Instance,
        where: ^reachability_datetime_threshold > i.unreachable_since,
        order_by: i.unreachable_since
      )

    query
    |> Repo.all()
    |> Enum.filter(&backoff_due?/1)
    |> Enum.map(&{&1.host, &1.unreachable_since})
  end

  def backoff_due?(%Instance{} = instance) do
    case metadata_value(instance, :backoff_until) do
      %DateTime{} = backoff_until ->
        DateTime.compare(backoff_until, DateTime.utc_now()) != :gt

      _ ->
        true
    end
  end

  defp parse_datetime(datetime) when is_binary(datetime) do
    case NaiveDateTime.from_iso8601(datetime) do
      {:ok, datetime} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(datetime), do: datetime

  defp instance_unique_host_error?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {:host, {_message, opts}} ->
        Keyword.get(opts, :constraint_name) == "instances_host_index" or
          Keyword.get(opts, :constraint) == :unique

      _ ->
        false
    end)
  end

  defp instance_unique_host_error?(%Ecto.ConstraintError{constraint: "instances_host_index"}),
    do: true

  defp instance_unique_host_error?(_), do: false

  defp update_instance_health(url_or_host, opts, fun) when is_function(fun, 2) do
    with host when is_binary(host) <- normalize_host(url_or_host) do
      instance = Repo.get_by(Instance, %{host: host}) || %Instance{host: host}
      changes = fun.(instance, now())

      instance
      |> changeset(Map.put_new(changes, :host, host))
      |> insert_or_update()
      |> tap_cache_update()
      |> tap_log_health_update(host, opts)
    else
      _ -> {:error, nil}
    end
  end

  defp insert_or_update(%Ecto.Changeset{data: %Instance{id: nil}} = changeset),
    do: Repo.insert(changeset)

  defp insert_or_update(changeset), do: Repo.update(changeset)

  defp tap_log_health_update({:ok, instance} = result, host, opts) do
    if Keyword.get(opts, :log, false) do
      Logger.debug("Recorded instance health for #{host}: #{inspect(instance.metadata)}")
    end

    result
  end

  defp tap_log_health_update(result, _host, _opts), do: result

  defp tap_cache_update({:ok, %Instance{} = instance} = result) do
    InstanceCache.sync(instance)
    result
  end

  defp tap_cache_update(result), do: result

  defp normalize_host(url_or_host) when is_binary(url_or_host) do
    case host(url_or_host) do
      host when is_binary(host) ->
        host
        |> String.trim()
        |> String.downcase()
        |> case do
          "" -> nil
          host -> host
        end

      _ ->
        nil
    end
  end

  defp merge_metadata(%Instance{} = instance, changes) do
    instance
    |> metadata_map()
    |> Map.merge(changes)
  end

  defp metadata_map(%Instance{metadata: nil}), do: %{}
  defp metadata_map(%Instance{metadata: metadata}), do: Map.from_struct(metadata)

  defp metadata_integer(%Instance{} = instance, key) do
    case metadata_value(instance, key) do
      value when is_integer(value) -> value
      _ -> 0
    end
  end

  defp metadata_value(%Instance{metadata: nil}, _key), do: nil
  defp metadata_value(%Instance{metadata: metadata}, key), do: Map.get(metadata, key)

  defp metadata_status(opts, default) do
    opts
    |> Keyword.get(:status, default)
    |> to_string()
  end

  defp metadata_reason(reason, opts) do
    source = Keyword.get(opts, :source)

    [source, reason]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.join(":")
  end

  defp backoff_until(now, failure_count) do
    minutes =
      reachability_backoff_base_minutes()
      |> Kernel.*(:math.pow(2, max(failure_count - 1, 0)))
      |> round()
      |> min(reachability_backoff_max_minutes())

    DateTime.add(now, minutes * 60, :second)
  end

  defp reachability_backoff_base_minutes do
    Config.get([:instances, :reachability_backoff_base_minutes], 15)
    |> normalize_positive_integer(15)
  end

  defp reachability_backoff_max_minutes do
    Config.get([:instances, :reachability_backoff_max_minutes], 1_440)
    |> normalize_positive_integer(1_440)
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _ -> default
    end
  end

  defp normalize_positive_integer(_, default), do: default

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  def get_or_update_favicon(%URI{host: host} = instance_uri) do
    existing_record = Repo.get_by(Instance, %{host: host})
    now = NaiveDateTime.utc_now()

    if existing_record && existing_record.favicon_updated_at &&
         NaiveDateTime.diff(now, existing_record.favicon_updated_at) < 86_400 do
      existing_record.favicon
    else
      favicon = scrape_favicon(instance_uri)

      if existing_record do
        existing_record
        |> changeset(%{favicon: favicon, favicon_updated_at: now})
        |> Repo.update()
      else
        %Instance{}
        |> changeset(%{host: host, favicon: favicon, favicon_updated_at: now})
        |> Repo.insert()
      end

      favicon
    end
  rescue
    e ->
      Logger.warning("Instance.get_or_update_favicon(\"#{host}\") error: #{inspect(e)}")
      nil
  catch
    :exit, reason ->
      Logger.warning("Instance.get_or_update_favicon(\"#{host}\") exit: #{inspect(reason)}")
      nil
  end

  defp scrape_favicon(%URI{} = instance_uri) do
    try do
      with {_, true} <- {:reachable, reachable_from_database?(instance_uri.host)},
           {:ok, %Tesla.Env{body: html}} <-
             Pleroma.HTTP.get(to_string(instance_uri), [{"accept", "text/html"}], pool: :media),
           {_, [favicon_rel | _]} when is_binary(favicon_rel) <-
             {:parse,
              html |> Floki.parse_document!() |> Floki.attribute("link[rel=icon]", "href")},
           {_, favicon} when is_binary(favicon) <-
             {:merge, to_string(URI.merge(instance_uri, favicon_rel))} do
        favicon
      else
        {:reachable, false} ->
          Logger.debug(
            "Instance.scrape_favicon(\"#{to_string(instance_uri)}\") ignored unreachable host"
          )

          nil

        _ ->
          nil
      end
    rescue
      e ->
        Logger.warning(
          "Instance.scrape_favicon(\"#{to_string(instance_uri)}\") error: #{inspect(e)}"
        )

        nil
    catch
      :exit, reason ->
        Logger.warning(
          "Instance.scrape_favicon(\"#{to_string(instance_uri)}\") exit: #{inspect(reason)}"
        )

        nil
    end
  end

  def get_or_update_metadata(%URI{host: host} = instance_uri) do
    existing_record = Repo.get_by(Instance, %{host: host})
    now = NaiveDateTime.utc_now()

    if fresh_metadata?(existing_record, now) do
      existing_record.metadata
    else
      metadata =
        case scrape_metadata(instance_uri) do
          nil -> existing_metadata(existing_record)
          metadata -> metadata
        end

      if existing_record do
        existing_record
        |> changeset(%{metadata: metadata, metadata_updated_at: now})
        |> Repo.update()
      else
        %Instance{}
        |> changeset(%{host: host, metadata: metadata, metadata_updated_at: now})
        |> Repo.insert()
      end

      metadata
    end
  end

  defp existing_metadata(%Instance{metadata: metadata}), do: metadata
  defp existing_metadata(_), do: nil

  defp fresh_metadata?(%Instance{metadata: metadata, metadata_updated_at: updated_at}, now)
       when not is_nil(updated_at) do
    metadata_has_software?(metadata) and NaiveDateTime.diff(now, updated_at) < 86_400
  end

  defp fresh_metadata?(_, _), do: false

  defp metadata_has_software?(metadata) do
    metadata
    |> metadata_software_name()
    |> case do
      name when is_binary(name) -> String.trim(name) != ""
      _ -> false
    end
  end

  defp metadata_software_name(%{} = metadata) do
    Map.get(metadata, :software_name) || Map.get(metadata, "software_name")
  end

  defp metadata_software_name(_), do: nil

  defp get_nodeinfo_uri(well_known) do
    links = Map.get(well_known, "links", [])

    [
      "http://nodeinfo.diaspora.software/ns/schema/2.1",
      "https://nodeinfo.diaspora.software/ns/schema/2.1",
      "http://nodeinfo.diaspora.software/ns/schema/2.0",
      "https://nodeinfo.diaspora.software/ns/schema/2.0"
    ]
    |> Enum.find_value(&nodeinfo_href_for_rel(links, &1))
    |> case do
      href when is_binary(href) ->
        {:ok, href}

      _ ->
        links
        |> Enum.find_value(&nodeinfo_href/1)
        |> case do
          href when is_binary(href) -> {:ok, href}
          _ -> {:error, :no_links}
        end
    end
  end

  defp nodeinfo_href_for_rel(links, rel) do
    links
    |> Enum.find_value(fn
      %{"rel" => ^rel} = link -> nodeinfo_href(link)
      _ -> nil
    end)
  end

  defp nodeinfo_href(%{"href" => href}) when is_binary(href) do
    if String.contains?(String.downcase(href), "nodeinfo") do
      href
    end
  end

  defp nodeinfo_href(_), do: nil

  defp scrape_metadata(%URI{} = instance_uri) do
    try do
      with {_, true} <- {:reachable, reachable_from_database?(instance_uri.host)},
           {:ok, %Tesla.Env{body: well_known_body}} <-
             instance_uri
             |> URI.merge("/.well-known/nodeinfo")
             |> to_string()
             |> Pleroma.HTTP.get([{"accept", "application/json"}]),
           {:ok, well_known_json} <- Jason.decode(well_known_body),
           {:ok, nodeinfo_uri} <- get_nodeinfo_uri(well_known_json),
           {:ok, %Tesla.Env{body: nodeinfo_body}} <-
             Pleroma.HTTP.get(nodeinfo_uri, [{"accept", "application/json"}]),
           {:ok, nodeinfo} <- Jason.decode(nodeinfo_body) do
        # Can extract more metadata from NodeInfo but need to be careful about it's size,
        # can't just dump the entire thing
        software = Map.get(nodeinfo, "software", %{})

        %{
          software_name: software["name"],
          software_version: software["version"]
        }
        |> Maps.put_if_present(:software_repository, software["repository"])
      else
        {:reachable, false} ->
          Logger.debug(
            "Instance.scrape_metadata(\"#{to_string(instance_uri)}\") ignored unreachable host"
          )

          nil

        _ ->
          nil
      end
    rescue
      e ->
        Logger.warning(
          "Instance.scrape_metadata(\"#{to_string(instance_uri)}\") error: #{inspect(e)}"
        )

        nil
    end
  end

  @doc """
  Deletes all users from an instance in a background task, thus also deleting
  all of those users' activities and notifications.
  """
  def delete_users_and_activities(host) when is_binary(host) do
    DeleteWorker.enqueue("delete_instance", %{"host" => host})
  end

  def perform(:delete_instance, host) when is_binary(host) do
    query = User.Query.build(%{nickname: "@#{host}"})

    query
    |> Repo.chunk_stream(100, :batches)
    |> Stream.each(fn users ->
      users
      |> Enum.each(fn user ->
        User.perform(:delete, user)
      end)
    end)
    |> Stream.run()

    Repo.delete_all(from(i in Instance, where: i.host == ^host))
    Pleroma.Workers.ReachabilityWorker.delete_jobs_for_host(host)
    InstanceCache.sync(host, nil)
  end
end
