defmodule Pleroma.Repo.Migrations.CreateBookmarkFolders do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:bookmark_folders, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :string, null: false)
      add(:emoji, :string)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all))

      timestamps()
    end

    alter table(:bookmarks) do
      add_if_not_exists(
        :folder_id,
        references(:bookmark_folders, type: :uuid, on_delete: :nilify_all)
      )
    end

    create_if_not_exists(unique_index(:bookmark_folders, [:user_id, :name]))
  end
end
