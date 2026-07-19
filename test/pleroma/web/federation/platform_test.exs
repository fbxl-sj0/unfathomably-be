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
    {"ActivityPods", :coordination},
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
    {"NeoDB", :culture},
    {"BookWyrm", :books},
    {"ForgeFed", :development},
    {"Bonfire ValueFlows", :coordination},
    {"CommonsPub", :publishing},
    {"ZenPub", :publishing},
    {"Vervis", :development},
    {"Postmarks", :bookmarks},
    {"wafrn", :microblog},
    {"Wanderer", :routes},
    {"XWiki", :publishing},
    {"Flohmarkt", :marketplace},
    {"Castopod", :audio},
    {"Castling.club", :games},
    {"Lemmy", :groups},
    {"Lotide", :groups},
    {"Local", :local},
    {"Bonfire", :groups},
    {"Kbin", :groups},
    {"Discourse", :groups},
    {"Mbin", :groups},
    {"Mobilizon", :events},
    {"Mutual Aid", :marketplace},
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

  test "prefers NodeInfo software over actor and fallback hints" do
    payload = %{
      "nodeinfo" => %{"software" => %{"name" => "mastodon"}},
      "generator" => %{"name" => "Pixelfed"},
      "platform" => "owncast",
      "type" => "Video"
    }

    assert %{platform: "mastodon", family: :microblog, confidence: :software} =
             Platform.classify(payload)
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

  test "classifies bounded native presentation metadata" do
    payload = %{
      "pleroma" => %{
        "native" => %{
          "fields" => %{"platform" => "flohmarkt"}
        }
      }
    }

    assert %{platform: "flohmarkt", family: :marketplace, confidence: :software} =
             Platform.classify(payload)
  end

  test "falls back to ActivityPub object type when software is unknown" do
    assert %{platform: "activitypub-audio", family: :audio, confidence: :object} =
             Platform.classify(%{"type" => "Audio"})

    assert %{platform: "activitypub-group", family: :groups, confidence: :object} =
             Platform.classify(%{"object" => %{"type" => "Group"}})

    assert %{platform: "bookwyrm", family: :books, confidence: :object} =
             Platform.classify(%{"type" => "Review"})

    assert %{platform: "bookwyrm", family: :books, confidence: :object} =
             Platform.classify(%{"type" => "Work"})

    assert %{platform: "forgefed", family: :development, confidence: :object} =
             Platform.classify(%{"type" => "Ticket"})

    assert %{platform: "activitypub-document", family: :publishing, confidence: :object} =
             Platform.classify(%{"type" => "Document"})

    assert %{
             platform: "bonfire_valueflows",
             family: :coordination,
             confidence: :object
           } = Platform.classify(%{"type" => "ValueFlows:EconomicEvent"})

    assert %{platform: "forgefed", family: :development, confidence: :object} =
             Platform.classify(%{"type" => "Proposal"})

    assert %{platform: "bonfire_valueflows", family: :coordination, confidence: :object} =
             Platform.classify(%{"type" => "ValueFlows:Proposal"})

    assert %{platform: "activitypods", family: :coordination, confidence: :object} =
             Platform.classify(%{"type" => "pair:Project"})

    assert %{platform: "mutual_aid", family: :marketplace, confidence: :object} =
             Platform.classify(%{"type" => "maid:Offer"})

    assert %{platform: "mutual_aid", family: :marketplace, confidence: :object} =
             Platform.classify(%{"type" => "https://mutual-aid.app/ns/core#Request"})
  end

  test "keeps unknown input safe and generic" do
    assert %{platform: "unknown", family: :generic, confidence: :unknown} =
             Platform.classify(%{"software" => %{"name" => "some-new-fediverse-thing"}})
  end
end

# end of test/pleroma/web/federation/platform_test.exs
