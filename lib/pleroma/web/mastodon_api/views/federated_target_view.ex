# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.FederatedTargetView do
  use Pleroma.Web, :view

  alias Pleroma.FederatedTargetCuration
  alias Pleroma.FederationStatus
  alias Pleroma.GroupMembership
  alias Pleroma.Nostr.Identity, as: NostrIdentity
  alias Pleroma.User
  alias Pleroma.UserRelationship
  alias Pleroma.Web.FederatedTarget
  alias Pleroma.Web.MastodonAPI.AccountView

  def render("targets.json", %{targets: targets} = opts) do
    target_users = Enum.map(targets, fn {_kind, target} -> target end)
    curated_positions = FederatedTargetCuration.active_positions(target_users)

    opts =
      opts
      |> preload_interaction_scores(target_users)
      |> preload_relationships(target_users)

    Enum.map(targets, fn
      {:group, %User{} = group} ->
        "group.json"
        |> render(Map.put(opts, :group, group))
        |> Map.put(:target_type, "group")
        |> Map.put(:curated, Map.has_key?(curated_positions, group.id))
        |> put_native_family(:group, group)

      {:source, %User{} = source} ->
        "source.json"
        |> render(Map.put(opts, :source, source))
        |> Map.put(:target_type, "source")
        |> put_native_family(:source, source)
    end)
  end

  def render("groups.json", %{groups: groups} = opts) do
    opts =
      opts
      |> preload_interaction_scores(groups)
      |> preload_relationships(groups)

    Enum.map(groups, &render("group.json", Map.put(opts, :group, &1)))
  end

  def render("group.json", %{group: %User{} = group} = opts) do
    account =
      AccountView.render("show.json", %{
        user: group,
        for: opts[:for],
        relationships: opts[:relationships]
      })

    relationship =
      render(
        "group_relationship.json",
        Map.merge(opts, %{user: opts[:for], group: group})
      )

    nostr = account[:nostr]
    owner_account = group_owner_account(nostr, opts)
    platform = group_platform(group, nostr)
    target_kind = group_target_kind(group, nostr)
    federation = FederationStatus.for_user(group)

    %{
      id: to_string(group.id),
      avatar: account[:avatar],
      avatar_static: account[:avatar_static],
      created_at: account[:created_at],
      deleted_at: nil,
      display_name: account[:display_name],
      domain: group_domain(group, nostr),
      emojis: account[:emojis] || [],
      group_visibility: if(group.is_locked, do: "members_only", else: "public"),
      header: account[:header],
      header_static: account[:header_static],
      locked: group.is_locked,
      membership_required: group.is_locked,
      members_count: group_member_count(group, opts, nostr),
      moderators_count: group_moderator_count(group, opts, nostr),
      note: account[:note] || "",
      owner: %{id: owner_account_id(owner_account, group)},
      owner_account: owner_account,
      posting_restricted_to_mods: group.posting_restricted_to_mods,
      relationship: relationship,
      slug: to_string(group.id),
      source: %{
        note: get_in(account, [:source, :note]) || "",
        pleroma: %{
          actor_type: group.actor_type,
          activitypub: %{
            attributed_to: group.attributed_to_address,
            discoverable: group.is_discoverable,
            featured: group.featured_address,
            followers: group.follower_address,
            following: group.following_address,
            indexable: group.is_indexable,
            outbox: group.outbox_address,
            posting_restricted_to_mods: group.posting_restricted_to_mods,
            shared_inbox: group.shared_inbox
          }
        }
      },
      statuses_visibility: "public",
      statuses_count: group_status_count(group, opts),
      tags: [],
      uri: group.ap_id,
      url: account[:url],
      actor_type: group.actor_type,
      ap_id: group.ap_id,
      platform: platform.platform,
      platform_label: platform.platform_label,
      platform_family: platform.platform_family,
      platform_confidence: platform.platform_confidence,
      target_profile: group_target_profile(group, nostr),
      target_kind: target_kind,
      target_kind_label: group_target_kind_label(group, nostr),
      interaction_score: contact_interaction_score(group, opts),
      capabilities: FederatedTarget.group_capabilities(group),
      federation: federation,
      nostr: nostr
    }
  end

  def render("group_relationships.json", %{groups: groups} = opts) do
    opts = preload_relationships(opts, groups)
    Enum.map(groups, &render("group_relationship.json", Map.put(opts, :group, &1)))
  end

  def render("group_relationship.json", %{user: nil, group: %User{} = group}) do
    federation = FederationStatus.for_user(group)

    %{
      id: to_string(group.id),
      blocked_by: false,
      can_follow: relationship_allowed?(nil, federation),
      can_post: can_post_to_group?(nil, group, nil, federation),
      federation_blocked: FederationStatus.defederated?(federation),
      member: false,
      moderation_message: relationship_message(nil, federation, group, nil),
      moderation_status: relationship_status(nil, federation, group, nil),
      muting: false,
      notifying: false,
      pending_requests: false,
      requested: false,
      role: "user"
    }
  end

  def render("group_relationship.json", %{user: user, group: %User{} = group} = opts) do
    if group.local && group.actor_type == "Group" do
      render_local_group_relationship(user, group)
    else
      render_remote_group_relationship(user, group, opts[:relationships])
    end
  end

  def render("group_memberships.json", %{memberships: memberships} = opts) do
    Enum.map(memberships, &render("group_membership.json", Map.put(opts, :membership, &1)))
  end

  def render("group_membership.json", %{membership: %GroupMembership{} = membership} = opts) do
    %{
      id: to_string(membership.id),
      role: membership.role,
      account: AccountView.render("show.json", %{user: membership.account, for: opts[:for]})
    }
  end

  def render("sources.json", %{sources: sources} = opts) do
    opts =
      opts
      |> preload_interaction_scores(sources)
      |> preload_relationships(sources)

    Enum.map(sources, &render("source.json", Map.put(opts, :source, &1)))
  end

  def render("source.json", %{source: %User{} = source} = opts) do
    account =
      AccountView.render("show.json", %{
        user: source,
        for: opts[:for],
        relationships: opts[:relationships]
      })

    relationship =
      render(
        "source_relationship.json",
        Map.merge(opts, %{user: opts[:for], source: source})
      )

    platform = FederatedTarget.source_platform(source)
    source_kind = FederatedTarget.source_kind(source)
    federation = FederationStatus.for_user(source)

    %{
      id: to_string(source.id),
      acct: account[:acct],
      actor_type: source.actor_type,
      ap_id: source.ap_id,
      avatar: account[:avatar],
      avatar_static: account[:avatar_static],
      created_at: account[:created_at],
      display_name: account[:display_name],
      domain: FederatedTarget.host(source) || "",
      emojis: account[:emojis] || [],
      header: account[:header],
      header_static: account[:header_static],
      note: account[:note] || "",
      relationship: relationship,
      platform: platform.platform,
      platform_label: platform.platform_label,
      platform_family: platform.platform_family,
      platform_confidence: platform.platform_confidence,
      source_profile: FederatedTarget.source_profile(source),
      source_kind: source_kind,
      source_kind_label: FederatedTarget.source_kind_label(source),
      interaction_score: contact_interaction_score(source, opts),
      capabilities: FederatedTarget.source_capabilities(source),
      federation: federation,
      uri: source.ap_id,
      url: account[:url],
      username: account[:username]
    }
  end

  def render("source_relationships.json", %{sources: sources} = opts) do
    opts = preload_relationships(opts, sources)
    Enum.map(sources, &render("source_relationship.json", Map.put(opts, :source, &1)))
  end

  def render("source_relationship.json", %{user: user, source: %User{} = source} = opts) do
    relationship =
      AccountView.render("relationship.json", %{
        user: user,
        target: source,
        relationships: opts[:relationships]
      })

    federation = FederationStatus.for_user(source)

    %{
      id: to_string(source.id),
      blocked_by: Map.get(relationship, :blocked_by, false),
      federation: federation,
      federation_blocked: FederationStatus.defederated?(federation),
      following: Map.get(relationship, :following, false),
      muting: Map.get(relationship, :muting, false),
      notifying: Map.get(relationship, :notifying),
      requested: Map.get(relationship, :requested, false)
    }
  end

  defp render_local_group_relationship(user, group) do
    relationship = GroupMembership.relationship(user, group)
    federation = FederationStatus.for_user(group)

    %{
      id: to_string(group.id),
      blocked_by: Map.get(relationship, :blocked_by, false),
      can_follow: relationship_allowed?(relationship, federation),
      can_post: can_post_to_group?(user, group, relationship, federation),
      federation_blocked: FederationStatus.defederated?(federation),
      moderation_message: relationship_message(relationship, federation, group, user),
      moderation_status: relationship_status(relationship, federation, group, user),
      member: Map.get(relationship, :member, false),
      muting: false,
      notifying: false,
      pending_requests: Map.get(relationship, :pending_requests, false),
      requested: Map.get(relationship, :requested, false),
      role: Map.get(relationship, :role, "user")
    }
  end

  defp render_remote_group_relationship(user, group, relationships) do
    relationship =
      AccountView.render("relationship.json", %{
        user: user,
        target: group,
        relationships: relationships
      })

    federation = FederationStatus.for_user(group)

    %{
      id: to_string(group.id),
      blocked_by: Map.get(relationship, :blocked_by, false),
      can_follow: relationship_allowed?(relationship, federation),
      can_post: can_post_to_group?(user, group, relationship, federation),
      federation_blocked: FederationStatus.defederated?(federation),
      moderation_message: relationship_message(relationship, federation, group, user),
      moderation_status: relationship_status(relationship, federation, group, user),
      member: Map.get(relationship, :following, false),
      muting: Map.get(relationship, :muting, false),
      notifying: Map.get(relationship, :notifying),
      pending_requests: false,
      requested: Map.get(relationship, :requested, false),
      role: GroupMembership.role(group, user)
    }
  end

  defp relationship_allowed?(relationship, federation) do
    not relationship_blocked_by?(relationship) and
      not FederationStatus.defederated?(federation)
  end

  defp can_post_to_group?(user, group, relationship, federation) do
    relationship_allowed?(relationship, federation) and
      (not group.posting_restricted_to_mods or
         (match?(%User{}, user) and GroupMembership.manager?(user, group)))
  end

  defp relationship_status(relationship, federation, group, user) do
    cond do
      relationship_blocked_by?(relationship) -> "blocked_by_group"
      FederationStatus.defederated?(federation) -> "federation_blocked"
      group.posting_restricted_to_mods and not manager?(user, group) -> "moderator_only"
      true -> "ok"
    end
  end

  defp relationship_message(relationship, federation, group, user) do
    cond do
      relationship_blocked_by?(relationship) ->
        "You are blocked from this group and cannot follow or post there."

      FederationStatus.defederated?(federation) ->
        FederationStatus.message(federation)

      group.posting_restricted_to_mods and not manager?(user, group) ->
        "Only group moderators can post here."

      true ->
        nil
    end
  end

  defp manager?(%User{} = user, %User{} = group), do: GroupMembership.manager?(user, group)
  defp manager?(_user, _group), do: false

  defp relationship_blocked_by?(relationship) when is_map(relationship) do
    Map.get(relationship, :blocked_by) == true
  end

  defp relationship_blocked_by?(_relationship), do: false

  defp group_member_count(group, %{refresh_counts: false}), do: group.follower_count || 0
  defp group_member_count(group, _opts), do: FederatedTarget.group_member_count(group)

  defp group_member_count(_group, _opts, %{members_count: count})
       when is_integer(count) and count >= 0,
       do: count

  defp group_member_count(group, opts, _nostr), do: group_member_count(group, opts)

  defp group_moderator_count(group, %{refresh_counts: false}), do: group.moderator_count || 0
  defp group_moderator_count(group, _opts), do: FederatedTarget.group_moderator_count(group)

  defp group_moderator_count(_group, _opts, %{moderators_count: count})
       when is_integer(count) and count >= 0,
       do: count

  defp group_moderator_count(group, opts, _nostr), do: group_moderator_count(group, opts)

  defp group_status_count(group, %{refresh_status_count: false}), do: group.note_count || 0
  defp group_status_count(group, %{refresh_counts: false}), do: group.note_count || 0
  defp group_status_count(group, _opts), do: FederatedTarget.group_status_count(group)

  defp group_owner_account(_nostr, %{refresh_counts: false}), do: nil

  defp group_owner_account(%{owner_pubkey: pubkey}, opts) when is_binary(pubkey) do
    case NostrIdentity.get_profile(pubkey) do
      %{user: %User{} = owner} ->
        AccountView.render("show.json", %{user: owner, for: opts[:for]})

      _ ->
        nil
    end
  end

  defp group_owner_account(_nostr, _opts), do: nil

  defp owner_account_id(%{id: id}, _group), do: to_string(id)
  defp owner_account_id(_owner_account, group), do: to_string(group.id)

  defp group_platform(_group, %{kind: "mirror_group"}) do
    %{
      platform: "nostr",
      platform_label: "Nostr",
      platform_family: "groups",
      platform_confidence: "native"
    }
  end

  defp group_platform(group, _nostr), do: FederatedTarget.group_platform(group)

  defp group_target_profile(_group, %{kind: "mirror_group", community_standard: "nip72"}),
    do: "nip72_community"

  defp group_target_profile(_group, %{kind: "mirror_group"}), do: "nip29_group"
  defp group_target_profile(group, _nostr), do: FederatedTarget.group_profile(group)

  defp group_target_kind(_group, %{kind: "mirror_group"}), do: "community"
  defp group_target_kind(group, _nostr), do: FederatedTarget.group_kind(group)

  defp group_target_kind_label(
         _group,
         %{kind: "mirror_group", community_standard: "nip72"}
       ),
       do: "Nostr moderated community"

  defp group_target_kind_label(_group, %{kind: "mirror_group"}), do: "Nostr community"
  defp group_target_kind_label(group, _nostr), do: FederatedTarget.group_kind_label(group)

  defp group_domain(_group, %{kind: "mirror_group", relay: relay}) when is_binary(relay) do
    URI.parse(relay).host || relay
  end

  defp group_domain(group, _nostr), do: FederatedTarget.host(group) || ""

  defp contact_interaction_score(_target, %{include_interaction_score: false}), do: 0

  defp contact_interaction_score(%User{id: id}, %{interaction_scores: scores}),
    do: Map.get(scores, id, 0)

  defp contact_interaction_score(target, _opts),
    do: FederatedTarget.contact_interaction_score(target)

  defp preload_interaction_scores(%{include_interaction_score: false} = opts, _targets), do: opts

  defp preload_interaction_scores(opts, targets) do
    Map.put_new_lazy(opts, :interaction_scores, fn ->
      FederatedTarget.contact_interaction_scores(targets)
    end)
  end

  defp preload_relationships(opts, targets) do
    reading_user = opts[:for] || opts[:user]

    Map.put_new_lazy(opts, :relationships, fn ->
      UserRelationship.view_relationships_option(reading_user, targets)
    end)
  end

  # Target search is also used outside Worlds. Add this optional hint only when
  # the backend can classify the actor structurally, rather than asking each
  # client to infer a native object family from an instance domain or label.
  defp put_native_family(target, :group, _group),
    do: Map.put(target, :native_family, "groups")

  defp put_native_family(target, :source, source) do
    case FederatedTarget.native_source_family(source) do
      family when is_binary(family) -> Map.put(target, :native_family, family)
      _ -> target
    end
  end
end
