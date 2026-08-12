# Unfathomably federated reading discovery
# -----------------------------------------
#
# File: reading_discovery.ex
#
# Purpose:
#   Search public BookWyrm-style reading objects already received through
#   normal federation.
#
# Responsibilities:
#   - limit discovery to public Create activities
#   - recognize reviews, commentary, quotations, ratings, shelves, and lists
#   - expose stable object, book, and actor URLs for local resolution
#   - paginate without contacting any remote reading community
#
# This file intentionally does not crawl BookWyrm instances, expose non-public
# shelves, infer reading history, or import objects merely because they match.

defmodule Pleroma.Web.ActivityPub.ReadingDiscovery do
  import Ecto.Query

  require Pleroma.Constants

  alias Pleroma.Activity
  alias Pleroma.Constants
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.User

  @max_limit 20
  @max_offset 5_000
  @max_query_length 200
  @max_object_candidates @max_offset + @max_limit + 1
  @query_timeout 15_000

  @spec search(map()) :: map()
  def search(params) when is_map(params) do
    query = params |> value("q") |> normalize_query()
    limit = params |> value("limit") |> bounded_integer(16, 1, @max_limit)
    offset = params |> value("offset") |> bounded_integer(0, 0, @max_offset)
    matching_book_ids = matching_book_ids(query)
    object_ids = matching_reading_object_ids(query, matching_book_ids)

    rows =
      case object_ids do
        [] ->
          []

        object_ids ->
          object_ids
          |> reading_query(limit + 1, offset)
          |> Repo.all(timeout: @query_timeout)
      end

    has_more = length(rows) > limit
    page_rows = Enum.take(rows, limit)
    book_contexts = page_rows |> referenced_book_urls() |> load_book_contexts()
    actor_labels = page_rows |> referenced_actor_urls() |> load_actor_labels()

    items =
      page_rows
      |> Enum.map(fn {_activity, object} ->
        normalize_object(object.data, book_contexts, actor_labels)
      end)
      |> Enum.reject(&is_nil/1)

    response(query, offset, limit, items, has_more)
  end

  defp response(query, offset, limit, items, has_more) do
    %{
      family: "reading",
      query: query,
      count: length(items),
      items: items,
      providers: [
        %{
          type: "local_federation_cache",
          host: local_host(),
          status: "ready"
        }
      ],
      has_more: has_more,
      next_offset: if(has_more, do: offset + limit, else: nil)
    }
  end

  # Reading objects are rare compared with ordinary ActivityPub Creates. Find
  # their object identifiers first through the existing JSONB GIN index, then
  # use the activity object's expression index for the visibility join. This
  # ordering avoids scanning millions of recent activities when no BookWyrm
  # reading records have reached the instance yet.
  defp matching_reading_object_ids(query, matching_book_ids) do
    reading_object_query()
    |> maybe_search(query, matching_book_ids)
    |> order_by([object: object], desc: object.id)
    |> limit(^@max_object_candidates)
    |> select([object: object], fragment("?->>'id'", object.data))
    |> Repo.all(timeout: @query_timeout)
    |> Enum.filter(&is_binary/1)
  end

  defp reading_object_query do
    from(object in Object,
      as: :object,
      where:
        ((fragment(~S|? @> '{"type":"Review"}'::jsonb|, object.data) or
            fragment(~S|? @> '{"type":"Comment"}'::jsonb|, object.data) or
            fragment(~S|? @> '{"type":"Quotation"}'::jsonb|, object.data) or
            fragment(~S|? @> '{"type":"Rating"}'::jsonb|, object.data) or
            fragment(~S|? @> '{"type":"Article"}'::jsonb|, object.data) or
            fragment(~S|? @> '{"type":"Note"}'::jsonb|, object.data) or
            fragment(~S|? @> '{"type":"ShelfItem"}'::jsonb|, object.data) or
            fragment(~S|? @> '{"type":"ListItem"}'::jsonb|, object.data) or
            fragment(~S|? @> '{"type":"SuggestionListItem"}'::jsonb|, object.data)) and
           (fragment("?->>'inReplyToBook' IS NOT NULL", object.data) or
              fragment("?->>'book' IS NOT NULL", object.data))) or
          fragment(~S|? @> '{"type":"Shelf"}'::jsonb|, object.data) or
          fragment(~S|? @> '{"type":"BookList"}'::jsonb|, object.data) or
          fragment(~S|? @> '{"type":"SuggestionList"}'::jsonb|, object.data)
    )
  end

  defp reading_query(object_ids, limit, offset) do
    Activity
    |> from(as: :activity)
    |> where(
      [activity: activity],
      fragment("?->>'type' = 'Create'", activity.data) and
        ^Constants.as_public() in activity.recipients
    )
    |> where(
      [activity: activity],
      fragment("associated_object_id(?)", activity.data) in ^object_ids
    )
    |> Activity.with_joined_object()
    |> order_by([activity: activity], desc: activity.id)
    |> limit(^limit)
    |> offset(^offset)
    |> select([activity: activity, object: object], {activity, object})
  end

  defp maybe_search(query, "", _matching_book_ids), do: query

  defp maybe_search(query, search, []) do
    where(
      query,
      [object: object],
      fragment(
        "unfathomably_reading_search_document(?) @@ websearch_to_tsquery('simple', ?)",
        object.data,
        ^search
      )
    )
  end

  defp maybe_search(query, search, matching_book_ids) do
    where(
      query,
      [object: object],
      fragment(
        "unfathomably_reading_search_document(?) @@ websearch_to_tsquery('simple', ?)",
        object.data,
        ^search
      ) or
        fragment("?->>'inReplyToBook'", object.data) in ^matching_book_ids or
        fragment("?->>'book'", object.data) in ^matching_book_ids
    )
  end

  defp normalize_object(data, book_contexts, actor_labels) when is_map(data) do
    type = value(data, "type")
    id = value(data, "id") |> safe_url()
    url = (reference_url(value(data, "url")) || id) |> safe_url()

    actor_url = actor_reference(data)

    book_url = direct_book_url(data)
    book_urls = collection_book_urls(data)
    content_warning = value(data, "summary") |> plain_text(500)
    content = value(data, "content") |> plain_text(1_500)

    title = reading_title(data, type)

    if type && id && url && title do
      %{
        id: id,
        family: "books",
        kind: reading_kind(data, type),
        object_type: type,
        title: title,
        summary: content || content_warning,
        content_warning: content_warning,
        sensitive:
          value(data, "sensitive") == true or
            (is_binary(content_warning) and is_binary(content)),
        quote: value(data, "quote") |> plain_text(1_000),
        url: url,
        activitypub_url: id,
        actor_url: actor_url,
        actor_label: Map.get(actor_labels, actor_url) || actor_label(actor_url),
        collection_url: reference_url(value(data, "partOf")) |> safe_url(),
        item_count: nonnegative_integer(value(data, "totalItems")),
        known_item_count: collection_item_count(data),
        book_url: book_url,
        conversation_root_url: book_url,
        reply_to_url: reference_url(value(data, "inReplyTo")) |> safe_url(),
        book: Map.get(book_contexts, book_url),
        book_urls: book_urls,
        books: Enum.map(book_urls, &Map.get(book_contexts, &1)) |> Enum.reject(&is_nil/1),
        position:
          nonnegative_integer(value(data, "position")) ||
            nonnegative_integer(value(data, "order")),
        position_mode: value(data, "positionMode") |> short_text(40),
        progress: numeric_value(value(data, "progress")),
        progress_mode: value(data, "progressMode") |> short_text(40),
        rating: numeric_value(value(data, "rating")),
        rating_best: numeric_value(value(data, "ratingBest")) || 5,
        reading_status: value(data, "readingStatus") |> short_text(80),
        published_at: (value(data, "published") || value(data, "updated")) |> short_text(80),
        source_host: source_host(id),
        local_action: "resolve"
      }
    end
  end

  defp normalize_object(_data, _book_contexts, _actor_labels), do: nil

  # BookWyrm serializes Review as Article and Comment or Quotation as Note for
  # software that does not advertise BookWyrm's extension vocabulary. The
  # explicit book relationship keeps these compatibility forms distinct from
  # ordinary social posts.
  defp reading_kind(data, type) when type in ["Article", "Note"] do
    cond do
      is_binary(value(data, "quote")) -> "quotation"
      not is_nil(numeric_value(value(data, "rating"))) and type == "Article" -> "review"
      not is_nil(numeric_value(value(data, "rating"))) -> "rating"
      type == "Article" -> "review"
      true -> "comment"
    end
  end

  defp reading_kind(_data, "Review"), do: "review"
  defp reading_kind(_data, "Comment"), do: "comment"
  defp reading_kind(_data, "Quotation"), do: "quotation"
  defp reading_kind(_data, "Rating"), do: "rating"
  defp reading_kind(_data, "Shelf"), do: "shelf"
  defp reading_kind(_data, "BookList"), do: "book_list"
  defp reading_kind(_data, "SuggestionList"), do: "suggestion_list"
  defp reading_kind(_data, "ShelfItem"), do: "shelf_item"
  defp reading_kind(_data, "ListItem"), do: "list_item"
  defp reading_kind(_data, "SuggestionListItem"), do: "suggestion_item"
  defp reading_kind(_data, _type), do: "reading"

  defp reading_title(data, type) do
    case value(data, "name") |> short_text(300) do
      nil -> default_title(type)
      title -> title
    end
  end

  defp default_title("Review"), do: "Book review"
  defp default_title("Comment"), do: "Book comment"
  defp default_title("Quotation"), do: "Book quotation"
  defp default_title("Rating"), do: "Book rating"
  defp default_title("Shelf"), do: "Reading shelf"
  defp default_title("BookList"), do: "Book list"
  defp default_title("SuggestionList"), do: "Reading suggestions"
  defp default_title("ShelfItem"), do: "Shelf entry"
  defp default_title("ListItem"), do: "Book-list entry"
  defp default_title("SuggestionListItem"), do: "Suggested book"
  defp default_title(_type), do: nil

  defp matching_book_ids(""), do: []

  defp matching_book_ids(search) do
    Object
    |> where(
      [object],
      fragment("?->>'type'", object.data) in ["Book", "Edition", "Work"]
    )
    |> where(
      [object],
      fragment(
        "unfathomably_book_search_document(?) @@ websearch_to_tsquery('simple', ?)",
        object.data,
        ^search
      )
    )
    |> select([object], fragment("?->>'id'", object.data))
    |> limit(200)
    |> Repo.all()
    |> Enum.filter(&is_binary/1)
  end

  defp referenced_book_urls(rows) do
    rows
    |> Enum.flat_map(fn {_activity, object} ->
      [direct_book_url(object.data) | collection_book_urls(object.data)]
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(160)
  end

  defp referenced_actor_urls(rows) do
    rows
    |> Enum.map(fn {_activity, object} -> actor_reference(object.data) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(@max_limit)
  end

  defp load_actor_labels([]), do: %{}

  defp load_actor_labels(actor_urls) do
    User
    |> where([user], user.ap_id in ^actor_urls)
    |> select([user], {user.ap_id, user.name, user.nickname})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {ap_id, name, nickname}, labels ->
      label = plain_text(name, 200) || short_text(nickname, 200) || actor_label(ap_id)

      if label do
        Map.put(labels, ap_id, label)
      else
        labels
      end
    end)
  end

  defp actor_reference(data) do
    (reference_url(value(data, "actor")) ||
       reference_url(value(data, "attributedTo")) ||
       reference_url(value(data, "owner")))
    |> safe_url()
  end

  defp direct_book_url(data) do
    (reference_url(value(data, "inReplyToBook")) || reference_url(value(data, "book")))
    |> safe_url()
  end

  defp load_book_contexts([]), do: %{}

  defp load_book_contexts(book_urls) do
    books =
      Object
      |> where([object], fragment("?->>'id'", object.data) in ^book_urls)
      |> where(
        [object],
        fragment("?->>'type'", object.data) in ["Book", "Edition", "Work"]
      )
      |> select([object], object.data)
      |> Repo.all()

    author_names =
      books
      |> Enum.flat_map(&reference_urls(value(&1, "authors")))
      |> Enum.uniq()
      |> Enum.take(200)
      |> load_author_names()

    Enum.reduce(books, %{}, fn data, contexts ->
      case normalize_book_context(data, author_names) do
        %{id: id} = context -> Map.put(contexts, id, context)
        _context -> contexts
      end
    end)
  end

  defp load_author_names([]), do: %{}

  defp load_author_names(author_urls) do
    Object
    |> where([object], fragment("?->>'id'", object.data) in ^author_urls)
    |> where([object], fragment("?->>'type' = 'Author'", object.data))
    |> select([object], object.data)
    |> Repo.all()
    |> Enum.reduce(%{}, fn data, names ->
      with id when is_binary(id) <- value(data, "id") |> safe_url(),
           name when is_binary(name) <- value(data, "name") |> short_text(200) do
        Map.put(names, id, name)
      else
        _author -> names
      end
    end)
  end

  defp normalize_book_context(data, author_names) do
    id = value(data, "id") |> safe_url()
    type = value(data, "type")
    title = value(data, "title") |> short_text(300)
    author_urls = reference_urls(value(data, "authors")) |> Enum.take(8)

    if id && type in ["Book", "Edition", "Work"] && title do
      %{
        id: id,
        type: String.downcase(type),
        title: title,
        subtitle: value(data, "subtitle") |> short_text(300),
        authors:
          Enum.map(author_urls, fn url ->
            %{url: url, name: Map.get(author_names, url)}
          end),
        work_url: reference_url(value(data, "work")) |> safe_url(),
        isbn_10: value(data, "isbn10") |> short_text(32),
        isbn_13: value(data, "isbn13") |> short_text(32),
        catalogue_links: catalogue_links(data),
        pages: nonnegative_integer(value(data, "pages")),
        physical_format:
          first_present([
            value(data, "physicalFormatDetail"),
            value(data, "physicalFormat")
          ])
          |> short_text(120),
        publishers: text_list(value(data, "publishers"), 6, 160),
        languages: text_list(value(data, "languages"), 6, 40),
        subjects: text_list(value(data, "subjects"), 8, 100),
        published_date:
          first_present([value(data, "publishedDate"), value(data, "firstPublishedDate")])
          |> short_text(80)
      }
    end
  end

  defp catalogue_links(data) do
    [
      catalogue_link("Open Library", value(data, "openlibraryKey"), &open_library_url/1),
      catalogue_link("Inventaire", value(data, "inventaireId"), &inventaire_url/1),
      catalogue_link("Finna", value(data, "finnaKey"), &finna_url/1),
      catalogue_link("LibraryThing", value(data, "librarythingKey"), &librarything_url/1),
      catalogue_link("Goodreads", value(data, "goodreadsKey"), &goodreads_url/1),
      catalogue_link("Wikidata", value(data, "wikidata"), &wikidata_url/1),
      catalogue_link("VIAF", value(data, "viaf"), &viaf_url/1),
      catalogue_link("BnF", value(data, "bnfId"), &bnf_url/1)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp catalogue_link(label, identifier, url_builder) do
    with identifier when is_binary(identifier) <- short_text(identifier, 255),
         url when is_binary(url) <- url_builder.(String.trim(identifier)),
         url when is_binary(url) <- safe_url(url) do
      %{label: label, url: url}
    else
      _ -> nil
    end
  end

  defp open_library_url("/works/" <> _rest = key), do: "https://openlibrary.org" <> key
  defp open_library_url("/books/" <> _rest = key), do: "https://openlibrary.org" <> key

  defp open_library_url(key) do
    cond do
      Regex.match?(~r/^OL[0-9]+W$/i, key) ->
        "https://openlibrary.org/works/" <> path_segment(key)

      Regex.match?(~r/^OL[0-9]+M$/i, key) ->
        "https://openlibrary.org/books/" <> path_segment(key)

      true ->
        nil
    end
  end

  defp inventaire_url(identifier),
    do: identifier_url("https://inventaire.io/entity/", identifier)

  defp finna_url(identifier), do: identifier_url("https://www.finna.fi/Record/", identifier)

  defp librarything_url(identifier),
    do: identifier_url("https://www.librarything.com/work/", identifier)

  defp goodreads_url(identifier),
    do: identifier_url("https://www.goodreads.com/book/show/", identifier)

  defp wikidata_url(identifier),
    do: identifier_url("https://www.wikidata.org/wiki/", identifier)

  defp viaf_url(identifier), do: identifier_url("https://viaf.org/viaf/", identifier)

  defp bnf_url("ark:/12148/" <> identifier),
    do: identifier_url("https://catalogue.bnf.fr/ark:/12148/", identifier)

  defp bnf_url(identifier),
    do: identifier_url("https://catalogue.bnf.fr/ark:/12148/", identifier)

  defp identifier_url(_prefix, ""), do: nil
  defp identifier_url(prefix, identifier), do: prefix <> path_segment(identifier)

  defp path_segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp reference_urls(value) do
    value
    |> List.wrap()
    |> Enum.map(&reference_url/1)
    |> Enum.map(&safe_url/1)
    |> Enum.reject(&is_nil/1)
  end

  defp text_list(value, maximum_items, maximum_length) do
    value
    |> List.wrap()
    |> Enum.map(&short_text(&1, maximum_length))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(maximum_items)
  end

  defp first_present(values), do: Enum.find(values, &(not is_nil(&1) and &1 != ""))

  defp actor_label(nil), do: nil

  defp actor_label(url) do
    case URI.parse(url) do
      %URI{host: host, path: path} when is_binary(host) and is_binary(path) ->
        name =
          path
          |> String.trim("/")
          |> String.split("/")
          |> List.last()

        if is_binary(name) and name != "", do: "@" <> name <> "@" <> host

      _ ->
        nil
    end
  end

  defp reference_url(value) when is_binary(value), do: value
  defp reference_url(%{"id" => id}) when is_binary(id), do: id
  defp reference_url(%{"href" => href}) when is_binary(href), do: href
  defp reference_url(%{"url" => url}) when is_binary(url), do: url
  defp reference_url([first | _rest]), do: reference_url(first)
  defp reference_url(_value), do: nil

  defp numeric_value(value) when is_integer(value), do: value * 1.0
  defp numeric_value(value) when is_float(value), do: value

  defp numeric_value(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp numeric_value(_value), do: nil

  defp nonnegative_integer(value) when is_integer(value) and value >= 0, do: value

  defp nonnegative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> number
      _ -> nil
    end
  end

  defp nonnegative_integer(_value), do: nil

  defp collection_item_count(data) do
    case collection_items(data) do
      items when is_list(items) -> length(items)
      _items -> nil
    end
  end

  defp collection_book_urls(data) do
    data
    |> collection_items()
    |> List.wrap()
    |> Enum.map(fn
      %{} = item -> reference_url(value(item, "book")) |> safe_url()
      _item -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(8)
  end

  defp collection_items(data) do
    value(data, "orderedItems") ||
      value(data, "items") ||
      value(data, "_unfathomably_reading_members")
  end

  defp value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || existing_atom_value(map, key)
  end

  defp value(_map, _key), do: nil

  defp existing_atom_value(map, key) do
    case safe_existing_atom(key) do
      nil -> nil
      atom -> Map.get(map, atom)
    end
  end

  defp safe_existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp normalize_query(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.slice(0, @max_query_length)
  end

  defp normalize_query(_value), do: ""

  defp bounded_integer(value, default, minimum, maximum) do
    parsed =
      case value do
        integer when is_integer(integer) ->
          integer

        binary when is_binary(binary) ->
          case Integer.parse(binary) do
            {integer, ""} -> integer
            _ -> default
          end

        _ ->
          default
      end

    parsed
    |> max(minimum)
    |> min(maximum)
  end

  defp plain_text(value, maximum) when is_binary(value) do
    value
    |> String.replace(~r/<[^>]*>/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, maximum)
    |> empty_to_nil()
  end

  defp plain_text(_value, _maximum), do: nil

  defp short_text(value, maximum) when is_binary(value) do
    value
    |> String.trim()
    |> String.slice(0, maximum)
    |> empty_to_nil()
  end

  defp short_text(_value, _maximum), do: nil

  defp safe_url(value) when is_binary(value) do
    value = String.trim(value)

    case URI.parse(value) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        value

      _ ->
        nil
    end
  end

  defp safe_url(_value), do: nil

  defp source_host(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> String.downcase(host)
      _ -> ""
    end
  end

  defp local_host do
    Pleroma.Web.Endpoint.url()
    |> source_host()
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
end

# end of reading_discovery.ex
