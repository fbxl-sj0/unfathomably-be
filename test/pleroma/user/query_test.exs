# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.User.QueryTest do
  use Pleroma.DataCase, async: false

  alias Pleroma.ATProto.Identity, as: ATProtoIdentity
  alias Pleroma.Diaspora.Entity, as: DiasporaEntity
  alias Pleroma.FollowingRelationship
  alias Pleroma.Nostr.Entity, as: NostrEntity
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.User.Query
  alias Pleroma.Web.ActivityPub.InternalFetchActor

  import Pleroma.Factory

  describe "internal users" do
    test "it filters out internal users by default" do
      %User{nickname: "internal.fetch"} = InternalFetchActor.get_actor()

      assert [_user] = User |> Repo.all()
      assert [] == %{} |> Query.build() |> Repo.all()
    end

    test "it filters out users without nickname by default" do
      insert(:user, %{nickname: nil})

      assert [_user] = User |> Repo.all()
      assert [] == %{} |> Query.build() |> Repo.all()
    end

    test "it returns internal users when enabled" do
      %User{nickname: "internal.fetch"} = InternalFetchActor.get_actor()
      insert(:user, %{nickname: nil})

      assert %{internal: true} |> Query.build() |> Repo.aggregate(:count) == 2
    end
  end

  test "is_suggested param" do
    _user1 = insert(:user, is_suggested: false)
    user2 = insert(:user, is_suggested: true)

    assert [^user2] =
             %{is_suggested: true}
             |> User.Query.build()
             |> Repo.all()
  end

  describe "account location" do
    test "treats locally hosted native-protocol mirrors as external accounts" do
      local_user = insert(:user, local: true)
      remote_user = insert(:user, local: false)
      nostr_user = insert(:user, local: true)
      atproto_user = insert(:user, local: true)
      diaspora_user = insert(:user, local: true)

      %NostrEntity{}
      |> NostrEntity.changeset(%{
        user_id: nostr_user.id,
        kind: "mirror_profile",
        pubkey: String.duplicate("a", 64)
      })
      |> Repo.insert!()

      %ATProtoIdentity{}
      |> ATProtoIdentity.changeset(%{user_id: atproto_user.id, did: "did:plc:alice"})
      |> Repo.insert!()

      %DiasporaEntity{}
      |> DiasporaEntity.changeset(%{
        user_id: diaspora_user.id,
        diaspora_id: "alice@diaspora.example",
        guid: "0123456789abcdef",
        pod_url: "https://diaspora.example",
        public_key: "public-key"
      })
      |> Repo.insert!()

      local_ids =
        %{account_local: true}
        |> Query.build()
        |> Repo.all()
        |> Enum.map(& &1.id)

      external_ids =
        %{account_external: true}
        |> Query.build()
        |> Repo.all()
        |> Enum.map(& &1.id)

      assert local_user.id in local_ids
      refute remote_user.id in local_ids
      refute nostr_user.id in local_ids
      refute atproto_user.id in local_ids
      refute diaspora_user.id in local_ids

      assert remote_user.id in external_ids
      assert nostr_user.id in external_ids
      assert atproto_user.id in external_ids
      assert diaspora_user.id in external_ids
      refute local_user.id in external_ids
    end
  end

  describe "recipients_from_activity param" do
    test "normalizes malformed recipient collections before querying" do
      recipient = insert(:user)
      follower = insert(:user)

      FollowingRelationship.follow(follower, recipient, :follow_accept)

      recipients = [
        recipient.ap_id,
        %{"id" => recipient.follower_address},
        %{"href" => "https://unused.example/followers"},
        nil,
        42,
        %{"type" => "Mention"},
        [recipient.ap_id]
      ]

      result =
        %{recipients_from_activity: recipients, select: [:id], internal: true}
        |> Query.build()
        |> Repo.all()
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert result == Enum.sort([recipient.id, follower.id])
    end

    test "treats malformed recipient input as an empty recipient filter" do
      insert(:user)

      assert [] =
               %{recipients_from_activity: %{"bad" => "shape"}, select: [:id], internal: true}
               |> Query.build()
               |> Repo.all()
    end
  end

  describe "is_privileged param" do
    setup do
      %{
        user: insert(:user, local: true, is_admin: false, is_moderator: false),
        moderator_user: insert(:user, local: true, is_admin: false, is_moderator: true),
        admin_user: insert(:user, local: true, is_admin: true, is_moderator: false),
        admin_moderator_user: insert(:user, local: true, is_admin: true, is_moderator: true),
        remote_user: insert(:user, local: false, is_admin: true, is_moderator: true),
        non_active_user:
          insert(:user, local: true, is_admin: true, is_moderator: true, is_active: false)
      }
    end

    test "doesn't return any users when there are no privileged roles" do
      clear_config([:instance, :admin_privileges], [])
      clear_config([:instance, :moderator_privileges], [])

      assert [] = User.Query.build(%{is_privileged: :cofe}) |> Repo.all()
    end

    test "returns moderator users if they are privileged", %{
      moderator_user: moderator_user,
      admin_moderator_user: admin_moderator_user
    } do
      clear_config([:instance, :admin_privileges], [])
      clear_config([:instance, :moderator_privileges], [:cofe])

      assert [_, _] = User.Query.build(%{is_privileged: :cofe}) |> Repo.all()
      assert moderator_user in (User.Query.build(%{is_privileged: :cofe}) |> Repo.all())
      assert admin_moderator_user in (User.Query.build(%{is_privileged: :cofe}) |> Repo.all())
    end

    test "returns admin users if they are privileged", %{
      admin_user: admin_user,
      admin_moderator_user: admin_moderator_user
    } do
      clear_config([:instance, :admin_privileges], [:cofe])
      clear_config([:instance, :moderator_privileges], [])

      assert [_, _] = User.Query.build(%{is_privileged: :cofe}) |> Repo.all()
      assert admin_user in (User.Query.build(%{is_privileged: :cofe}) |> Repo.all())
      assert admin_moderator_user in (User.Query.build(%{is_privileged: :cofe}) |> Repo.all())
    end

    test "returns admin and moderator users if they are both privileged", %{
      moderator_user: moderator_user,
      admin_user: admin_user,
      admin_moderator_user: admin_moderator_user
    } do
      clear_config([:instance, :admin_privileges], [:cofe])
      clear_config([:instance, :moderator_privileges], [:cofe])

      assert [_, _, _] = User.Query.build(%{is_privileged: :cofe}) |> Repo.all()
      assert admin_user in (User.Query.build(%{is_privileged: :cofe}) |> Repo.all())
      assert moderator_user in (User.Query.build(%{is_privileged: :cofe}) |> Repo.all())
      assert admin_moderator_user in (User.Query.build(%{is_privileged: :cofe}) |> Repo.all())
    end
  end
end
