# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.MRF.KeywordPolicy do
  require Pleroma.Constants

  alias Pleroma.Web.ActivityPub.MRF.Utils

  @moduledoc "Reject or Word-Replace activities with a keyword or regex"

  @behaviour Pleroma.Web.ActivityPub.MRF.Policy

  @text_fields ~w[content summary name]
  @language_map_fields ~w[contentMap summaryMap nameMap]

  defp string_matches?(string, _) when not is_binary(string) do
    false
  end

  defp string_matches?(string, pattern) when is_binary(pattern) do
    String.contains?(normalize_match_text(string), normalize_match_text(pattern))
  end

  defp string_matches?(string, pattern) do
    String.match?(String.normalize(string, :nfkc), pattern)
  end

  defp normalize_match_text(value) do
    value
    |> String.normalize(:nfkc)
    |> String.downcase()
  end

  defp object_payload(%{} = object) do
    object_text_values(object)
    |> Enum.join("\n")
  end

  defp object_text_values(%{} = object) do
    scalar_values = Enum.map(@text_fields, &object[&1])

    language_map_values =
      Enum.flat_map(@language_map_fields, fn field ->
        case object[field] do
          values when is_map(values) -> Map.values(values)
          _ -> []
        end
      end)

    (scalar_values ++ language_map_values)
    |> Enum.filter(&is_binary/1)
  end

  defp has_text_payload?(%{} = object), do: object_text_values(object) != []

  defp replace_patterns(value, replacements) when is_binary(value) do
    Enum.reduce(replacements, value, fn {pattern, replacement}, acc ->
      String.replace(acc, pattern, replacement)
    end)
  end

  defp check_reject(%{"object" => %{} = object} = activity) do
    with {:ok, _new_object} <-
           Pleroma.Object.Updater.do_with_history(object, fn object ->
             payload = object_payload(object)

             if Enum.any?(Pleroma.Config.get([:mrf_keyword, :reject]), fn pattern ->
                  string_matches?(payload, pattern)
                end) do
               {:reject, "[KeywordPolicy] Matches with rejected keyword"}
             else
               {:ok, activity}
             end
           end) do
      {:ok, activity}
    else
      e -> e
    end
  end

  defp check_ftl_removal(%{"type" => "Create", "to" => to, "object" => %{} = object} = activity)
       when is_list(to) do
    check_keyword = fn object ->
      payload = object_payload(object)

      if Enum.any?(Pleroma.Config.get([:mrf_keyword, :federated_timeline_removal]), fn pattern ->
           string_matches?(payload, pattern)
         end) do
        {:should_delist, nil}
      else
        {:ok, %{}}
      end
    end

    should_delist? = fn object ->
      with {:ok, _} <- Pleroma.Object.Updater.do_with_history(object, check_keyword) do
        false
      else
        _ -> true
      end
    end

    if Pleroma.Constants.as_public() in to and should_delist?.(object) do
      to = List.delete(to, Pleroma.Constants.as_public())
      cc = [Pleroma.Constants.as_public() | activity["cc"] || []]

      activity =
        activity
        |> Map.put("to", to)
        |> Map.put("cc", cc)

      {:ok, activity}
    else
      {:ok, activity}
    end
  end

  defp check_ftl_removal(activity) do
    {:ok, activity}
  end

  defp check_replace(%{"object" => %{} = object} = activity) do
    replace_kw = fn object ->
      replacements = Pleroma.Config.get([:mrf_keyword, :replace])

      @text_fields
      |> Enum.reduce(object, fn field, object ->
        case object[field] do
          value when is_binary(value) ->
            Map.put(object, field, replace_patterns(value, replacements))

          _ ->
            object
        end
      end)
      |> then(fn object ->
        Enum.reduce(@language_map_fields, object, fn field, object ->
          case object[field] do
            values when is_map(values) ->
              values =
                Map.new(values, fn
                  {language, value} when is_binary(value) ->
                    {language, replace_patterns(value, replacements)}

                  entry ->
                    entry
                end)

              Map.put(object, field, values)

            _ ->
              object
          end
        end)
      end)
      |> (fn object -> {:ok, object} end).()
    end

    {:ok, object} = Pleroma.Object.Updater.do_with_history(object, replace_kw)

    activity = Map.put(activity, "object", object)

    {:ok, activity}
  end

  @impl true
  def filter(%{"type" => type, "object" => %{} = object} = activity)
      when type in ["Create", "Update"] do
    if has_text_payload?(object) do
      with {:ok, activity} <- check_reject(activity),
           {:ok, activity} <- check_ftl_removal(activity),
           {:ok, activity} <- check_replace(activity) do
        {:ok, activity}
      else
        {:reject, nil} -> {:reject, "[KeywordPolicy] "}
        {:reject, _} = e -> e
        _e -> {:reject, "[KeywordPolicy] "}
      end
    else
      {:ok, activity}
    end
  end

  @impl true
  def filter(activity), do: {:ok, activity}

  @impl true
  def describe do
    mrf_keyword =
      Pleroma.Config.get(:mrf_keyword, [])
      |> Enum.map(fn {key, value} ->
        {key,
         Enum.map(value, fn
           {pattern, replacement} ->
             %{
               "pattern" => Utils.describe_regex_or_string(pattern),
               "replacement" => replacement
             }

           pattern ->
             Utils.describe_regex_or_string(pattern)
         end)}
      end)
      |> Enum.into(%{})

    {:ok, %{mrf_keyword: mrf_keyword}}
  end

  @impl true
  def config_description do
    %{
      key: :mrf_keyword,
      related_policy: "Pleroma.Web.ActivityPub.MRF.KeywordPolicy",
      label: "MRF Keyword",
      description:
        "Reject or Word-Replace activities matching a keyword or [Regex](https://hexdocs.pm/elixir/Regex.html).",
      children: [
        %{
          key: :reject,
          type: {:list, :string},
          description: """
            A list of patterns which result in the activity being rejected.

            Each pattern can be a string or [Regex](https://hexdocs.pm/elixir/Regex.html) in the format of `~r/PATTERN/`.
          """,
          suggestions: ["foo", ~r/foo/iu]
        },
        %{
          key: :federated_timeline_removal,
          type: {:list, :string},
          description: """
            A list of patterns which result in the activity being removed from federated timelines (a.k.a unlisted).

            Each pattern can be a string or [Regex](https://hexdocs.pm/elixir/Regex.html) in the format of `~r/PATTERN/`.
          """,
          suggestions: ["foo", ~r/foo/iu]
        },
        %{
          key: :replace,
          type: {:list, :tuple},
          key_placeholder: "instance",
          value_placeholder: "reason",
          description: """
            **Pattern**: a string or [Regex](https://hexdocs.pm/elixir/Regex.html) in the format of `~r/PATTERN/`.

            **Replacement**: a string. Leaving the field empty is permitted.
          """
        }
      ]
    }
  end
end
