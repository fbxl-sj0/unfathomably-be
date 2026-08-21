# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.WebFingerTest do
  use Pleroma.DataCase, async: false
  alias Pleroma.Web.ActivityPub.Marketplace
  alias Pleroma.Web.WebFinger
  import ExUnit.CaptureLog
  import Pleroma.Factory
  import Tesla.Mock

  setup do
    mock(fn env -> apply(HttpRequestMock, :request, [env]) end)
    :ok
  end

  test "advertises supported FEP-3b86 activity intents" do
    clear_config([:instance, :federating], true)

    user = insert(:user)
    endpoint = Pleroma.Web.Endpoint.url()
    follow_template = endpoint <> "/activitypub/externalInteraction?uri={object}"
    create_template = endpoint <> "/share?url={object}"
    links = WebFinger.represent_user(user, "JSON")["links"]

    assert %{"template" => ^follow_template} =
             Enum.find(links, &(&1["rel"] == "https://w3id.org/fep/3b86/Follow"))

    assert %{"template" => ^create_template} =
             Enum.find(links, &(&1["rel"] == "https://w3id.org/fep/3b86/Create"))
  end

  describe "host meta" do
    test "returns a link to the xml lrdd" do
      host_info = WebFinger.host_meta()

      assert String.contains?(host_info, Pleroma.Web.Endpoint.url())
    end
  end

  describe "incoming webfinger request" do
    test "works for fqns" do
      user = insert(:user)

      {:ok, result} =
        WebFinger.webfinger("#{user.nickname}@#{Pleroma.Web.Endpoint.host()}", "XML")

      assert is_binary(result)
    end

    test "works for Unicode local usernames" do
      user = insert(:user, nickname: "書評")

      assert {:ok, result} =
               WebFinger.webfinger(
                 "acct:#{user.nickname}@#{Pleroma.Web.Endpoint.host()}",
                 "JSON"
               )

      assert result["subject"] ==
               "acct:#{user.nickname}@#{Pleroma.Web.WebFinger.domain()}"
    end

    test "works for ap_ids" do
      user = insert(:user)

      {:ok, result} = WebFinger.webfinger(user.ap_id, "XML")
      assert is_binary(result)
    end

    test "treats a legacy nil alias list as empty" do
      user = insert(:user, also_known_as: nil)

      assert WebFinger.represent_user(user, "JSON")["aliases"] == [user.ap_id]
    end

    test "resolves the marketplace service actor through its conventional handle" do
      {:ok, actor} = Marketplace.service_actor()

      {:ok, result} =
        WebFinger.webfinger(
          "#{Marketplace.service_actor_webfinger_nickname()}@#{Pleroma.Web.Endpoint.host()}",
          "JSON"
        )

      assert result["subject"] ==
               "acct:#{Marketplace.service_actor_webfinger_nickname()}@#{Pleroma.Web.WebFinger.domain()}"

      assert actor.ap_id in result["aliases"]
    end
  end

  test "requires exact match for Endpoint host or WebFinger domain" do
    clear_config([Pleroma.Web.WebFinger, :domain], "pleroma.dev")
    user = insert(:user)

    assert {:error, "Couldn't find user"} ==
             WebFinger.webfinger("#{user.nickname}@#{Pleroma.Web.Endpoint.host()}xxxx", "JSON")

    assert {:error, "Couldn't find user"} ==
             WebFinger.webfinger("#{user.nickname}@pleroma.devxxxx", "JSON")

    assert {:ok, _} =
             WebFinger.webfinger("#{user.nickname}@#{Pleroma.Web.Endpoint.host()}", "JSON")

    assert {:ok, _} =
             WebFinger.webfinger("#{user.nickname}@pleroma.dev", "JSON")
  end

  describe "fingering" do
    test "returns error for nonsensical input" do
      capture_log(fn ->
        assert {:error, _} = WebFinger.finger("bliblablu")
        assert {:error, _} = WebFinger.finger("pleroma.social")
        assert {:error, _} = WebFinger.finger("https://%")
      end)
    end

    test "handles json documents without a links array" do
      Tesla.Mock.mock(fn
        %{url: "https://nolinks.example/.well-known/host-meta"} ->
          {:ok, %Tesla.Env{status: 404, body: ""}}

        %{
          url:
            "https://nolinks.example/.well-known/webfinger?resource=acct:alice@nolinks.example",
          headers: headers
        } ->
          assert {"accept", "application/jrd+json, application/json, application/xrd+xml;q=0.9"} in headers

          {:ok,
           %Tesla.Env{
             status: 200,
             body: ~s({"subject":"acct:alice@nolinks.example"}),
             headers: [{"content-type", "application/jrd+json"}]
           }}
      end)

      assert {:ok, data} = WebFinger.finger("alice@nolinks.example")
      assert data["subject"] == "acct:alice@nolinks.example"
      refute Map.has_key?(data, "ap_id")
    end

    test "returns error when there is no content-type header" do
      Tesla.Mock.mock(fn
        %{url: "https://social.heldscal.la/.well-known/host-meta"} ->
          {:ok,
           %Tesla.Env{
             status: 200,
             body: File.read!("test/fixtures/tesla_mock/social.heldscal.la_host_meta")
           }}

        %{
          url:
            "https://social.heldscal.la/.well-known/webfinger?resource=acct:invalid_content@social.heldscal.la"
        } ->
          {:ok, %Tesla.Env{status: 200, body: ""}}
      end)

      user = "invalid_content@social.heldscal.la"
      assert {:error, {:content_type, nil}} = WebFinger.finger(user)
    end

    test "returns error when fails parse xml or json" do
      user = "invalid_content@social.heldscal.la"
      assert {:error, %Jason.DecodeError{}} = WebFinger.finger(user)
    end

    test "returns the ActivityPub actor URI for an ActivityPub user" do
      user = "framasoft@framatube.org"

      {:ok, _data} = WebFinger.finger(user)
    end

    test "it work for AP-only user" do
      user = "kpherox@mstdn.jp"

      {:ok, data} = WebFinger.finger(user)

      assert data["magic_key"] == nil
      assert data["salmon"] == nil

      assert data["topic"] == nil
      assert data["subject"] == "acct:kPherox@mstdn.jp"
      assert data["ap_id"] == "https://mstdn.jp/users/kPherox"
      assert data["subscribe_address"] == "https://mstdn.jp/authorize_interaction?acct={uri}"
    end

    test "it gets the xrd endpoint" do
      {:ok, template} = WebFinger.find_lrdd_template("social.heldscal.la")

      assert template == "https://social.heldscal.la/.well-known/webfinger?resource={uri}"
    end

    test "it gets the xrd endpoint for hubzilla" do
      {:ok, template} = WebFinger.find_lrdd_template("macgirvin.com")

      assert template == "https://macgirvin.com/xrd/?uri={uri}"
    end

    test "it gets the xrd endpoint for statusnet" do
      {:ok, template} = WebFinger.find_lrdd_template("status.alpicola.com")

      assert template == "https://status.alpicola.com/main/xrd?uri={uri}"
    end

    test "it works with idna domains as nickname" do
      nickname = "lain@" <> to_string(:idna.encode("zetsubou.みんな"))

      {:ok, _data} = WebFinger.finger(nickname)
    end

    test "it works with idna domains as link" do
      ap_id = "https://" <> to_string(:idna.encode("zetsubou.みんな")) <> "/users/lain"
      {:ok, _data} = WebFinger.finger(ap_id)
    end

    test "preserves bracketed IPv6 hosts and non-default ports from actor URLs" do
      actor_id = "https://[2606:4700:4700::1111]:8443/users/alice"
      expected_authority = "https://[2606:4700:4700::1111]:8443/"

      Tesla.Mock.mock(fn env ->
        assert String.starts_with?(env.url, expected_authority)

        if String.ends_with?(env.url, "/.well-known/host-meta") do
          {:ok, %Tesla.Env{status: 404, body: ""}}
        else
          assert {"accept", "application/jrd+json, application/json, application/xrd+xml;q=0.9"} in env.headers

          {:ok,
           %Tesla.Env{
             status: 200,
             body:
               Jason.encode!(%{
                 "subject" => "acct:alice@[2606:4700:4700::1111]:8443",
                 "links" => [
                   %{
                     "rel" => "self",
                     "type" => "application/activity+json",
                     "href" => actor_id
                   }
                 ]
               }),
             headers: [{"content-type", "application/jrd+json"}]
           }}
        end
      end)

      assert {:ok, %{"ap_id" => ^actor_id}} = WebFinger.finger(actor_id)
    end

    test "respects json content-type" do
      Tesla.Mock.mock(fn
        %{
          url:
            "https://mastodon.social/.well-known/webfinger?resource=acct:emelie@mastodon.social"
        } ->
          {:ok,
           %Tesla.Env{
             status: 200,
             body: File.read!("test/fixtures/tesla_mock/webfinger_emelie.json"),
             headers: [{"content-type", "application/jrd+json"}]
           }}

        %{url: "https://mastodon.social/.well-known/host-meta"} ->
          {:ok,
           %Tesla.Env{
             status: 200,
             body: File.read!("test/fixtures/tesla_mock/mastodon.social_host_meta")
           }}
      end)

      {:ok, _data} = WebFinger.finger("emelie@mastodon.social")
    end

    test "respects xml content-type" do
      Tesla.Mock.mock(fn
        %{
          url: "https://pawoo.net/.well-known/webfinger?resource=acct:pekorino@pawoo.net"
        } ->
          {:ok,
           %Tesla.Env{
             status: 200,
             body: File.read!("test/fixtures/tesla_mock/https___pawoo.net_users_pekorino.xml"),
             headers: [{"content-type", "application/xrd+xml"}]
           }}

        %{url: "https://pawoo.net/.well-known/host-meta"} ->
          {:ok,
           %Tesla.Env{
             status: 200,
             body: File.read!("test/fixtures/tesla_mock/pawoo.net_host_meta")
           }}
      end)

      {:ok, _data} = WebFinger.finger("pekorino@pawoo.net")
    end

    test "refuses to process XML remote entities" do
      Tesla.Mock.mock(fn
        %{
          url: "https://pawoo.net/.well-known/webfinger?resource=acct:pekorino@pawoo.net"
        } ->
          {:ok,
           %Tesla.Env{
             status: 200,
             body: File.read!("test/fixtures/xml_external_entities.xml"),
             headers: [{"content-type", "application/xrd+xml"}]
           }}

        %{url: "https://pawoo.net/.well-known/host-meta"} ->
          {:ok,
           %Tesla.Env{
             status: 200,
             body: File.read!("test/fixtures/tesla_mock/pawoo.net_host_meta")
           }}
      end)

      capture_log(fn ->
        assert :error = WebFinger.finger("pekorino@pawoo.net")
      end)
    end

    test "prevents spoofing" do
      Tesla.Mock.mock(fn
        %{
          url: "https://gleasonator.com/.well-known/webfinger?resource=acct:alex@gleasonator.com"
        } ->
          {:ok,
           %Tesla.Env{
             status: 200,
             body: File.read!("test/fixtures/tesla_mock/webfinger_spoof.json"),
             headers: [{"content-type", "application/jrd+json"}]
           }}

        %{url: "https://gleasonator.com/.well-known/host-meta"} ->
          {:ok,
           %Tesla.Env{
             status: 200,
             body: File.read!("test/fixtures/tesla_mock/gleasonator.com_host_meta")
           }}
      end)

      {:error, _data} = WebFinger.finger("alex@gleasonator.com")
    end
  end
end
