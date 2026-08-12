# Pleroma: A lightweight social networking server
# Copyright (c) 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Repo.Migrations.AddPkceToOAuthAuthorizations do
  use Ecto.Migration

  def change do
    alter table(:oauth_authorizations) do
      add(:redirect_uri, :text)
      add(:code_challenge, :string, size: 128)
      add(:code_challenge_method, :string, size: 8)
    end
  end
end

# end of 20260807120000_add_pkce_to_oauth_authorizations.exs
