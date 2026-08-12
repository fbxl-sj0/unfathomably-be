# Unfathomably native object resolver
# ------------------------------------
#
# File: native_object_resolver.ex
#
# Purpose:
#   Resolve one user-supplied ActivityPub object URL for the Worlds interface.
#
# Responsibilities:
#   - accept only bounded HTTP(S) object URLs
#   - use the ordinary contained, MRF-filtered object fetch pipeline
#   - return an existing visible status when the object has a Create activity
#   - project public source-only native resources into bounded display metadata
#
# This file intentionally does not search remote directories, follow actors,
# create synthetic social activity, or federate fetched resource documents.

defmodule Pleroma.Web.ActivityPub.NativeObjectResolver do
  require Pleroma.Constants

  alias Pleroma.Activity
  alias Pleroma.HTML
  alias Pleroma.Object
  alias Pleroma.Object.Fetcher
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.CustomObject
  alias Pleroma.Web.ActivityPub.MRF
  alias Pleroma.Web.ActivityPub.ObjectValidator
  alias Pleroma.Web.ActivityPub.Visibility
  alias Pleroma.Web.Federation.Platform

  @max_url_length 2_048
  @max_title_length 180
  @max_summary_length 800
  @max_field_length 500
  @max_fields 48
  @max_list_items 16

  @native_families ~w[
    audio
    books
    bookmarks
    coordination
    culture
    development
    events
    games
    groups
    longform
    marketplace
    models
    photo
    publishing
    routes
    video
  ]

  @doc """
  Resolves one exact native object URL.

  Existing Create-backed objects retain the ordinary status visibility rules.
  Direct resources are returned only when their validated shape belongs to a
  known Worlds family and their audience is either explicitly public or absent,
  as is common for public catalog records.
  """
  @spec resolve(User.t(), term()) ::
          {:ok, {:status, Activity.t()}}
          | {:ok, {:resource, map()}}
          | {:error, :invalid_url | :not_found}
  def resolve(%User{} = user, value) do
    with {:ok, url} <- normalize_url(value) do
      resolve_url(user, url)
    else
      {:error, :invalid_url} = error -> error
    end
  end

  def resolve(_user, _value), do: {:error, :invalid_url}

  defp resolve_url(user, url) do
    case Pleroma.ATProto.Bridge.resolve_url(url) do
      {:ok, %Activity{} = activity} ->
        {:ok, {:status, activity}}

      _ ->
        case Object.get_cached_by_ap_id(url) do
          %Object{} = object -> result_for_object(user, object)
          nil -> resolve_uncached_url(user, url)
        end
    end
  end

  # Fetch once, then let the ordinary object pipeline ingest the contained
  # payload without issuing another request. If a source-only resource cannot
  # become a social status, the fallback examines that same validated input.
  defp resolve_uncached_url(user, url) do
    with {:ok, prefetched_object} <- Fetcher.fetch_prefetched_remote_object_from_id(url),
         {:ok, data} <- Fetcher.prefetched_object_data(prefetched_object) do
      case Fetcher.fetch_object_from_id(url, prefetched_object: prefetched_object) do
        {:ok, %Object{} = object} ->
          result_for_object(user, object)

        _error ->
          resolve_source_resource(url, data)
      end
    else
      _error -> {:error, :not_found}
    end
  end

  defp result_for_object(user, %Object{data: %{} = data} = object) do
    with {:ok, identity} <- native_identity(data) do
      case Activity.get_create_by_object_ap_id(data["id"]) do
        %Activity{} = activity ->
          if Visibility.visible_for_user?(activity, user) do
            {:ok, {:status, activity}}
          else
            {:error, :not_found}
          end

        nil ->
          resource_result(object, identity)
      end
    end
  end

  defp result_for_object(_user, _object), do: {:error, :not_found}

  defp resource_result(%Object{data: data}, identity) do
    if CustomObject.direct_resource?(data) and public_resource?(data) do
      present_resource(data, identity)
    else
      {:error, :not_found}
    end
  end

  # Some specialized systems expose a public object directly without an
  # enclosing Create activity. If ordinary status ingestion cannot represent
  # that object, retain the fetcher's containment boundary and run the same
  # validator and MRF gates before returning display-only metadata. The raw
  # object is not persisted and no synthetic social activity is created.
  defp resolve_source_resource(url, data) do
    with true <- CustomObject.discoverable?(data),
         {:ok, identity} <- native_identity(data),
         true <- public_resource?(data),
         data <- put_source_validation_audience(data),
         {:ok, data, _meta} <-
           ObjectValidator.validate(data, local: false, fetched_from: url),
         {:ok, data} <- MRF.filter(data) do
      present_resource(data, identity)
    else
      _error -> {:error, :not_found}
    end
  end

  defp present_resource(data, identity) do
    presentation = CustomObject.presentation(data) || %{}
    fields = presentation[:fields] || %{}
    source_url = safe_http_reference(data["url"]) || safe_http_reference(data["id"])

    if source_url do
      {:ok,
       {:resource,
        %{
          canonical_url: safe_http_reference(data["id"]) || source_url,
          family: identity.family,
          fields: serializable_fields(fields),
          kind: field_value(fields, :kind),
          platform: identity.platform,
          source_host: source_host(source_url),
          source_url: source_url,
          summary: resource_summary(data, fields),
          title: resource_title(data, fields, presentation[:type]),
          type: presentation[:type] || data["type"]
        }}}
    else
      {:error, :not_found}
    end
  end

  defp native_identity(data) do
    presentation = CustomObject.presentation(data) || %{}
    fields = presentation[:fields] || %{}
    classification = Platform.classify(data)

    family =
      fields
      |> field_value(:family)
      |> normalize_family()
      |> case do
        nil -> normalize_family(classification.family)
        value -> value
      end

    platform =
      field_value(fields, :platform) ||
        normalize_scalar(classification.platform, 80) ||
        "activitypub"

    if family in @native_families do
      {:ok, %{family: family, platform: platform}}
    else
      {:error, :not_found}
    end
  end

  defp normalize_family(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_family()

  defp normalize_family("software"), do: "development"
  defp normalize_family("markets"), do: "marketplace"
  defp normalize_family(value) when value in @native_families, do: value
  defp normalize_family(_value), do: nil

  defp public_resource?(data) do
    recipients =
      recipient_ids(data["to"]) ++ recipient_ids(data["cc"]) ++ recipient_ids(data["audience"])

    blind_recipients = recipient_ids(data["bto"]) ++ recipient_ids(data["bcc"])

    blind_recipients == [] and
      (recipients == [] or Pleroma.Constants.as_public() in recipients)
  end

  # Object validators require an addressed Note. A source-only native resource
  # may omit addressing entirely, so validate a non-persisted public copy after
  # shape and visibility checks have already rejected private or blind data.
  defp put_source_validation_audience(data) do
    recipients =
      recipient_ids(data["to"]) ++ recipient_ids(data["cc"]) ++ recipient_ids(data["audience"])

    if recipients == [] do
      Map.put(data, "to", [Pleroma.Constants.as_public()])
    else
      data
    end
  end

  defp recipient_ids(value) when is_binary(value), do: [value]

  defp recipient_ids(value) when is_list(value) do
    value
    |> Enum.flat_map(&recipient_ids/1)
    |> Enum.uniq()
  end

  defp recipient_ids(%{"id" => id}) when is_binary(id), do: [id]
  defp recipient_ids(_value), do: []

  defp resource_title(data, fields, type) do
    [
      field_value(fields, :title),
      field_value(fields, :name),
      field_value(fields, :model_name),
      field_value(fields, :listing_name),
      data["name"],
      data["title"],
      type_label(type || data["type"])
    ]
    |> Enum.find_value(&plain_text(&1, @max_title_length))
    |> Kernel.||("Native resource")
  end

  defp resource_summary(data, fields) do
    [
      field_value(fields, :detail),
      data["summary"],
      data["content"]
    ]
    |> Enum.find_value(&plain_text(&1, @max_summary_length))
  end

  defp type_label(value) when is_binary(value) do
    value
    |> String.split(["#", "/", ":"])
    |> List.last()
  end

  defp type_label(_value), do: nil

  defp serializable_fields(fields) when is_map(fields) do
    fields
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.reduce_while(%{}, fn {key, value}, result ->
      if map_size(result) >= @max_fields do
        {:halt, result}
      else
        key = to_string(key)
        value = serializable_value(value)

        if byte_size(key) <= 64 and not is_nil(value) do
          {:cont, Map.put(result, key, value)}
        else
          {:cont, result}
        end
      end
    end)
  end

  defp serializable_fields(_fields), do: %{}

  defp serializable_value(value) when is_binary(value),
    do: normalize_scalar(value, @max_field_length)

  defp serializable_value(value) when is_number(value) or is_boolean(value), do: value

  defp serializable_value(value) when is_list(value) do
    values =
      value
      |> Enum.take(@max_list_items)
      |> Enum.map(&serializable_value/1)
      |> Enum.reject(&is_nil/1)

    if values == [], do: nil, else: values
  end

  defp serializable_value(_value), do: nil

  defp field_value(fields, key) when is_map(fields) do
    Map.get(fields, key) || Map.get(fields, to_string(key))
  end

  defp field_value(_fields, _key), do: nil

  defp plain_text(value, limit) when is_binary(value) do
    value
    |> HTML.strip_non_content()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> normalize_scalar(limit)
  end

  defp plain_text(_value, _limit), do: nil

  defp normalize_scalar(value, limit) when is_binary(value) and is_integer(limit) do
    value = String.trim(value)
    if value == "", do: nil, else: String.slice(value, 0, limit)
  end

  defp normalize_scalar(_value, _limit), do: nil

  defp safe_http_reference(value) when is_list(value) do
    Enum.find_value(value, &safe_http_reference/1)
  end

  defp safe_http_reference(%{"href" => value}), do: safe_http_reference(value)
  defp safe_http_reference(%{"id" => value}), do: safe_http_reference(value)
  defp safe_http_reference(%{"url" => value}), do: safe_http_reference(value)

  defp safe_http_reference(value) when is_binary(value) do
    case normalize_url(value) do
      {:ok, url} -> url
      _error -> nil
    end
  end

  defp safe_http_reference(_value), do: nil

  defp source_host(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> String.downcase(host)
      _uri -> ""
    end
  end

  defp normalize_url(value) when is_binary(value) do
    url = String.trim(value)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when byte_size(url) > 0 and byte_size(url) <= @max_url_length and
             scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, url}

      _uri ->
        {:error, :invalid_url}
    end
  end

  defp normalize_url(_value), do: {:error, :invalid_url}
end

# end of lib/pleroma/web/activity_pub/native_object_resolver.ex
