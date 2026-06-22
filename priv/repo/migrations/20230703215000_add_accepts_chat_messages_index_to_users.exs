defmodule Pleroma.Repo.Migrations.AddAcceptsChatMessagesIndexToUsers do
  use Ecto.Migration

  def change do
    create_if_not_exists(index(:users, [:accepts_chat_messages]))
  end
end
