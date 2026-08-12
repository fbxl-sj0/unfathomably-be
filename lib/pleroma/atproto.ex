# Unfathomably BE
# ----------------
#
# File: atproto.ex
#
# Purpose:
#   Define the public boundary for selective AT Protocol interoperability.
#
# Responsibilities:
#   - expose feature metadata and unambiguous identity resolution
#   - enqueue committed local activities for linked-account publishing
#   - document the deliberately bounded storage model to clients
#
# This file intentionally does NOT run a relay, mirror a repository, or expose
# PDS authorization credentials.

defmodule Pleroma.ATProto do
  alias Pleroma.Activity
  alias Pleroma.ATProto.Identities
  alias Pleroma.Config
  alias Pleroma.Workers.ATProtoPublishWorker

  def enabled?, do: Config.get([__MODULE__, :enabled], false) == true

  def instance_metadata do
    if enabled?() do
      %{
        enabled: true,
        network: "bluesky",
        storage: "selective",
        retained_objects: ["followed", "explicit", "direct_interaction"],
        actions: ["post", "edit", "delete", "reply", "like", "repost", "quote", "follow"]
      }
    end
  end

  def resolve(identifier) when is_binary(identifier) do
    if enabled?() do
      identifier
      |> normalize_identifier()
      |> case do
        nil -> {:error, :not_found}
        value -> Identities.resolve(value)
      end
    else
      {:error, :not_found}
    end
  end

  def resolve(_identifier), do: {:error, :not_found}

  def maybe_enqueue_activity(%Activity{local: true} = activity, meta) do
    if enabled?() and not Keyword.get(meta, :atproto_ingest, false) do
      ATProtoPublishWorker.enqueue_activity(activity.id)
    end

    :ok
  end

  def maybe_enqueue_activity(_activity, _meta), do: :ok

  defp normalize_identifier(identifier) when byte_size(identifier) <= 2_048 do
    identifier = String.trim(identifier)

    cond do
      String.starts_with?(identifier, "did:") ->
        identifier

      String.starts_with?(identifier, "at:") ->
        identifier |> String.trim_leading("at:") |> String.trim_leading("@")

      String.starts_with?(identifier, "https://bsky.app/profile/") ->
        identifier
        |> String.trim_leading("https://bsky.app/profile/")
        |> String.split("/", parts: 2)
        |> List.first()

      true ->
        String.trim_leading(identifier, "@")
    end
  end

  defp normalize_identifier(_identifier), do: nil
end

# end of atproto.ex
