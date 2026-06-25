# Pleroma: A lightweight social networking server
# Copyright (C) 2017-2026 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.PleromaAPI.PostArchiveImportView do
  use Pleroma.Web, :view

  alias Pleroma.User.PostArchiveImport
  alias Pleroma.Web.CommonAPI.Utils

  def render("show.json", %{post_archive_import: %PostArchiveImport{} = import}) do
    %{
      id: import.id,
      content_type: import.content_type,
      file_name: import.file_name,
      file_size: import.file_size,
      state: to_string(import.state),
      processed_number: import.processed_number,
      total_items: import.total_items,
      imported_count: import.imported_count,
      original_actor: import.original_actor,
      error: import.error,
      approved_at: maybe_date(import.approved_at),
      inserted_at: Utils.to_masto_date(import.inserted_at)
    }
  end

  def render("index.json", %{post_archive_imports: imports}) do
    render_many(imports, __MODULE__, "show.json", as: :post_archive_import)
  end

  defp maybe_date(nil), do: nil
  defp maybe_date(date), do: Utils.to_masto_date(date)
end
