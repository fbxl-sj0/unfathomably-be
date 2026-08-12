# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.AttachmentValidator do
  use Ecto.Schema

  alias Pleroma.EctoType.ActivityPub.ObjectValidators

  import Ecto.Changeset

  @primary_key false
  # Remote objects occasionally contain very large representation arrays. A
  # status renderer needs a small set of usable alternatives, not an unbounded
  # copy of peer-controlled metadata.
  @max_url_candidates 32

  embedded_schema do
    field(:id, :string)
    field(:type, :string, default: "Link")
    field(:mediaType, ObjectValidators.MIME, default: "application/octet-stream")
    field(:name, :string)
    field(:summary, :string)
    field(:blurhash, :string)

    embeds_many :url, UrlObjectValidator, primary_key: false do
      field(:type, :string, default: "Link")
      field(:href, ObjectValidators.Uri)
      field(:mediaType, ObjectValidators.MIME, default: "application/octet-stream")
      field(:width, :integer)
      field(:height, :integer)
    end
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

  def changeset(struct, data) do
    data =
      data
      |> fix_media_type()
      |> fix_url()

    struct
    |> cast(data, [:id, :type, :mediaType, :name, :summary, :blurhash])
    |> cast_embed(:url, with: &url_changeset/2, required: true)
  end

  def url_changeset(struct, data) do
    data = fix_media_type(data)

    struct
    |> cast(data, [:type, :href, :mediaType, :width, :height])
    |> validate_inclusion(:type, ["Link"])
    |> validate_required([:type, :href, :mediaType])
  end

  def fix_media_type(data) do
    Map.put(
      data,
      "mediaType",
      data["mediaType"] || data["mimeType"] || "application/octet-stream"
    )
  end

  defp handle_href(href, mediaType, data) do
    [
      %{
        "href" => href,
        "type" => "Link",
        "mediaType" => mediaType,
        "width" => data["width"],
        "height" => data["height"]
      }
    ]
  end

  defp fix_url(data) do
    cond do
      is_binary(data["url"]) ->
        Map.put(
          data,
          "url",
          normalize_url_candidates(handle_href(data["url"], data["mediaType"], data))
        )

      is_binary(data["href"]) and data["url"] == nil ->
        Map.put(
          data,
          "url",
          normalize_url_candidates(handle_href(data["href"], data["mediaType"], data))
        )

      is_list(data["url"]) ->
        Map.put(data, "url", normalize_url_candidates(data["url"]))

      true ->
        data
    end
  end

  @doc false
  def normalize_url_candidates(candidates) when is_list(candidates) do
    candidates
    |> Enum.take(@max_url_candidates)
    |> Enum.reduce([], fn
      %{} = candidate, normalized ->
        href = candidate["href"] || candidate["url"]

        if safe_http_url?(href) do
          candidate =
            candidate
            |> Map.put("href", href)
            |> Map.delete("url")
            |> Map.put("type", "Link")

          [candidate | normalized]
        else
          normalized
        end

      _candidate, normalized ->
        normalized
    end)
    |> Enum.reverse()
  end

  def normalize_url_candidates(_candidates), do: []

  defp safe_http_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp safe_http_url?(_url), do: false

  defp validate_data(cng) do
    cng
    |> validate_inclusion(:type, ~w[Link Document Audio Image Video])
    |> validate_required([:mediaType, :type])
  end
end
