defmodule Pleroma.Repo.Migrations.AddPinnedToChats do
  use Ecto.Migration

  def change do
    alter table(:chats) do
      add(:pinned, :boolean, default: false)
    end
  end
end
