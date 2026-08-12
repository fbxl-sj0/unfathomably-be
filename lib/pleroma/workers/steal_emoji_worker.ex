# Unfathomably remote emoji maintenance
# --------------------------------------
# File: steal_emoji_worker.ex
# Purpose: Install allowlisted remote emoji without blocking federation.
# Responsibilities: Validate, deduplicate, download, and atomically install emoji.
# This file intentionally does NOT contain ActivityPub filtering or rendering.

defmodule Pleroma.Workers.StealEmojiWorker do
  use Oban.Worker,
    queue: :background,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete, keys: [:shortcode]]

  require Logger

  alias Pleroma.Config
  alias Pleroma.Emoji

  @maximum_shortcode_bytes 100
  @maximum_extension_bytes 8

  def enqueue(shortcode, url, source_host) do
    %{"shortcode" => shortcode, "url" => url, "source_host" => source_host}
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "shortcode" => shortcode,
          "url" => url,
          "source_host" => source_host
        }
      }) do
    with true <- eligible_source_host?(source_host),
         true <- eligible_shortcode?(shortcode),
         %URI{scheme: scheme, host: host, userinfo: userinfo} <- URI.parse(url),
         true <- scheme in ["http", "https"],
         true <- is_binary(host) and host != "",
         true <- userinfo in [nil, ""] do
      install(shortcode, url)
    else
      _ -> :discard
    end
  end

  def perform(%Oban.Job{}), do: :discard

  defp eligible_source_host?(source_host) when is_binary(source_host) do
    source_host = String.downcase(source_host)

    Config.get([:mrf_steal_emoji, :hosts], [])
    |> Enum.any?(fn host -> is_binary(host) and String.downcase(host) == source_host end)
  end

  defp eligible_source_host?(_source_host), do: false

  defp eligible_shortcode?(shortcode) when is_binary(shortcode) do
    shortcode != "" and byte_size(shortcode) <= @maximum_shortcode_bytes and
      Path.basename(shortcode) == shortcode and
      not String.contains?(shortcode, ["/", "\\"]) and
      not rejected_shortcode?(shortcode)
  end

  defp eligible_shortcode?(_shortcode), do: false

  defp rejected_shortcode?(shortcode) do
    Config.get([:mrf_steal_emoji, :rejected_shortcodes], [])
    |> Enum.any?(fn
      pattern when is_binary(pattern) -> shortcode == pattern
      %Regex{} = pattern -> Regex.match?(pattern, shortcode)
      _pattern -> true
    end)
  end

  defp install(shortcode, url) do
    emoji_dir_path =
      Config.get(
        [:mrf_steal_emoji, :path],
        Path.join(Config.get([:instance, :static_dir]), "emoji/stolen")
      )

    with :ok <- File.mkdir_p(emoji_dir_path) do
      lock = {{__MODULE__, emoji_dir_path, shortcode}, self()}

      case :global.trans(lock, fn -> install_under_lock(shortcode, url, emoji_dir_path) end) do
        {:aborted, reason} -> {:error, {:lock_failed, reason}}
        result -> result
      end
    end
  end

  defp install_under_lock(shortcode, url, emoji_dir_path) do
    if installed?(emoji_dir_path, shortcode),
      do: :ok,
      else: download_and_install(shortcode, url, emoji_dir_path)
  end

  defp installed?(emoji_dir_path, shortcode) do
    case File.ls(emoji_dir_path) do
      {:ok, files} -> Enum.any?(files, &(Path.rootname(&1) == shortcode))
      {:error, _reason} -> false
    end
  end

  defp download_and_install(shortcode, original_url, emoji_dir_path) do
    case Pleroma.HTTP.get(Pleroma.Web.MediaProxy.url(original_url)) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_binary(body) ->
        install_body(shortcode, original_url, body, emoji_dir_path)

      {:ok, %{status: status}} when status in [408, 425, 429] or status in 500..599 ->
        {:error, {:http_status, status}}

      {:ok, %{status: status}} ->
        Logger.debug(
          "Remote emoji #{Pleroma.Helpers.UriHelper.log_safe_url(original_url)} returned terminal HTTP #{status}"
        )

        :discard

      {:error, reason} ->
        Logger.warning(
          "Failed to fetch remote emoji #{Pleroma.Helpers.UriHelper.log_safe_url(original_url)}: #{Pleroma.Helpers.UriHelper.log_safe_text(reason)}"
        )

        {:error, reason}

      other ->
        Logger.warning(
          "Invalid remote emoji response for #{Pleroma.Helpers.UriHelper.log_safe_url(original_url)}: #{Pleroma.Helpers.UriHelper.log_safe_text(other)}"
        )

        {:error, :invalid_response}
    end
  end

  defp install_body(shortcode, original_url, body, emoji_dir_path) do
    size_limit = Config.get([:mrf_steal_emoji, :size_limit], 50_000)

    if byte_size(body) <= size_limit do
      file_path = Path.join(emoji_dir_path, shortcode <> safe_extension(original_url))
      temporary_path = file_path <> ".tmp-#{System.unique_integer([:positive])}"

      result =
        with :ok <- File.write(temporary_path, body, [:binary]),
             :ok <- File.rename(temporary_path, file_path) do
          Emoji.reload()
          Logger.info("Stole new emoji: :#{shortcode}:")
          :ok
        end

      _ = File.rm(temporary_path)
      result
    else
      Logger.debug(
        "Remote emoji :#{shortcode}: is #{byte_size(body)} B, over the #{size_limit} B limit"
      )

      :discard
    end
  end

  defp safe_extension(url) do
    extension =
      case URI.parse(url) do
        %URI{path: path} when is_binary(path) -> path |> Path.basename() |> Path.extname()
        _uri -> ""
      end

    if extension =~ ~r/^\.[A-Za-z0-9]{1,#{@maximum_extension_bytes}}$/,
      do: String.downcase(extension),
      else: ".png"
  end
end

# end of steal_emoji_worker.ex
