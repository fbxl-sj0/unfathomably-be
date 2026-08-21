# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.HTML do
  # Scrubbers are compiled on boot so they can be configured in OTP releases
  #  @on_load :compile_scrubbers

  @presentation_non_content_selectors [".quote-inline", ".recipients-inline", ".invisible"]

  def compile_scrubbers do
    dir = Path.join(:code.priv_dir(:pleroma), "scrubbers")

    dir
    |> Pleroma.Utils.compile_dir()
    |> case do
      {:error, _errors, _warnings} ->
        raise "Compiling scrubbers failed"

      {:ok, _modules, _warnings} ->
        :ok
    end
  end

  defp get_scrubbers(scrubber) when is_atom(scrubber), do: [scrubber]
  defp get_scrubbers(scrubbers) when is_list(scrubbers), do: scrubbers
  defp get_scrubbers(_), do: [Pleroma.HTML.Scrubber.Default]

  def get_scrubbers do
    Pleroma.Config.get([:markup, :scrub_policy])
    |> get_scrubbers
  end

  def filter_tags(html, nil) do
    filter_tags(html, get_scrubbers())
  end

  def filter_tags(html, scrubbers) when is_list(scrubbers) do
    Enum.reduce(scrubbers, html, fn scrubber, html ->
      filter_tags(html, scrubber)
    end)
  end

  def filter_tags(html, scrubber) do
    {:ok, content} = FastSanitize.Sanitizer.scrub(html, scrubber)
    content
  end

  def filter_tags(html), do: filter_tags(html, nil)
  def strip_tags(html), do: filter_tags(html, FastSanitize.Sanitizer.StripTags)

  @doc """
  Converts authored HTML to presentation text without transport-only fallback
  elements.

  Quote fallback markup is useful to clients that do not understand native
  quotes, but including it while deriving a title or catalog summary makes the
  quoted body appear to be authored content. Invisible URL fragments and
  recipient affordances have the same problem.
  """
  def strip_non_content(html) when is_binary(html) do
    case Floki.parse_fragment(html) do
      {:ok, tree} ->
        tree
        |> remove_presentation_non_content()
        |> Floki.raw_html()
        |> strip_tags()

      _ ->
        strip_tags(html)
    end
  rescue
    _ -> strip_tags(html)
  catch
    _, _ -> strip_tags(html)
  end

  def strip_non_content(_), do: ""

  defp remove_presentation_non_content(tree) do
    Enum.reduce(@presentation_non_content_selectors, tree, fn selector, current ->
      Floki.filter_out(current, selector)
    end)
  end

  def ensure_scrubbed_html(
        content,
        scrubbers,
        fake,
        callback
      ) do
    content =
      content
      |> filter_tags(scrubbers)
      |> callback.()

    if fake do
      {:ignore, content}
    else
      {:commit, content}
    end
  end

  @spec extract_first_external_url_from_object(Pleroma.Object.t()) :: String.t() | nil
  def extract_first_external_url_from_object(%{data: data}) when is_map(data) do
    extract_link_attachment_url(data["attachment"]) ||
      extract_first_external_url_from_content(data["content"])
  end

  def extract_first_external_url_from_object(_), do: nil

  defp extract_first_external_url_from_content(content) when is_binary(content) do
    content
    |> Floki.parse_fragment!()
    |> Floki.find("a:not(.mention,.hashtag,.attachment,[rel~=\"tag\"])")
    |> Enum.take(1)
    |> Floki.attribute("href")
    |> Enum.at(0)
  end

  defp extract_first_external_url_from_content(_), do: nil

  defp extract_link_attachment_url(attachments) when is_list(attachments) do
    Enum.find_value(attachments, &link_attachment_url/1)
  end

  defp extract_link_attachment_url(attachment) when is_map(attachment),
    do: link_attachment_url(attachment)

  defp extract_link_attachment_url(_), do: nil

  @doc """
  Returns the first safe web destination carried by an ActivityPub Link.

  ActivityPub producers use both a direct `href` and the attachment-style
  `url: [{href: ...}]` shape. Treating only the first form as a link turns
  Lemmy and similar link posts into unknown downloadable media.
  """
  def link_attachment_url(%{"type" => "Link"} = attachment) do
    (attachment["href"] || nested_link_url(attachment["url"]))
    |> valid_web_url()
  end

  def link_attachment_url(_), do: nil

  defp nested_link_url(url) when is_binary(url), do: url

  defp nested_link_url(urls) when is_list(urls) do
    Enum.find_value(urls, &nested_link_url/1)
  end

  defp nested_link_url(%{"href" => href}) when is_binary(href), do: href
  defp nested_link_url(%{"url" => url}), do: nested_link_url(url)
  defp nested_link_url(_), do: nil

  defp valid_web_url(href) when is_binary(href) do
    case URI.parse(href) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        href

      _ ->
        nil
    end
  rescue
    URI.Error -> nil
  end

  defp valid_web_url(_), do: nil
end
