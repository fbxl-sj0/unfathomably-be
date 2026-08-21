# Unfathomably: cross-project CVE regression coverage
#
# File: cve_regression_test.exs
#
# Purpose:
#   Keep native protections for Mastodon and Pleroma vulnerability classes
#   from regressing as federation support evolves.
#
# Responsibilities:
#   - exercise public-address classification
#   - enforce remote poll and local list resource bounds
#   - reject ambiguous email addresses
#   - confirm malformed MathML is harmless
#   - reject expired streaming credentials
#
# This file intentionally does not reproduce Rails-only or absent subsystems.

defmodule Pleroma.Security.CVERegressionTest do
  use Pleroma.DataCase, async: true

  import Pleroma.Factory

  require Pleroma.Constants

  alias Pleroma.HTTP.PublicAddress
  alias Pleroma.List
  alias Pleroma.Tesla.Middleware.PublicAddress, as: PublicAddressMiddleware
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ObjectValidators.QuestionValidator
  alias Pleroma.Web.MastodonAPI.WebsocketHandler
  alias Pleroma.Web.MediaProxy

  describe "outbound public-address enforcement" do
    test "rejects private, translated, transition, and special-use addresses" do
      blocked_urls = [
        "http://127.0.0.1/",
        "http://169.254.169.254/latest/meta-data/",
        "http://192.88.99.1/",
        "http://[::]/",
        "http://[::1]/",
        "http://[::ffff:127.0.0.1]/",
        "http://[::127.0.0.1]/",
        "http://[64:ff9b::7f00:1]/",
        "http://[64:ff9b:1::1]/",
        "http://[100::1]/",
        "http://[2001:10::1]/",
        "http://[2001:20::1]/",
        "http://[2002:7f00:1::]/",
        "http://[3fff::1]/"
      ]

      Enum.each(blocked_urls, fn url ->
        refute PublicAddress.public_url?(url), "expected #{url} to be rejected"
      end)
    end

    test "accepts ordinary public address literals and rejects URL credentials" do
      assert PublicAddress.public_url?("https://8.8.8.8/")
      assert PublicAddress.public_url?("https://[2001:4860:4860::8888]/")
      refute PublicAddress.public_url?("https://user:password@8.8.8.8/")
    end

    test "media proxy verifies the decoded remote destination" do
      assert {:error, :unsupported_remote_url} =
               MediaProxy.verify_remote_http_url("http://127.0.0.1/private.png")

      assert :ok = MediaProxy.verify_remote_http_url("https://8.8.8.8/public.png")
    end

    test "pinned requests retain URI host as their HTTP authority" do
      client =
        Tesla.client(
          [{PublicAddressMiddleware, []}],
          fn env -> {:ok, env} end
        )

      assert {:ok, env} = Tesla.get(client, "https://8.8.8.8:8443/avatar.png")
      assert Tesla.get_header(env, "host") == "8.8.8.8:8443"

      assert {:ok, env} = Tesla.get(client, "https://[2001:4860:4860::8888]/avatar.png")
      assert Tesla.get_header(env, "host") == "[2001:4860:4860::8888]"
    end
  end

  test "remote polls cannot exceed the configured option limit" do
    actor =
      insert(:user,
        local: false,
        ap_id: "https://polls.example.test/users/alice",
        follower_address: "https://polls.example.test/users/alice/followers"
      )

    options =
      Enum.map(1..21, fn number ->
        %{"name" => "Option #{number}", "type" => "Note"}
      end)

    changeset =
      QuestionValidator.cast_and_validate(%{
        "id" => "https://polls.example.test/objects/oversized",
        "type" => "Question",
        "actor" => actor.ap_id,
        "attributedTo" => actor.ap_id,
        "context" => "https://polls.example.test/contexts/oversized",
        "to" => [Pleroma.Constants.as_public()],
        "oneOf" => options
      })

    refute changeset.valid?
    assert changeset.errors[:oneOf]
  end

  test "lists have bounded titles and per-account allocation" do
    user = insert(:user)

    assert {:error, changeset} = List.create(String.duplicate("x", 257), user)
    assert changeset.errors[:title]

    Enum.each(1..50, fn number ->
      assert {:ok, _list} = List.create("List #{number}", user)
    end)

    assert {:error, changeset} = List.create("List 51", user)
    assert changeset.errors[:user_id]
  end

  test "email validation rejects percent-routed addresses" do
    user = insert(:user)
    changeset = User.update_as_admin_changeset(user, %{"email" => "alice%victim@example.com"})

    refute changeset.valid?
    assert changeset.errors[:email]
  end

  test "malformed MathML is stripped without raising" do
    result = Pleroma.HTML.filter_tags("<p>before</p><math><mrow><mo></math><p>after</p>")

    assert result =~ "before"
    assert result =~ "after"
    refute result =~ "<math"
  end

  test "expired OAuth tokens cannot establish streaming sessions" do
    user = insert(:user)

    token =
      insert(:oauth_token, user: user, scopes: ["read"], valid_until: ~N[2000-01-01 00:00:00])

    transport_info = %{
      params: %{"stream" => "user", "access_token" => token.token},
      connect_info: %{sec_websocket_headers: []}
    }

    assert {:error, :unauthorized} = WebsocketHandler.connect(transport_info)
  end

  test "restricted federated timelines also restrict hashtag streams" do
    clear_config([:restrict_unauthenticated, :timelines, :federated], true)

    assert {:error, :unauthorized} =
             Pleroma.Web.Streamer.get_topic("hashtag", nil, nil, %{"tag" => "security"})
  end
end

defmodule Pleroma.Security.TargetRateLimitRegressionTest do
  use Pleroma.Web.ConnCase, async: false

  alias Pleroma.Web.Plugs.RateLimiter

  test "parameter identity cannot be bypassed by changing source addresses" do
    clear_config([:rate_limit, :security_target_test], {60_000, 1})

    options =
      RateLimiter.init(
        name: :security_target_test,
        params: ["email", "nickname"],
        identity: :params
      )

    first =
      :post
      |> build_conn("/?email=target@example.com")
      |> Plug.Conn.fetch_query_params()
      |> Map.put(:remote_ip, {198, 51, 100, 1})
      |> RateLimiter.call(options)

    second =
      :post
      |> build_conn("/?email=TARGET@example.com")
      |> Plug.Conn.fetch_query_params()
      |> Map.put(:remote_ip, {203, 0, 113, 1})
      |> RateLimiter.call(options)

    refute first.halted
    assert second.halted
    assert second.status == 429
  end
end

# end of cve_regression_test.exs
