# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Object.Fetcher do
  alias Pleroma.HTTP
  alias Pleroma.Instances
  alias Pleroma.Maps
  alias Pleroma.Object
  alias Pleroma.Object.Containment
  alias Pleroma.Signature
  alias Pleroma.Web.ActivityPub.InternalFetchActor
  alias Pleroma.Web.ActivityPub.MRF
  alias Pleroma.Web.ActivityPub.ObjectValidator
  alias Pleroma.Web.ActivityPub.Pipeline
  alias Pleroma.Web.ActivityPub.RemoteReplies
  alias Pleroma.Web.ActivityPub.Transmogrifier
  alias Pleroma.Web.Federator

  require Pleroma.Constants
  require Logger

  @activity_types ~w(Accept Add Announce Block Create Delete Dislike EmojiReact Flag Follow Join Leave Like Listen Move Reject Remove Undo Update)
  @activity_streams_profile "https://www.w3.org/ns/activitystreams"
  @object_fetch_accept_header Pleroma.Constants.activity_json_accept_header() <>
                                ", text/html;q=0.1"

  @spec reinject_object(struct(), map()) :: {:ok, Object.t()} | {:error, any()}
  defp reinject_object(%Object{data: %{}} = object, new_data) do
    Logger.debug("Reinjecting object #{new_data["id"]}")

    with {:ok, new_data, _} <- ObjectValidator.validate(new_data, %{}),
         {:ok, new_data} <- MRF.filter(new_data),
         {:ok, new_object, _} <-
           Object.Updater.do_update_and_invalidate_cache(
             object,
             new_data,
             _touch_changeset? = true
           ) do
      {:ok, new_object}
    else
      e ->
        Logger.error("Error while processing object: #{inspect(e)}")
        {:error, e}
    end
  end

  defp reinject_object(_, new_data) do
    with {:ok, object, _} <- Pipeline.common_pipeline(new_data, local: false) do
      {:ok, object}
    else
      e -> e
    end
  end

  def refetch_object(%Object{data: %{"id" => id}} = object) do
    with {:local, false} <- {:local, Object.local?(object)},
         {:ok, new_data} <- fetch_and_contain_remote_object_from_id(id),
         {:ok, object} <- reinject_object(object, new_data) do
      {:ok, object}
    else
      {:local, true} -> {:ok, object}
      e -> {:error, e}
    end
  end

  # Note: will create a Create activity, which we need internally at the moment.
  def fetch_object_from_id(id, options \\ []) do
    with {_, nil} <- {:fetch_object, Object.get_cached_by_ap_id(id)},
         {_, true} <- {:allowed_depth, Federator.allowed_thread_distance?(options[:depth])},
         {_, {:ok, data}} <- {:fetch, fetch_and_contain_remote_object_from_id(id)},
         data <- RemoteReplies.maybe_inline_reply_ids(data, options),
         {_, nil} <- {:normalize, Object.normalize(data, fetch: false)},
         params <- prepare_activity_params(data),
         {_, :ok} <- {:containment, Containment.contain_origin(id, params)},
         {_, {:ok, activity}} <-
           {:transmogrifier, Transmogrifier.handle_incoming(params, options)},
         {_, _data, %Object{} = object} <-
           {:object, data, Object.normalize(activity, fetch: false)} do
      {:ok, object}
    else
      {:allowed_depth, false} ->
        {:error, "Max thread distance exceeded."}

      {:containment, _} ->
        {:error, "Object containment failed."}

      {:transmogrifier, {:error, {:reject, e}}} ->
        {:reject, e}

      {:transmogrifier, {:reject, e}} ->
        {:reject, e}

      {:transmogrifier, _} = e ->
        {:error, e}

      {:object, data, nil} ->
        reinject_object(%Object{}, data)

      {:normalize, object = %Object{}} ->
        {:ok, object}

      {:fetch_object, %Object{} = object} ->
        {:ok, object}

      {:fetch, {:error, error}} ->
        {:error, error}

      e ->
        e
    end
  end

  defp prepare_activity_params(%{"type" => type} = data) when type in @activity_types, do: data

  defp prepare_activity_params(data) do
    actor = object_fetch_actor(data)
    object = put_object_fetch_actor(data, actor)

    %{
      "type" => "Create",
      "actor" => actor,
      "object" => object
    }
    |> Maps.put_if_present("to", data["to"])
    |> Maps.put_if_present("cc", data["cc"])
    |> Maps.put_if_present("bto", data["bto"])
    |> Maps.put_if_present("bcc", data["bcc"])
  end

  defp object_fetch_actor(%{"actor" => actor}) when is_binary(actor), do: actor

  defp object_fetch_actor(%{"actor" => %{"id" => actor}}) when is_binary(actor), do: actor

  defp object_fetch_actor(%{"actor" => actors}) when is_list(actors),
    do: actor_from_attributions(actors)

  defp object_fetch_actor(%{"attributedTo" => actor}) when is_binary(actor), do: actor

  defp object_fetch_actor(%{"attributedTo" => %{"id" => actor}}) when is_binary(actor), do: actor

  defp object_fetch_actor(%{"attributedTo" => attributions}) when is_list(attributions),
    do: actor_from_attributions(attributions)

  defp object_fetch_actor(data), do: Containment.get_actor(data)

  defp actor_from_attributions(attributions) do
    actor_from_attributions(attributions, ["Group"]) ||
      actor_from_attributions(attributions, ["Person", "Service", "Application"]) ||
      first_attribution_id(attributions)
  end

  defp actor_from_attributions(attributions, types) do
    Enum.find_value(attributions, fn
      %{"id" => id, "type" => type} when is_binary(id) ->
        if type in types, do: id

      _ ->
        nil
    end)
  end

  defp first_attribution_id(attributions) do
    Enum.find_value(attributions, fn
      id when is_binary(id) -> id
      %{"id" => id} when is_binary(id) -> id
      _ -> nil
    end)
  end

  defp put_object_fetch_actor(data, actor) when is_binary(actor) do
    data
    |> Map.put("actor", actor)
    |> Map.put("attributedTo", actor)
  end

  defp put_object_fetch_actor(data, _actor), do: data

  def fetch_object_from_id!(id, options \\ []) do
    with {:ok, object} <- fetch_object_from_id(id, options) do
      object
    else
      {:error, %Tesla.Mock.Error{}} ->
        nil

      {:error, "Object has been deleted"} ->
        nil

      {:reject, reason} ->
        Logger.info("Rejected #{id} while fetching: #{inspect(reason)}")
        nil

      e ->
        log_fetch_error(id, e)
        nil
    end
  end

  defp log_fetch_error(id, {:error, {:http, code}}) when code in [401, 403, 404, 410] do
    Logger.debug("Remote object #{id} returned HTTP #{code} while fetching")
  end

  defp log_fetch_error(id, {:error, {:transmogrifier, {:error, reason}}})
       when reason in [:actor_not_found, :object_not_found] do
    Logger.debug("Remote activity #{id} referenced unavailable #{reason} while fetching")
  end

  defp log_fetch_error(id, {:error, {:http, code}}) do
    Logger.warning("Remote object #{id} returned HTTP #{code} while fetching")
  end

  defp log_fetch_error(id, {:error, reason})
       when reason in [:closed, :timeout, :checkout_timeout] do
    Logger.info("Transient remote fetch failure for #{id}: #{inspect(reason)}")
  end

  defp log_fetch_error(id, e) do
    Logger.warning("Error while fetching #{id}: #{inspect(e)}")
  end

  defp make_signature(id, date) do
    uri = URI.parse(id)

    signature =
      InternalFetchActor.get_actor()
      |> Signature.sign(%{
        "(request-target)": "get #{request_target(uri)}",
        host: signature_host(uri),
        date: date
      })

    {"signature", signature}
  end

  defp request_target(%URI{path: path, query: query}) do
    path =
      case path do
        path when path in [nil, ""] -> "/"
        path -> path
      end

    case query do
      query when query in [nil, ""] -> path
      query -> "#{path}?#{query}"
    end
  end

  defp signature_host(%URI{host: host, port: port, scheme: scheme}) do
    if port == URI.default_port(scheme) do
      host
    else
      "#{host}:#{port}"
    end
  end

  defp sign_fetch(headers, id, date) do
    if Pleroma.Config.get([:activitypub, :sign_object_fetches]) do
      [make_signature(id, date) | headers]
    else
      headers
    end
  end

  defp maybe_date_fetch(headers, date) do
    if Pleroma.Config.get([:activitypub, :sign_object_fetches]) do
      [{"date", date} | headers]
    else
      headers
    end
  end

  def fetch_and_contain_remote_object_from_id(id)

  def fetch_and_contain_remote_object_from_id(%{"id" => id}),
    do: fetch_and_contain_remote_object_from_id(id)

  def fetch_and_contain_remote_object_from_id(id) when is_binary(id) do
    Logger.debug("Fetching object #{id} via AP")

    with {:scheme, true} <- {:scheme, String.starts_with?(id, "http")},
         {:ok, body} <- get_object(id),
         {:ok, data} <- safe_json_decode(body),
         :ok <- Containment.contain_origin_from_id(id, data) do
      if not Instances.reachable?(id) do
        Instances.set_reachable(id)
      end

      {:ok, data}
    else
      {:scheme, _} ->
        {:error, "Unsupported URI scheme"}

      {:error, e} ->
        {:error, e}

      e ->
        {:error, e}
    end
  end

  def fetch_and_contain_remote_object_from_id(_id),
    do: {:error, "id must be a string"}

  defp get_object(id, terminal? \\ false) do
    date = Pleroma.Signature.signed_date()

    headers =
      [{"accept", @object_fetch_accept_header}]
      |> maybe_date_fetch(date)
      |> sign_fetch(id, date)

    case HTTP.get(id, headers) do
      {:ok, %{body: body, status: code, headers: headers}} when code in 200..299 ->
        content_type = header_value(headers, "content-type")

        cond do
          activitypub_content_type?(content_type) ->
            {:ok, body}

          terminal? ->
            {:error, {:content_type, content_type}}

          true ->
            maybe_fetch_activitypub_alternate(id, body, headers, content_type)
        end

      {:ok, %{status: code}} when code in [404, 410] ->
        {:error, "Object has been deleted"}

      {:ok, %{status: code}} ->
        {:error, {:http, code}}

      {:error, e} ->
        {:error, e}

      e ->
        {:error, e}
    end
  end

  defp maybe_fetch_activitypub_alternate(id, body, headers, content_type) do
    with {:ok, alternate_id} <- activitypub_alternate_url(id, body, headers, content_type) do
      get_object(alternate_id, true)
    else
      _ -> {:error, {:content_type, content_type}}
    end
  end

  defp activitypub_alternate_url(id, body, headers, content_type) do
    link_header_activitypub_alternate(id, headers) ||
      html_activitypub_alternate(id, body, content_type) ||
      {:error, :no_activitypub_alternate}
  end

  defp link_header_activitypub_alternate(id, headers) do
    headers
    |> header_values("link")
    |> Enum.find_value(&activitypub_alternate_from_link_header(id, &1))
  end

  defp activitypub_alternate_from_link_header(id, header) when is_binary(header) do
    ~r/<([^>]*)>\s*((?:\s*;\s*[^,]*)*)/
    |> Regex.scan(header)
    |> Enum.find_value(fn [_, href, params] ->
      rel = link_header_param(params, "rel")
      type = link_header_param(params, "type")

      if alternate_rel?(rel) and activitypub_content_type?(type) do
        validate_alternate_url(id, href)
      end
    end)
  end

  defp activitypub_alternate_from_link_header(_id, _header), do: nil

  defp link_header_param(params, name) do
    quoted = ~r/(?:^|;)\s*#{name}\s*=\s*"([^"]*)"/i
    unquoted = ~r/(?:^|;)\s*#{name}\s*=\s*([^;,\s]+)/i

    case Regex.run(quoted, params) || Regex.run(unquoted, params) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp alternate_rel?(rel) when is_binary(rel) do
    rel
    |> String.downcase()
    |> String.split()
    |> Enum.member?("alternate")
  end

  defp alternate_rel?(_rel), do: false

  defp html_activitypub_alternate(id, body, content_type) do
    with true <- html_content_type?(content_type),
         {:ok, html} <- Floki.parse_document(body),
         href when is_binary(href) <-
           html
           |> Floki.find("link[rel~=alternate]")
           |> Enum.find_value(&activitypub_alternate_from_html_link/1) do
      validate_alternate_url(id, href)
    else
      _ -> nil
    end
  end

  defp activitypub_alternate_from_html_link(link) do
    type =
      [link]
      |> Floki.attribute("type")
      |> List.first()

    if activitypub_content_type?(type) do
      [link]
      |> Floki.attribute("href")
      |> List.first()
    end
  end

  defp validate_alternate_url(base_id, href) do
    with url when is_binary(url) <- absolute_alternate_url(base_id, href),
         true <- same_origin?(base_id, url),
         false <- url == base_id do
      {:ok, url}
    else
      _ -> nil
    end
  end

  defp absolute_alternate_url(base_id, href) when is_binary(href) do
    href = String.trim(href)

    cond do
      href == "" ->
        nil

      String.starts_with?(href, "//") ->
        base_id
        |> URI.parse()
        |> Map.get(:scheme)
        |> Kernel.<>(":")
        |> Kernel.<>(href)

      true ->
        href_uri = URI.parse(href)

        if href_uri.scheme in ["http", "https"] do
          href
        else
          base_id
          |> URI.merge(href)
          |> URI.to_string()
        end
    end
  rescue
    _ -> nil
  end

  defp absolute_alternate_url(_base_id, _href), do: nil

  defp same_origin?(left, right) do
    left_uri = URI.parse(left)
    right_uri = URI.parse(right)

    left_uri.scheme == right_uri.scheme and
      normalize_host(left_uri.host) == normalize_host(right_uri.host) and
      effective_port(left_uri) == effective_port(right_uri)
  end

  defp normalize_host(host) when is_binary(host), do: String.downcase(host)
  defp normalize_host(_host), do: nil

  defp effective_port(%URI{port: nil, scheme: scheme}), do: URI.default_port(scheme)
  defp effective_port(%URI{port: port}), do: port

  defp html_content_type?(content_type) do
    match?({:ok, "text", "html", _}, media_type(content_type))
  end

  defp activitypub_content_type?(content_type) do
    case media_type(content_type) do
      {:ok, "application", "activity+json", _} ->
        true

      {:ok, "application", "ld+json", %{"profile" => profile}} ->
        profile
        |> String.split()
        |> Enum.member?(@activity_streams_profile)

      _ ->
        false
    end
  end

  defp media_type(content_type) when is_binary(content_type),
    do: Plug.Conn.Utils.media_type(content_type)

  defp media_type(_content_type), do: :error

  defp header_value(headers, name) do
    headers
    |> header_values(name)
    |> List.first()
  end

  defp header_values(headers, name) do
    name = String.downcase(name)

    Enum.flat_map(headers, fn
      {key, value} when is_binary(key) and is_binary(value) ->
        if String.downcase(key) == name, do: [value], else: []

      {key, values} when is_binary(key) and is_list(values) ->
        if String.downcase(key) == name, do: Enum.filter(values, &is_binary/1), else: []

      _ ->
        []
    end)
  end

  defp safe_json_decode(nil), do: {:ok, nil}
  defp safe_json_decode(json), do: Jason.decode(json)
end
