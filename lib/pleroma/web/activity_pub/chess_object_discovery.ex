# Unfathomably received chess discovery
# --------------------------------------
#
# File: chess_object_discovery.ex
#
# Purpose:
#   Find public Castling-compatible chess positions already received through
#   ActivityPub and present the latest known move for each game.
#
# Responsibilities:
#   - identify chess notes from their game, SAN, and FEN fields
#   - require a public remote Create or Update before cataloguing a position
#   - collapse move-note chains into one latest-position card per game
#   - retain a bounded chronological trail of already-received SAN moves
#   - validate all notation, actor, media, and URL fields returned to the UI
#
# This file intentionally does not expose direct game traffic, infer games from
# hostnames or prose, fetch remote histories, or submit chess moves.

defmodule Pleroma.Web.ActivityPub.ChessObjectDiscovery do
  import Ecto.Query

  alias Pleroma.Config
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.Web.ActivityPub.CastlingDiscovery

  @public "https://www.w3.org/ns/activitystreams#Public"
  @maximum_candidates 240
  @maximum_offset 200

  def search(query, limit, offset) do
    query = normalize_query(query)
    limit = normalize_integer(limit, 18, 1, 30)
    offset = normalize_integer(offset, 0, 0, @maximum_offset)
    candidate_limit = min(max((offset + limit) * 4, 24), @maximum_candidates)

    items =
      query
      |> candidate_query(candidate_limit)
      |> Repo.all()
      |> Enum.map(&normalize_object/1)
      |> Enum.reject(&is_nil/1)
      |> aggregate_games()
      |> Enum.drop(offset)
      |> Enum.take(limit)

    %{
      items: items,
      communities: [],
      provider: %{
        type: "local_chess",
        host: local_host(),
        status: "ready"
      }
    }
  end

  defp candidate_query(query, candidate_limit) do
    Object
    |> where(
      [object],
      fragment("?->>'type' = 'Note'", object.data) and
        fragment("jsonb_typeof(?->'game') = 'string'", object.data) and
        fragment("jsonb_typeof(?->'fen') = 'string'", object.data)
    )
    |> where(
      [object],
      fragment(
        """
        EXISTS (
          SELECT 1
          FROM activities AS activity
          WHERE activity.local = FALSE
            AND activity.data->>'type' IN ('Create', 'Update')
            AND CASE jsonb_typeof(activity.data->'object')
                  WHEN 'string' THEN activity.data->>'object'
                  WHEN 'object' THEN activity.data->'object'->>'id'
                END = ?->>'id'
            AND (
              COALESCE(?->'to', 'null'::jsonb) @> to_jsonb(?::text)
              OR COALESCE(?->'cc', 'null'::jsonb) @> to_jsonb(?::text)
              OR COALESCE(activity.data->'to', 'null'::jsonb) @> to_jsonb(?::text)
              OR COALESCE(activity.data->'cc', 'null'::jsonb) @> to_jsonb(?::text)
            )
        )
        """,
        object.data,
        object.data,
        ^@public,
        object.data,
        ^@public,
        ^@public,
        ^@public
      )
    )
    |> maybe_search(query)
    |> order_by([object], desc: object.inserted_at, desc: object.id)
    |> limit(^candidate_limit)
  end

  defp maybe_search(query, ""), do: query

  defp maybe_search(query, term) do
    like_term = "%#{escape_like(String.downcase(term))}%"

    where(
      query,
      [object],
      fragment(
        """
        to_tsvector(
          'simple',
          coalesce(?->>'content', '') || ' ' ||
          coalesce(?->>'game', '') || ' ' ||
          coalesce(?->>'san', '')
        ) @@ plainto_tsquery('simple', ?)
        OR lower(?->>'game') LIKE ? ESCAPE '\\'
        OR lower(?->>'san') = ?
        """,
        object.data,
        object.data,
        object.data,
        ^term,
        object.data,
        ^like_term,
        object.data,
        ^String.downcase(term)
      )
    )
  end

  defp normalize_object(%Object{data: data} = object) when is_map(data) do
    with game_url when not is_nil(game_url) <- valid_https_url(data["game"]),
         fen when not is_nil(fen) <- CastlingDiscovery.valid_fen(data["fen"]),
         move_url when not is_nil(move_url) <- valid_https_url(data["id"]),
         source_host when is_binary(source_host) <- URI.parse(game_url).host,
         true <- same_origin?(game_url, move_url) do
      participants = participants(data["tag"])
      white = Enum.at(participants, 0)
      black = Enum.at(participants, 1)
      position = position_metadata(fen)
      content = plain_text(data["content"], 500)

      %{
        id: "received-chess:#{object.id}",
        family: "game",
        kind: "received_chess_game",
        title: game_title(white, black),
        url: game_url,
        latest_move_url: move_url,
        source_host: source_host,
        fen: fen,
        active_color: active_color(fen),
        participants: participants,
        published_at: published_at(data["published"], object.inserted_at)
      }
      |> Map.merge(position)
      |> put_optional(:last_move, bounded_string(data["san"], 32))
      |> put_optional(:content, content)
      |> put_optional(:reported_status, reported_status(content))
      |> put_optional(:white, white)
      |> put_optional(:black, black)
      |> put_optional(:board_image_url, board_image_url(data["attachment"]))
    else
      _ -> nil
    end
  end

  defp normalize_object(_), do: nil

  defp aggregate_games(items) do
    history_by_game = Enum.group_by(items, & &1.url)

    items
    |> Enum.uniq_by(& &1.url)
    |> Enum.map(fn latest ->
      recent_moves =
        history_by_game
        |> Map.fetch!(latest.url)
        |> Enum.filter(&is_binary(&1[:last_move]))
        |> Enum.uniq_by(& &1.latest_move_url)
        |> Enum.take(12)
        |> Enum.reverse()
        |> Enum.map(fn position ->
          %{
            san: position.last_move,
            url: position.latest_move_url,
            published_at: position.published_at
          }
        end)

      latest
      |> Map.put(:loaded_move_count, length(recent_moves))
      |> put_optional(:recent_moves, empty_list_to_nil(recent_moves))
    end)
  end

  defp participants(tags) do
    tags
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.filter(&(short_type(&1["type"]) == "Mention"))
    |> Enum.map(&participant/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.actor_url)
    |> Enum.take(8)
  end

  defp participant(tag) do
    with actor_url when not is_nil(actor_url) <- valid_https_url(tag["href"] || tag["url"]),
         host when is_binary(host) <- URI.parse(actor_url).host do
      %{
        actor_url: actor_url,
        handle: bounded_string(tag["name"], 300) || handle_from_url(actor_url, host)
      }
    else
      _ -> nil
    end
  end

  defp handle_from_url(actor_url, host) do
    username =
      actor_url
      |> URI.parse()
      |> Map.get(:path)
      |> to_string()
      |> String.split("/", trim: true)
      |> List.last()
      |> bounded_string(100)

    if username && Regex.match?(~r/\A[\p{L}\p{N}_.-]+\z/u, username) do
      "@#{username}@#{host}"
    end
  end

  defp game_title(%{handle: white}, %{handle: black})
       when is_binary(white) and is_binary(black),
       do: "#{white} vs. #{black}"

  defp game_title(_, _), do: "Federated chess game"

  defp active_color(fen) do
    case String.split(fen, " ") do
      [_, "w" | _] -> "white"
      [_, "b" | _] -> "black"
    end
  end

  defp position_metadata(fen) do
    case String.split(fen, " ") do
      [_, active, _, _, _, fullmove] when active in ["w", "b"] ->
        case Integer.parse(fullmove) do
          {number, ""} when number > 0 ->
            %{
              fullmove_number: number,
              position_ply: (number - 1) * 2 + if(active == "b", do: 1, else: 0)
            }

          _ ->
            %{}
        end

      _ ->
        %{}
    end
  end

  defp reported_status(content) when is_binary(content) do
    content = String.downcase(content)

    cond do
      String.contains?(content, "checkmate.") -> "checkmate"
      String.contains?(content, "draw.") -> "draw"
      String.contains?(content, "'s turn") -> "active"
      true -> nil
    end
  end

  defp reported_status(_), do: nil

  defp board_image_url(attachments) do
    attachments
    |> List.wrap()
    |> Enum.find_value(fn
      %{"type" => type} = attachment when type in ["Image", "Document"] ->
        media_url(attachment["url"])

      _ ->
        nil
    end)
  end

  defp media_url(value) when is_binary(value), do: valid_https_url(value)
  defp media_url(%{"href" => value}), do: media_url(value)
  defp media_url(%{"url" => value}), do: media_url(value)
  defp media_url(values) when is_list(values), do: Enum.find_value(values, &media_url/1)
  defp media_url(_), do: nil

  defp plain_text(value, maximum) when is_binary(value) do
    value =
      case Floki.parse_fragment(value) do
        {:ok, document} -> Floki.text(document)
        _ -> value
      end

    value
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, maximum)
    |> empty_to_nil()
  end

  defp plain_text(_, _), do: nil

  defp published_at(value, fallback) do
    bounded_string(value, 100) || timestamp(fallback)
  end

  defp timestamp(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp(_), do: nil

  defp valid_https_url(value) when is_binary(value) do
    value = String.trim(value)

    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil} = uri
      when is_binary(host) and byte_size(host) > 0 and byte_size(value) <= 2048 ->
        URI.to_string(uri)

      _ ->
        nil
    end
  end

  defp valid_https_url(_), do: nil

  defp same_origin?(left, right) do
    left = URI.parse(left)
    right = URI.parse(right)

    left.scheme == right.scheme and
      String.downcase(left.host || "") == String.downcase(right.host || "") and
      effective_port(left) == effective_port(right)
  end

  defp effective_port(%URI{scheme: "https", port: nil}), do: 443
  defp effective_port(%URI{port: port}), do: port

  defp short_type(value) when is_binary(value) do
    value
    |> String.split(["#", "/"], trim: true)
    |> List.last()
  end

  defp short_type(_), do: nil

  defp normalize_query(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.slice(0, 200)
  end

  defp normalize_query(_), do: ""

  defp normalize_integer(value, _default, minimum, maximum) when is_integer(value) do
    value |> max(minimum) |> min(maximum)
  end

  defp normalize_integer(_, default, _minimum, _maximum), do: default

  defp bounded_string(value, maximum) when is_binary(value) do
    value = String.trim(value)

    if value != "" && String.length(value) <= maximum do
      value
    end
  end

  defp bounded_string(_, _), do: nil

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
  defp empty_list_to_nil([]), do: nil
  defp empty_list_to_nil(value), do: value

  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp local_host do
    case Config.get([Pleroma.Web.Endpoint, :url, :host]) do
      host when is_binary(host) and host != "" -> host
      _ -> "local"
    end
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end

# end of chess_object_discovery.ex
