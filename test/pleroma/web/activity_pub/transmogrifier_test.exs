# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.TransmogrifierTest do
  use Oban.Testing, repo: Pleroma.Repo
  use Pleroma.DataCase

  alias Pleroma.Activity
  alias Pleroma.Object
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Transmogrifier
  alias Pleroma.Web.ActivityPub.Utils
  alias Pleroma.Web.AdminAPI.AccountView
  alias Pleroma.Web.CommonAPI

  require Pleroma.Constants

  import Mock
  import Pleroma.Factory
  import ExUnit.CaptureLog

  setup_all do
    Tesla.Mock.mock_global(fn env -> apply(HttpRequestMock, :request, [env]) end)
    :ok
  end

  setup do: clear_config([:instance, :max_remote_account_fields])

  describe "handle_incoming" do
    test "it works for incoming unfollows with an existing follow" do
      user = insert(:user)

      follow_data =
        File.read!("test/fixtures/mastodon-follow-activity.json")
        |> Jason.decode!()
        |> Map.put("object", user.ap_id)

      {:ok, %Activity{data: _, local: false}} = Transmogrifier.handle_incoming(follow_data)

      data =
        File.read!("test/fixtures/mastodon-unfollow-activity.json")
        |> Jason.decode!()
        |> Map.put("object", follow_data)

      {:ok, %Activity{data: data, local: false}} = Transmogrifier.handle_incoming(data)

      assert data["type"] == "Undo"
      assert data["object"]["type"] == "Follow"
      assert data["object"]["object"] == user.ap_id
      assert data["actor"] == "http://mastodon.example.org/users/admin"

      refute User.following?(User.get_cached_by_ap_id(data["actor"]), user)
    end

    test "it accepts Flag activities" do
      user = insert(:user)
      other_user = insert(:user)

      {:ok, activity} = CommonAPI.post(user, %{status: "test post"})
      object = Object.normalize(activity, fetch: false)

      note_obj = %{
        "type" => "Note",
        "id" => activity.object.data["id"],
        "content" => "test post",
        "published" => object.data["published"],
        "actor" => AccountView.render("show.json", %{user: user, skip_visibility_check: true})
      }

      message = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "cc" => [user.ap_id],
        "object" => [user.ap_id, activity.data["id"]],
        "type" => "Flag",
        "content" => "blocked AND reported!!!",
        "actor" => other_user.ap_id
      }

      assert {:ok, activity} = Transmogrifier.handle_incoming(message)

      assert activity.data["object"] == [user.ap_id, note_obj]
      assert activity.data["content"] == "blocked AND reported!!!"
      assert activity.data["actor"] == other_user.ap_id
      assert activity.data["cc"] == [user.ap_id]
    end

    test "it unwraps Mbin group announces around Flag activities" do
      user = insert(:user)
      reporter = insert(:user, local: false)

      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          ap_id: "https://mbin.example/m/main",
          follower_address: "https://mbin.example/m/main/followers"
        )

      {:ok, reported_activity} = CommonAPI.post(user, %{status: "test post"})
      object = Object.normalize(reported_activity, fetch: false)

      note_obj = %{
        "type" => "Note",
        "id" => reported_activity.object.data["id"],
        "content" => "test post",
        "published" => object.data["published"],
        "actor" => AccountView.render("show.json", %{user: user, skip_visibility_check: true})
      }

      flag = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "actor" => reporter.ap_id,
        "content" => "reported from a magazine",
        "object" => [user.ap_id, reported_activity.data["id"]],
        "to" => [user.ap_id],
        "cc" => [group.ap_id],
        "type" => "Flag"
      }

      announce = %{
        "id" => "https://mbin.example/activities/announce/flag/1",
        "actor" => group.ap_id,
        "object" => flag,
        "published" => "2026-06-24T00:00:00Z",
        "to" => [Pleroma.Constants.as_public()],
        "cc" => [group.follower_address],
        "type" => "Announce"
      }

      assert {:ok, activity} = Transmogrifier.handle_incoming(announce)

      assert activity.data["type"] == "Flag"
      assert activity.data["object"] == [user.ap_id, note_obj]
      assert activity.data["content"] == "reported from a magazine"
      assert activity.data["actor"] == reporter.ap_id
      assert activity.data["cc"] == [user.ap_id]
    end

    test "it rejects Flag activities when both reporter and reported account are remote" do
      reporter = insert(:user, local: false, domain: "mastodon.cat")
      reported = insert(:user, local: false, domain: "nicecrew.digital")

      message = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "actor" => reporter.ap_id,
        "content" => "blocked AND reported!!!",
        "object" => [reported.ap_id, "https://nicecrew.digital/objects/report-status"],
        "type" => "Flag"
      }

      assert {:reject, reason} = Transmogrifier.handle_incoming(message)
      assert reason =~ "third-party report"
      refute "Flag" |> Pleroma.Activity.Queries.by_type() |> Pleroma.Repo.one()
    end

    test "it acknowledges View and Read activities without storing receipt state" do
      for type <- ["View", "Read"] do
        message = %{
          "id" => "https://friendica.example/activities/#{String.downcase(type)}/1",
          "actor" => "https://friendica.example/profile/alice",
          "object" => "https://social.example/objects/1",
          "type" => type
        }

        assert {:ok, :ignored} = Transmogrifier.handle_incoming(message)
        refute Activity.get_by_ap_id(message["id"])
      end
    end

    test "it acknowledges Owncast stream lifecycle activities without storing presence state" do
      public = Pleroma.Constants.as_public()

      offer = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "https://silo.ffmuc.net/federation/stream-live",
        "type" => "Offer",
        "actor" => "https://silo.ffmuc.net/federation/user/streamer",
        "object" => "https://silo.ffmuc.net",
        "to" => public,
        "cc" => "https://silo.ffmuc.net/federation/user/streamer/followers",
        "https://owncast.online/ns#serverName" => "Freifunk München - Weather Stream",
        "https://owncast.online/ns#streamStatus" => "live",
        "https://owncast.online/ns#streamTitle" => "Heimstettner See Cam"
      }

      leave = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "https://silo.ffmuc.net/federation/stream-offline",
        "type" => "Leave",
        "actor" => "https://silo.ffmuc.net/federation/user/streamer",
        "object" => "https://silo.ffmuc.net",
        "to" => public,
        "cc" => "https://silo.ffmuc.net/federation/user/streamer/followers"
      }

      for message <- [offer, leave] do
        assert {:ok, :ignored} = Transmogrifier.handle_incoming(message)
        refute Activity.get_by_ap_id(message["id"])
      end
    end

    test "it rejects ordinary Offer activities without Owncast stream metadata" do
      message = %{
        "id" => "https://example.org/activities/offer/1",
        "type" => "Offer",
        "actor" => "https://example.org/users/alice",
        "object" => "https://example.org/objects/1"
      }

      assert :error = Transmogrifier.handle_incoming(message)
    end

    test "it accepts Move activities" do
      old_user = insert(:user)
      new_user = insert(:user)

      message = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => "Move",
        "actor" => old_user.ap_id,
        "object" => old_user.ap_id,
        "target" => new_user.ap_id
      }

      assert :error = Transmogrifier.handle_incoming(message)

      {:ok, _new_user} = User.update_and_set_cache(new_user, %{also_known_as: [old_user.ap_id]})

      assert {:ok, %Activity{} = activity} = Transmogrifier.handle_incoming(message)
      assert activity.actor == old_user.ap_id
      assert activity.data["actor"] == old_user.ap_id
      assert activity.data["object"] == old_user.ap_id
      assert activity.data["target"] == new_user.ap_id
      assert activity.data["type"] == "Move"
    end

    test "it fixes both the Create and object contexts in a reply" do
      insert(:user, ap_id: "https://mk.absturztau.be/users/8ozbzjs3o8")
      insert(:user, ap_id: "https://p.helene.moe/users/helene")

      create_activity =
        "test/fixtures/create-pleroma-reply-to-misskey-thread.json"
        |> File.read!()
        |> Jason.decode!()

      assert {:ok, %Activity{} = activity} = Transmogrifier.handle_incoming(create_activity)

      object = Object.normalize(activity, fetch: false)

      assert activity.data["context"] == object.data["context"]
    end

    test "it keeps link tags" do
      insert(:user, ap_id: "https://example.org/users/alice")

      message = File.read!("test/fixtures/fep-e232.json") |> Jason.decode!()

      assert {{:ok, activity}, log} =
               with_log(fn ->
                 Transmogrifier.handle_incoming(message)
               end)

      assert log =~ "Couldn't fetch \"https://example.org/objects/9\""

      object = Object.normalize(activity)
      assert [%{"type" => "Mention"}, %{"type" => "Link"}] = object.data["tag"]
    end

    test "it accepts quote posts" do
      insert(:user, ap_id: "https://misskey.io/users/7rkrarq81i")

      object = File.read!("test/fixtures/quote_post/misskey_quote_post.json") |> Jason.decode!()

      message = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => "Create",
        "actor" => "https://misskey.io/users/7rkrarq81i",
        "object" => object
      }

      assert {:ok, activity} = Transmogrifier.handle_incoming(message)

      # Object was created in the database
      object = Object.normalize(activity)
      assert object.data["quoteUrl"] == "https://misskey.io/notes/8vs6wxufd0"

      # It fetched the quoted post
      assert Object.normalize("https://misskey.io/notes/8vs6wxufd0")
    end
  end

  describe "prepare outgoing" do
    test "it inlines private announced objects" do
      user = insert(:user)

      {:ok, activity} = CommonAPI.post(user, %{status: "hey", visibility: "private"})

      {:ok, announce_activity} = CommonAPI.repeat(activity.id, user)

      {:ok, modified} = Transmogrifier.prepare_outgoing(announce_activity.data)

      assert modified["object"]["content"] == "hey"
      assert modified["object"]["actor"] == modified["object"]["attributedTo"]
    end

    test "it turns mentions into tags" do
      user = insert(:user)
      other_user = insert(:user)

      {:ok, activity} =
        CommonAPI.post(user, %{status: "hey, @#{other_user.nickname}, how are ya? #2hu"})

      with_mock Pleroma.Notification,
        get_notified_from_activity: fn _, _ -> [] end do
        {:ok, modified} = Transmogrifier.prepare_outgoing(activity.data)

        object = modified["object"]

        expected_mention = %{
          "href" => other_user.ap_id,
          "name" => "@#{other_user.nickname}",
          "type" => "Mention"
        }

        expected_tag = %{
          "href" => Pleroma.Web.Endpoint.url() <> "/tags/2hu",
          "type" => "Hashtag",
          "name" => "#2hu"
        }

        refute called(Pleroma.Notification.get_notified_from_activity(:_, :_))
        assert Enum.member?(object["tag"], expected_tag)
        assert Enum.member?(object["tag"], expected_mention)
      end
    end

    test "it tolerates malformed outgoing tags and recipient shapes when generating mention tags" do
      mentioned = insert(:user)

      object = %{
        "id" => "https://local.test/objects/malformed-outgoing-tags",
        "type" => "Note",
        "actor" => "https://local.test/users/alice",
        "to" => %{"id" => mentioned.ap_id},
        "cc" => %{"unexpected" => "shape"},
        "tag" => %{"type" => "Hashtag", "name" => "#kept"}
      }

      object = Transmogrifier.add_mention_tags(object)

      assert %{"type" => "Hashtag", "name" => "#kept"} in object["tag"]
      assert %{"type" => "Mention", "href" => href} =
               Enum.find(object["tag"], &(&1["href"] == mentioned.ap_id))
      assert href == mentioned.ap_id
    end

    test "it tolerates scalar and object tag shapes when expanding hashtags" do
      assert %{
               "tag" => [
                 %{
                   "href" => href,
                   "name" => "#woodworking",
                   "type" => "Hashtag"
                 }
               ]
             } = Transmogrifier.add_hashtags(%{"tag" => "woodworking"})

      assert href == Pleroma.Web.Endpoint.url() <> "/tags/woodworking"

      assert %{"tag" => [%{"type" => "Hashtag", "name" => "#kept"}]} =
               Transmogrifier.add_hashtags(%{"tag" => %{"type" => "Hashtag", "name" => "#kept"}})
    end

    test "it tolerates malformed emoji metadata while preserving existing tags" do
      assert %{"tag" => [%{"type" => "Hashtag", "name" => "#kept"}]} =
               Transmogrifier.add_emoji_tags(%{
                 "emoji" => nil,
                 "tag" => %{"type" => "Hashtag", "name" => "#kept"}
               })
    end

    test "it does not turn group audience addresses into generated mention tags" do
      user = insert(:user)
      parent_author = insert(:user, local: false, nickname: "alice@lemmy.example")

      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "main@lemmy.example",
          ap_id: "https://lemmy.example/c/main"
        )

      parent = insert(:note_activity, user: parent_author)

      {:ok, activity} =
        CommonAPI.post(user, %{
          status: "replying without synthetic tags",
          in_reply_to_id: parent.id,
          group_id: group.ap_id
        })

      {:ok, modified} = Transmogrifier.prepare_outgoing(activity.data)
      object = modified["object"]

      mention_hrefs =
        object["tag"]
        |> Enum.filter(&(is_map(&1) and &1["type"] == "Mention"))
        |> Enum.map(& &1["href"])

      assert object["audience"] == group.ap_id
      refute Map.has_key?(object, "pleroma_internal")
      refute group.ap_id in mention_hrefs
      refute parent_author.ap_id in mention_hrefs
    end

    test "it serializes group vote audience as a scalar for threadiverse receivers" do
      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "main@lemmy.example",
          ap_id: "https://lemmy.example/c/main"
        )

      like = %{
        "id" => "https://local.example/activities/like-1",
        "type" => "Like",
        "actor" => "https://local.example/users/alice",
        "object" => "https://lemmy.example/post/1",
        "audience" => [group.ap_id],
        "to" => ["https://lemmy.example/u/poster"],
        "cc" => [Pleroma.Constants.as_public()]
      }

      undo = %{
        "id" => "https://local.example/activities/undo-like-1",
        "type" => "Undo",
        "actor" => like["actor"],
        "object" => like,
        "audience" => [group.ap_id],
        "to" => ["https://lemmy.example/u/poster"],
        "cc" => [Pleroma.Constants.as_public()]
      }

      like_activity = insert(:like_activity, data_attrs: like)

      undo_by_id =
        undo
        |> Map.put("id", "https://local.example/activities/undo-like-2")
        |> Map.put("object", like_activity.data["id"])

      {:ok, outgoing_like} = Transmogrifier.prepare_outgoing(like)
      {:ok, outgoing_undo} = Transmogrifier.prepare_outgoing(undo)
      {:ok, outgoing_undo_by_id} = Transmogrifier.prepare_outgoing(undo_by_id)

      assert outgoing_like["audience"] == group.ap_id
      assert outgoing_undo["audience"] == group.ap_id
      assert outgoing_undo["object"]["audience"] == group.ap_id
      assert outgoing_undo_by_id["audience"] == group.ap_id
      assert outgoing_undo_by_id["object"]["type"] == "Like"
      assert outgoing_undo_by_id["object"]["audience"] == group.ap_id
    end

    test "it serializes group delete audience as a scalar for threadiverse receivers" do
      group =
        insert(:user,
          actor_type: "Group",
          local: false,
          nickname: "main@lemmy.example",
          ap_id: "https://lemmy.example/c/main"
        )

      delete = %{
        "id" => "https://local.example/activities/delete-1",
        "type" => "Delete",
        "actor" => "https://local.example/users/alice",
        "object" => "https://local.example/objects/comment-1",
        "audience" => [group.ap_id],
        "to" => [Pleroma.Constants.as_public()],
        "cc" => [group.ap_id]
      }

      {:ok, outgoing_delete} = Transmogrifier.prepare_outgoing(delete)

      assert outgoing_delete["audience"] == group.ap_id
    end

    test "it omits empty outgoing audiences for threadiverse delete receivers" do
      delete = %{
        "id" => "https://local.example/activities/delete-ordinary-1",
        "type" => "Delete",
        "actor" => "https://local.example/users/alice",
        "object" => "https://local.example/objects/comment-1",
        "audience" => [],
        "to" => [Pleroma.Constants.as_public()],
        "cc" => []
      }

      {:ok, outgoing_delete} = Transmogrifier.prepare_outgoing(delete)

      refute Map.has_key?(outgoing_delete, "audience")
    end

    test "it adds the json-ld context and the conversation property" do
      user = insert(:user)

      {:ok, activity} = CommonAPI.post(user, %{status: "hey"})
      {:ok, modified} = Transmogrifier.prepare_outgoing(activity.data)

      assert modified["@context"] == Utils.make_json_ld_header()["@context"]

      assert modified["object"]["conversation"] == modified["context"]
    end

    test "it sets the 'attributedTo' property to the actor of the object if it doesn't have one" do
      user = insert(:user)

      {:ok, activity} = CommonAPI.post(user, %{status: "hey"})
      {:ok, modified} = Transmogrifier.prepare_outgoing(activity.data)

      assert modified["object"]["actor"] == modified["object"]["attributedTo"]
    end

    test "it strips internal hashtag data" do
      user = insert(:user)

      {:ok, activity} = CommonAPI.post(user, %{status: "#2hu"})

      expected_tag = %{
        "href" => Pleroma.Web.Endpoint.url() <> "/tags/2hu",
        "type" => "Hashtag",
        "name" => "#2hu"
      }

      {:ok, modified} = Transmogrifier.prepare_outgoing(activity.data)

      assert modified["object"]["tag"] == [expected_tag]
    end

    test "it strips internal fields" do
      user = insert(:user)

      {:ok, activity} =
        CommonAPI.post(user, %{
          status: "#2hu :firefox:",
          generator: %{type: "Application", name: "TestClient", url: "https://pleroma.social"}
        })

      # Ensure injected application data made it into the activity
      # as we don't have a Token to derive it from, otherwise it will
      # be nil and the test will pass
      assert %{
               type: "Application",
               name: "TestClient",
               url: "https://pleroma.social"
             } == activity.object.data["generator"]

      {:ok, modified} = Transmogrifier.prepare_outgoing(activity.data)

      assert length(modified["object"]["tag"]) == 2

      assert is_nil(modified["object"]["emoji"])
      assert is_nil(modified["object"]["like_count"])
      assert is_nil(modified["object"]["announcements"])
      assert is_nil(modified["object"]["announcement_count"])
      assert is_nil(modified["object"]["generator"])
    end

    test "it strips internal fields of article" do
      activity = insert(:article_activity)

      {:ok, modified} = Transmogrifier.prepare_outgoing(activity.data)

      assert length(modified["object"]["tag"]) == 2

      assert is_nil(modified["object"]["emoji"])
      assert is_nil(modified["object"]["like_count"])
      assert is_nil(modified["object"]["announcements"])
      assert is_nil(modified["object"]["announcement_count"])
      assert is_nil(modified["object"]["likes"])
    end

    test "the directMessage flag is present" do
      user = insert(:user)
      other_user = insert(:user)

      {:ok, activity} = CommonAPI.post(user, %{status: "2hu :moominmamma:"})

      {:ok, modified} = Transmogrifier.prepare_outgoing(activity.data)

      assert modified["directMessage"] == false

      {:ok, activity} = CommonAPI.post(user, %{status: "@#{other_user.nickname} :moominmamma:"})

      {:ok, modified} = Transmogrifier.prepare_outgoing(activity.data)

      assert modified["directMessage"] == false

      {:ok, activity} =
        CommonAPI.post(user, %{
          status: "@#{other_user.nickname} :moominmamma:",
          visibility: "direct"
        })

      {:ok, modified} = Transmogrifier.prepare_outgoing(activity.data)

      assert modified["directMessage"] == true
    end

    test "it strips BCC field" do
      user = insert(:user)
      {:ok, list} = Pleroma.List.create("foo", user)

      {:ok, activity} = CommonAPI.post(user, %{status: "foobar", visibility: "list:#{list.id}"})

      {:ok, modified} = Transmogrifier.prepare_outgoing(activity.data)

      assert is_nil(modified["bcc"])
    end

    test "it can handle Listen activities" do
      listen_activity = insert(:listen)

      {:ok, modified} = Transmogrifier.prepare_outgoing(listen_activity.data)

      assert modified["type"] == "Listen"

      user = insert(:user)

      {:ok, activity} = CommonAPI.listen(user, %{"title" => "lain radio episode 1"})

      {:ok, _modified} = Transmogrifier.prepare_outgoing(activity.data)
    end

    test "custom emoji urls are URI encoded" do
      # :dinosaur: filename has a space -> dino walking.gif
      user = insert(:user)

      {:ok, activity} = CommonAPI.post(user, %{status: "everybody do the dinosaur :dinosaur:"})

      {:ok, prepared} = Transmogrifier.prepare_outgoing(activity.data)

      assert length(prepared["object"]["tag"]) == 1

      url = prepared["object"]["tag"] |> List.first() |> Map.get("icon") |> Map.get("url")

      assert url == "http://localhost:4001/emoji/dino%20walking.gif"
    end

    test "it adds contentMap if language is specified" do
      user = insert(:user)

      {:ok, activity} = CommonAPI.post(user, %{status: "тест", language: "uk"})

      {:ok, prepared} = Transmogrifier.prepare_outgoing(activity.data)

      assert prepared["object"]["contentMap"] == %{
               "uk" => "тест"
             }
    end

    test "it prepares a quote post" do
      user = insert(:user)

      {:ok, quoted_post} = CommonAPI.post(user, %{status: "hey"})
      {:ok, quote_post} = CommonAPI.post(user, %{status: "hey", quote_id: quoted_post.id})

      {:ok, modified} = Transmogrifier.prepare_outgoing(quote_post.data)

      %{data: %{"id" => quote_id}} = Object.normalize(quoted_post)

      assert modified["object"]["quoteUrl"] == quote_id
      assert modified["object"]["quoteUri"] == quote_id
      assert modified["object"]["_misskey_quote"] == quote_id
    end
  end

  describe "actor rewriting" do
    test "it fixes the actor URL property to be a proper URI" do
      data = %{
        "url" => %{"href" => "http://example.com"}
      }

      rewritten = Transmogrifier.maybe_fix_user_object(data)
      assert rewritten["url"] == "http://example.com"
    end
  end

  describe "actor origin containment" do
    test "it rejects activities which reference objects with bogus origins" do
      data = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "http://mastodon.example.org/users/admin/activities/1234",
        "actor" => "http://mastodon.example.org/users/admin",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "object" => "https://info.pleroma.site/activity.json",
        "type" => "Announce"
      }

      assert capture_log(fn ->
               {:error, _} = Transmogrifier.handle_incoming(data)
             end) =~ "Object containment failed"
    end

    test "it rejects activities which reference objects that have an incorrect attribution (variant 1)" do
      data = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "http://mastodon.example.org/users/admin/activities/1234",
        "actor" => "http://mastodon.example.org/users/admin",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "object" => "https://info.pleroma.site/activity2.json",
        "type" => "Announce"
      }

      assert capture_log(fn ->
               {:error, _} = Transmogrifier.handle_incoming(data)
             end) =~ "Object containment failed"
    end

    test "it rejects activities which reference objects that have an incorrect attribution (variant 2)" do
      data = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "http://mastodon.example.org/users/admin/activities/1234",
        "actor" => "http://mastodon.example.org/users/admin",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "object" => "https://info.pleroma.site/activity3.json",
        "type" => "Announce"
      }

      assert capture_log(fn ->
               {:error, _} = Transmogrifier.handle_incoming(data)
             end) =~ "Object containment failed"
    end
  end

  describe "fix_explicit_addressing" do
    setup do
      user = insert(:user)
      [user: user]
    end

    test "moves non-explicitly mentioned actors to cc", %{user: user} do
      explicitly_mentioned_actors = [
        "https://pleroma.gold/users/user1",
        "https://pleroma.gold/user2"
      ]

      object = %{
        "actor" => user.ap_id,
        "to" => explicitly_mentioned_actors ++ ["https://social.beepboop.ga/users/dirb"],
        "cc" => [],
        "tag" =>
          Enum.map(explicitly_mentioned_actors, fn href ->
            %{"type" => "Mention", "href" => href}
          end)
      }

      fixed_object = Transmogrifier.fix_explicit_addressing(object, user.follower_address)
      assert Enum.all?(explicitly_mentioned_actors, &(&1 in fixed_object["to"]))
      refute "https://social.beepboop.ga/users/dirb" in fixed_object["to"]
      assert "https://social.beepboop.ga/users/dirb" in fixed_object["cc"]
    end

    test "does not move actor's follower collection to cc", %{user: user} do
      object = %{
        "actor" => user.ap_id,
        "to" => [user.follower_address],
        "cc" => []
      }

      fixed_object = Transmogrifier.fix_explicit_addressing(object, user.follower_address)
      assert user.follower_address in fixed_object["to"]
      refute user.follower_address in fixed_object["cc"]
    end

    test "removes recipient's follower collection from cc", %{user: user} do
      recipient = insert(:user)

      object = %{
        "actor" => user.ap_id,
        "to" => [recipient.ap_id, "https://www.w3.org/ns/activitystreams#Public"],
        "cc" => [user.follower_address, recipient.follower_address]
      }

      fixed_object = Transmogrifier.fix_explicit_addressing(object, user.follower_address)

      assert user.follower_address in fixed_object["cc"]
      refute recipient.follower_address in fixed_object["cc"]
      refute recipient.follower_address in fixed_object["to"]
    end
  end

  describe "fix_summary/1" do
    test "returns fixed object" do
      assert Transmogrifier.fix_summary(%{"summary" => nil}) == %{"summary" => ""}
      assert Transmogrifier.fix_summary(%{"summary" => "ok"}) == %{"summary" => "ok"}
      assert Transmogrifier.fix_summary(%{}) == %{"summary" => ""}
    end
  end

  describe "fix_url/1" do
    test "fixes data for object when url is map" do
      object = %{
        "url" => %{
          "type" => "Link",
          "mimeType" => "video/mp4",
          "href" => "https://peede8d-46fb-ad81-2d4c2d1630e3-480.mp4"
        }
      }

      assert Transmogrifier.fix_url(object) == %{
               "url" => "https://peede8d-46fb-ad81-2d4c2d1630e3-480.mp4"
             }
    end

    test "returns non-modified object" do
      assert Transmogrifier.fix_url(%{"type" => "Text"}) == %{"type" => "Text"}
    end
  end

  describe "get_obj_helper/2" do
    test "returns nil when cannot normalize object" do
      assert capture_log(fn ->
               refute Transmogrifier.get_obj_helper("test-obj-id")
             end) =~ "Unsupported URI scheme"
    end

    @tag capture_log: true
    test "returns {:ok, %Object{}} for success case" do
      assert {:ok, %Object{}} =
               Transmogrifier.get_obj_helper(
                 "https://mstdn.io/users/mayuutann/statuses/99568293732299394"
               )
    end
  end

  describe "fix_attachments/1" do
    test "puts dimensions into attachment url field" do
      object = %{
        "attachment" => [
          %{
            "type" => "Document",
            "name" => "Hello world",
            "url" => "https://media.example.tld/1.jpg",
            "width" => 880,
            "height" => 960,
            "mediaType" => "image/jpeg",
            "blurhash" => "eTKL26+HDjcEIBVl;ds+K6t301W.t7nit7y1E,R:v}ai4nXSt7V@of"
          }
        ]
      }

      expected = %{
        "attachment" => [
          %{
            "type" => "Document",
            "name" => "Hello world",
            "url" => [
              %{
                "type" => "Link",
                "mediaType" => "image/jpeg",
                "href" => "https://media.example.tld/1.jpg",
                "width" => 880,
                "height" => 960
              }
            ],
            "mediaType" => "image/jpeg",
            "blurhash" => "eTKL26+HDjcEIBVl;ds+K6t301W.t7nit7y1E,R:v}ai4nXSt7V@of"
          }
        ]
      }

      assert Transmogrifier.fix_attachments(object) == expected
    end

    test "ignores malformed attachment media types" do
      object = %{
        "attachment" => [
          %{
            "type" => "Document",
            "name" => "Odd remote upload",
            "url" => %{
              "type" => "Link",
              "href" => "https://media.example.tld/odd.bin"
            },
            "mediaType" => <<1::1>>,
            "mimeType" => nil
          }
        ]
      }

      assert Transmogrifier.fix_attachments(object) == %{
               "attachment" => [
                 %{
                   "type" => "Document",
                   "name" => "Odd remote upload",
                   "url" => [
                     %{
                       "type" => "Link",
                       "href" => "https://media.example.tld/odd.bin"
                     }
                   ]
                 }
               ]
             }
    end
  end

  test "fix_attachments/1 skips malformed attachment entries instead of raising" do
    assert Transmogrifier.fix_attachments(%{
             "attachment" => [
               "not an attachment",
               %{
                 "type" => "Document",
                 "url" => "https://media.example.tld/valid.jpg",
                 "mediaType" => "image/jpeg"
               }
             ]
           }) == %{
             "attachment" => [
               %{
                 "type" => "Document",
                 "mediaType" => "image/jpeg",
                 "url" => [
                   %{
                     "type" => "Link",
                     "mediaType" => "image/jpeg",
                     "href" => "https://media.example.tld/valid.jpg"
                   }
                 ]
               }
             ]
           }
  end

  describe "prepare_attachments/1" do
    test "skips malformed outgoing attachments instead of raising" do
      object = %{
        "attachment" => [
          %{
            "type" => "Document",
            "name" => "Good",
            "url" => [
              %{
                "type" => "Link",
                "mediaType" => "image/jpeg",
                "href" => "https://media.example/good.jpg"
              }
            ]
          },
          %{"type" => "Document", "url" => []},
          "not an attachment"
        ]
      }

      assert Transmogrifier.prepare_attachments(object) == %{
               "attachment" => [
                 %{
                   "mediaType" => "image/jpeg",
                   "name" => "Good",
                   "type" => "Document",
                   "url" => "https://media.example/good.jpg"
                 }
               ]
             }
    end
  end

  describe "prepare_object/1" do
    test "it keeps actor and attributedTo synchronized for refetched objects" do
      original = %{
        "id" => "https://example.test/objects/announced",
        "type" => "Note",
        "attributedTo" => "https://example.test/users/alice",
        "content" => "Threadiverse receivers expect actor on refetched objects."
      }

      processed = Transmogrifier.prepare_object(original)

      assert processed["actor"] == "https://example.test/users/alice"
      assert processed["attributedTo"] == "https://example.test/users/alice"
    end

    test "it processes history" do
      original = %{
        "formerRepresentations" => %{
          "orderedItems" => [
            %{
              "generator" => %{},
              "emoji" => %{"blobcat" => "http://localhost:4001/emoji/blobcat.png"}
            }
          ]
        }
      }

      processed = Transmogrifier.prepare_object(original)

      history_item = Enum.at(processed["formerRepresentations"]["orderedItems"], 0)

      refute Map.has_key?(history_item, "generator")

      assert [%{"name" => ":blobcat:"}] = history_item["tag"]
    end

    test "it works when there is no or bad history" do
      original = %{
        "formerRepresentations" => %{
          "items" => [
            %{
              "generator" => %{},
              "emoji" => %{"blobcat" => "http://localhost:4001/emoji/blobcat.png"}
            }
          ]
        }
      }

      processed = Transmogrifier.prepare_object(original)
      assert processed["formerRepresentations"] == original["formerRepresentations"]
    end
  end
end
