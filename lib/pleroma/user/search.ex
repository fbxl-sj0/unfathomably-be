# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.User.Search do
  alias Pleroma.EctoType.ActivityPub.ObjectValidators.Uri, as: UriType
  alias Pleroma.FASP.AccountSearch
  alias Pleroma.Instances
  alias Pleroma.Instances.Instance
  alias Pleroma.Nostr.Entity, as: NostrEntity
  alias Pleroma.Nostr.Protocol, as: NostrProtocol
  alias Pleroma.Nostr.Search, as: NostrSearch
  alias Pleroma.Pagination
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.FederatedTarget

  import Ecto.Query

  @limit 20
  @domain_disallowed_chars ~r/[!"#$%&'()*+,\/:;<=>?@\[\]\\^_`{|}~\s]+/u

  def search(query_string, opts \\ []) do
    resolve = Keyword.get(opts, :resolve, false)
    following = Keyword.get(opts, :following, false)
    result_limit = Keyword.get(opts, :limit, @limit)
    offset = Keyword.get(opts, :offset, 0)
    capabilities = Keyword.get(opts, :capabilities, []) || []

    for_user = Keyword.get(opts, :for_user)

    query_string = format_query(query_string)

    # If this returns anything, it should bounce to the top
    maybe_resolved = maybe_resolve(resolve, for_user, query_string)

    fasp_user_ids =
      maybe_search_fasp(query_string, for_user, following, offset, result_limit)

    remote_nostr_user_ids =
      maybe_search_remote_nostr(
        query_string,
        for_user,
        following,
        offset,
        result_limit
      )

    top_user_ids =
      query_string
      |> maybe_search_nostr(result_limit)
      |> Kernel.++(remote_nostr_user_ids)
      |> Kernel.++(fasp_user_ids)
      |> maybe_add_resolved(maybe_resolved)
      |> maybe_add_ap_id_match(query_string)
      |> maybe_add_uri_match(query_string)
      |> Enum.uniq()

    results =
      query_string
      |> search_query(for_user, following, top_user_ids, capabilities)
      |> Pagination.fetch_paginated(%{"offset" => offset, "limit" => result_limit}, :offset)

    results
  end

  defp maybe_search_fasp(query, %User{}, false, 0, limit)
       when is_binary(query) and byte_size(query) >= 2 do
    if String.starts_with?(query, ["http://", "https://"]) do
      []
    else
      AccountSearch.user_ids(query, limit)
    end
  end

  defp maybe_search_fasp(_query, _for_user, _following, _offset, _limit), do: []

  defp maybe_search_remote_nostr(query, %User{}, false, 0, limit)
       when is_binary(query) and is_integer(limit) and limit > 0 do
    NostrSearch.profile_user_ids(query, limit)
  end

  defp maybe_search_remote_nostr(_query, _for_user, _following, _offset, _limit), do: []

  defp maybe_search_nostr(query, limit)
       when is_binary(query) and byte_size(query) >= 2 and is_integer(limit) and limit > 0 do
    limit = min(limit, @limit)
    pattern = nostr_search_pattern(query)

    direct_ids =
      case nostr_pubkey(query) do
        pubkey when is_binary(pubkey) ->
          NostrEntity
          |> where([entity], entity.kind == "mirror_profile" and entity.pubkey == ^pubkey)
          |> select([entity], entity.user_id)
          |> limit(1)
          |> Repo.all()

        _ ->
          []
      end

    metadata_ids =
      NostrEntity
      |> where([entity], entity.kind == "mirror_profile")
      |> where(
        [entity],
        fragment("lower(coalesce(?->>'name', '')) LIKE ?", entity.metadata, ^pattern) or
          fragment(
            "lower(coalesce(?->>'display_name', '')) LIKE ?",
            entity.metadata,
            ^pattern
          ) or
          fragment("lower(coalesce(?->>'username', '')) LIKE ?", entity.metadata, ^pattern) or
          fragment("lower(coalesce(?->>'displayName', '')) LIKE ?", entity.metadata, ^pattern) or
          fragment("lower(coalesce(?->>'nip05', '')) LIKE ?", entity.metadata, ^pattern)
      )
      |> select([entity], entity.user_id)
      |> limit(^limit)
      |> Repo.all()

    event_ids =
      NostrEntity
      |> join(:inner, [entity], event in "nostr_events",
        on: field(event, :pubkey) == entity.pubkey
      )
      |> where([entity, event], entity.kind == "mirror_profile" and field(event, :kind) == 0)
      |> where(
        [_entity, event],
        fragment("lower(coalesce(?->>'content', '')) LIKE ?", field(event, :data), ^pattern)
      )
      |> select([entity, _event], entity.user_id)
      |> distinct(true)
      |> limit(^limit)
      |> Repo.all()

    (direct_ids ++ metadata_ids ++ event_ids)
    |> Enum.uniq()
    |> Enum.take(limit)
  end

  defp maybe_search_nostr(_query, _limit), do: []

  defp nostr_search_pattern(query) do
    query =
      query
      |> String.downcase()
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    "%#{query}%"
  end

  defp nostr_pubkey(query) do
    case NostrProtocol.decode_identifier(query) do
      {:ok, %{type: :profile, pubkey: pubkey}} when is_binary(pubkey) ->
        pubkey

      _ ->
        mostr_pubkey(query)
    end
  end

  defp mostr_pubkey(query) do
    query = String.trim_leading(query, "@")

    case String.split(query, "@", parts: 2) do
      [pubkey, host] ->
        if valid_nostr_pubkey?(pubkey) and allowed_mostr_host?(host),
          do: String.downcase(pubkey)

      _ ->
        mostr_url_pubkey(query)
    end
  end

  defp mostr_url_pubkey(query) do
    with %URI{scheme: scheme, host: host, path: path} <- URI.parse(query),
         true <- scheme in ["http", "https"],
         true <- allowed_mostr_host?(host),
         [pubkey] <-
           Regex.run(~r|/users/([0-9a-fA-F]{64})(?:/)?\z|, path, capture: :all_but_first),
         true <- valid_nostr_pubkey?(pubkey) do
      String.downcase(pubkey)
    else
      _ -> nil
    end
  rescue
    URI.Error -> nil
  end

  defp allowed_mostr_host?(host) when is_binary(host) do
    host = String.downcase(host)

    Pleroma.Config.get([Pleroma.Nostr, :mostr_hosts], ["mostr.pub"])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.any?(fn configured_host ->
      configured_host = String.downcase(configured_host)
      host == configured_host or String.ends_with?(host, "." <> configured_host)
    end)
  end

  defp allowed_mostr_host?(_host), do: false

  defp valid_nostr_pubkey?(pubkey) when is_binary(pubkey),
    do: Regex.match?(~r/^[0-9a-fA-F]{64}$/, pubkey)

  defp valid_nostr_pubkey?(_pubkey), do: false

  defp maybe_add_resolved(list, {:ok, %User{} = user}) do
    [user.id | list]
  end

  defp maybe_add_resolved(list, _), do: list

  defp maybe_add_ap_id_match(list, query) do
    if user = User.get_cached_by_ap_id(query) do
      [user.id | list]
    else
      list
    end
  end

  defp maybe_add_uri_match(list, query) do
    with {:ok, query} <- UriType.cast(query),
         q = from(u in User, where: u.uri == ^query, select: u.id),
         users = Pleroma.Repo.all(q) do
      users ++ list
    else
      _ -> list
    end
  end

  defp format_query(query_string) do
    query_string = strip_identifier_controls(query_string)

    # Strip the beginning @ off if there is a query
    query_string = String.trim_leading(query_string, "@")

    with [name, domain] <- String.split(query_string, "@"),
         {:ok, encoded_domain} <- encode_domain(domain) do
      name <> "@" <> encoded_domain
    else
      _ -> query_string
    end
  end

  defp strip_identifier_controls(query_string) when is_binary(query_string) do
    query_string
    |> String.replace(~r/\p{C}+/u, " ")
    |> String.trim()
  end

  defp strip_identifier_controls(_query_string), do: ""

  defp encode_domain(domain) do
    domain = String.replace(domain, @domain_disallowed_chars, "")

    try do
      {:ok, domain |> String.to_charlist() |> :idna.encode() |> to_string()}
    catch
      _kind, _reason -> :error
    end
  end

  defp search_query(query_string, for_user, following, top_user_ids, capabilities) do
    for_user
    |> base_query(following)
    |> filter_blocked_user(for_user)
    |> filter_invisible_users()
    |> filter_internal_users()
    |> filter_blocked_domains(for_user)
    |> filter_unreachable_users()
    |> fts_search(query_string, top_user_ids)
    |> trigram_rank(query_string)
    |> boost_search_rank(for_user, top_user_ids)
    |> subquery()
    |> order_by_search_rank(for_user)
    |> maybe_restrict_local(for_user)
    |> maybe_restrict_accepting_chat_messages(capabilities)
    |> filter_deactivated_users()
  end

  defp fts_search(query, query_string, top_user_ids) do
    query_string = to_tsquery(query_string)

    from(
      u in query,
      where:
        fragment(
          # The fragment must _exactly_ match `users_fts_index`, otherwise the index won't work
          """
          (
            setweight(to_tsvector('simple', regexp_replace(?, '\\W', ' ', 'g')), 'A') ||
            setweight(to_tsvector('simple', regexp_replace(coalesce(?, ''), '\\W', ' ', 'g')), 'B')
          ) @@ to_tsquery('simple', ?)
          """,
          u.nickname,
          u.name,
          ^query_string
        ) or u.id in ^top_user_ids
    )
  end

  defp to_tsquery(query_string) do
    String.trim_trailing(query_string, "@" <> local_domain())
    |> String.replace(~r/[!-\/|@|[-`|{-~|:-?]+/, " ")
    |> String.trim()
    |> String.split()
    |> Enum.map(&(&1 <> ":*"))
    |> Enum.join(" | ")
  end

  # Considers nickname match, localized nickname match, name match; preferences nickname match
  defp trigram_rank(query, query_string) do
    from(
      u in query,
      select_merge: %{
        search_rank:
          fragment(
            """
            similarity(?, ?) +
            similarity(?, regexp_replace(?, '@.+', '')) +
            similarity(?, trim(coalesce(?, '')))
            """,
            ^query_string,
            u.nickname,
            ^query_string,
            u.nickname,
            ^query_string,
            u.name
          )
      }
    )
  end

  defp base_query(%User{} = user, true), do: User.get_friends_query(user)
  defp base_query(_user, _following), do: User

  defp filter_invisible_users(query) do
    from(q in query, where: q.invisible == false)
  end

  defp filter_internal_users(query) do
    from(q in query, where: q.actor_type != "Application")
  end

  defp filter_deactivated_users(query) do
    from(q in query, where: q.is_active == true)
  end

  defp filter_blocked_user(query, %User{} = blocker) do
    query
    |> join(:left, [u], b in Pleroma.UserRelationship,
      as: :blocks,
      on: b.relationship_type == ^:block and b.source_id == ^blocker.id and u.id == b.target_id
    )
    |> where([blocks: b], is_nil(b.target_id))
  end

  defp filter_blocked_user(query, _), do: query

  defp filter_blocked_domains(query, %User{domain_blocks: domain_blocks})
       when domain_blocks != [] do
    domains =
      domain_blocks
      |> Enum.map(&Instances.host/1)
      |> Enum.filter(&is_binary/1)

    if domains == [] do
      query
    else
      from(q in query, where: fragment("ap_id_host(?)", q.ap_id) not in ^domains)
    end
  end

  defp filter_blocked_domains(query, _), do: query

  defp filter_unreachable_users(query) do
    from(u in query,
      left_join: i in Instance,
      on: fragment("lower(?) = ap_id_host(?)", i.host, u.ap_id),
      where: is_nil(i.unreachable_since)
    )
  end

  defp maybe_resolve(true, user, query) do
    case {limit(), user} do
      {:all, _} -> :noop
      {:unauthenticated, %User{}} -> FederatedTarget.resolve_target(query)
      {:unauthenticated, _} -> :noop
      {false, _} -> FederatedTarget.resolve_target(query)
    end
  end

  defp maybe_resolve(_, _, _), do: :noop

  defp maybe_restrict_local(q, user) do
    case {limit(), user} do
      {:all, _} -> restrict_local(q)
      {:unauthenticated, %User{}} -> q
      {:unauthenticated, _} -> restrict_local(q)
      {false, _} -> q
    end
  end

  defp limit, do: Pleroma.Config.get([:instance, :limit_to_local_content], :unauthenticated)

  defp restrict_local(q), do: where(q, [u], u.local == true)

  defp maybe_restrict_accepting_chat_messages(query, capabilities) do
    if "accepts_chat_messages" in capabilities do
      from(q in query, where: q.accepts_chat_messages == true)
    else
      query
    end
  end

  defp local_domain, do: Pleroma.Config.get([Pleroma.Web.Endpoint, :url, :host])

  defp boost_search_rank(query, %User{} = for_user, top_user_ids) do
    friends_ids = User.get_friends_ids(for_user)
    followers_ids = User.get_followers_ids(for_user)

    from(u in subquery(query),
      select_merge: %{
        search_type:
          fragment(
            """
             CASE WHEN (?) THEN 2
             WHEN (?) THEN 1
             ELSE 0 END
            """,
            u.id in ^top_user_ids,
            u.id in ^friends_ids or u.id in ^followers_ids
          ),
        search_rank:
          fragment(
            """
             CASE WHEN (?) THEN (?) * 1.5
             WHEN (?) THEN (?) * 1.3
             WHEN (?) THEN (?) * 1.1
             WHEN (?) THEN 9001
             ELSE (?) END
            """,
            u.id in ^friends_ids and u.id in ^followers_ids,
            u.search_rank,
            u.id in ^friends_ids,
            u.search_rank,
            u.id in ^followers_ids,
            u.search_rank,
            u.id in ^top_user_ids,
            u.search_rank
          )
      }
    )
  end

  defp boost_search_rank(query, _for_user, top_user_ids) do
    from(u in subquery(query),
      select_merge: %{
        search_type:
          fragment(
            """
             CASE WHEN (?) THEN 2
             ELSE 0 END
            """,
            u.id in ^top_user_ids
          ),
        search_rank:
          fragment(
            """
             CASE WHEN (?) THEN 9001
             ELSE (?) END
            """,
            u.id in ^top_user_ids,
            u.search_rank
          )
      }
    )
  end

  defp order_by_search_rank(query, %User{}) do
    order_by(
      query,
      [u],
      desc: u.search_type,
      desc_nulls_last:
        fragment(
          "CASE WHEN ? = 1 THEN COALESCE(?, ?) ELSE NULL END",
          u.search_type,
          u.last_status_at,
          u.last_active_at
        ),
      desc: u.search_rank
    )
  end

  defp order_by_search_rank(query, _), do: order_by(query, desc: :search_rank)
end
