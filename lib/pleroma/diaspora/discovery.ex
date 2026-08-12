# Unfathomably BE
# ----------------
#
# File: diaspora/discovery.ex
#
# Purpose:
#   Discover diaspora* identities through WebFinger and hCard.
#
# Responsibilities:
#   - locate the authoritative hCard and pod seed links
#   - extract GUID, profile presentation, delivery URL, and RSA public key
#   - constrain network requests and response sizes
#
# This file intentionally does NOT accept ActivityPub actor data as diaspora*
# proof or trust a key that was not obtained from the discovered hCard.

defmodule Pleroma.Diaspora.Discovery do
  alias Pleroma.ATProto.URL
  alias Pleroma.HTTP
  alias Pleroma.Keys
  alias Pleroma.Web.XML

  @maximum_response_bytes 1_048_576
  @leading_doctype ~r/\A\s*<!DOCTYPE\s+[^>]*>\s*/iu

  def discover(diaspora_id) when is_binary(diaspora_id) do
    diaspora_id =
      diaspora_id |> String.trim() |> String.trim_leading("acct:") |> String.downcase()

    with [name, host] <- String.split(diaspora_id, "@"),
         true <- name != "" and byte_size(diaspora_id) <= 320,
         true <- URL.public_host?(host),
         {:ok, webfinger} <- get_json(webfinger_url(host, diaspora_id)),
         hcard_url when is_binary(hcard_url) <- hcard_link(webfinger),
         {:ok, hcard} <- get_xml(hcard_url),
         {:ok, profile} <- parse_hcard(hcard, diaspora_id, host, webfinger) do
      {:ok, profile}
    else
      _ -> {:error, :not_found}
    end
  end

  def discover(_diaspora_id), do: {:error, :not_found}

  defp webfinger_url(host, diaspora_id) do
    "https://#{host}/.well-known/webfinger?resource=" <>
      URI.encode_www_form("acct:#{diaspora_id}")
  end

  defp hcard_link(%{"links" => links}) when is_list(links) do
    Enum.find_value(links, fn
      %{"rel" => rel, "href" => href}
      when rel in [
             "http://microformats.org/profile/hcard",
             "http://webfinger.net/rel/profile-page"
           ] ->
        if URL.public_https_url?(href), do: href

      _ ->
        nil
    end)
  end

  defp hcard_link(_webfinger), do: nil

  defp parse_hcard(doc, diaspora_id, host, webfinger) do
    guid = XML.string_from_xpath(class_xpath("uid"), doc)
    public_key = XML.string_from_xpath(class_xpath("key"), doc)
    full_name = XML.string_from_xpath(class_xpath("fn"), doc)
    nickname = XML.string_from_xpath(class_xpath("nickname"), doc)
    photo = XML.string_from_xpath(class_xpath("photo") <> "/@src", doc)

    profile_url =
      XML.string_from_xpath(class_xpath("url") <> "/@href", doc) || profile_link(webfinger)

    pod_url = seed_link(webfinger) || "https://#{host}"
    receive_url = receive_link(webfinger)

    with true <- valid_guid?(guid),
         [_key | _rest] <- Keys.public_keys_from_pem(public_key),
         true <- URL.public_https_url?(pod_url) do
      {:ok,
       %{
         diaspora_id: diaspora_id,
         guid: guid,
         pod_url: pod_url,
         profile_url: safe_url(profile_url),
         receive_url: safe_url(receive_url),
         public_key: public_key,
         name: bounded(full_name || nickname, 100),
         nickname: bounded(nickname, 100),
         avatar_url: safe_url(photo)
       }}
    else
      _ -> {:error, :invalid_hcard}
    end
  end

  defp class_xpath(name) do
    # xmerl's XPath evaluator implements contains/2 but not normalize-space/1.
    # Padding both sides still matches a complete class token in pod hCards
    # without relying on the unsupported function.
    "//*[contains(concat(' ', @class, ' '), ' #{name} ')]"
  end

  defp seed_link(%{"links" => links}) when is_list(links) do
    Enum.find_value(links, fn
      %{"rel" => "http://joindiaspora.com/seed_location", "href" => href} -> safe_url(href)
      _ -> nil
    end)
  end

  defp seed_link(_webfinger), do: nil

  defp profile_link(%{"links" => links}) when is_list(links) do
    Enum.find_value(links, fn
      %{"rel" => "http://webfinger.net/rel/profile-page", "href" => href} -> safe_url(href)
      _ -> nil
    end)
  end

  defp profile_link(_webfinger), do: nil

  defp receive_link(%{"links" => links}) when is_list(links) do
    Enum.find_value(links, fn
      %{"rel" => rel, "href" => href}
      when rel in [
             "salmon",
             "http://joindiaspora.com/receive",
             "http://diasporafoundation.org/receive"
           ] ->
        safe_url(href)

      _ ->
        nil
    end)
  end

  defp receive_link(_webfinger), do: nil

  defp get_json(url) do
    with true <- URL.public_https_url?(url),
         {:ok, %{status: status, body: body}} when status in 200..299 <-
           HTTP.get(url, [{"accept", "application/jrd+json, application/json"}],
             pool: :federation
           ),
         true <- is_binary(body) and byte_size(body) <= @maximum_response_bytes,
         {:ok, %{} = data} <- Jason.decode(body) do
      {:ok, data}
    else
      _ -> {:error, :not_found}
    end
  end

  defp get_xml(url) do
    with true <- URL.public_https_url?(url),
         {:ok, %{status: status, body: body}} when status in 200..299 <-
           HTTP.get(url, [{"accept", "text/html, application/xhtml+xml"}], pool: :federation),
         true <- is_binary(body) and byte_size(body) <= @maximum_response_bytes,
         {:ok, doc} <- body |> strip_leading_doctype() |> XML.parse_document() do
      {:ok, doc}
    else
      _ -> {:error, :not_found}
    end
  end

  defp strip_leading_doctype(body) do
    # diaspora* pods commonly serialize hCards as XHTML with the legacy HTML
    # 4 public DOCTYPE. xmerl correctly refuses to fetch that external DTD,
    # but it also rejects the otherwise self-contained document. Removing only
    # a leading declaration retains the no-external-entity boundary while
    # allowing the profile fields in the document itself to be parsed.
    Regex.replace(@leading_doctype, body, "", global: false)
  end

  defp valid_guid?(guid),
    do:
      is_binary(guid) and
        Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_@.:-]{14,253}[A-Za-z0-9]\z/, guid)

  defp safe_url(url) when is_binary(url), do: if(URL.public_https_url?(url), do: url)
  defp safe_url(_url), do: nil
  defp bounded(value, limit) when is_binary(value), do: String.slice(String.trim(value), 0, limit)
  defp bounded(_value, _limit), do: nil
end

# end of diaspora/discovery.ex
