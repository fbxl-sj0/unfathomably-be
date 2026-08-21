# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.WebFinger do
  alias Pleroma.HTTP
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Marketplace
  alias Pleroma.Web.Endpoint
  alias Pleroma.Web.Federator.Publisher
  alias Pleroma.Web.XML
  alias Pleroma.XmlBuilder
  require Logger

  def host_meta do
    base_url = Endpoint.url()

    {
      :XRD,
      %{xmlns: "http://docs.oasis-open.org/ns/xri/xrd-1.0"},
      {
        :Link,
        %{
          rel: "lrdd",
          type: "application/xrd+xml",
          template: "#{base_url}/.well-known/webfinger?resource={uri}"
        }
      }
    }
    |> XmlBuilder.to_doc()
  end

  def webfinger(resource, fmt) when fmt in ["XML", "JSON"] do
    if server_prefix_resource?(resource) do
      {:ok, represent_server(fmt)}
    else
      user_webfinger(resource, fmt)
    end
  end

  defp user_webfinger(resource, fmt) do
    host = Pleroma.Web.Endpoint.host()

    domains =
      [host, Pleroma.Config.get([__MODULE__, :domain])]
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&Regex.escape/1)
      |> Enum.join("|")

    # ActivityPub handles are Unicode identifiers in practice. Marks are
    # included so decomposed characters remain resolvable, while punctuation
    # stays limited to the characters already accepted for local nicknames.
    regex =
      ~r/\A(?:acct:)?(?<username>[\p{L}\p{N}\p{M}_.-]+)@(?:#{domains})\z/u

    with %{"username" => username} <- Regex.named_captures(regex, resource),
         %User{} = user <- get_local_user_by_webfinger_nickname(username) do
      {:ok, represent_user(user, fmt)}
    else
      _e ->
        with %User{} = user <- User.get_cached_by_ap_id(resource) do
          {:ok, represent_user(user, fmt)}
        else
          _e ->
            {:error, "Couldn't find user"}
        end
    end
  end

  defp represent_server("JSON") do
    %{
      "subject" => server_prefix(),
      "links" => [
        %{
          "rel" => "https://www.w3.org/ns/activitystreams#Service",
          "type" => "application/activity+json",
          "href" => Marketplace.service_actor_ap_id()
        }
      ]
    }
  end

  defp represent_server("XML") do
    {
      :XRD,
      %{xmlns: "http://docs.oasis-open.org/ns/xri/xrd-1.0"},
      [
        {:Subject, server_prefix()},
        {:Link,
         %{
           rel: "https://www.w3.org/ns/activitystreams#Service",
           type: "application/activity+json",
           href: Marketplace.service_actor_ap_id()
         }}
      ]
    }
    |> XmlBuilder.to_doc()
  end

  # FEP-d556 defines the resource as the server prefix, not an arbitrary local
  # URL. Keep this comparison strict so a profile, object, query, or fragment
  # cannot be mistaken for the server-level actor request.
  defp server_prefix_resource?(resource) when is_binary(resource) do
    resource_uri = URI.parse(resource)
    endpoint_uri = URI.parse(Endpoint.url())

    is_binary(resource_uri.scheme) and
      is_binary(resource_uri.host) and
      String.downcase(resource_uri.scheme) == String.downcase(endpoint_uri.scheme) and
      String.downcase(resource_uri.host) == String.downcase(endpoint_uri.host) and
      effective_port(resource_uri) == effective_port(endpoint_uri) and
      resource_uri.path in [nil, "", "/"] and
      is_nil(resource_uri.userinfo) and
      is_nil(resource_uri.query) and
      is_nil(resource_uri.fragment)
  rescue
    URI.Error -> false
  end

  defp server_prefix_resource?(_resource), do: false

  defp server_prefix do
    endpoint_uri = URI.parse(Endpoint.url())

    endpoint_uri
    |> Map.put(:path, "/")
    |> Map.put(:query, nil)
    |> Map.put(:fragment, nil)
    |> URI.to_string()
  end

  defp effective_port(%URI{port: port}) when is_integer(port), do: port
  defp effective_port(%URI{scheme: "https"}), do: 443
  defp effective_port(%URI{scheme: "http"}), do: 80
  defp effective_port(_uri), do: nil

  # Marketplace peers conventionally discover their instance actor as
  # `instance@host`, while the local account uses an internal nickname to keep
  # that public alias unavailable to ordinary registrations. Prefer an existing
  # service actor for the alias, but keep the normal user lookup as a fallback
  # for older instances that already have a local `instance` account.
  defp get_local_user_by_webfinger_nickname(username) do
    if username == Marketplace.service_actor_webfinger_nickname() do
      User.get_cached_by_ap_id(Marketplace.service_actor_ap_id()) ||
        User.get_cached_by_nickname(username)
    else
      User.get_cached_by_nickname(username)
    end
  end

  defp gather_links(%User{} = user) do
    [
      %{
        "rel" => "http://webfinger.net/rel/profile-page",
        "type" => "text/html",
        "href" => user.ap_id
      }
    ] ++
      Publisher.gather_webfinger_links(user) ++
      gather_activity_intent_links() ++
      Pleroma.Diaspora.webfinger_links(user)
  end

  defp gather_activity_intent_links do
    if Pleroma.Federation.enabled?() do
      endpoint = Pleroma.Web.Endpoint.url()

      [
        %{
          "rel" => "https://w3id.org/fep/3b86/Follow",
          "template" => endpoint <> "/activitypub/externalInteraction?uri={object}"
        },
        %{
          "rel" => "https://w3id.org/fep/3b86/Create",
          "template" => endpoint <> "/share?url={object}"
        }
      ]
    else
      []
    end
  end

  defp gather_aliases(%User{} = user) do
    [user.ap_id | List.wrap(user.also_known_as)]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  def represent_user(user, "JSON") do
    %{
      "subject" => "acct:#{Marketplace.webfinger_nickname(user)}@#{domain()}",
      "aliases" => gather_aliases(user),
      "links" => gather_links(user)
    }
  end

  def represent_user(user, "XML") do
    aliases =
      user
      |> gather_aliases()
      |> Enum.map(&{:Alias, &1})

    links =
      gather_links(user)
      |> Enum.map(fn link -> {:Link, link} end)

    {
      :XRD,
      %{xmlns: "http://docs.oasis-open.org/ns/xri/xrd-1.0"},
      [
        {:Subject, "acct:#{Marketplace.webfinger_nickname(user)}@#{domain()}"}
      ] ++ aliases ++ links
    }
    |> XmlBuilder.to_doc()
  end

  def domain do
    Pleroma.Config.get([__MODULE__, :domain]) || Pleroma.Web.Endpoint.host()
  end

  defp webfinger_from_xml(body) do
    with {:ok, doc} <- XML.parse_document(body) do
      subject = XML.string_from_xpath("//Subject", doc)

      subscribe_address =
        ~s{//Link[@rel="http://ostatus.org/schema/1.0/subscribe"]/@template}
        |> XML.string_from_xpath(doc)

      ap_id =
        ~s{//Link[@rel="self" and @type="application/activity+json"]/@href}
        |> XML.string_from_xpath(doc)

      data = %{
        "subject" => subject,
        "subscribe_address" => subscribe_address,
        "ap_id" => ap_id
      }

      {:ok, data}
    end
  end

  defp webfinger_from_json(body) do
    with {:ok, doc} <- Jason.decode(body) do
      links = if is_list(doc["links"]), do: doc["links"], else: []

      data =
        Enum.reduce(links, %{"subject" => doc["subject"]}, fn link, data ->
          case {link["type"], link["rel"]} do
            {"application/activity+json", "self"} ->
              Map.put(data, "ap_id", link["href"])

            {"application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\"", "self"} ->
              Map.put(data, "ap_id", link["href"])

            {nil, "http://ostatus.org/schema/1.0/subscribe"} ->
              Map.put(data, "subscribe_address", link["template"])

            _ ->
              Logger.debug("Unhandled type: #{inspect(link["type"])}")
              data
          end
        end)

      {:ok, data}
    end
  end

  def get_template_from_xml(body) do
    xpath = "//Link[@rel='lrdd']/@template"

    with {_, {:ok, doc}} <- {:xml_parse, XML.parse_document(body)},
         {_, template} when template != nil <-
           {:find_template, XML.string_from_xpath(xpath, doc)} do
      {:ok, template}
    else
      error -> {:error, error}
    end
  end

  @cachex Pleroma.Config.get([:cachex, :provider], Cachex)
  def find_lrdd_template(domain) do
    @cachex.fetch!(:host_meta_cache, domain, fn _ ->
      {:commit, fetch_lrdd_template(domain)}
    end)
  rescue
    e -> {:error, "Cachex error: #{inspect(e)}"}
  end

  defp fetch_lrdd_template(domain) do
    # WebFinger is restricted to HTTPS - https://tools.ietf.org/html/rfc7033#section-9.1
    meta_url = "https://#{domain}/.well-known/host-meta"

    with {:ok, %{status: status, body: body}} when status in 200..299 <-
           HTTP.get(meta_url, [], pool: :federation, public_only: true) do
      get_template_from_xml(body)
    else
      error ->
        Logger.debug(
          "Can't find LRDD template in #{Pleroma.Helpers.UriHelper.log_safe_url(meta_url)}: #{Pleroma.Helpers.UriHelper.log_safe_text(error)}"
        )

        {:error, :lrdd_not_found}
    end
  end

  defp get_address_from_domain(domain, account)
       when is_binary(domain) and is_binary(account) do
    resource = if String.starts_with?(account, "acct:"), do: account, else: "acct:#{account}"

    encoded_account =
      resource
      |> URI.encode()
      |> String.replace("[", "%5B")
      |> String.replace("]", "%5D")

    case find_lrdd_template(domain) do
      {:ok, template} ->
        String.replace(template, "{uri}", encoded_account)

      _ ->
        "https://#{domain}/.well-known/webfinger?resource=#{encoded_account}"
    end
  end

  defp get_address_from_domain(_, _), do: {:error, :webfinger_no_domain}

  @spec finger(String.t()) :: {:ok, map()} | {:error, any()}
  def finger(account), do: do_finger(account, true)

  defp do_finger(account, follow_redirects) do
    account =
      account
      |> String.replace(~r/\p{C}+/u, " ")
      |> String.trim()
      |> String.trim_leading("@")

    domain =
      with [_name, domain] <- String.split(account, "@") do
        domain
      else
        _e -> uri_authority(account)
      end

    with address when is_binary(address) <- get_address_from_domain(domain, account),
         {:ok, %{status: status, body: body, headers: headers}} when status in 200..299 <-
           HTTP.get(
             address,
             [
               {"accept", "application/jrd+json, application/json, application/xrd+xml;q=0.9"}
             ],
             pool: :federation,
             public_only: true
           ) do
      case List.keyfind(headers, "content-type", 0) do
        {_, content_type} ->
          case Pleroma.Web.MediaType.match(content_type, [
                 {"application", "xrd+xml"},
                 {"application", "xml"},
                 {"application", "jrd+json"},
                 {"application", "json"}
               ]) do
            {"application", subtype, _} when subtype in ~w(xrd+xml xml) ->
              webfinger_from_xml(body)

            {"application", subtype, _} when subtype in ~w(jrd+json json) ->
              webfinger_from_json(body)

            nil ->
              {:error, {:content_type, content_type}}
          end

        _ ->
          {:error, {:content_type, nil}}
      end
      |> case do
        {:ok, data} ->
          if follow_redirects do
            validate_webfinger(address, data)
          else
            {:ok, data}
          end

        error ->
          error
      end
    else
      error ->
        Logger.debug("Couldn't finger #{account}: #{inspect(error)}")
        error
    end
  end

  defp validate_webfinger(request_url, %{"subject" => "acct:" <> acct = subject} = data) do
    with [_name, acct_host] <- String.split(acct, "@"),
         {_, resolved_url} <- {:address, get_address_from_domain(acct_host, subject)},
         {_, true} <- {:url_match, resolved_webfinger_matches?(request_url, resolved_url, data)} do
      {:ok, data}
    else
      _ -> {:error, {:webfinger_invalid, request_url, data}}
    end
  end

  defp validate_webfinger(url, data), do: {:error, {:webfinger_invalid, url, data}}

  defp uri_authority(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{host: host, port: port, scheme: scheme} when is_binary(host) and host != "" ->
        host
        |> bracket_ipv6_host()
        |> maybe_append_port(port, scheme)

      _ ->
        nil
    end
  rescue
    URI.Error -> nil
  end

  defp uri_authority(_), do: nil

  defp bracket_ipv6_host(host) do
    if String.contains?(host, ":") and not String.starts_with?(host, "[") do
      "[#{host}]"
    else
      host
    end
  end

  defp maybe_append_port(authority, port, scheme)
       when is_integer(port) and is_binary(scheme) do
    default_port = if scheme == "https", do: 443, else: 80
    if port == default_port, do: authority, else: "#{authority}:#{port}"
  end

  defp maybe_append_port(authority, _port, _scheme), do: authority

  defp resolved_webfinger_matches?(request_url, resolved_url, _data)
       when request_url == resolved_url do
    true
  end

  defp resolved_webfinger_matches?(
         request_url,
         resolved_url,
         %{"subject" => "acct:" <> acct} = data
       ) do
    case webfinger_url_match_status(request_url, resolved_url) do
      true ->
        true

      false ->
        false

      :refetch ->
        with {:ok, %{"subject" => "acct:" <> new_acct} = new_data} <- do_finger(acct, false),
             true <- acct == new_acct,
             true <- webfinger_data_matches?(data, new_data) do
          true
        else
          _ -> false
        end
    end
  end

  defp resolved_webfinger_matches?(request_url, resolved_url, _data)
       when is_binary(request_url) and is_binary(resolved_url) do
    webfinger_url_match_status(request_url, resolved_url) == true
  end

  defp webfinger_url_match_status(request_url, resolved_url) do
    request_uri = URI.parse(request_url)
    resolved_uri = URI.parse(resolved_url)

    cond do
      String.downcase(request_url) == String.downcase(resolved_url) ->
        true

      request_uri.host != resolved_uri.host ->
        false

      true ->
        :refetch
    end
  end

  defp webfinger_data_matches?(%{"ap_id" => ap_id}, %{"ap_id" => ap_id}) when ap_id != "" do
    true
  end

  defp webfinger_data_matches?(_data, _new_data), do: false
end
