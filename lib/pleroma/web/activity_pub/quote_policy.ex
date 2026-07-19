# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.QuotePolicy do
  @moduledoc """
  Normalizes ActivityPub quote interaction policies and decides whether a
  quote is automatic, requires approval, or is denied.

  Missing policies retain the legacy Pleroma/Rebased behavior. Explicit
  policies are authoritative so a peer cannot bypass a denial by omitting a
  QuoteRequest after publishing its quote post.
  """

  alias Pleroma.Object
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.Visibility

  require Pleroma.Constants

  @public Pleroma.Constants.as_public()
  @policies ~w[public followers following manual nobody]

  @spec build(User.t(), String.t() | atom() | nil) :: map()
  def build(%User{} = author, policy) do
    case normalize_name(policy) do
      "followers" -> policy([author.follower_address], [])
      "following" -> policy([following_address(author)], [])
      "manual" -> policy([], [@public])
      "nobody" -> policy([], [])
      _ -> policy([@public], [])
    end
  end

  @spec name(map() | nil, Object.t() | nil) :: String.t()
  def name(%{"canQuote" => can_quote}, %Object{} = object) when is_map(can_quote) do
    automatic = collection(can_quote["automaticApproval"])
    manual = collection(can_quote["manualApproval"])
    author = User.get_cached_by_ap_id(object.data["actor"])

    cond do
      @public in automatic -> "public"
      author && author.follower_address in automatic -> "followers"
      author && following_address(author) in automatic -> "following"
      @public in manual -> "manual"
      automatic == [] and manual == [] -> "nobody"
      true -> "custom"
    end
  end

  def name(_, %Object{} = object) do
    if Visibility.get_visibility(object) in ~w[public unlisted local],
      do: "legacy",
      else: "nobody"
  end

  def name(_, _), do: "nobody"

  @spec decision(Object.t(), User.t() | String.t() | nil) :: :automatic | :manual | :denied
  def decision(%Object{} = quoted_object, actor) do
    actor = actor_user(actor)
    author = User.get_cached_by_ap_id(quoted_object.data["actor"])

    cond do
      Visibility.get_visibility(quoted_object) == "direct" ->
        :denied

      is_nil(author) or is_nil(actor) ->
        anonymous_decision(quoted_object)

      actor.ap_id == author.ap_id ->
        :automatic

      blocked?(author, actor) ->
        :denied

      is_map(quoted_object.data["interactionPolicy"]) ->
        explicit_decision(quoted_object, author, actor)

      Visibility.get_visibility(quoted_object) in ~w[public unlisted local] ->
        :automatic

      true ->
        :denied
    end
  end

  def decision(_, _), do: :denied

  @spec allowed?(Object.t(), User.t() | nil) :: boolean()
  def allowed?(%Object{} = object, user), do: decision(object, user) != :denied
  def allowed?(_, _), do: false

  @spec valid_authorization?(map(), String.t(), Object.t(), Object.t()) :: boolean()
  def valid_authorization?(document, expected_id, quote_object, quoted_object)
      when is_map(document) and is_binary(expected_id) do
    quoted_actor = quoted_object.data["actor"]

    document["type"] == "QuoteAuthorization" and
      document["id"] == expected_id and
      document["attributedTo"] == quoted_actor and
      document["interactingObject"] == quote_object.data["id"] and
      document["interactionTarget"] == quoted_object.data["id"] and
      same_origin?(expected_id, quoted_actor)
  end

  def valid_authorization?(_, _, _, _), do: false

  defp normalize_name(policy) when is_atom(policy), do: normalize_name(Atom.to_string(policy))
  defp normalize_name(policy) when policy in @policies, do: policy
  defp normalize_name(_), do: "public"

  defp policy(automatic, manual) do
    %{
      "canQuote" => %{
        "automaticApproval" => automatic,
        "manualApproval" => manual
      }
    }
  end

  defp explicit_decision(%Object{data: %{"interactionPolicy" => policy}}, author, actor) do
    can_quote = policy["canQuote"] || %{}
    automatic = collection(can_quote["automaticApproval"])
    manual = collection(can_quote["manualApproval"])

    cond do
      matches?(automatic, author, actor) -> :automatic
      matches?(manual, author, actor) -> :manual
      true -> :denied
    end
  end

  defp anonymous_decision(%Object{data: %{"interactionPolicy" => policy}}) when is_map(policy) do
    can_quote = policy["canQuote"] || %{}

    cond do
      @public in collection(can_quote["automaticApproval"]) -> :automatic
      @public in collection(can_quote["manualApproval"]) -> :manual
      true -> :denied
    end
  end

  defp anonymous_decision(%Object{} = object) do
    if Visibility.get_visibility(object) in ~w[public unlisted local],
      do: :automatic,
      else: :denied
  end

  defp matches?(values, author, actor) do
    @public in values or actor.ap_id in values or
      (author.follower_address in values and User.following?(actor, author)) or
      (following_address(author) in values and User.following?(author, actor))
  end

  defp collection(values) do
    values
    |> List.wrap()
    |> Enum.flat_map(fn
      value when is_binary(value) -> [value]
      %{"id" => value} when is_binary(value) -> [value]
      %{"items" => items} -> collection(items)
      %{"orderedItems" => items} -> collection(items)
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp actor_user(%User{} = user), do: user
  defp actor_user(actor) when is_binary(actor), do: User.get_cached_by_ap_id(actor)
  defp actor_user(_), do: nil

  defp blocked?(author, actor), do: User.blocks?(author, actor) or User.blocks?(actor, author)

  defp following_address(%User{} = user), do: user.ap_id <> "/following"

  defp same_origin?(left, right) do
    left = URI.parse(left)
    right = URI.parse(right)

    is_binary(left.host) and is_binary(right.host) and
      String.downcase(left.host) == String.downcase(right.host) and
      (left.port || URI.default_port(left.scheme)) ==
        (right.port || URI.default_port(right.scheme))
  rescue
    URI.Error -> false
  end
end

# end of quote_policy.ex
