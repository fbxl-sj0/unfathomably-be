# Unfathomably BE
# ----------------
#
# File: type.ex
#
# Purpose:
#   Normalize ActivityStreams and JSON-LD type values at protocol boundaries.
#
# Responsibilities:
#   - accept the scalar and array forms permitted by JSON-LD
#   - prefer known concrete ActivityStreams types over generic base classes
#   - bound untrusted type arrays and values before dispatch
#
# This file intentionally does not validate complete objects or expand arbitrary
# JSON-LD contexts.

defmodule Pleroma.Web.ActivityPub.Type do
  @moduledoc false

  @generic_types MapSet.new(~w[
    Activity Collection CollectionPage IntransitiveActivity Object
    OrderedCollection OrderedCollectionPage
  ])
  @maximum_types 32
  @maximum_type_bytes 512
  @activity_streams_namespaces [
    "as:",
    "http://www.w3.org/ns/activitystreams#",
    "https://www.w3.org/ns/activitystreams#"
  ]

  @spec first_known(term(), [String.t()]) :: String.t() | nil
  def first_known(value, known_types) when is_list(known_types) do
    values =
      value
      |> List.wrap()
      |> Enum.filter(&(is_binary(&1) and &1 != "" and byte_size(&1) <= @maximum_type_bytes))
      |> Enum.uniq()
      |> Enum.take(@maximum_types)

    exact = Enum.find(known_types, &(&1 in values))

    activity_streams_alias =
      Enum.find_value(values, &known_activity_streams_type(&1, known_types))

    exact || activity_streams_alias ||
      Enum.find(values, &(not generic_type?(&1))) || List.first(values)
  end

  defp known_activity_streams_type(value, known_types) do
    if Enum.any?(@activity_streams_namespaces, &String.starts_with?(value, &1)) do
      short = value |> String.split(["#", "/", ":"], trim: true) |> List.last()
      Enum.find(known_types, &(&1 == short))
    end
  end

  defp generic_type?(value) do
    short = value |> String.split(["#", "/", ":"], trim: true) |> List.last()
    MapSet.member?(@generic_types, short)
  end
end

# end of type.ex
