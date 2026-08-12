# Unfathomably Castling discovery
# --------------------------------
#
# File: castling_discovery.ex
#
# Purpose:
#   Discover public Castling.club challengers and recent chess games after an
#   authenticated user explicitly asks to load the Games discovery panel.
#
# Responsibilities:
#   - read configured Castling service home pages
#   - parse public challenge-board and recent-game entries
#   - fetch a bounded number of game objects for board and move metadata
#   - validate every remote URL and chess field before returning it to the UI
#
# This file intentionally does not poll Castling in the background, issue
# challenges, import complete game histories, or treat a game root as a normal
# ActivityPub status.

defmodule Pleroma.Web.ActivityPub.CastlingDiscovery do
  alias Pleroma.Config
  alias Pleroma.HTTP
  alias Pleroma.Web.ActivityPub.ChessObjectDiscovery

  @cachex Config.get([:cachex, :provider], Cachex)
  @cache :native_catalog_cache
  @cache_ttl :timer.minutes(5)
  @cache_retention_ttl :timer.minutes(30)
  @cache_lock :unfathomably_castling_discovery
  @game_path ~r|\A/games/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\z|i
  @object_path ~r|\A/objects/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z|i
  @maximum_html_bytes 1_000_000
  @maximum_game_bytes 500_000
  @maximum_games 6
  @detail_concurrency 3
  @detail_timeout 16_000

  def searches(query, limit, offset) do
    query = normalized_query(query)
    limit = limit |> max(1) |> min(30)

    external_results =
      Config.get([:native_discovery, :castling_indexes], [])
      |> Enum.map(&normalize_index/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.take(3)
      |> Enum.map(&search_index(&1, query, limit, offset))

    [ChessObjectDiscovery.search(query, limit, offset) | external_results]
  end

  defp search_index(index, _query, _limit, offset) when offset > 0 do
    empty_result(index, "ready")
  end

  defp search_index(index, query, limit, _offset) do
    cache_key = {:castling_index, index, query, limit}

    case cached_result(cache_key) do
      {:fresh, result} ->
        result

      cached ->
        case :global.trans(
               {@cache_lock, cache_key},
               fn -> refresh_index(cache_key, index, query, limit, cached) end,
               [node()]
             ) do
          {:aborted, _reason} -> cached_or_unavailable(cached, index)
          result -> result
        end
    end
  end

  defp refresh_index(cache_key, index, query, limit, previous) do
    case cached_result(cache_key) do
      {:fresh, result} ->
        result

      cached ->
        stale = prefer_cached(cached, previous)

        case fetch_index(index, query, limit) do
          {:ok, result} ->
            cache_result(cache_key, result)
            result

          :error ->
            cached_or_unavailable(stale, index)
        end
    end
  end

  defp fetch_index(index, query, limit) do
    with {:ok, body} <- fetch(index, "text/html", @maximum_html_bytes),
         {:ok, document} <- Floki.parse_document(body) do
      games =
        document
        |> Floki.find("tr")
        |> Enum.map(&parse_game_row(index, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(&matches_query?(&1, query))
        |> Enum.take(min(limit, @maximum_games))
        |> enrich_games()

      challengers =
        document
        |> Floki.find("ul.challenge-board li")
        |> Enum.map(&parse_challenger(index, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(&matches_query?(&1, query))
        |> Enum.take(max(limit - length(games), 0))

      {:ok, result(index, "ready", games ++ challengers)}
    else
      _ -> :error
    end
  end

  defp cached_result(cache_key) do
    now = System.system_time(:millisecond)

    case @cachex.get(@cache, cache_key) do
      {:ok, %{fetched_at: fetched_at, result: result}}
      when is_integer(fetched_at) and is_map(result) ->
        age = now - fetched_at

        if age >= 0 and age <= @cache_ttl do
          {:fresh, result}
        else
          {:stale, result}
        end

      _ ->
        :miss
    end
  end

  defp cache_result(cache_key, result) do
    value = %{fetched_at: System.system_time(:millisecond), result: result}
    _ = @cachex.put(@cache, cache_key, value, ttl: @cache_retention_ttl)
  end

  defp prefer_cached({:stale, _result} = cached, _previous), do: cached
  defp prefer_cached(_cached, {:stale, _result} = previous), do: previous
  defp prefer_cached(_cached, _previous), do: :miss

  defp cached_or_unavailable({:stale, result}, _index), do: result
  defp cached_or_unavailable(_cached, index), do: empty_result(index, "unavailable")

  defp parse_game_row(index, row) do
    link =
      row
      |> Floki.find("a[href]")
      |> Enum.find(fn anchor ->
        case first_attribute(anchor, "href") do
          href when is_binary(href) -> Regex.match?(@game_path, URI.parse(href).path || "")
          _ -> false
        end
      end)

    with link when not is_nil(link) <- link,
         href when is_binary(href) <- first_attribute(link, "href"),
         {:ok, game_url, game_id} <- game_url(index, href),
         {:ok, white, black} <- players(Floki.text(link)) do
      host = URI.parse(index).host

      %{
        id: "castling:#{host}:#{game_id}",
        family: "game",
        kind: "chess_game",
        title: "@#{white} vs. @#{black}",
        url: game_url,
        source_url: index,
        source_host: host,
        platform: "castling",
        white: %{username: white},
        black: %{username: black},
        turn: turn_number(Floki.text(row)),
        published_at: row_time(row),
        arbiter_handle: "@king@#{host}"
      }
    else
      _ -> nil
    end
  end

  defp parse_challenger(index, row) do
    actor_link =
      row
      |> Floki.find("a[href]")
      |> Enum.find(fn anchor ->
        case first_attribute(anchor, "href") do
          href when is_binary(href) -> valid_https_url(href) != nil
          _ -> false
        end
      end)

    with actor_link when not is_nil(actor_link) <- actor_link,
         actor_url when is_binary(actor_url) <- first_attribute(actor_link, "href"),
         actor_url when not is_nil(actor_url) <- valid_https_url(actor_url),
         username when not is_nil(username) <- challenger_username(Floki.text(actor_link)),
         actor_host when is_binary(actor_host) <- URI.parse(actor_url).host do
      host = URI.parse(index).host
      handle = "@#{username}@#{actor_host}"
      digest = :crypto.hash(:sha256, actor_url) |> Base.encode16(case: :lower)

      %{
        id: "castling:#{host}:challenger:#{digest}",
        family: "game",
        kind: "open_challenge",
        title: "@#{username}",
        handle: handle,
        actor_url: actor_url,
        source_url: index,
        source_host: host,
        platform: "castling",
        published_at: nil,
        arbiter_handle: "@king@#{host}"
      }
    else
      _ -> nil
    end
  end

  defp enrich_games([]), do: []

  defp enrich_games(games) do
    # Game objects can be large because they contain every move. Keep both the
    # count and concurrency bounded so one user action cannot overwhelm the
    # Castling service or consume an unbounded number of local HTTP workers.
    games
    |> Task.async_stream(&cached_enrich_game/1,
      ordered: true,
      max_concurrency: @detail_concurrency,
      timeout: @detail_timeout,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, game} -> game
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp cached_enrich_game(game) do
    cache_key = {:castling_game, game.url}

    case @cachex.get(@cache, cache_key) do
      {:ok, cached} when is_map(cached) ->
        cached

      _ ->
        enriched = enrich_game(game)

        if Map.has_key?(enriched, :fen) do
          _ = @cachex.put(@cache, cache_key, enriched, ttl: @cache_ttl)
        end

        enriched
    end
  end

  defp enrich_game(game) do
    case fetch(game.url, "application/activity+json", @maximum_game_bytes) do
      {:ok, body} ->
        with {:ok, data} when is_map(data) <- Jason.decode(body),
             true <- data["id"] == game.url,
             fen when not is_nil(fen) <- valid_fen(data["fen"]) do
          moves = if is_list(data["moves"]), do: data["moves"], else: []
          latest_move = moves |> Enum.filter(&is_map/1) |> List.last()
          white = player(data["whiteUsername"], data["whiteActor"], game.white)
          black = player(data["blackUsername"], data["blackActor"], game.black)
          active_color = active_color(fen)

          game
          |> Map.put(:fen, fen)
          |> Map.put(:white, white)
          |> Map.put(:black, black)
          |> Map.put(:title, "#{player_label(white)} vs. #{player_label(black)}")
          |> Map.put(:active_color, active_color)
          |> Map.put(:next_player, if(active_color == "white", do: white, else: black))
          |> Map.put(:move_count, length(moves))
          |> put_optional(:badge, bounded_string(data["badge"], 80))
          |> put_optional(:setup_note, setup_note(data["setupNote"]))
          |> merge_latest_move(latest_move, game.source_url)
        else
          _ -> game
        end

      _ ->
        game
    end
  end

  defp merge_latest_move(game, nil, _index), do: game

  defp merge_latest_move(game, move, index) do
    move_url = same_origin_path(move["id"], index, @object_path)
    san = bounded_string(move["san"], 16)
    published_at = bounded_string(move["published"], 100) || game.published_at
    board_image_url = board_image_url(move, index)

    game
    |> put_optional(:latest_move_url, move_url)
    |> put_optional(:last_move, san)
    |> put_optional(:board_image_url, board_image_url)
    |> Map.put(:published_at, published_at)
  end

  defp player(username, actor_url, fallback) do
    username = bounded_string(username, 100) || fallback.username
    actor_url = valid_https_url(actor_url)

    %{username: username}
    |> put_optional(:actor_url, actor_url)
    |> put_optional(:handle, actor_handle(username, actor_url))
  end

  defp actor_handle(username, actor_url) when is_binary(username) and is_binary(actor_url) do
    with host when is_binary(host) <- URI.parse(actor_url).host,
         local_name when local_name != "" <-
           username |> String.trim_leading("@") |> String.split("@") |> List.first() do
      "@#{local_name}@#{String.downcase(host)}"
    else
      _ -> nil
    end
  end

  defp actor_handle(_username, _actor_url), do: nil

  defp player_label(%{handle: handle}) when is_binary(handle), do: handle
  defp player_label(%{username: username}), do: "@#{String.trim_leading(username, "@")}"

  defp players(text) do
    case Regex.run(~r/@([^\s]+)\s+vs\.\s+.*?@([^\s]+)/u, text, capture: :all_but_first) do
      [white, black] ->
        with white when not is_nil(white) <- bounded_username(white),
             black when not is_nil(black) <- bounded_username(black) do
          {:ok, white, black}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp challenger_username(text) do
    text
    |> String.trim()
    |> String.trim_leading("@")
    |> bounded_username()
  end

  defp bounded_username(value) do
    value = bounded_string(value, 100)

    if value && !String.contains?(value, ["@", "/", "\\"]) do
      value
    end
  end

  defp game_url(index, href) do
    url = index |> URI.merge(href) |> URI.to_string()

    with %URI{path: path} <- URI.parse(url),
         [game_id] <- Regex.run(@game_path, path || "", capture: :all_but_first),
         ^url <- same_origin_path(url, index, @game_path) do
      {:ok, url, String.downcase(game_id)}
    else
      _ -> :error
    end
  end

  defp turn_number(text) do
    case Regex.run(~r/\(turn\s+([0-9]+)\)/i, text, capture: :all_but_first) do
      [value] ->
        case Integer.parse(value) do
          {turn, ""} when turn >= 0 and turn <= 10_000 -> turn
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp row_time(row) do
    row
    |> Floki.find("td.time")
    |> Floki.text()
    |> bounded_string(100)
  end

  defp board_image_url(move, index) do
    [move["image"], move["attachment"]]
    |> Enum.find_value(&media_url(&1, index))
  end

  defp media_url(value, index) when is_binary(value), do: same_origin_path(value, index, ~r{\A/})
  defp media_url(%{"url" => value}, index), do: media_url(value, index)

  defp media_url(values, index) when is_list(values),
    do: Enum.find_value(values, &media_url(&1, index))

  defp media_url(_, _), do: nil

  defp setup_note(%{"content" => content}), do: html_text(content, 500)
  defp setup_note(content) when is_binary(content), do: html_text(content, 500)
  defp setup_note(_content), do: nil

  defp html_text(content, maximum) when is_binary(content) do
    case Floki.parse_fragment(content) do
      {:ok, nodes} ->
        nodes
        |> Floki.text()
        |> String.replace(~r/\s+/u, " ")
        |> bounded_string(maximum)

      _ ->
        nil
    end
  end

  defp html_text(_content, _maximum), do: nil

  defp active_color(fen) do
    case String.split(fen, " ") do
      [_, "w" | _] -> "white"
      [_, "b" | _] -> "black"
    end
  end

  def valid_fen(value) do
    with fen when not is_nil(fen) <- bounded_string(value, 128),
         [board, active, castling, en_passant, halfmove, fullmove] <- String.split(fen, " "),
         true <- valid_board?(board),
         true <- active in ["w", "b"],
         true <- Regex.match?(~r/\A(?:-|[KQkq]{1,4})\z/, castling),
         true <- Regex.match?(~r/\A(?:-|[a-h][36])\z/, en_passant),
         true <- valid_counter?(halfmove, 0),
         true <- valid_counter?(fullmove, 1) do
      fen
    else
      _ -> nil
    end
  end

  defp valid_board?(board) do
    ranks = String.split(board, "/")
    length(ranks) == 8 && Enum.all?(ranks, &(rank_width(&1) == 8))
  end

  defp rank_width(rank) do
    rank
    |> String.graphemes()
    |> Enum.reduce_while(0, fn
      piece, width when piece in ~w(p r n b q k P R N B Q K) ->
        {:cont, width + 1}

      digit, width ->
        case Integer.parse(digit) do
          {count, ""} when count >= 1 and count <= 8 -> {:cont, width + count}
          _ -> {:halt, -1}
        end
    end)
  end

  defp valid_counter?(value, minimum) do
    case Integer.parse(value) do
      {number, ""} when number >= minimum and number <= 100_000 -> true
      _ -> false
    end
  end

  defp matches_query?(_item, ""), do: true

  defp matches_query?(item, query) do
    item
    |> Map.take([:title, :handle, :source_host])
    |> Map.values()
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> String.downcase()
    |> String.contains?(query)
  end

  defp fetch(url, accept, maximum_bytes) do
    case HTTP.get(url, [{"accept", accept}], pool: :federation, recv_timeout: 5_000) do
      {:ok, %Tesla.Env{status: status, body: body}}
      when status >= 200 and status < 300 and is_binary(body) and
             byte_size(body) <= maximum_bytes ->
        {:ok, body}

      _ ->
        :error
    end
  end

  defp same_origin_path(value, index, path_pattern) do
    with value when is_binary(value) <- value,
         %URI{} = candidate <- URI.parse(value),
         %URI{} = source <- URI.parse(index),
         true <- candidate.scheme == "https",
         true <- candidate.host == source.host,
         true <- effective_port(candidate) == effective_port(source),
         true <- is_nil(candidate.userinfo),
         true <- Regex.match?(path_pattern, candidate.path || "") do
      URI.to_string(candidate)
    else
      _ -> nil
    end
  end

  defp valid_https_url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil} = uri
      when is_binary(host) and byte_size(host) > 0 ->
        URI.to_string(uri)

      _ ->
        nil
    end
  end

  defp valid_https_url(_), do: nil

  defp normalize_index(value) when is_binary(value) do
    case URI.parse(String.trim(value)) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil} = uri
      when is_binary(host) and byte_size(host) > 0 ->
        uri
        |> Map.put(:path, "")
        |> URI.to_string()
        |> String.trim_trailing("/")

      _ ->
        nil
    end
  end

  defp normalize_index(_), do: nil

  defp normalized_query(query) when is_binary(query) do
    query
    |> String.trim()
    |> String.downcase()
    |> String.slice(0, 200)
  end

  defp normalized_query(_), do: ""

  defp first_attribute(node, name), do: node |> Floki.attribute(name) |> List.first()

  defp bounded_string(value, maximum) when is_binary(value) do
    value = String.trim(value)

    if value != "" && String.length(value) <= maximum do
      value
    end
  end

  defp bounded_string(_, _), do: nil

  defp effective_port(%URI{port: port}) when is_integer(port), do: port
  defp effective_port(%URI{scheme: "https"}), do: 443

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp result(index, status, items) do
    host = URI.parse(index).host

    %{
      items: items,
      communities: [],
      provider: %{
        type: "castling",
        host: host,
        url: index,
        status: status,
        arbiter_handle: "@king@#{host}"
      }
    }
  end

  defp empty_result(index, status), do: result(index, status, [])
end

# end of castling_discovery.ex
