# Unfathomably: ActivityPub quote hydration
#
# File: quote_hydration.ex

# Purpose:
#   Hydrate uncached quoted objects without blocking incoming federation.

# Responsibilities:
#   - enqueue deduplicated quote fetches after a quoting object is stored
#   - reconcile pending quote authorization and counters after hydration

# This file intentionally does NOT normalize ActivityPub wire data or render
# Mastodon API statuses.

defmodule Pleroma.QuoteHydration do
  @moduledoc """
  Coordinates asynchronous hydration of quoted ActivityPub objects.
  """

  import Ecto.Query

  alias Pleroma.Object
  alias Pleroma.QuoteAuthorization
  alias Pleroma.Repo
  alias Pleroma.Workers.RemoteFetcherWorker

  @reconciliation_limit 500

  def maybe_enqueue(
        %Object{data: %{"quoteUrl" => quote_url}},
        false,
        depth
      )
      when is_binary(quote_url) and quote_url != "" do
    if is_nil(Object.get_by_ap_id(quote_url)) do
      %{
        "op" => "fetch_quote",
        "id" => quote_url,
        "depth" => normalize_depth(depth)
      }
      |> RemoteFetcherWorker.new()
      |> Oban.insert()
    else
      {:ok, :cached}
    end
  end

  def maybe_enqueue(_object, _quote_counted?, _depth), do: {:ok, :ignored}

  def reconcile(quote_url) when is_binary(quote_url) do
    Object
    # Keep the comparison in JSONB form so objects_quote_url can answer the
    # reconciliation lookup without scanning the entire objects table.
    |> where(
      [object],
      fragment("?->'quoteUrl' = to_jsonb(CAST(? AS text))", object.data, ^quote_url)
    )
    |> limit(@reconciliation_limit)
    |> Repo.all()
    |> Enum.each(&register_hydrated_quote/1)

    :ok
  end

  def reconcile(_quote_url), do: :ok

  defp register_hydrated_quote(%Object{} = object) do
    case QuoteAuthorization.register(object, false) do
      {:ok, _object, true} -> Object.increase_quotes_count(object.data["quoteUrl"])
      _other -> :ok
    end
  end

  defp normalize_depth(depth) when is_integer(depth) and depth >= 0, do: depth
  defp normalize_depth(_depth), do: 0
end

# end of quote_hydration.ex
