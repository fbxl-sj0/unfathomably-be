# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.PollOption do
  @moduledoc """
  Normalizes the plain-text names shared by Question options and Answer votes.

  Some ActivityPub producers HTML-escape poll labels even though `name` is a
  plain-text property. Decoding harmless entities in both validators keeps a
  remote vote comparable with the option it selects. Tag-bearing values are
  rejected before storage rather than interpreted or silently stripped.
  """

  def normalize_name(name) when is_binary(name), do: HtmlEntities.decode(name)
  def normalize_name(name), do: name

  def validate_name(changeset, field \\ :name) do
    Ecto.Changeset.validate_change(changeset, field, fn ^field, name ->
      if plain_text_name?(name), do: [], else: [{field, "must be plain text"}]
    end)
  end

  defp plain_text_name?(name) when is_binary(name) do
    decoded = HtmlEntities.decode(name)

    # The general HTML scrubber also normalizes some valid Unicode text. Poll
    # labels are plain strings, so parse them and reject actual markup rather
    # than comparing them with a transformed copy.
    case Floki.parse_fragment(decoded) do
      {:ok, nodes} -> Enum.all?(nodes, &is_binary/1)
      {:error, _reason} -> false
    end
  end

  defp plain_text_name?(_name), do: false
end

# end of poll_option.ex
