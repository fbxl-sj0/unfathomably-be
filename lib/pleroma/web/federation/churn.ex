# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Federation.Churn do
  @moduledoc """
  Small helpers for routine ActivityPub failure classification.

  Federation produces a steady stream of expected rejects: dead actors,
  deleted objects, protocol extensions that this server does not persist, and
  forwarded activities whose HTTP signature does not match the logical actor.

  This module keeps those cases explicit so the rest of the pipeline can keep
  enforcing the protocol while still learning useful local state from the
  failures.
  """

  import Ecto.Changeset, only: [get_field: 2]

  alias Pleroma.User

  @signature_retry_reasons [
    :actor_signature_mismatch,
    :host_header_mismatch,
    :invalid_signature,
    :origin_containment_failed,
    :invalid_signature_retry_metadata,
    :missing_signature_retry_metadata
  ]

  @type signature_retry_category ::
          :forwarded_download_activity
          | :forwarded_view_activity
          | :signature_actor_mismatch
          | :host_header_mismatch
          | :invalid_signature
          | :origin_containment_failed
          | :metadata_error
          | :unknown

  @spec logged_signature_retry_reason?(atom()) :: boolean()
  def logged_signature_retry_reason?(reason), do: reason in @signature_retry_reasons

  @spec signature_retry_category(atom(), map()) :: signature_retry_category()
  def signature_retry_category(:actor_signature_mismatch, %{type: "View"}),
    do: :forwarded_view_activity

  def signature_retry_category(:actor_signature_mismatch, %{type: "Download"}),
    do: :forwarded_download_activity

  def signature_retry_category(:actor_signature_mismatch, _context),
    do: :signature_actor_mismatch

  def signature_retry_category(:host_header_mismatch, _context), do: :host_header_mismatch

  def signature_retry_category(:invalid_signature, _context), do: :invalid_signature

  def signature_retry_category(:origin_containment_failed, _context),
    do: :origin_containment_failed

  def signature_retry_category(reason, _context)
      when reason in [:invalid_signature_retry_metadata, :missing_signature_retry_metadata],
      do: :metadata_error

  def signature_retry_category(_reason, _context), do: :unknown

  @spec signature_retry_log_level(atom(), map()) :: Logger.level()
  def signature_retry_log_level(:actor_signature_mismatch, %{type: "View"}), do: :debug
  def signature_retry_log_level(:actor_signature_mismatch, %{type: "Download"}), do: :debug

  def signature_retry_log_level(reason, _context)
      when reason in [
             :actor_signature_mismatch,
             :host_header_mismatch,
             :invalid_signature,
             :origin_containment_failed
           ],
      do: :info

  def signature_retry_log_level(reason, _context)
      when reason in [:invalid_signature_retry_metadata, :missing_signature_retry_metadata],
      do: :warning

  def signature_retry_log_level(_reason, _context), do: :debug

  @spec mark_deactivated_actor(any(), any()) :: {:ok, String.t()} | :noop
  def mark_deactivated_actor(error, _source_id \\ nil) do
    with {:ok, actor_id} <- deactivated_actor_id(error),
         %User{local: false} = user <- User.get_cached_by_ap_id(actor_id),
         {:ok, _user} <- User.set_remote_deactivated(user) do
      {:ok, actor_id}
    else
      _ -> :noop
    end
  end

  @spec deactivated_actor_id(any()) :: {:ok, String.t()} | :error
  def deactivated_actor_id(error) do
    with %Ecto.Changeset{} = changeset <- find_changeset(error),
         true <- actor_deactivated_error?(changeset),
         actor_id when is_binary(actor_id) and actor_id != "" <- changeset_actor(changeset) do
      {:ok, actor_id}
    else
      _ -> :error
    end
  end

  defp actor_deactivated_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:actor, {"user is deactivated", _opts}} -> true
      _ -> false
    end)
  end

  defp changeset_actor(%Ecto.Changeset{} = changeset) do
    params = changeset.params || %{}

    get_field(changeset, :actor) ||
      changeset.changes[:actor] ||
      params["actor"] ||
      params[:actor]
  end

  defp find_changeset(%Ecto.Changeset{} = changeset), do: changeset

  defp find_changeset(%_{}), do: nil

  defp find_changeset({:error, value}), do: find_changeset(value)

  defp find_changeset({left, right}), do: find_changeset(left) || find_changeset(right)

  defp find_changeset(list) when is_list(list), do: Enum.find_value(list, &find_changeset/1)

  defp find_changeset(map) when is_map(map) do
    Enum.find_value(map, fn {_key, value} -> find_changeset(value) end)
  end

  defp find_changeset(_), do: nil
end

# end of churn.ex
