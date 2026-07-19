# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.Transmogrifier.AnnounceHandlingTest do
  use Pleroma.DataCase

  alias Pleroma.Activity
  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.Transmogrifier
  alias Pleroma.Web.CommonAPI

  import Pleroma.Factory

  require Pleroma.Constants

  test "it works for incoming honk announces" do
    user = insert(:user, ap_id: "https://honktest/u/test", local: false)
    other_user = insert(:user)
    {:ok, post} = CommonAPI.post(other_user, %{status: "bonkeronk"})

    announce = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "actor" => "https://honktest/u/test",
      "id" => "https://honktest/u/test/bonk/1793M7B9MQ48847vdx",
      "object" => post.data["object"],
      "published" => "2019-06-25T19:33:58Z",
      "to" => "https://www.w3.org/ns/activitystreams#Public",
      "type" => "Announce"
    }

    {:ok, %Activity{local: false}} = Transmogrifier.handle_incoming(announce)

    object = Object.get_by_ap_id(post.data["object"])

    assert length(object.data["announcements"]) == 1
    assert user.ap_id in object.data["announcements"]
  end

  test "it works for incoming announces with actor being inlined (kroeg)" do
    data = File.read!("test/fixtures/kroeg-announce-with-inline-actor.json") |> Jason.decode!()

    _user = insert(:user, local: false, ap_id: data["actor"]["id"])
    other_user = insert(:user)

    {:ok, post} = CommonAPI.post(other_user, %{status: "kroegeroeg"})

    data =
      data
      |> put_in(["object", "id"], post.data["object"])

    {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(data)

    assert data["actor"] == "https://puckipedia.com/"
  end

  test "it works for incoming announces, fetching the announced object" do
    data =
      File.read!("test/fixtures/mastodon-announce.json")
      |> Jason.decode!()
      |> Map.put("object", "http://mastodon.example.org/users/admin/statuses/99541947525187367")

    Tesla.Mock.mock(fn
      %{method: :get} ->
        %Tesla.Env{
          status: 200,
          body: File.read!("test/fixtures/mastodon-note-object.json"),
          headers: HttpRequestMock.activitypub_object_headers()
        }
    end)

    _user = insert(:user, local: false, ap_id: data["actor"])

    {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(data)

    assert data["actor"] == "http://mastodon.example.org/users/admin"
    assert data["type"] == "Announce"

    assert data["id"] ==
             "http://mastodon.example.org/users/admin/statuses/99542391527669785/activity"

    assert data["object"] ==
             "http://mastodon.example.org/users/admin/statuses/99541947525187367"

    assert(Activity.get_create_by_object_ap_id(data["object"]))
  end

  @tag capture_log: true
  test "it works for incoming announces with an existing activity" do
    user = insert(:user)
    {:ok, activity} = CommonAPI.post(user, %{status: "hey"})

    data =
      File.read!("test/fixtures/mastodon-announce.json")
      |> Jason.decode!()
      |> Map.put("object", activity.data["object"])

    _user = insert(:user, local: false, ap_id: data["actor"])

    {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(data)

    assert data["actor"] == "http://mastodon.example.org/users/admin"
    assert data["type"] == "Announce"

    assert data["id"] ==
             "http://mastodon.example.org/users/admin/statuses/99542391527669785/activity"

    assert data["object"] == activity.data["object"]

    assert Activity.get_create_by_object_ap_id(data["object"]).id == activity.id
  end

  test "outgoing group announces embed root Notes as Lemmy-style Create/Page activities" do
    author = insert(:user, local: false, ap_id: "https://lotide.example/apub/users/1")
    group = insert(:user, actor_type: "Group")

    object =
      insert(:note,
        user: author,
        data: %{
          "id" => "https://lotide.example/apub/posts/1",
          "type" => "Note",
          "actor" => author.ap_id,
          "attributedTo" => author.ap_id,
          "to" => [group.ap_id, Pleroma.Constants.as_public()],
          "cc" => [],
          "audience" => group.ap_id,
          "name" => "Lotide-shaped group root",
          "content" => "<p>A group post body.</p>",
          "context" => "https://lotide.example/apub/posts/1"
        }
      )

    announce = %{
      "id" => Pleroma.Web.ActivityPub.Utils.generate_activity_id(),
      "type" => "Announce",
      "actor" => group.ap_id,
      "object" => object.data["id"],
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [group.follower_address]
    }

    assert {:ok, outgoing} = Transmogrifier.prepare_outgoing(announce)

    assert outgoing["object"]["type"] == "Create"
    assert outgoing["object"]["actor"] == author.ap_id
    assert outgoing["object"]["audience"] == group.ap_id
    assert outgoing["object"]["to"] == [Pleroma.Constants.as_public()]
    assert outgoing["object"]["cc"] == [group.ap_id]

    page = outgoing["object"]["object"]

    assert page["id"] == object.data["id"]
    assert page["type"] == "Page"
    assert page["attributedTo"] == author.ap_id
    assert page["name"] == "Lotide-shaped group root"
    assert page["audience"] == group.ap_id
    assert page["to"] == [group.ap_id, Pleroma.Constants.as_public()]
    assert page["cc"] == []
    refute Map.has_key?(page, "actor")
    refute Map.has_key?(page, "bto")
    refute Map.has_key?(page, "bcc")
  end

  test "it handles Lemmy-style announces of delete activities" do
    actor = insert(:user, local: false, ap_id: "http://lemmy.example/u/admin")

    create = %{
      "id" => "http://lemmy.example/activities/create/1",
      "actor" => actor.ap_id,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => ["http://lemmy.example/c/main"],
      "type" => "Create",
      "object" => %{
        "type" => "Note",
        "id" => "http://lemmy.example/comment/1",
        "actor" => actor.ap_id,
        "attributedTo" => actor.ap_id,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => ["http://lemmy.example/c/main"],
        "content" => "<p>threadiverse comment</p>",
        "mediaType" => "text/html",
        "published" => "2026-06-21T00:00:00Z"
      }
    }

    {:ok, activity} = Transmogrifier.handle_incoming(create)

    announce = %{
      "id" => "http://lemmy.example/activities/announce/delete/1",
      "actor" => "http://lemmy.example/c/main",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => ["http://lemmy.example/c/main/followers"],
      "type" => "Announce",
      "object" => %{
        "id" => "http://lemmy.example/activities/delete/1",
        "actor" => actor.ap_id,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => ["http://lemmy.example/c/main"],
        "object" => "http://lemmy.example/comment/1",
        "type" => "Delete",
        "audience" => "http://lemmy.example/c/main"
      }
    }

    {:ok, %Activity{data: %{"type" => "Delete"}}} = Transmogrifier.handle_incoming(announce)

    refute Activity.get_by_id(activity.id)

    object = Object.get_by_ap_id("http://lemmy.example/comment/1")
    assert object.data["type"] == "Tombstone"
  end

  @tag capture_log: true
  test "it rejects announces wrapping malformed activities without raising" do
    actor =
      insert(:user,
        local: false,
        ap_id: "https://malformed-announce.example/u/alice",
        follower_address: "https://malformed-announce.example/u/alice/followers"
      )

    group =
      insert(:user,
        local: false,
        actor_type: "Group",
        ap_id: "https://malformed-announce.example/c/main",
        follower_address: "https://malformed-announce.example/c/main/followers"
      )

    announce = %{
      "id" => "https://malformed-announce.example/activities/announce/1",
      "actor" => group.ap_id,
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [group.follower_address],
      "type" => "Announce",
      "object" => %{
        "id" => "https://malformed-announce.example/activities/like/1",
        "actor" => actor.ap_id,
        "to" => [Pleroma.Constants.as_public()],
        "cc" => [group.follower_address],
        "object" => %{"type" => "Note", "content" => "missing id"},
        "type" => "Like"
      }
    }

    assert {:error, _} = Transmogrifier.handle_incoming(announce)
  end

  test "it handles threadiverse announces of create activities" do
    actor = insert(:user, local: false, ap_id: "http://piefed.example/u/admin")

    create = %{
      "id" => "http://piefed.example/activities/create/1",
      "actor" => actor.ap_id,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => ["http://piefed.example/c/main"],
      "type" => "Create",
      "object" => %{
        "type" => "Note",
        "id" => "http://piefed.example/comment/1",
        "actor" => actor.ap_id,
        "attributedTo" => actor.ap_id,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "cc" => ["http://piefed.example/c/main"],
        "content" => "<p>threadiverse comment</p>",
        "mediaType" => "text/html",
        "published" => "2026-06-21T00:00:00Z"
      }
    }

    announce = %{
      "id" => "http://piefed.example/activities/announce/create/1",
      "actor" => "http://piefed.example/c/main",
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => ["http://piefed.example/c/main/followers"],
      "type" => "Announce",
      "object" => create
    }

    {:ok, %Activity{data: %{"type" => "Create"}}} = Transmogrifier.handle_incoming(announce)

    assert Object.get_by_ap_id("http://piefed.example/comment/1")
  end

  test "it does not count group actor announces as user boosts" do
    author = insert(:user)

    group =
      insert(:user,
        local: false,
        actor_type: "Group",
        ap_id: "https://mbin.example/m/main",
        follower_address: "https://mbin.example/m/main/followers"
      )

    {:ok, post} = CommonAPI.post(author, %{status: "group-distributed post"})
    object = Object.get_by_ap_id(post.data["object"])

    announce = %{
      "id" => "https://mbin.example/activities/announce/1",
      "actor" => group.ap_id,
      "object" => object.data["id"],
      "published" => "2026-06-24T00:00:00Z",
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [group.follower_address],
      "type" => "Announce"
    }

    assert {:ok, %Activity{local: false}} = Transmogrifier.handle_incoming(announce)

    object = Object.get_by_ap_id(post.data["object"])
    assert object.data["announcement_count"] == 0
    refute group.ap_id in object.data["announcements"]
  end

  test "it unwraps Mbin group announces around Update activities" do
    author =
      insert(:user,
        local: false,
        ap_id: "https://mbin.example/u/user",
        nickname: "user@mbin.example",
        follower_address: "https://mbin.example/u/user/followers"
      )

    group =
      insert(:user,
        local: false,
        actor_type: "Group",
        ap_id: "https://mbin.example/m/main",
        follower_address: "https://mbin.example/m/main/followers"
      )

    note =
      insert(:note,
        user: author,
        data: %{
          "id" => "https://mbin.example/m/main/p/1",
          "to" => [group.ap_id, Pleroma.Constants.as_public()],
          "cc" => [author.follower_address],
          "content" => "<p>old body</p>",
          "context" => "https://mbin.example/m/main/p/1/context",
          "published" => "2026-06-23T00:00:00Z"
        }
      )

    _create = insert(:note_activity, user: author, note: note, local: false)

    updated_note =
      note.data
      |> Map.put("content", "<p>new body</p>")
      |> Map.put("audience", group.ap_id)
      |> Map.put("updated", "2026-06-24T00:00:00Z")

    update = %{
      "id" => "https://mbin.example/activities/update/1",
      "type" => "Update",
      "actor" => author.ap_id,
      "published" => "2026-06-24T00:00:00Z",
      "to" => [group.ap_id, Pleroma.Constants.as_public()],
      "cc" => [author.follower_address],
      "object" => updated_note,
      "audience" => group.ap_id
    }

    announce = %{
      "id" => "https://mbin.example/activities/announce/update/1",
      "type" => "Announce",
      "actor" => group.ap_id,
      "object" => update,
      "to" => [Pleroma.Constants.as_public()],
      "cc" => [group.follower_address],
      "published" => "2026-06-24T00:00:01Z",
      "audience" => group.ap_id
    }

    assert {:ok, %Activity{data: %{"type" => "Update"}}} =
             Transmogrifier.handle_incoming(announce)

    assert %{data: %{"content" => "<p>new body</p>"}} = Object.get_by_ap_id(note.data["id"])
  end

  test "it accepts Ibis comments whose wrapping Create adds the Group recipient" do
    author =
      insert(:user,
        local: false,
        ap_id: "https://ibis.example/user/editor",
        follower_address: nil
      )

    group =
      insert(:user,
        local: false,
        actor_type: "Group",
        ap_id: "https://ibis.example/",
        follower_address: nil
      )

    _article =
      insert(:note,
        user: author,
        data: %{
          "id" => "https://ibis.example/article/Alien_Wiki",
          "content" => "<p>The parent Ibis Article.</p>",
          "to" => [Pleroma.Constants.as_public(), group.ap_id]
        }
      )

    note = %{
      "attributedTo" => author.ap_id,
      "content" => "<p>A native Ibis comment.</p>",
      "id" => "https://ibis.example/comment/1",
      "inReplyTo" => "https://ibis.example/article/Alien_Wiki",
      "published" => "2026-07-18T00:00:00Z",
      "to" => [Pleroma.Constants.as_public()],
      "type" => "Note"
    }

    create = %{
      "actor" => author.ap_id,
      "cc" => [],
      "id" => "https://ibis.example/activity/create-comment-1",
      "object" => note,
      "to" => [Pleroma.Constants.as_public(), group.ap_id],
      "type" => "Create"
    }

    announce = %{
      "actor" => group.ap_id,
      "cc" => ["https://ibis.example/followers"],
      "id" => "https://ibis.example/activity/announce-comment-1",
      "object" => create,
      "to" => [Pleroma.Constants.as_public()],
      "type" => "Announce"
    }

    assert {:ok, %Activity{data: %{"type" => "Create"}}} =
             Transmogrifier.handle_incoming(announce)

    assert %Object{data: stored_note} = Object.get_by_ap_id(note["id"])
    assert group.ap_id in stored_note["to"]
    assert Pleroma.Constants.as_public() in stored_note["to"]
  end

  # Ignore inlined activities for now
  @tag skip: true
  test "it works for incoming announces with an inlined activity" do
    data =
      File.read!("test/fixtures/mastodon-announce-private.json")
      |> Jason.decode!()

    _user =
      insert(:user,
        local: false,
        ap_id: data["actor"],
        follower_address: data["actor"] <> "/followers"
      )

    {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(data)

    assert data["actor"] == "http://mastodon.example.org/users/admin"
    assert data["type"] == "Announce"

    assert data["id"] ==
             "http://mastodon.example.org/users/admin/statuses/99542391527669785/activity"

    object = Object.normalize(data["object"], fetch: false)

    assert object.data["id"] == "http://mastodon.example.org/@admin/99541947525187368"
    assert object.data["content"] == "this is a private toot"
  end

  @tag capture_log: true
  test "it rejects incoming announces with an inlined activity from another origin" do
    Tesla.Mock.mock(fn
      %{method: :get} -> %Tesla.Env{status: 404, body: ""}
    end)

    data =
      File.read!("test/fixtures/bogus-mastodon-announce.json")
      |> Jason.decode!()

    _user = insert(:user, local: false, ap_id: data["actor"])

    assert {:error, _e} = Transmogrifier.handle_incoming(data)
  end
end
