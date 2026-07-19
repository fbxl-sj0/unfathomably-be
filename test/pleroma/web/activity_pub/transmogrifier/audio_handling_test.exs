# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.Transmogrifier.AudioHandlingTest do
  use Oban.Testing, repo: Pleroma.Repo
  use Pleroma.DataCase

  alias Pleroma.Activity
  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.Transmogrifier
  alias Pleroma.Web.CommonAPI

  import Pleroma.Factory

  require Pleroma.Constants

  test "it works for incoming listens" do
    _user = insert(:user, ap_id: "http://mastodon.example.org/users/admin")

    data = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [],
      "type" => "Listen",
      "id" => "http://mastodon.example.org/users/admin/listens/1234/activity",
      "actor" => "http://mastodon.example.org/users/admin",
      "object" => %{
        "type" => "Audio",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => [],
        "id" => "http://mastodon.example.org/users/admin/listens/1234",
        "attributedTo" => "http://mastodon.example.org/users/admin",
        "title" => "lain radio episode 1",
        "artist" => "lain",
        "album" => "lain radio",
        "length" => 180_000
      }
    }

    {:ok, %Activity{local: false} = activity} = Transmogrifier.handle_incoming(data)

    object = Object.normalize(activity, fetch: false)

    assert object.data["title"] == "lain radio episode 1"
    assert object.data["artist"] == "lain"
    assert object.data["album"] == "lain radio"
    assert object.data["length"] == 180_000
  end

  test "Funkwhale Audio object" do
    Tesla.Mock.mock(fn
      %{url: "https://channels.tests.funkwhale.audio/federation/actors/compositions"} ->
        %Tesla.Env{
          status: 200,
          body: File.read!("test/fixtures/tesla_mock/funkwhale_channel.json"),
          headers: HttpRequestMock.activitypub_object_headers()
        }
    end)

    data = File.read!("test/fixtures/tesla_mock/funkwhale_create_audio.json") |> Jason.decode!()

    {:ok, %Activity{local: false} = activity} = Transmogrifier.handle_incoming(data)

    assert object = Object.normalize(activity, fetch: false)

    assert object.data["to"] == ["https://www.w3.org/ns/activitystreams#Public"]

    assert object.data["cc"] == [
             "https://channels.tests.funkwhale.audio/federation/actors/compositions/followers"
           ]

    assert object.data["url"] == "https://channels.tests.funkwhale.audio/library/tracks/74"

    assert object.data["attachment"] == [
             %{
               "mediaType" => "audio/ogg",
               "type" => "Link",
               "url" => [
                 %{
                   "href" =>
                     "https://channels.tests.funkwhale.audio/api/v1/listen/3901e5d8-0445-49d5-9711-e096cf32e515/?upload=42342395-0208-4fee-a38d-259a6dae0871&download=false",
                   "mediaType" => "audio/ogg",
                   "type" => "Link"
                 }
               ]
             }
           ]
  end

  test "it accepts a Funkwhale Listen that references a Track" do
    actor = "https://audio.example/users/listener"
    track_ap_id = "https://audio.example/federation/music/tracks/123"
    _user = insert(:user, ap_id: actor)

    {:ok, _track} =
      Object.create(%{
        "actor" => "https://audio.example/federation/actors/service",
        "id" => track_ap_id,
        "name" => "Referenced Funkwhale track",
        "to" => [Pleroma.Constants.as_public()],
        "type" => "Audio"
      })

    data = %{
      "actor" => actor,
      "cc" => [],
      "id" => "https://audio.example/users/listener/listenings/456",
      "object" => track_ap_id,
      "to" => [Pleroma.Constants.as_public()],
      "type" => "Listen"
    }

    assert {:ok, %Activity{local: false} = activity} =
             Transmogrifier.handle_incoming(data)

    assert activity.data["object"] == track_ap_id
    assert Object.normalize(activity, fetch: false).data["name"] == "Referenced Funkwhale track"
  end

  test "it prepares a federated-track scrobble as a Funkwhale Track Listen" do
    user = insert(:user)
    track_ap_id = "https://audio.example/federation/music/tracks/789"

    {:ok, _track} =
      Object.create(%{
        "actor" => "https://audio.example/federation/actors/service",
        "id" => track_ap_id,
        "name" => "Outgoing Funkwhale track",
        "to" => [Pleroma.Constants.as_public()],
        "type" => "Audio"
      })

    assert {:ok, activity} =
             CommonAPI.listen(user, %{
               title: "Outgoing Funkwhale track",
               track_ap_id: track_ap_id
             })

    assert activity.data["object"] == track_ap_id

    assert {:ok, outgoing} = Transmogrifier.prepare_outgoing(activity.data)
    assert outgoing["object"] == %{"id" => track_ap_id, "type" => "Track"}
    refute Map.has_key?(outgoing, "_pleroma_listen_track_ap_id")
  end
end
