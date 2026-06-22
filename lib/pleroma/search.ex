defmodule Pleroma.Search do
  alias Pleroma.Object
  alias Pleroma.Workers.SearchIndexingWorker

  require Pleroma.Constants

  def add_to_index(%Pleroma.Activity{id: activity_id}) do
    SearchIndexingWorker.enqueue("add_to_index", %{"activity" => activity_id})
  end

  def remove_from_index(%Pleroma.Object{id: object_id}) do
    SearchIndexingWorker.enqueue("remove_from_index", %{"object" => object_id})
  end

  def search(query, options) do
    search_module = Pleroma.Config.get([Pleroma.Search, :module], Pleroma.Activity)

    search_module.search(options[:for_user], query, options)
  end

  def object_to_search_data(%Object{} = object) do
    data = object.data

    if search_indexable_object?(data) do
      content_str =
        case data["content"] do
          [nil | rest] -> to_string(rest)
          str -> str
        end

      content =
        with {:ok, scrubbed} <-
               FastSanitize.Sanitizer.scrub(content_str, Pleroma.HTML.Scrubber.SearchIndexing),
             trimmed <- String.trim(scrubbed) do
          trimmed
        end

      if content != "" do
        {:ok, published, _} = DateTime.from_iso8601(data["published"])

        %{
          id: object.id,
          content: content,
          ap: data["id"],
          published: DateTime.to_unix(published)
        }
      end
    end
  end

  def object_to_search_data(_), do: nil

  defp search_indexable_object?(
         %{"type" => "Note", "content" => content, "published" => published} = data
       )
       when not is_nil(content) and content not in ["", "."] and not is_nil(published) do
    to = Map.get(data, "to", [])
    cc = Map.get(data, "cc", [])

    Pleroma.Constants.as_public() in List.wrap(to) or
      Pleroma.Constants.as_public() in List.wrap(cc)
  end

  defp search_indexable_object?(_), do: false
end
