# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.MastodonAPI.FederatedTargetView do
  use Pleroma.Web, :view

  alias Pleroma.FederationStatus
  alias Pleroma.GroupMembership
  alias Pleroma.User
  alias Pleroma.Web.FederatedTarget
  alias Pleroma.Web.MastodonAPI.AccountView

  def render("targets.json", %{targets: targets} = opts) do
    Enum.map(targets, fn
      {:group, %User{} = group} ->
        "group.json"
        |> render(Map.put(opts, :group, group))
        |> Map.put(:target_type, "group")

      {:source, %User{} = source} ->
        "source.json"
        |> render(Map.put(opts, :source, source))
        |> Map.put(:target_type, "source")
    end)
  end

  def render("groups.json", %{groups: groups} = opts) do
    Enum.map(groups, &render("group.json", Map.put(opts, :group, &1)))
  end

  def render("group.json", %{group: %User{} = group} = opts) do
    account = AccountView.render("show.json", %{user: group, for: opts[:for]})
    relationship = render("group_relationship.json", %{user: opts[:for], group: group})
    platform = FederatedTarget.group_platform(group)
    target_kind = FederatedTarget.group_kind(group)
    federation = FederationStatus.for_user(group)

    %{
      id: to_string(group.id),
      avatar: account[:avatar],
      avatar_static: account[:avatar_static],
      created_at: account[:created_at],
      deleted_at: nil,
      display_name: account[:display_name],
      domain: FederatedTarget.host(group) || "",
      emojis: account[:emojis] || [],
      group_visibility: if(group.is_locked, do: "members_only", else: "public"),
      header: account[:header],
      header_static: account[:header_static],
      locked: group.is_locked,
      membership_required: group.is_locked,
      members_count: group_member_count(group, opts),
      moderators_count: group_moderator_count(group, opts),
      note: account[:note] || "",
      owner: %{id: to_string(group.id)},
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
      tags: [],
      uri: group.ap_id,
      url: account[:url],
      actor_type: group.actor_type,
      ap_id: group.ap_id,
      platform: platform.platform,
      platform_label: platform.platform_label,
      platform_family: platform.platform_family,
      platform_confidence: platform.platform_confidence,
      target_profile: FederatedTarget.group_profile(group),
      target_kind: target_kind,
      target_kind_label: FederatedTarget.group_kind_label(group),
      interaction_score: contact_interaction_score(group, opts),
      capabilities: FederatedTarget.group_capabilities(group),
      federation: federation
    }
  end

  def render("group_relationships.json", %{groups: groups} = opts) do
    Enum.map(groups, &render("group_relationship.json", Map.put(opts, :group, &1)))
  end

  def render("group_relationship.json", %{user: nil, group: %User{} = group}) do
    %{
      id: to_string(group.id),
      blocked_by: false,
      can_follow: true,
      can_post: true,
      federation_blocked: false,
      member: false,
      moderation_message: nil,
      moderation_status: "ok",
      muting: false,
      notifying: false,
      pending_requests: false,
      requested: false,
      role: "user"
    }
  end

  def render("group_relationship.json", %{user: user, group: %User{} = group}) do
    if group.local && group.actor_type == "Group" do
      render_local_group_relationship(user, group)
    else
      render_remote_group_relationship(user, group)
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
    Enum.map(sources, &render("source.json", Map.put(opts, :source, &1)))
  end

  def render("source.json", %{source: %User{} = source} = opts) do
    account = AccountView.render("show.json", %{user: source, for: opts[:for]})
    relationship = render("source_relationship.json", %{user: opts[:for], source: source})
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
    Enum.map(sources, &render("source_relationship.json", Map.put(opts, :source, &1)))
  end

  def render("source_relationship.json", %{user: user, source: %User{} = source}) do
    relationship = AccountView.render("relationship.json", %{user: user, target: source})
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
      can_post: relationship_allowed?(relationship, federation),
      federation_blocked: FederationStatus.defederated?(federation),
      moderation_message: relationship_message(relationship, federation),
      moderation_status: relationship_status(relationship, federation),
      member: Map.get(relationship, :member, false),
      muting: false,
      notifying: false,
      pending_requests: Map.get(relationship, :pending_requests, false),
      requested: Map.get(relationship, :requested, false),
      role: Map.get(relationship, :role, "user")
    }
  end

  defp render_remote_group_relationship(user, group) do
    relationship = AccountView.render("relationship.json", %{user: user, target: group})
    federation = FederationStatus.for_user(group)

    %{
      id: to_string(group.id),
      blocked_by: Map.get(relationship, :blocked_by, false),
      can_follow: relationship_allowed?(relationship, federation),
      can_post: relationship_allowed?(relationship, federation),
      federation_blocked: FederationStatus.defederated?(federation),
      moderation_message: relationship_message(relationship, federation),
      moderation_status: relationship_status(relationship, federation),
      member: Map.get(relationship, :following, false),
      muting: Map.get(relationship, :muting, false),
      notifying: Map.get(relationship, :notifying),
      pending_requests: false,
      requested: Map.get(relationship, :requested, false),
      role: "user"
    }
  end

  defp relationship_allowed?(relationship, federation) do
    not relationship_blocked_by?(relationship) and
      not FederationStatus.defederated?(federation)
  end

  defp relationship_status(relationship, federation) do
    cond do
      relationship_blocked_by?(relationship) -> "blocked_by_group"
      FederationStatus.defederated?(federation) -> "federation_blocked"
      true -> "ok"
    end
  end

  defp relationship_message(relationship, federation) do
    cond do
      relationship_blocked_by?(relationship) ->
        "You are blocked from this group and cannot follow or post there."

      FederationStatus.defederated?(federation) ->
        FederationStatus.message(federation)

      true ->
        nil
    end
  end

  defp relationship_blocked_by?(relationship) do
    Map.get(relationship, :blocked_by) == true
  end

  defp group_member_count(group, %{refresh_counts: false}), do: group.follower_count || 0
  defp group_member_count(group, _opts), do: FederatedTarget.group_member_count(group)

  defp group_moderator_count(group, %{refresh_counts: false}), do: group.moderator_count || 0
  defp group_moderator_count(group, _opts), do: FederatedTarget.group_moderator_count(group)

  defp contact_interaction_score(_target, %{include_interaction_score: false}), do: 0

  defp contact_interaction_score(target, _opts),
    do: FederatedTarget.contact_interaction_score(target)
end
