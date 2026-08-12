# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.MRF.StealEmojiPolicy do
  require Logger

  alias Pleroma.Config
  alias Pleroma.Workers.StealEmojiWorker

  @moduledoc "Detect new emoji and queue allowlisted installations"
  @behaviour Pleroma.Web.ActivityPub.MRF.Policy

  @maximum_shortcode_bytes 100

  defp accept_host?(host) when is_binary(host) do
    host = String.downcase(host)

    Config.get([:mrf_steal_emoji, :hosts], [])
    |> Enum.any?(fn configured_host ->
      is_binary(configured_host) and String.downcase(configured_host) == host
    end)
  end

  defp accept_host?(_host), do: false

  defp shortcode_matches?(shortcode, pattern) when is_binary(pattern), do: shortcode == pattern
  defp shortcode_matches?(shortcode, %Regex{} = pattern), do: Regex.match?(pattern, shortcode)
  defp shortcode_matches?(_shortcode, _pattern), do: true

  @impl true
  def filter(%{"object" => %{"emoji" => foreign_emojis, "actor" => actor}} = activity)
      when is_list(foreign_emojis) or is_map(foreign_emojis) do
    host = Pleroma.Instances.host(actor)

    if host != Pleroma.Web.Endpoint.host() and accept_host?(host) do
      installed = Pleroma.Emoji.get_all() |> Enum.map(fn {shortcode, _url} -> shortcode end)

      foreign_emojis
      |> Enum.filter(fn
        {shortcode, url} when is_binary(shortcode) and is_binary(url) ->
          rejected? =
            Config.get([:mrf_steal_emoji, :rejected_shortcodes], [])
            |> Enum.any?(fn pattern -> shortcode_matches?(shortcode, pattern) end)

          shortcode not in installed and shortcode != "" and
            byte_size(shortcode) <= @maximum_shortcode_bytes and
            Path.basename(shortcode) == shortcode and
            not String.contains?(shortcode, ["/", "\\"]) and not rejected?

        _emoji ->
          false
      end)
      |> Enum.each(fn {shortcode, url} ->
        case StealEmojiWorker.enqueue(shortcode, url, host) do
          {:ok, _job} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Failed to enqueue remote emoji :#{shortcode}: from #{host}: #{inspect(reason)}"
            )
        end
      end)
    end

    {:ok, activity}
  end

  def filter(activity), do: {:ok, activity}

  @impl true
  def config_description do
    %{
      key: :mrf_steal_emoji,
      related_policy: "Pleroma.Web.ActivityPub.MRF.StealEmojiPolicy",
      label: "MRF Emojis",
      description: "Steals emojis from selected instances when it sees them.",
      children: [
        %{
          key: :hosts,
          type: {:list, :string},
          description: "List of hosts to steal emojis from",
          suggestions: [""]
        },
        %{
          key: :rejected_shortcodes,
          type: {:list, :string},
          description: "A list of exact shortcode strings or Regex patterns to reject.",
          suggestions: ["foo", ~r/foo/]
        },
        %{
          key: :size_limit,
          type: :integer,
          description: "File size limit (in bytes), checked before an emoji is saved to the disk",
          suggestions: ["100000"]
        }
      ]
    }
  end

  @impl true
  def describe, do: {:ok, %{}}
end

# end of steal_emoji_policy.ex
