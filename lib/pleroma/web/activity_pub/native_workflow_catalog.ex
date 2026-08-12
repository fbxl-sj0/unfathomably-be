# Unfathomably native federation workflow catalog
# ------------------------------------------------
#
# File: native_workflow_catalog.ex
#
# Purpose:
#   Describe the specialized federation workflows supported by this server in
#   a stable, provider-neutral form that clients can present to ordinary users.
#
# Responsibilities:
#   - keep supported native families aligned with backend capabilities
#   - identify the ecosystems and object shapes represented by each family
#   - describe safe local participation actions without listing remote servers
#
# This file intentionally does not discover instances, contact remote
# providers, resolve objects, or establish federation relationships.

defmodule Pleroma.Web.ActivityPub.NativeWorkflowCatalog do
  @moduledoc false

  @workflows [
    %{
      family: "books",
      platforms: ["BookWyrm"],
      objects: ["books", "editions", "shelves", "reviews", "reading activity"],
      participation: ["find books", "follow readers", "review", "shelve", "track reading"]
    },
    %{
      family: "culture",
      platforms: ["NeoDB"],
      objects: ["catalog items", "collections", "ratings", "reviews"],
      participation: ["find works", "follow reviewers", "rate", "review", "collect"]
    },
    %{
      family: "audio",
      platforms: ["Funkwhale", "Castopod"],
      objects: ["artists", "albums", "tracks", "podcasts", "libraries", "playlists"],
      participation: ["listen", "follow creators", "favourite", "share recordings"]
    },
    %{
      family: "video",
      platforms: ["PeerTube", "Owncast"],
      objects: ["channels", "videos", "playlists", "live streams"],
      participation: ["watch", "follow channels", "comment", "react", "share video"]
    },
    %{
      family: "photo",
      platforms: ["Pixelfed"],
      objects: ["photographs", "albums", "image descriptions"],
      participation: ["browse", "follow photographers", "reply", "favourite", "share photos"]
    },
    %{
      family: "events",
      platforms: ["Mobilizon", "Gancio", "WordPress Event Bridge"],
      objects: ["events", "places", "organizers", "participation records"],
      participation: ["find events", "follow organizers", "RSVP", "comment", "create events"]
    },
    %{
      family: "groups",
      platforms: [
        "Lemmy",
        "MBin",
        "PieFed",
        "NodeBB",
        "Discourse",
        "Friendica",
        "Hubzilla",
        "FediGroups",
        "Bonfire"
      ],
      objects: ["communities", "forums", "channels", "topics", "moderation activity"],
      participation: ["find communities", "follow or join", "post", "reply", "moderate"]
    },
    %{
      family: "marketplace",
      platforms: ["Flohmarkt"],
      objects: ["classified advertisements", "offers", "requests", "seller profiles"],
      participation: [
        "browse listings",
        "contact sellers",
        "offer",
        "request",
        "publish listings"
      ]
    },
    %{
      family: "routes",
      platforms: ["Wanderer"],
      objects: ["routes", "trails", "geographic data", "GPX tracks"],
      participation: ["find routes", "inspect maps", "follow authors", "share routes"]
    },
    %{
      family: "models",
      platforms: ["Manyfold"],
      objects: ["3D models", "files", "collections", "creators"],
      participation: ["find models", "inspect files", "follow creators", "share models"]
    },
    %{
      family: "development",
      platforms: ["ForgeFed", "Forgejo", "Gitea", "GitLab", "Vervis"],
      objects: ["projects", "repositories", "issues", "merge requests", "commits"],
      participation: ["follow projects", "inspect issues", "reply", "share development activity"]
    },
    %{
      family: "coordination",
      platforms: ["Bonfire ValueFlows", "mutual-aid federation", "ActivityPods"],
      objects: ["offers", "needs", "resources", "intentions", "processes", "proposals"],
      participation: [
        "find needs",
        "offer help",
        "request help",
        "coordinate",
        "publish intentions"
      ]
    },
    %{
      family: "games",
      platforms: ["Castling.club"],
      objects: ["chess games", "players", "positions", "moves", "challenges"],
      participation: ["find players", "inspect games", "follow play", "join challenges"]
    },
    %{
      family: "longform",
      platforms: ["WriteFreely", "WordPress", "Flipboard", "RSS and Atom publishers"],
      objects: ["articles", "blogs", "newsletters", "feed entries"],
      participation: ["read", "follow authors", "reply", "share articles"]
    },
    %{
      family: "bookmarks",
      platforms: ["Postmarks"],
      objects: ["bookmarks", "links", "notes", "tags"],
      participation: ["find links", "follow curators", "save", "annotate", "share bookmarks"]
    },
    %{
      family: "publishing",
      platforms: ["ZenPub", "Ibis", "XWiki", "CommonsPub"],
      objects: ["publications", "documents", "chapters", "knowledge resources"],
      participation: ["read", "follow publishers", "discuss", "share publications"]
    }
  ]

  @workflow_paths %{
    "audio" => %{
      creation: ["describe the recording", "upload playable audio", "publish"],
      actions: ["listen", "favourite", "reply", "follow the artist"]
    },
    "video" => %{
      creation: ["describe the video", "upload the video", "publish"],
      actions: ["watch", "comment", "react", "share"]
    },
    "longform" => %{
      creation: ["write the article", "add publishing details", "publish"],
      actions: ["read", "reply", "follow the author", "share"]
    },
    "photo" => %{
      creation: ["describe the photographs", "upload the images", "publish"],
      actions: ["view full size", "reply", "favourite", "share"]
    },
    "books" => %{
      creation: ["identify the book", "record reading or review", "publish"],
      actions: ["add to shelf", "rate or review", "discuss", "follow the reader"]
    },
    "bookmarks" => %{
      creation: ["paste the page address", "add an annotation", "publish"],
      actions: ["open the page", "save", "discuss", "share"]
    },
    "groups" => %{
      creation: ["name the community", "set access and posting rules", "create"],
      actions: ["join or follow", "read discussions", "post", "moderate"]
    },
    "events" => %{
      creation: ["describe the event", "set time and place", "publish"],
      actions: ["RSVP", "discuss", "follow the organizer", "share"]
    },
    "marketplace" => %{
      creation: ["describe the offer or request", "set terms and fulfilment", "publish"],
      actions: ["contact privately", "discuss terms", "track availability", "share"]
    },
    "routes" => %{
      creation: ["describe the route", "upload GPX or link its route page", "publish"],
      actions: ["view map", "download GPX", "discuss", "follow the author"]
    },
    "models" => %{
      creation: ["describe the model", "upload or link its model file", "publish"],
      actions: ["inspect", "download", "discuss", "follow the designer"]
    },
    "development" => %{
      creation: ["choose project or ticket", "add repository and development details", "publish"],
      actions: ["follow development", "file issues", "discuss", "track state"]
    },
    "coordination" => %{
      creation: ["choose offer or request", "describe resource, place, and time", "publish"],
      actions: ["respond", "coordinate", "track fulfilment", "share"]
    },
    "games" => %{
      creation: ["choose the game and players", "set position, time, and state", "publish"],
      actions: ["inspect position", "respond or join", "follow play", "discuss"]
    },
    "culture" => %{
      creation: ["identify the work", "record rating or review", "publish"],
      actions: ["rate or review", "discuss", "collect", "follow reviewers"]
    },
    "publishing" => %{
      creation: ["describe the publication", "upload or link the document", "publish"],
      actions: ["read", "download", "discuss", "follow the publisher"]
    }
  }

  @spec render() :: %{version: pos_integer(), workflows: [map()]}
  def render do
    workflows =
      Enum.map(@workflows, fn workflow ->
        Map.merge(workflow, Map.fetch!(@workflow_paths, workflow.family))
      end)

    %{version: 2, workflows: workflows}
  end
end

# end of native_workflow_catalog.ex
