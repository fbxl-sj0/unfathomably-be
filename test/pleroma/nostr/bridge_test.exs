# Unfathomably BE
# ----------------
#
# File: test/pleroma/nostr/bridge_test.exs
#
# Purpose:
#   Exercise Nostr follow and community membership integration with local users.
#
# Responsibilities:
#   - prove native profile follows publish without an ActivityPub activity ID
#   - keep relay subscriptions bounded to profiles followed by local users
#   - keep discovery-relay profile backfills bound to their requested identity
#   - prove NIP-29 joins accept the canonical user follow result
#
# This file intentionally does NOT open network relay connections or duplicate
# the protocol validation tests.

defmodule Pleroma.Nostr.BridgeTest do
  use Pleroma.DataCase, async: false
  use Oban.Testing, repo: Pleroma.Repo

  import Pleroma.Factory

  alias Pleroma.Activity
  alias Pleroma.Nostr
  alias Pleroma.Nostr.Bridge
  alias Pleroma.Nostr.Community
  alias Pleroma.Nostr.Entity
  alias Pleroma.Nostr.Identity
  alias Pleroma.Nostr.Protocol
  alias Pleroma.Nostr.Store
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.CommonAPI
  alias Pleroma.Workers.NostrProfileBackfillWorker

  @relay_url "wss://nostr.example"

  setup do
    clear_config([Pleroma.Nostr],
      enabled: true,
      bridge_secret: String.duplicate("bridge-secret-", 3),
      relay_url: "wss://local.example/relay",
      external_relays: [@relay_url],
      discovery_relays: [],
      allow_user_relays: true
    )
  end

  test "profile follows publish and do not recursively subscribe to contact graphs" do
    local_user = insert(:user)
    followed = insert(:user)
    discovered_contact = insert(:user)
    followed_pubkey = String.duplicate("a", 64)
    discovered_pubkey = String.duplicate("b", 64)

    insert_entity(followed, "mirror_profile", followed_pubkey)
    insert_entity(discovered_contact, "mirror_profile", discovered_pubkey)

    assert {:ok, _local_user} = Bridge.follow(local_user, followed)

    assert {:ok, _followed, _discovered_contact} =
             User.follow(followed, discovered_contact, :follow_accept)

    authors =
      @relay_url
      |> Bridge.filters_for_relay()
      |> Enum.flat_map(&Map.get(&1, "authors", []))

    assert followed_pubkey in authors
    refute discovered_pubkey in authors
  end

  test "approved response relays subscribe to bounded local actor responses" do
    response_relay = "wss://responses.example"
    local_user = insert(:user)

    clear_config([Pleroma.Nostr, :response_relays], [response_relay])
    assert {:ok, local_entity} = Identity.local_actor(local_user)

    assert response_relay in Nostr.configured_relays()
    assert Nostr.allowed_relay?(response_relay)
    refute response_relay in Nostr.profile_discovery_relays()

    assert response_relay
           |> Bridge.filters_for_relay()
           |> Enum.any?(fn filter ->
             local_entity.pubkey in Map.get(filter, "#p", []) and
               1 in Map.get(filter, "kinds", []) and
               7 in Map.get(filter, "kinds", []) and
               is_integer(filter["since"])
           end)
  end

  test "unknown relay authors may address local actors or exported local events" do
    local_user = insert(:user)
    remote_private_key = String.duplicate("2", 64)

    assert {:ok, local_entity} = Identity.local_actor(local_user)

    assert {:ok, direct_reply} =
             Protocol.sign_event(
               1,
               [
                 ["e", String.duplicate("e", 64)],
                 ["p", local_entity.pubkey]
               ],
               "A direct first-contact reply",
               remote_private_key
             )

    assert :ok = Community.authorize(direct_reply, @relay_url, :relay)

    assert {:ok, activity} = CommonAPI.post(local_user, %{status: "A local Nostr target"})
    assert :ok = Bridge.publish_activity(activity)

    assert %Pleroma.Nostr.Event{id: target_id} =
             Store.get_by_ap_activity_id(activity.id)

    assert {:ok, reaction} =
             Protocol.sign_event(7, [["e", target_id]], "+", remote_private_key)

    assert :ok = Community.authorize(reaction, @relay_url, :relay)

    assert {:ok, unrelated} =
             Protocol.sign_event(
               7,
               [["e", String.duplicate("f", 64)]],
               "+",
               remote_private_key
             )

    assert {:error, "restricted", "writer is not known to this relay"} =
             Community.authorize(unrelated, @relay_url, :relay)
  end

  test "public relay destinations retain the primary relay and add configured fallbacks" do
    fallback_relay = "wss://fallback.example"

    clear_config([Pleroma.Nostr, :external_relays], [@relay_url, fallback_relay])
    clear_config([Pleroma.Nostr, :profile_discovery_relays], [fallback_relay])

    assert Nostr.public_relay_destinations([@relay_url, nil, "not a relay"]) == [
             @relay_url,
             fallback_relay
           ]
  end

  test "public exports preserve authored plain-text whitespace" do
    actor = insert(:user)
    content = "A rendered line with & punctuation.\n\n@someone remains separated.\n\nFinal line."

    assert {:ok, activity} = CommonAPI.post(actor, %{status: content})
    assert :ok = Bridge.publish_activity(activity)

    assert %Pleroma.Nostr.Event{data: %{"content" => ^content}} =
             Store.get_by_ap_activity_id(activity.id)
  end

  test "replies to kind 1 notes use marked NIP-10 thread tags" do
    actor = insert(:user)
    parent_author = insert(:user, local: false)
    parent_activity = insert(:note_activity, user: parent_author)
    parent_object = Object.normalize(parent_activity, fetch: false)
    private_key = String.duplicate("9", 64)

    assert {:ok, parent_event} = Protocol.sign_event(1, [], "Native parent", private_key)

    assert {:ok, _stored, true} =
             Store.put(parent_event,
               relay_url: @relay_url,
               ap_activity_id: parent_activity.id,
               ap_object_id: parent_object.data["id"]
             )

    assert {:ok, reply} =
             CommonAPI.post(actor, %{
               status: "A native threaded reply",
               in_reply_to_status_id: parent_activity.id
             })

    assert :ok = Bridge.publish_activity(reply)

    assert %Pleroma.Nostr.Event{kind: 1, data: %{"tags" => tags}} =
             Store.get_by_ap_activity_id(reply.id)

    assert ["e", parent_event["id"], @relay_url, "root", parent_event["pubkey"]] in tags
    refute Enum.any?(tags, &match?(["E" | _rest], &1))
  end

  test "replies to ActivityPub-only posts use a NIP-22 external thread scope" do
    actor = insert(:user)
    parent_author = insert(:user, local: false)
    parent_activity = insert(:note_activity, user: parent_author)
    parent_object = Object.normalize(parent_activity, fetch: false)
    parent_id = parent_object.data["id"]

    assert {:ok, reply} =
             CommonAPI.post(actor, %{
               status: "An externally scoped reply",
               in_reply_to_status_id: parent_activity.id
             })

    assert :ok = Bridge.publish_activity(reply)

    assert %Pleroma.Nostr.Event{kind: 1_111, data: %{"content" => content, "tags" => tags}} =
             Store.get_by_ap_activity_id(reply.id)

    assert ["I", parent_id, parent_id] in tags
    assert ["K", "web"] in tags
    assert ["i", parent_id, parent_id] in tags
    assert ["k", "web"] in tags
    assert String.ends_with?(content, parent_id)
  end

  test "NIP-29 community joins publish after creating the local relationship" do
    local_user = insert(:user)
    group = insert(:user, local: false, actor_type: "Group")

    %Entity{}
    |> Entity.changeset(%{
      user_id: group.id,
      kind: "mirror_group",
      pubkey: String.duplicate("c", 64),
      relay_url: @relay_url,
      group_id: "unfathomably"
    })
    |> Repo.insert!()

    assert {:ok, ^group} = Community.join(local_user, group)
  end

  test "NIP-65 relay lists become bounded profile read and write destinations" do
    user = insert(:user)
    private_key = String.duplicate("4", 64)

    assert {:ok, event} =
             Protocol.sign_event(
               10_002,
               [
                 ["r", "wss://read.example", "read"],
                 ["r", "wss://write.example", "write"],
                 ["r", "wss://both.example"]
               ],
               "",
               private_key
             )

    insert_entity(user, "mirror_profile", event["pubkey"])

    assert {:ok, _entity} = Identity.update_relay_list(event, @relay_url)

    assert "wss://read.example" in Identity.relays_for_user(user, :read)
    refute "wss://read.example" in Identity.relays_for_user(user, :write)
    assert "wss://write.example" in Identity.relays_for_user(user, :write)
    assert "wss://both.example" in Identity.relays_for_user(user, :read)
    assert "wss://both.example" in Identity.relays_for_user(user, :write)
  end

  test "NIP-65 subscriptions download followed authors from write relays" do
    local_user = insert(:user)
    followed = insert(:user)
    private_key = String.duplicate("6", 64)

    assert {:ok, event} =
             Protocol.sign_event(
               10_002,
               [
                 ["r", "wss://read.example", "read"],
                 ["r", "wss://write.example", "write"]
               ],
               "",
               private_key
             )

    insert_entity(followed, "mirror_profile", event["pubkey"])
    assert {:ok, _entity} = Identity.update_relay_list(event, @relay_url)
    assert {:ok, _local_user, _followed} = User.follow(local_user, followed, :follow_accept)

    write_authors =
      Bridge.filters_for_relay("wss://write.example")
      |> Enum.flat_map(&Map.get(&1, "authors", []))

    read_authors =
      Bridge.filters_for_relay("wss://read.example")
      |> Enum.flat_map(&Map.get(&1, "authors", []))

    assert event["pubkey"] in write_authors
    refute event["pubkey"] in read_authors
  end

  test "profile backfills accept only bounded events for the requested identity" do
    private_key = String.duplicate("5", 64)

    assert {:ok, note} = Protocol.sign_event(1, [], "A signed profile note", private_key)

    assert :ok =
             Community.authorize(
               note,
               @relay_url,
               {:profile_backfill, note["pubkey"]}
             )

    assert {:error, "restricted", "event does not match the requested profile backfill"} =
             Community.authorize(
               note,
               @relay_url,
               {:profile_backfill, String.duplicate("f", 64)}
             )

    assert {:ok, contacts} = Protocol.sign_event(3, [], "", private_key)

    assert {:error, "restricted", "event does not match the requested profile backfill"} =
             Community.authorize(
               contacts,
               @relay_url,
               {:profile_backfill, contacts["pubkey"]}
             )
  end

  test "profile backfills retain empty signed text events without creating invalid statuses" do
    private_key = String.duplicate("8", 64)
    activity_count = Repo.aggregate(Activity, :count, :id)

    assert {:ok, event} =
             Protocol.sign_event(
               1,
               [["e", String.duplicate("a", 64), @relay_url, "reply"]],
               "",
               private_key
             )

    assert {:ok, ^event} =
             Bridge.ingest_event(
               event,
               @relay_url,
               {:profile_backfill, event["pubkey"]}
             )

    assert %Pleroma.Nostr.Event{ap_activity_id: nil} = Store.get(event["id"])
    assert Repo.aggregate(Activity, :count, :id) == activity_count
  end

  test "profile mirror creation reuses an actor committed by a competing insert" do
    pubkey = String.duplicate("d", 64)
    identity = %{type: :profile, pubkey: pubkey, relays: [@relay_url]}

    assert {:ok, user} = Identity.resolve(identity)
    assert %Entity{} = entity = Identity.get_profile(pubkey)
    Repo.delete!(entity)

    assert {:ok, winner} = Identity.resolve(identity)
    assert winner.id == user.id
    assert %Entity{user_id: user_id} = Identity.get_profile(pubkey)
    assert user_id == user.id
  end

  test "new profile mirrors enqueue bounded metadata hydration" do
    pubkey = String.duplicate("e", 64)

    assert {:ok, _user} =
             Identity.resolve(%{type: :profile, pubkey: pubkey, relays: [@relay_url]})

    assert_enqueued(worker: NostrProfileBackfillWorker, args: %{"pubkey" => pubkey})
  end

  test "thread hydration accepts only exact signed content targets" do
    private_key = String.duplicate("7", 64)

    assert {:ok, parent} = Protocol.sign_event(1, [], "A requested parent", private_key)

    assert :ok =
             Community.authorize(
               parent,
               @relay_url,
               {:thread_hydration, [parent["id"]]}
             )

    assert {:error, "restricted", "event is outside the requested thread neighborhood"} =
             Community.authorize(
               parent,
               @relay_url,
               {:thread_hydration, [String.duplicate("f", 64)]}
             )

    assert {:ok, contacts} = Protocol.sign_event(3, [], "", private_key)

    assert {:error, "restricted", "event is outside the requested thread neighborhood"} =
             Community.authorize(
               contacts,
               @relay_url,
               {:thread_hydration, [contacts["id"]]}
             )
  end

  defp insert_entity(user, kind, pubkey) do
    %Entity{}
    |> Entity.changeset(%{
      user_id: user.id,
      kind: kind,
      pubkey: pubkey,
      relay_url: @relay_url
    })
    |> Repo.insert!()
  end
end

# end of test/pleroma/nostr/bridge_test.exs
