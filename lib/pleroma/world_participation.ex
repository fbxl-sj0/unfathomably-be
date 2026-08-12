# Unfathomably profile Worlds participation
# ------------------------------------------
#
# File: world_participation.ex
#
# Purpose:
#
#   Summarize the public native object families associated with an account.
#
# Responsibilities:
#
#   * count public, feed-eligible native objects attributed to an actor
#   * include durable personal book shelf participation
#   * return families in the same stable order used by the Worlds interface
#
# This file intentionally does NOT fetch remote actors, publish activities, or
# expose private objects and shelf metadata.

defmodule Pleroma.WorldParticipation do
  import Ecto.Query

  alias Pleroma.BookShelfEntry
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User

  @public "https://www.w3.org/ns/activitystreams#Public"
  @families ~w[
    audio video longform photo books bookmarks groups events development
    models marketplace games routes culture coordination publishing
  ]

  def list(%User{} = user) do
    native_counts =
      Object
      |> where([object], fragment("?->>'actor' = ?", object.data, ^user.ap_id))
      |> where(
        [object],
        fragment(
          "(?->'to' = to_jsonb(?::text) OR ?->'to' @> jsonb_build_array(?::text) OR ?->'cc' = to_jsonb(?::text) OR ?->'cc' @> jsonb_build_array(?::text))",
          object.data,
          ^@public,
          object.data,
          ^@public,
          object.data,
          ^@public,
          object.data,
          ^@public
        )
      )
      |> where([object], fragment("unfathomably_native_discoverable(?)", object.data))
      |> where([object], fragment("unfathomably_native_feed_eligible(?)", object.data))
      |> where(
        [object],
        not is_nil(fragment("unfathomably_native_family(?)", object.data))
      )
      |> group_by([object], fragment("unfathomably_native_family(?)", object.data))
      |> select(
        [object],
        {fragment("unfathomably_native_family(?)", object.data), count(object.id)}
      )
      |> Repo.all()
      |> Map.new()

    book_count =
      BookShelfEntry
      |> where([entry], entry.user_id == ^user.id)
      |> Repo.aggregate(:count, :id)

    native_counts =
      if book_count > 0 do
        Map.update(native_counts, "books", book_count, &(&1 + book_count))
      else
        native_counts
      end

    @families
    |> Enum.flat_map(fn family ->
      case Map.get(native_counts, family, 0) do
        count when count > 0 -> [%{id: family, count: count}]
        _count -> []
      end
    end)
  end
end

# end of world_participation.ex
