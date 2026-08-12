# Unfathomably BE
# ----------------
#
# File: native_catalog.ex
#
# Purpose:
#   Find external metadata candidates for the bounded Worlds authoring flows.
#
# Responsibilities:
#   - normalize and bound human-entered catalog queries
#   - pace, identify, and cache calls to approved metadata providers
#   - map provider responses into small editable draft candidates
#   - preserve provider identity and source links for user review
#
# This file intentionally does not publish ActivityPub objects, accept arbitrary
# provider URLs, download remote artwork, or make external metadata authoritative.

defmodule Pleroma.Web.ActivityPub.NativeCatalog do
  @moduledoc false

  alias Pleroma.Config
  alias Pleroma.HTTP
  alias Pleroma.Web.ActivityPub.NativeDiscovery

  require Logger

  @cachex Config.get([:cachex, :provider], Cachex)
  @cache :native_catalog_cache
  @cache_ttl :timer.minutes(5)
  @open_library_interval_ms 500
  @open_library_lock :unfathomably_open_library_catalog
  @musicbrainz_interval_ms 1_100
  @musicbrainz_lock :unfathomably_musicbrainz_catalog
  @max_response_bytes 1_000_000
  @result_limit 8
  @open_library_fields Enum.join(
                         [
                           "key",
                           "title",
                           "author_name",
                           "first_publish_year",
                           "isbn",
                           "language",
                           "editions",
                           "editions.key",
                           "editions.title",
                           "editions.language",
                           "editions.isbn",
                           "editions.publish_date"
                         ],
                         ","
                       )

  @language_names %{
    "ara" => "Arabic",
    "chi" => "Chinese",
    "deu" => "German",
    "dut" => "Dutch",
    "eng" => "English",
    "fre" => "French",
    "ger" => "German",
    "ita" => "Italian",
    "jpn" => "Japanese",
    "kor" => "Korean",
    "lat" => "Latin",
    "pol" => "Polish",
    "por" => "Portuguese",
    "rus" => "Russian",
    "spa" => "Spanish",
    "swe" => "Swedish",
    "zho" => "Chinese"
  }

  @culture_categories %{
    "album" => "music",
    "film" => "movie",
    "game" => "game",
    "podcast" => "podcast",
    "series" => "tv"
  }

  @spec search(String.t() | nil, String.t() | nil, String.t() | nil) ::
          {:ok, [map()]}
          | {:error,
             :invalid_category | :invalid_query | :provider_unavailable | :unsupported_template}
  def search(template, query, category \\ nil)

  def search("books", query, _category) do
    with {:ok, query} <- normalize_query(query) do
      bookwyrm_candidates = connected_bookwyrm_candidates(query)

      case cached_open_library_search(query) do
        {:ok, metadata_candidates} ->
          {:ok, merge_book_candidates(bookwyrm_candidates, metadata_candidates)}

        {:error, _reason} when bookwyrm_candidates != [] ->
          {:ok, bookwyrm_candidates}

        error ->
          error
      end
    end
  end

  def search("audio", query, _category) do
    with {:ok, query} <- normalize_query(query) do
      cached_musicbrainz_search(query)
    end
  end

  def search("culture", query, category) do
    with {:ok, query} <- normalize_query(query),
         {:ok, remote_category} <- culture_category(category) do
      {:ok, connected_neodb_candidates(query, category || "film", remote_category)}
    end
  end

  def search(_template, _query, _category), do: {:error, :unsupported_template}

  defp normalize_query(query) when is_binary(query) do
    query = String.trim(query)

    cond do
      not String.valid?(query) ->
        {:error, :invalid_query}

      String.length(query) < 2 or String.length(query) > 100 ->
        {:error, :invalid_query}

      true ->
        {:ok, normalize_isbn(query)}
    end
  end

  defp normalize_query(_query), do: {:error, :invalid_query}

  defp normalize_isbn(query) do
    compact = String.replace(query, ~r/[\s-]/u, "")

    if Regex.match?(~r/^\d{13}$|^\d{9}[\dXx]$/, compact) do
      String.upcase(compact)
    else
      query
    end
  end

  defp cached_open_library_search(query) do
    cache_key = {:open_library_search, String.downcase(query)}

    case @cachex.get(@cache, cache_key) do
      {:ok, results} when is_list(results) ->
        {:ok, results}

      _ ->
        paced_open_library_search(cache_key, query)
    end
  end

  defp paced_open_library_search(cache_key, query) do
    lock = {@open_library_lock, self()}

    case :global.trans(lock, fn -> search_under_lock(cache_key, query) end, [node()]) do
      {:aborted, _reason} -> {:error, :provider_unavailable}
      result -> result
    end
  end

  defp search_under_lock(cache_key, query) do
    case @cachex.get(@cache, cache_key) do
      {:ok, results} when is_list(results) ->
        {:ok, results}

      _ ->
        pace_open_library()

        case fetch_open_library(query) do
          {:ok, results} = result ->
            _ = @cachex.put(@cache, cache_key, results, ttl: @cache_ttl)
            result

          error ->
            error
        end
    end
  end

  defp pace_open_library do
    pace_provider(:open_library, @open_library_interval_ms)
  end

  defp pace_provider(provider, interval_ms) do
    key = {:provider_last_request, provider}
    now = System.system_time(:millisecond)

    last_request =
      case @cachex.get(@cache, key) do
        {:ok, value} when is_integer(value) -> value
        _ -> 0
      end

    wait_ms = max(last_request + interval_ms - now, 0)

    if wait_ms > 0 do
      Process.sleep(wait_ms)
    end

    _ = @cachex.put(@cache, key, System.system_time(:millisecond), ttl: @cache_ttl)
  end

  defp cached_musicbrainz_search(query) do
    cache_key = {:musicbrainz_recording_search, String.downcase(query)}

    case @cachex.get(@cache, cache_key) do
      {:ok, results} when is_list(results) ->
        {:ok, results}

      _ ->
        paced_musicbrainz_search(cache_key, query)
    end
  end

  defp paced_musicbrainz_search(cache_key, query) do
    lock = {@musicbrainz_lock, self()}

    case :global.trans(lock, fn -> musicbrainz_search_under_lock(cache_key, query) end, [node()]) do
      {:aborted, _reason} -> {:error, :provider_unavailable}
      result -> result
    end
  end

  defp musicbrainz_search_under_lock(cache_key, query) do
    case @cachex.get(@cache, cache_key) do
      {:ok, results} when is_list(results) ->
        {:ok, results}

      _ ->
        pace_provider(:musicbrainz, @musicbrainz_interval_ms)

        case fetch_musicbrainz(query) do
          {:ok, results} = result ->
            _ = @cachex.put(@cache, cache_key, results, ttl: @cache_ttl)
            result

          error ->
            error
        end
    end
  end

  defp fetch_musicbrainz(query) do
    query_string =
      URI.encode_query(%{
        "fmt" => "json",
        "limit" => Integer.to_string(@result_limit),
        "query" => query
      })

    url = "https://musicbrainz.org/ws/2/recording?" <> query_string
    headers = [{"accept", "application/json"}, {"user-agent", provider_user_agent()}]

    case HTTP.get(url, headers, pool: :default, recv_timeout: 5_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        decode_musicbrainz(body)

      {:ok, %{status: status}} when status in [408, 425, 429, 500, 502, 503, 504] ->
        Logger.info("MusicBrainz catalog search deferred after HTTP #{status}")
        {:error, :provider_unavailable}

      {:ok, %{status: status}} ->
        Logger.warning("MusicBrainz catalog search returned HTTP #{status}")
        {:error, :provider_unavailable}

      {:error, reason} ->
        Logger.info("MusicBrainz catalog search failed: #{inspect(reason)}")
        {:error, :provider_unavailable}
    end
  end

  defp decode_musicbrainz(body) when byte_size(body) <= @max_response_bytes do
    case Jason.decode(body) do
      {:ok, %{"recordings" => recordings}} when is_list(recordings) ->
        {:ok,
         recordings
         |> Enum.take(@result_limit)
         |> Enum.flat_map(&musicbrainz_candidate/1)}

      _ ->
        Logger.warning("MusicBrainz catalog search returned malformed JSON")
        {:error, :provider_unavailable}
    end
  end

  defp decode_musicbrainz(_body) do
    Logger.warning("MusicBrainz catalog search exceeded the response size limit")
    {:error, :provider_unavailable}
  end

  defp musicbrainz_candidate(%{"id" => id, "title" => raw_title} = recording)
       when is_binary(id) and is_binary(raw_title) do
    title = bounded_string(raw_title, 300)

    if title != "" and Regex.match?(~r/^[0-9a-f-]{36}$/i, id) do
      artists = musicbrainz_artists(recording["artist-credit"])
      release = first_map(recording["releases"])
      album = bounded_string(release["title"], 300)
      release_date = bounded_string(recording["first-release-date"], 32)
      genres = musicbrainz_genres(recording["genres"] || recording["tags"])

      fields =
        %{}
        |> maybe_put("artist", Enum.join(artists, ", "))
        |> maybe_put("album", album)
        |> maybe_put("release_date", release_date)
        |> maybe_put("genres", Enum.join(genres, ", "))

      [
        %{
          id: "musicbrainz:" <> id,
          provider: "musicbrainz",
          provider_label: "MusicBrainz",
          source_url: "https://musicbrainz.org/recording/" <> id,
          subtitle:
            [Enum.join(artists, ", "), album, release_date]
            |> Enum.reject(&(&1 == ""))
            |> Enum.join(" | "),
          title: title,
          fields: fields
        }
      ]
    else
      []
    end
  end

  defp musicbrainz_candidate(_recording), do: []

  defp musicbrainz_artists(values) when is_list(values) do
    values
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) -> [bounded_string(name, 100)]
      %{"artist" => %{"name" => name}} when is_binary(name) -> [bounded_string(name, 100)]
      _ -> []
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(5)
  end

  defp musicbrainz_artists(_values), do: []

  defp musicbrainz_genres(values) when is_list(values) do
    values
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) -> [bounded_string(name, 60)]
      _ -> []
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(8)
  end

  defp musicbrainz_genres(_values), do: []

  defp first_map([value | _]) when is_map(value), do: value
  defp first_map(_values), do: %{}

  defp fetch_open_library(query) do
    query_string =
      URI.encode_query(%{
        "fields" => @open_library_fields,
        "limit" => Integer.to_string(@result_limit),
        "q" => query
      })

    url = "https://openlibrary.org/search.json?" <> query_string
    headers = [{"accept", "application/json"}, {"user-agent", provider_user_agent()}]

    case HTTP.get(url, headers, pool: :default, recv_timeout: 5_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        decode_open_library(body)

      {:ok, %{status: status}} when status in [408, 425, 429, 500, 502, 503, 504] ->
        Logger.info("Open Library catalog search deferred after HTTP #{status}")
        {:error, :provider_unavailable}

      {:ok, %{status: status}} ->
        Logger.warning("Open Library catalog search returned HTTP #{status}")
        {:error, :provider_unavailable}

      {:error, reason} ->
        Logger.info("Open Library catalog search failed: #{inspect(reason)}")
        {:error, :provider_unavailable}
    end
  end

  defp decode_open_library(body) when byte_size(body) <= @max_response_bytes do
    case Jason.decode(body) do
      {:ok, %{"docs" => docs}} when is_list(docs) ->
        {:ok, docs |> Enum.take(@result_limit) |> Enum.flat_map(&open_library_candidate/1)}

      _ ->
        Logger.warning("Open Library catalog search returned malformed JSON")
        {:error, :provider_unavailable}
    end
  end

  defp decode_open_library(_body) do
    Logger.warning("Open Library catalog search exceeded the response size limit")
    {:error, :provider_unavailable}
  end

  defp open_library_candidate(doc) when is_map(doc) do
    edition = preferred_edition(doc)

    with {provider_id, source_url} <- source_identity(edition, doc),
         title when title != "" <- candidate_title(edition, doc) do
      authors = safe_strings(doc["author_name"], 3, 100)
      publication = publication_label(edition, doc)

      fields =
        %{}
        |> maybe_put("author", Enum.join(authors, ", "))
        |> maybe_put("edition", publication)
        |> maybe_put("isbn", preferred_isbn(edition, doc))
        |> maybe_put("language", preferred_language(edition, doc))

      [
        %{
          federatable: false,
          id: "open_library:" <> provider_id,
          provider: "open_library",
          provider_label: "Open Library",
          source_url: source_url,
          subtitle:
            Enum.join(Enum.reject([Enum.join(authors, ", "), publication], &(&1 == "")), " | "),
          title: title,
          fields: fields
        }
      ]
    else
      _ -> []
    end
  end

  defp open_library_candidate(_doc), do: []

  defp connected_bookwyrm_candidates(query) do
    %{"family" => "catalog", "category" => "book", "q" => query, "limit" => "8"}
    |> NativeDiscovery.search()
    |> Map.get(:items, [])
    |> Enum.flat_map(&bookwyrm_candidate/1)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp connected_neodb_candidates(query, category, remote_category) do
    %{
      "family" => "catalog",
      "category" => remote_category,
      "q" => query,
      "limit" => Integer.to_string(@result_limit)
    }
    |> NativeDiscovery.search()
    |> Map.get(:items, [])
    |> Enum.flat_map(&neodb_candidate(&1, category))
    |> Enum.take(@result_limit)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp neodb_candidate(item, category) when is_map(item) do
    id = discovery_value(item, :id)
    title = bounded_string(discovery_value(item, :title), 300)
    source_url = discovery_value(item, :url)
    source_host = bounded_string(discovery_value(item, :source_host), 255)
    year = bounded_string(discovery_value(item, :year), 20)

    credits =
      case discovery_value(item, :credits) do
        values when is_list(values) ->
          values
          |> Enum.flat_map(fn credit ->
            case bounded_string(discovery_value(credit, :name), 100) do
              "" -> []
              name -> [name]
            end
          end)
          |> Enum.uniq()
          |> Enum.take(4)

        _ ->
          []
      end

    if is_binary(id) and String.starts_with?(id, "neodb:") and title != "" and
         valid_http_url?(source_url) do
      [
        %{
          federatable: true,
          fields: %{"category" => category},
          id: id,
          provider: "neodb",
          provider_label: if(source_host == "", do: "NeoDB", else: "NeoDB at " <> source_host),
          reference_url: source_url,
          source_url: source_url,
          subtitle: Enum.join(Enum.reject([Enum.join(credits, ", "), year], &(&1 == "")), " | "),
          title: title
        }
      ]
    else
      []
    end
  end

  defp neodb_candidate(_item, _category), do: []

  defp culture_category(nil), do: {:ok, "movie"}

  defp culture_category(category) when is_binary(category) do
    case Map.fetch(@culture_categories, category) do
      {:ok, remote_category} -> {:ok, remote_category}
      :error -> {:error, :invalid_category}
    end
  end

  defp culture_category(_category), do: {:error, :invalid_category}

  defp bookwyrm_candidate(item) when is_map(item) do
    id = discovery_value(item, :id)
    title = bounded_string(discovery_value(item, :title), 300)
    source_url = discovery_value(item, :url)
    source_host = bounded_string(discovery_value(item, :source_host), 255)
    credits = discovery_value(item, :credits)

    authors =
      if is_list(credits) do
        credits
        |> Enum.flat_map(fn credit ->
          if discovery_value(credit, :role) == "author" do
            case bounded_string(discovery_value(credit, :name), 100) do
              "" -> []
              name -> [name]
            end
          else
            []
          end
        end)
        |> Enum.take(4)
      else
        []
      end

    year = bounded_string(discovery_value(item, :year), 20)

    if is_binary(id) and title != "" and valid_http_url?(source_url) and
         Pleroma.BookShelfEntry.federatable_book_uri?(source_url) do
      fields =
        %{}
        |> maybe_put("author", Enum.join(authors, ", "))
        |> maybe_put("edition", year)

      [
        %{
          federatable: true,
          fields: fields,
          id: id,
          provider: "bookwyrm",
          provider_label:
            if(source_host == "", do: "BookWyrm", else: "BookWyrm at " <> source_host),
          reference_url: source_url,
          source_url: source_url,
          subtitle: Enum.join(Enum.reject([Enum.join(authors, ", "), year], &(&1 == "")), " | "),
          title: title
        }
      ]
    else
      []
    end
  end

  defp bookwyrm_candidate(_item), do: []

  defp merge_book_candidates(bookwyrm_candidates, metadata_candidates) do
    (bookwyrm_candidates ++ metadata_candidates)
    |> Enum.uniq_by(& &1.source_url)
    |> Enum.take(@result_limit)
  end

  defp discovery_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp valid_http_url?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) ->
        true

      _ ->
        false
    end
  end

  defp valid_http_url?(_value), do: false

  defp preferred_edition(%{"editions" => %{"docs" => [edition | _]}}) when is_map(edition),
    do: edition

  defp preferred_edition(_doc), do: %{}

  defp source_identity(edition, doc) do
    case open_library_id(edition["key"], "books", "M") do
      nil ->
        case open_library_id(doc["key"], "works", "W") do
          nil -> nil
          id -> {id, "https://openlibrary.org/works/" <> id}
        end

      id ->
        {id, "https://openlibrary.org/books/" <> id}
    end
  end

  defp open_library_id(value, collection, suffix) when is_binary(value) do
    id = String.replace_prefix(value, "/#{collection}/", "")

    if Regex.match?(Regex.compile!("^OL[0-9]+#{suffix}$"), id), do: id
  end

  defp open_library_id(_value, _collection, _suffix), do: nil

  defp candidate_title(edition, doc) do
    bounded_string(edition["title"], 300) |> fallback_string(bounded_string(doc["title"], 300))
  end

  defp publication_label(edition, doc) do
    edition["publish_date"]
    |> first_string(60)
    |> fallback_string(year_string(doc["first_publish_year"]))
  end

  defp preferred_isbn(edition, doc) do
    (safe_strings(edition["isbn"], 20, 32) ++ safe_strings(doc["isbn"], 20, 32))
    |> Enum.map(&normalize_isbn/1)
    |> Enum.find(&valid_isbn?/1)
  end

  defp valid_isbn?(<<prefix::binary-size(3), _rest::binary>> = isbn)
       when prefix in ["978", "979"] and byte_size(isbn) == 13 do
    with {:ok, digits} <- decimal_digits(isbn),
         {body, [check_digit]} <- Enum.split(digits, 12) do
      weighted_sum =
        body
        |> Enum.with_index()
        |> Enum.reduce(0, fn {digit, index}, sum ->
          multiplier = if rem(index, 2) == 0, do: 1, else: 3
          sum + digit * multiplier
        end)

      rem(weighted_sum + check_digit, 10) == 0
    else
      _ -> false
    end
  end

  defp valid_isbn?(isbn) when byte_size(isbn) == 10 do
    {body, check_character} = String.split_at(isbn, 9)

    with {:ok, digits} <- decimal_digits(body),
         {:ok, check_digit} <- isbn_10_check_digit(check_character) do
      weighted_sum =
        digits
        |> Enum.zip(10..2//-1)
        |> Enum.reduce(0, fn {digit, multiplier}, sum ->
          sum + digit * multiplier
        end)

      rem(weighted_sum + check_digit, 11) == 0
    else
      _ -> false
    end
  end

  defp valid_isbn?(_isbn), do: false

  defp decimal_digits(value) do
    value
    |> String.to_charlist()
    |> Enum.reduce_while({:ok, []}, fn
      character, {:ok, digits} when character in ?0..?9 ->
        {:cont, {:ok, [character - ?0 | digits]}}

      _character, _accumulator ->
        {:halt, :error}
    end)
    |> case do
      {:ok, digits} -> {:ok, Enum.reverse(digits)}
      :error -> :error
    end
  end

  defp isbn_10_check_digit("X"), do: {:ok, 10}

  defp isbn_10_check_digit(character) do
    case decimal_digits(character) do
      {:ok, [digit]} -> {:ok, digit}
      _ -> :error
    end
  end

  defp preferred_language(edition, doc) do
    code =
      first_string(edition["language"], 12) |> fallback_string(first_string(doc["language"], 12))

    Map.get(@language_names, code, code)
  end

  defp provider_user_agent do
    contact = Config.get([:instance, :email])

    contact =
      if is_binary(contact) and contact != "", do: contact, else: Pleroma.Web.Endpoint.url()

    "#{Pleroma.Application.named_version()} (#{contact})"
  end

  defp safe_strings(values, count, length) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&bounded_string(&1, length))
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(count)
  end

  defp safe_strings(_values, _count, _length), do: []

  defp first_string(values, length) when is_list(values) do
    values |> Enum.find(&is_binary/1) |> bounded_string(length)
  end

  defp first_string(value, length), do: bounded_string(value, length)

  defp bounded_string(value, length) when is_binary(value) do
    if String.valid?(value), do: value |> String.trim() |> String.slice(0, length), else: ""
  end

  defp bounded_string(_value, _length), do: ""

  defp fallback_string("", fallback), do: fallback
  defp fallback_string(value, _fallback), do: value

  defp year_string(value) when is_integer(value) and value >= 0 and value <= 9999,
    do: Integer.to_string(value)

  defp year_string(_value), do: ""

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

# end of lib/pleroma/web/activity_pub/native_catalog.ex
