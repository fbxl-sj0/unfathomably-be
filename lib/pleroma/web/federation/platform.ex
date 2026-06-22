# Project: Unfathomably Backend
# ------------------------------
#
# File: lib/pleroma/web/federation/platform.ex
#
# Purpose:
#
#   Classify remote ActivityPub software and object payloads into stable
#   product families that the backend and frontend can test against.
#
# Responsibilities:
#
#   * map known federated software names to UI families
#   * fall back from software metadata to ActivityPub object type
#   * provide a compact, deterministic contract for fixture tests
#
# This file intentionally does NOT contain:
#
#   * network calls
#   * persistence logic
#   * frontend rendering decisions

defmodule Pleroma.Web.Federation.Platform do
  @moduledoc """
  Classifies federated platforms into families we can test and render.

  The point is not to make every remote service look identical. The point is to
  give backend normalization and frontend rendering the same vocabulary, so a
  Funkwhale channel, a Lemmy community, a WordPress blog, and a Pixelfed profile
  can each get a native-feeling surface while still sharing fallback behavior.
  """

  @type family ::
          :audio
          | :video
          | :longform
          | :microblog
          | :photo
          | :books
          | :bookmarks
          | :groups
          | :events
          | :local
          | :generic

  @type confidence :: :software | :object | :unknown

  @type classification :: %{
          platform: String.t(),
          label: String.t(),
          family: family(),
          confidence: confidence()
        }

  @software %{
    "ap groups" => %{platform: "ap_groups", label: "AP-Groups", family: :groups},
    "bookwyrm" => %{platform: "bookwyrm", label: "BookWyrm", family: :books},
    "bonfire" => %{platform: "bonfire", label: "Bonfire", family: :groups},
    "buzzrelay" => %{platform: "buzzrelay", label: "BuzzRelay", family: :groups},
    "castopod" => %{platform: "castopod", label: "Castopod", family: :audio},
    "discourse" => %{platform: "discourse", label: "Discourse", family: :groups},
    "elgg" => %{platform: "elgg", label: "Elgg", family: :groups},
    "fedibird group" => %{platform: "fedibird_group", label: "Fedibird Group", family: :groups},
    "fedigroup" => %{platform: "fedigroups", label: "FediGroups", family: :groups},
    "fedigroups" => %{platform: "fedigroups", label: "FediGroups", family: :groups},
    "flipboard" => %{platform: "flipboard", label: "Flipboard", family: :longform},
    "friendica" => %{platform: "friendica", label: "Friendica", family: :groups},
    "funkwhale" => %{platform: "funkwhale", label: "Funkwhale", family: :audio},
    "gancio" => %{platform: "gancio", label: "Gancio", family: :events},
    "gotosocial" => %{platform: "gotosocial", label: "GoToSocial", family: :microblog},
    "group actor" => %{platform: "group_actor", label: "Group Actor", family: :groups},
    "guppe" => %{platform: "guppe", label: "Guppe", family: :groups},
    "hubzilla" => %{platform: "hubzilla", label: "Hubzilla", family: :groups},
    "iceshrimp" => %{platform: "iceshrimp", label: "Iceshrimp", family: :microblog},
    "kbin" => %{platform: "kbin", label: "Kbin", family: :groups},
    "lemmy" => %{platform: "lemmy", label: "Lemmy", family: :groups},
    "local" => %{platform: "local", label: "Local", family: :local},
    "lotide" => %{platform: "lotide", label: "Lotide", family: :groups},
    "mastodon" => %{platform: "mastodon", label: "Mastodon", family: :microblog},
    "mbin" => %{platform: "mbin", label: "Mbin", family: :groups},
    "misskey" => %{platform: "misskey", label: "Misskey", family: :microblog},
    "mitra" => %{platform: "mitra", label: "Mitra", family: :microblog},
    "mobilizon" => %{platform: "mobilizon", label: "Mobilizon", family: :events},
    "nodebb" => %{platform: "nodebb", label: "NodeBB", family: :groups},
    "owncast" => %{platform: "owncast", label: "Owncast", family: :video},
    "peertube" => %{platform: "peertube", label: "PeerTube", family: :video},
    "piefed" => %{platform: "piefed", label: "PieFed", family: :groups},
    "pixelfed" => %{platform: "pixelfed", label: "Pixelfed", family: :photo},
    "pleroma" => %{platform: "pleroma", label: "Pleroma/Akkoma", family: :microblog},
    "postmarks" => %{platform: "postmarks", label: "Postmarks", family: :bookmarks},
    "sharkey" => %{platform: "sharkey", label: "Sharkey", family: :microblog},
    "snac" => %{platform: "snac", label: "snac", family: :microblog},
    "smithereen" => %{platform: "smithereen", label: "Smithereen", family: :groups},
    "streams forte" => %{platform: "streams_forte", label: "Streams/Forte", family: :groups},
    "tootgroup" => %{platform: "tootgroup", label: "tootgroup.py", family: :groups},
    "wafrn" => %{platform: "wafrn", label: "wafrn", family: :microblog},
    "wordpress event bridge" => %{
      platform: "wordpress_event_bridge",
      label: "WordPress Event Bridge",
      family: :events
    },
    "wordpress" => %{platform: "wordpress", label: "WordPress", family: :longform},
    "writefreely" => %{platform: "writefreely", label: "WriteFreely", family: :longform}
  }

  @object_types %{
    "Article" => %{platform: "activitypub-article", label: "Article", family: :longform},
    "Audio" => %{platform: "activitypub-audio", label: "Audio", family: :audio},
    "Event" => %{platform: "activitypub-event", label: "Event", family: :events},
    "Group" => %{platform: "activitypub-group", label: "Group", family: :groups},
    "Image" => %{platform: "activitypub-image", label: "Image", family: :photo},
    "Note" => %{platform: "activitypub-note", label: "Note", family: :microblog},
    "Page" => %{platform: "activitypub-page", label: "Page", family: :longform},
    "Question" => %{platform: "activitypub-question", label: "Question", family: :groups},
    "Video" => %{platform: "activitypub-video", label: "Video", family: :video}
  }

  @doc "Returns all software platform records used by compatibility fixtures."
  @spec known_platforms() :: [classification()]
  def known_platforms do
    @software
    |> Map.values()
    |> Enum.map(&with_confidence(&1, :software))
    |> Enum.sort_by(& &1.platform)
  end

  @doc "Classifies a software name, NodeInfo payload, actor, or ActivityPub object."
  @spec classify(term()) :: classification()
  def classify(name) when is_binary(name) do
    software_classification(%{"software" => %{"name" => name}}) || unknown()
  end

  def classify(%{} = input) do
    software_classification(input) || object_classification(input) || unknown()
  end

  def classify(_), do: unknown()

  defp software_classification(input) do
    input
    |> software_names()
    |> Enum.find_value(&lookup_software/1)
    |> case do
      nil -> nil
      classification -> with_confidence(classification, :software)
    end
  end

  defp object_classification(input) do
    type =
      get_path(input, [:type]) ||
        get_path(input, [:object, :type]) ||
        get_path(input, [:activity, :object, :type])

    case type do
      type when is_binary(type) ->
        @object_types
        |> Map.get(type)
        |> case do
          nil -> nil
          classification -> with_confidence(classification, :object)
        end

      _ ->
        nil
    end
  end

  defp lookup_software(name) do
    normalized = normalize_name(name)

    Map.get(@software, normalized) ||
      normalized
      |> String.split(" ", trim: true)
      |> Enum.find_value(&Map.get(@software, &1))
  end

  defp software_names(input) do
    [
      get_path(input, [:software, :name]),
      get_path(input, [:nodeinfo, :software, :name]),
      get_path(input, [:metadata, :software, :name]),
      get_path(input, [:platform]),
      get_path(input, [:application]),
      get_path(input, [:generator])
    ]
    |> Enum.flat_map(&name_candidates/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp name_candidates(%{} = value) do
    [
      get_path(value, [:name]),
      get_path(value, [:type]),
      get_path(value, [:id])
    ]
    |> Enum.flat_map(&name_candidates/1)
  end

  defp name_candidates(value) when is_binary(value), do: [value]
  defp name_candidates(_), do: []

  defp normalize_name(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.trim()
  end

  defp get_path(value, path) do
    Enum.reduce_while(path, value, fn key, current ->
      case get_value(current, key) do
        nil -> {:halt, nil}
        next -> {:cont, next}
      end
    end)
  end

  defp get_value(%{} = value, key) when is_atom(key) do
    Map.get(value, key) || Map.get(value, Atom.to_string(key))
  end

  defp get_value(%{} = value, key) when is_binary(key), do: Map.get(value, key)
  defp get_value(_, _), do: nil

  defp with_confidence(classification, confidence) do
    Map.put(classification, :confidence, confidence)
  end

  defp unknown do
    %{
      platform: "unknown",
      label: "Unknown",
      family: :generic,
      confidence: :unknown
    }
  end
end

# end of lib/pleroma/web/federation/platform.ex
