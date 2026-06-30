defmodule Pleroma.Web.RichMedia.Card do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Pleroma.Activity
  alias Pleroma.HTML
  alias Pleroma.Object
  alias Pleroma.Repo
  alias Pleroma.Web.RichMedia.Parser
  alias Pleroma.Workers.RichMediaWorker

  @cachex Pleroma.Config.get([:cachex, :provider], Cachex)
  @config_impl Application.compile_env(:pleroma, [__MODULE__, :config_impl], Pleroma.Config)

  @type t :: %Pleroma.Web.RichMedia.Card{}

  schema "rich_media_card" do
    field(:url_hash, :binary)
    field(:fields, :map)

    timestamps()
  end

  @doc false
  def changeset(card, attrs) do
    card
    |> cast(attrs, [:url_hash, :fields])
    |> validate_required([:url_hash, :fields])
    |> unique_constraint(:url_hash)
  end

  @spec create(String.t(), map()) :: {:ok, t()}
  def create(url, fields) do
    url_hash = url_to_hash(url)

    fields = Map.put_new(fields, "url", url)

    %Pleroma.Web.RichMedia.Card{}
    |> changeset(%{url_hash: url_hash, fields: fields})
    |> Repo.insert(on_conflict: {:replace, [:fields]}, conflict_target: :url_hash)
  end

  @spec delete(String.t()) :: {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()} | :ok
  def delete(url) do
    url_hash = url_to_hash(url)
    @cachex.del(:rich_media_cache, url_hash)

    case get_by_url(url) do
      %Pleroma.Web.RichMedia.Card{} = card -> Repo.delete(card)
      nil -> :ok
    end
  end

  @spec get_by_url(String.t() | nil) :: t() | nil | :error
  def get_by_url(url) when is_binary(url) do
    host = Pleroma.Instances.host(url)

    with true <- @config_impl.get([:rich_media, :enabled]),
         true <- is_binary(host),
         true <- host not in @config_impl.get([:rich_media, :ignore_hosts], []) do
      url_hash = url_to_hash(url)

      case @cachex.get(:rich_media_cache, url_hash) do
        {:ok, %Pleroma.Web.RichMedia.Card{} = card} ->
          card

        {:ok, :error} ->
          :error

        _ ->
          __MODULE__
          |> where(url_hash: ^url_hash)
          |> Repo.one()
          |> tap(fn
            %Pleroma.Web.RichMedia.Card{} = card -> @cachex.put(:rich_media_cache, url_hash, card)
            _ -> :ok
          end)
      end
    else
      _ -> :error
    end
  end

  def get_by_url(nil), do: nil

  @spec get_or_backfill_by_url(String.t(), keyword()) :: t() | nil
  def get_or_backfill_by_url(url, opts \\ []) do
    host = Pleroma.Instances.host(url)

    with true <- @config_impl.get([:rich_media, :enabled]),
         true <- is_binary(host),
         true <- host not in @config_impl.get([:rich_media, :ignore_hosts], []) do
      case get_by_url(url) do
        %Pleroma.Web.RichMedia.Card{} = card ->
          card

        nil ->
          activity_id = Keyword.get(opts, :activity_id, nil)
          opts = Keyword.get(opts, :opts, %{})
          stream = Map.get(opts, :stream, true)

          args = %{"op" => "backfill", "url" => url}
          args = if activity_id, do: Map.put(args, "activity_id", activity_id), else: args
          args = if stream == false, do: Map.put(args, "stream", false), else: args

          RichMediaWorker.new(args)
          |> Oban.insert()

          nil

        :error ->
          nil
      end
    else
      _ -> nil
    end
  end

  @spec get_by_object(Object.t()) :: t() | nil | :error
  def get_by_object(object) do
    case HTML.extract_first_external_url_from_object(object) do
      nil -> nil
      url -> get_or_backfill_by_url(url)
    end
  end

  @spec get_by_activity(Activity.t(), %{}) :: t() | nil | :error
  def get_by_activity(activity, opts \\ %{})

  # Fake/Draft activity
  def get_by_activity(%Activity{id: "pleroma:fakeid"} = activity, _opts) do
    with {_, true} <- {:config, @config_impl.get([:rich_media, :enabled])},
         %Object{} = object <- Object.normalize(activity, fetch: false),
         url when not is_nil(url) <- HTML.extract_first_external_url_from_object(object) do
      case get_by_url(url) do
        # Cache hit
        %Pleroma.Web.RichMedia.Card{} = card ->
          card

        # Cache miss, but fetch for rendering the Draft
        _ ->
          with {:ok, fields} <- Parser.parse(url),
               {:ok, card} <- create(url, fields) do
            card
          else
            _ -> nil
          end
      end
    else
      _ ->
        nil
    end
  end

  def get_by_activity(activity, opts) do
    with %Object{} = object <- Object.normalize(activity, fetch: false),
         {_, nil} <- {:cached, get_cached_url(object, activity.id)} do
      nil
    else
      {:cached, url} ->
        get_or_backfill_by_url(url, activity_id: activity.id, opts: opts)

      _ ->
        :error
    end
  end

  @spec url_to_hash(String.t()) :: String.t()
  def url_to_hash(url) do
    :crypto.hash(:sha256, url) |> Base.encode16(case: :lower)
  end

  defp get_cached_url(object, activity_id) do
    key = "URL|#{activity_id}"

    @cachex.fetch!(:scrubber_cache, key, fn _ ->
      url = HTML.extract_first_external_url_from_object(object)
      Activity.HTML.add_cache_key_for(activity_id, key)

      {:commit, url}
    end)
  end
end
