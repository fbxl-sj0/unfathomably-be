# Project: Unfathomably Backend Test Suite
# ----------------------------------------
#
# File: test/pleroma/web/federation/platform_test.exs
#
# Purpose:
#
#   Keep the backend platform-family contract stable for federated source
#   and group compatibility work.
#
# Responsibilities:
#
#   * prove named fediverse platforms map to expected families
#   * prove NodeInfo-style software metadata is accepted
#   * prove ActivityPub object type fallback stays safe
#
# This file intentionally does NOT contain:
#
#   * network federation calls
#   * database setup
#   * frontend rendering assertions

defmodule Pleroma.Web.Federation.PlatformTest do
  use ExUnit.Case, async: true

  alias Pleroma.Web.Federation.Platform

  @platform_cases [
    {"Funkwhale", :audio},
    {"WordPress", :longform},
    {"WriteFreely", :longform},
    {"GoToSocial", :microblog},
    {"Iceshrimp", :microblog},
    {"snac", :microblog},
    {"Pixelfed", :photo},
    {"Mitra", :microblog},
    {"Owncast", :video},
    {"Misskey", :microblog},
    {"Sharkey", :microblog},
    {"BookWyrm", :books},
    {"Postmarks", :bookmarks},
    {"wafrn", :microblog},
    {"Castopod", :audio},
    {"Lemmy", :groups},
    {"Lotide", :groups},
    {"Local", :local},
    {"Bonfire", :groups},
    {"Kbin", :groups},
    {"Discourse", :groups},
    {"Mbin", :groups},
    {"Mobilizon", :events},
    {"NodeBB", :groups},
    {"PieFed", :groups},
    {"FediGroups", :groups},
    {"Fedibird Group", :groups},
    {"AP-Groups", :groups},
    {"BuzzRelay", :groups},
    {"Guppe", :groups},
    {"Flipboard", :longform},
    {"Elgg", :groups},
    {"Friendica", :groups},
    {"Gancio", :events},
    {"Hubzilla", :groups},
    {"PeerTube", :video},
    {"WordPress Event Bridge", :events},
    {"Mastodon", :microblog},
    {"Pleroma", :microblog}
  ]

  test "classifies named fediverse software into native UI families" do
    for {software, family} <- @platform_cases do
      assert %{family: ^family, confidence: :software} =
               Platform.classify(%{"software" => %{"name" => software}})
    end
  end

  test "classifies nested NodeInfo metadata" do
    payload = %{
      "nodeinfo" => %{
        "software" => %{
          "name" => "lemmy",
          "version" => "1.0.0"
        }
      }
    }

    assert %{
             platform: "lemmy",
             label: "Lemmy",
             family: :groups,
             confidence: :software
           } = Platform.classify(payload)
  end

  test "classifies actor generator metadata" do
    payload = %{
      "type" => "Person",
      "generator" => %{
        "type" => "Application",
        "name" => "Pixelfed"
      }
    }

    assert %{platform: "pixelfed", family: :photo, confidence: :software} =
             Platform.classify(payload)
  end

  test "falls back to ActivityPub object type when software is unknown" do
    assert %{platform: "activitypub-audio", family: :audio, confidence: :object} =
             Platform.classify(%{"type" => "Audio"})

    assert %{platform: "activitypub-group", family: :groups, confidence: :object} =
             Platform.classify(%{"object" => %{"type" => "Group"}})
  end

  test "keeps unknown input safe and generic" do
    assert %{platform: "unknown", family: :generic, confidence: :unknown} =
             Platform.classify(%{"software" => %{"name" => "some-new-fediverse-thing"}})
  end
end

# end of test/pleroma/web/federation/platform_test.exs
