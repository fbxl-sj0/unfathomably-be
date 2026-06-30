# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.AudioImageVideoValidator do
  use Ecto.Schema

  alias Pleroma.EctoType.ActivityPub.ObjectValidators
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonFixes
  alias Pleroma.Web.ActivityPub.ObjectValidators.CommonValidations
  alias Pleroma.Web.ActivityPub.Transmogrifier

  import Ecto.Changeset

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

  defp find_attachment(url) do
    mpeg_url =
      Enum.find(url, fn
        %{"mediaType" => mime_type, "tag" => tags} when is_list(tags) ->
          mime_type == "application/x-mpegURL"

        _ ->
          false
      end)

    url
    |> Enum.concat(mpeg_url["tag"] || [])
    |> Enum.find(fn
      %{"mediaType" => mime_type} ->
        String.starts_with?(mime_type, ["video/", "audio/", "image/"])

      %{"mimeType" => mime_type} ->
        String.starts_with?(mime_type, ["video/", "audio/", "image/"])

      _ ->
        false
    end)
  end

  defp fix_url(%{"url" => url} = data) when is_list(url) do
    attachment = find_attachment(url)

    link_element =
      Enum.find(url, fn
        %{"mediaType" => "text/html"} -> true
        %{"mimeType" => "text/html"} -> true
        _ -> false
      end)

    data
    |> Map.put("attachment", [attachment])
    |> Map.put("url", link_element["href"])
  end

  defp fix_url(data), do: data

  defp fix_content(%{"mediaType" => "text/markdown", "content" => content} = data)
       when is_binary(content) do
    content =
      content
      |> Pleroma.Formatter.markdown_to_html()
      |> Pleroma.HTML.filter_tags()

    Map.put(data, "content", content)
  end

  defp fix_content(data), do: data

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

  defp fix(data) do
    data
    |> CommonFixes.fix_actor()
    |> CommonFixes.fix_object_defaults()
    |> CommonFixes.fix_quote_url()
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
